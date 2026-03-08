#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Remove OpenStack Homelably from this server  (v4)
# =============================================================================
# WARNING: This is destructive and irreversible!
#
# Usage:
#   sudo bash uninstall.sh            # interactive
#   sudo bash uninstall.sh --dry-run  # preview only, no changes
# =============================================================================

set -euo pipefail

# ─── FLAGS ────────────────────────────────────────────────────────────────────
DRY_RUN=false
SELECTIVE=false
SELECTIVE_COMPONENTS=()
for arg in "$@"; do
    [[ "${arg}" == "--dry-run"   ]] && DRY_RUN=true
    [[ "${arg}" == "--selective" ]] && SELECTIVE=true
done
export DRY_RUN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try to source lib.sh and main.env — non-fatal if missing
if [[ -f "${SCRIPT_DIR}/scripts/lib.sh"    ]]; then source "${SCRIPT_DIR}/scripts/lib.sh"; fi
if [[ -f "${SCRIPT_DIR}/configs/main.env"  ]]; then source "${SCRIPT_DIR}/configs/main.env"; fi

# Fallback colours if lib.sh wasn't found
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── DRY-RUN ──────────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    if [[ "${arg}" == "--dry-run" ]]; then DRY_RUN=true; fi
done

if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "\n${CYAN}${BOLD}  ── DRY-RUN MODE — no changes will be made ──${NC}\n"
fi

run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

run_sql() {
    local sql="$1"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] mysql:${NC} ${sql}"
        return 0
    fi
    mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "${DB_PASS:-}") \
          -u root <<< "${sql}" 2>/dev/null || true
}

# ─── DETECT DISTRO & HARDWARE ─────────────────────────────────────────────────
if command -v detect_distro &>/dev/null; then
    detect_distro
else
    DISTRO_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
fi

HW=$(systemd-detect-virt 2>/dev/null || echo "unknown")
if [[ "${HW}" == "none" ]]; then HW="physical"; fi

# ─── GUARD: must be root ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}  ✖ ERROR:${NC} Must be run as root. Use: sudo bash uninstall.sh"
    exit 1
fi

# ─── BANNER ───────────────────────────────────────────────────────────────────
echo -e "${RED}"
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │   ⚠  WARNING — DESTRUCTIVE OPERATION                   │"
echo "  │                                                         │"
printf "  │   Host  : %-44s│\n" "$(hostname) (${HOST_IP:-unknown IP})"
printf "  │   OS    : %-44s│\n" "${DISTRO_ID} / hw: ${HW}"
echo "  │                                                         │"
echo "  │   ALL VMs, networks, images, databases, and configs     │"
echo "  │   will be permanently deleted.                          │"
echo "  └─────────────────────────────────────────────────────────┘"
echo -e "${NC}"

# ─── STEP 1: Confirm hostname ─────────────────────────────────────────────────
CURRENT_HOST=$(hostname)
echo -e "  ${YELLOW}Type this server's hostname to continue.${NC}"
echo -ne "  Hostname (${BOLD}${CURRENT_HOST}${NC}): "
read -r host_input

if [[ "${host_input}" != "${CURRENT_HOST}" ]]; then
    echo -e "\n  Hostname mismatch ('${host_input}' ≠ '${CURRENT_HOST}'). Aborted."
    exit 0
fi

# ─── STEP 2: Offer backup ─────────────────────────────────────────────────────
echo ""
echo -e "  ${YELLOW}Create a database backup before wiping?${NC}"
echo -e "  ${DIM}~30 seconds, saves SQL dumps to /var/backups/openstack-pre-uninstall/${NC}"
echo -ne "  Backup now? (Y/n): "
read -r backup_choice

if [[ ! "${backup_choice}" =~ ^[Nn]$ ]]; then
    BACKUP_DIR="/var/backups/openstack-pre-uninstall/$(date +%Y%m%d_%H%M%S)"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would create backup at ${BACKUP_DIR}${NC}"
    elif command -v mysqldump &>/dev/null; then
        mkdir -p "${BACKUP_DIR}"
        for db in keystone glance placement nova_api nova nova_cell0 neutron; do
            mysqldump \
                --defaults-extra-file=<(printf '[client]\npassword=%s\n' "${DB_PASS:-}") \
                -u root --single-transaction "${db}" \
                > "${BACKUP_DIR}/${db}.sql" 2>/dev/null || true
        done
        echo -e "  ${GREEN}✔${NC} Backup saved to ${BACKUP_DIR}"
    else
        echo -e "  ${YELLOW}  ⚠${NC} mysqldump not found — skipping backup."
    fi
fi

# ─── STEP 3: Final confirmation ───────────────────────────────────────────────
echo ""
echo -e "  ${RED}${BOLD}Last chance. Type  yes I am sure  to proceed:${NC} "
echo -ne "  > "
read -r final_confirm

if [[ "${final_confirm}" != "yes I am sure" ]]; then
    echo "  Aborted."
    exit 0
fi

echo ""
echo -e "  ${CYAN}Starting removal...${NC}"
echo ""

# ─── STEP 4: Stop services ────────────────────────────────────────────────────
echo -e "  Stopping OpenStack services..."

SERVICES=(
    nova-api nova-conductor nova-scheduler nova-compute nova-novncproxy
    neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent
    glance-api placement-api apache2 keystone
    rabbitmq-server memcached etcd
    mariadb mysql
    cinder-api cinder-scheduler cinder-volume
    swift-proxy heat-api heat-engine
    barbican-api octavia-api octavia-worker
    manila-api designate-central designate-api
)

for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "  ${DIM}[DRY-RUN]${NC} Would stop: ${svc}"
            _mark "service:${svc}" "skipped(dry-run)"
        else
            run systemctl stop "${svc}"
            run systemctl disable "${svc}" 2>/dev/null || true
            echo -e "  ${GREEN}✔${NC} Stopped: ${svc}"
            _mark "service:${svc}" "stopped"
        fi
    else
        _mark "service:${svc}" "not-running"
    fi
done

# ─── STEP 5: Remove packages ──────────────────────────────────────────────────
echo ""
echo -e "  Purging OpenStack packages..."

PKGS=(
    nova-api nova-conductor nova-scheduler nova-compute nova-novncproxy
    neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent
    glance placement-api keystone openstack-dashboard
    rabbitmq-server memcached etcd
    mariadb-server python3-openstackclient
    cinder-api cinder-scheduler cinder-volume
    swift swift-proxy heat-common barbican-api
    octavia-api octavia-worker manila-api designate-common
)

for pkg in "${PKGS[@]}"; do
    if dpkg -l "${pkg}" &>/dev/null 2>&1; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "  ${DIM}[DRY-RUN]${NC} Would purge: ${pkg}"
            _mark "package:${pkg}" "skipped(dry-run)"
        else
            run apt-get purge -y "${pkg}" 2>/dev/null || true
            _mark "package:${pkg}" "purged"
        fi
    else
        _mark "package:${pkg}" "not-installed"
    fi
done

run apt-get autoremove -y
echo -e "  ${GREEN}✔${NC} Packages removed."

# ─── STEP 6: Drop databases ───────────────────────────────────────────────────
echo ""
echo -e "  Dropping databases..."

for db in keystone glance placement nova_api nova nova_cell0 neutron; do
    run_sql "DROP DATABASE IF EXISTS ${db};"
    echo -e "  ${GREEN}✔${NC} Dropped: ${db}"
done

# ─── STEP 7: Remove config and data dirs ─────────────────────────────────────
echo ""
echo -e "  Removing config and data directories..."

DIRS=(
    /etc/nova /etc/neutron /etc/glance
    /etc/keystone /etc/placement /etc/openstack-dashboard
    /var/lib/nova /var/lib/neutron /var/lib/glance
    /var/lib/keystone /var/lib/placement
    /var/log/nova /var/log/neutron /var/log/glance /var/log/keystone
)

for dir in "${DIRS[@]}"; do
    if [[ -d "${dir}" ]]; then
        run rm -rf "${dir}"
        echo -e "  ${GREEN}✔${NC} Removed: ${dir}"
    fi
done

# ─── STEP 8: Clean up /etc/hosts ─────────────────────────────────────────────
echo ""
echo -e "  Cleaning /etc/hosts..."

if grep -q "# openstack-complete" /etc/hosts 2>/dev/null; then
    run sed -i '/# openstack-complete/d' /etc/hosts
    echo -e "  ${GREEN}✔${NC} Removed openstack-complete entries from /etc/hosts"
else
    echo -e "  ${DIM}No openstack-complete entries in /etc/hosts.${NC}"
fi

# ─── STEP 9: Remove cron jobs ─────────────────────────────────────────────────
echo ""
echo -e "  Removing cron jobs..."

for cron_file in \
    /etc/cron.d/openstack-monitor \
    /etc/cron.d/openstack-backup \
    /etc/cron.d/openstack-ssl-renew; do
    if [[ -f "${cron_file}" ]]; then
        run rm -f "${cron_file}"
        echo -e "  ${GREEN}✔${NC} Removed: ${cron_file}"
    fi
done

# ─── STEP 10: Optionally remove logs ─────────────────────────────────────────
if [[ -d "${SCRIPT_DIR}/logs" ]]; then
    echo ""
    echo -ne "  ${YELLOW}Remove deployment logs in ${SCRIPT_DIR}/logs/?${NC} (y/N): "
    read -r rm_logs
    if [[ "${rm_logs}" =~ ^[Yy]$ ]]; then
        run rm -rf "${SCRIPT_DIR}/logs"
        echo -e "  ${GREEN}✔${NC} Logs removed."
    else
        echo -e "  ${DIM}Logs kept at ${SCRIPT_DIR}/logs/${NC}"
    fi
fi

# ─── DONE ─────────────────────────────────────────────────────────────────────
echo ""
_print_removal_summary

if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "  ${CYAN}${BOLD}Dry-run complete.${NC} No changes were made."
    echo -e "  ${DIM}Re-run without --dry-run to perform the actual removal.${NC}"
else
    echo -e "  ${GREEN}${BOLD}✔ OpenStack has been fully removed from this server.${NC}"
    echo ""
    echo -e "  ${DIM}To reinstall:  sudo bash deploy.sh --wizard${NC}"
    echo -e "  ${DIM}Backups kept:  ${BACKUP_PATH:-/var/backups/openstack}${NC}"
fi
echo ""
