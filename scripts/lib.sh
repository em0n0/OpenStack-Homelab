#!/usr/bin/env bash
# =============================================================================
# lib.sh — Shared Helper Library  (v4)
# Sourced by every script in the project. Never run directly.
#
# Fixes vs v3:
#   • require_root() — use if/fi not &&  (set -e treats false && as error)
#   • detect_network_interfaces() — return 0 not count (non-zero = set -e crash)
#   • clear_checkpoints() — use if/fi not &&
#   • step_ran() — explicit return 1 on miss
#   • password length check — ${#val} not ${#!var} (invalid bash)
#   • require_internet() — if/fi not one-liner
# =============================================================================

# ─── COLOURS ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── DRY-RUN GLOBAL FLAG ──────────────────────────────────────────────────────
: "${DRY_RUN:=false}"

# ─── LOGGING ──────────────────────────────────────────────────────────────────
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()      { echo -e "${GREEN}  ✔${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}▸ $1${NC}\n${CYAN}$(printf '─%.0s' {1..55})${NC}"; }

error() {
    echo -e "${RED}  ✖ ERROR:${NC} $*" >&2
    if (( BASH_SUBSHELL > 0 )); then
        exit 1
    else
        return 1
    fi
}

# ─── DRY-RUN WRAPPERS ─────────────────────────────────────────────────────────
run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

run_mysql() {
    local sql="$1"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] mysql:${NC} ${sql}"
        return 0
    fi
    mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "${DB_PASS}") \
          -u root <<< "${sql}" 2>/dev/null
}

# ─── DISTRO DETECTION ─────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
        DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
        local id_like="${ID_LIKE:-}"
        if [[ "${DISTRO_ID}" == "debian" || "${id_like}" == *"debian"* || "${id_like}" == *"ubuntu"* ]]; then
            DISTRO_FAMILY="debian"
        else
            DISTRO_FAMILY="${DISTRO_ID}"
        fi
    else
        DISTRO_ID="unknown"; DISTRO_VERSION="unknown"
        DISTRO_CODENAME="unknown"; DISTRO_FAMILY="unknown"
    fi
    export DISTRO_ID DISTRO_VERSION DISTRO_CODENAME DISTRO_FAMILY
}

# ─── HARDWARE DETECTION ───────────────────────────────────────────────────────
detect_hardware_type() {
    if command -v systemd-detect-virt &>/dev/null; then
        local virt; virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        case "${virt}" in
            none)
                HARDWARE_TYPE="physical" ;;
            kvm|qemu|vmware|virtualbox|xen|hyperv|parallels|bhyve)
                HARDWARE_TYPE="vm" ;;
            docker|lxc*|openvz|podman|systemd-nspawn)
                HARDWARE_TYPE="container" ;;
            *)
                HARDWARE_TYPE="vm" ;;
        esac
    else
        HARDWARE_TYPE="unknown"
    fi
    export HARDWARE_TYPE

    if [[ "${HARDWARE_TYPE}" == "physical" ]]; then
        echo -e "\n${YELLOW}${BOLD}  ── Bare-Metal Deployment Detected ──${NC}"
        echo -e "  ${DIM}Things to verify before deploying on real hardware:${NC}"
        echo -e "   ${CYAN}•${NC} CPU virtualisation (VT-x / AMD-V) enabled in BIOS/UEFI"
        echo -e "   ${CYAN}•${NC} 2 NICs recommended — one management, one for VM traffic"
        echo -e "   ${CYAN}•${NC} NTP reachable — clock skew breaks Keystone token validation"
        echo -e "   ${CYAN}•${NC} IOMMU enabled for GPU/SR-IOV passthrough (optional)"
        echo ""
    fi
}

# ─── NETWORK INTERFACE DISCOVERY ──────────────────────────────────────────────
detect_network_interfaces() {
    DETECTED_IFACES=()
    local -a skip_prefixes=( lo docker virbr veth tun tap br- lxc lxd vnet dummy )

    while IFS= read -r iface; do
        local skip=false
        for pfx in "${skip_prefixes[@]}"; do
            if [[ "${iface}" == "${pfx}"* ]]; then
                skip=true
                break
            fi
        done
        if ${skip}; then continue; fi

        if [[ -e "/sys/class/net/${iface}/device" ]] || \
           [[ "$(cat /sys/class/net/${iface}/type 2>/dev/null)" == "1" ]]; then
            DETECTED_IFACES+=("${iface}")
        fi
    done < <(ls /sys/class/net/ 2>/dev/null | sort)

    export DETECTED_IFACES
    return 0   # always return 0 — non-zero would trigger set -e
}

print_iface_menu() {
    local i=1
    for iface in "${DETECTED_IFACES[@]}"; do
        local ip_addr; ip_addr=$(ip -4 addr show "${iface}" 2>/dev/null \
            | awk '/inet / {print $2}' | head -1)
        local state; state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
        local state_color="${GREEN}"
        if [[ "${state}" != "up" ]]; then state_color="${YELLOW}"; fi
        printf "   ${BOLD}%d${NC}  %-12s  %b%-8s${NC}  %s\n" \
            "${i}" "${iface}" "${state_color}" "${state}" "${ip_addr:-no IP assigned}"
        i=$(( i + 1 ))
    done
}

# ─── DISTRO-AWARE PACKAGE NAMES ───────────────────────────────────────────────
get_os_pkg() {
    local logical="$1"
    case "${logical}" in
        mariadb-server)      echo "mariadb-server" ;;
        python3-openstackclient) echo "python3-openstackclient" ;;
        openstack-dashboard) echo "openstack-dashboard" ;;
        *)                   echo "${logical}" ;;
    esac
}

# ─── GUARDS ───────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo bash $0"
    fi
}

require_debian_based() {
    detect_distro

    if [[ "${DISTRO_FAMILY}" != "debian" ]]; then
        error "A Debian-based distro is required (Ubuntu, Debian, Mint…). Detected: ${DISTRO_ID}"
    fi

    if ! command -v apt-get &>/dev/null; then
        error "apt-get not found. Cannot continue."
    fi

    if ! command -v systemctl &>/dev/null; then
        error "systemd is required but not found."
    fi

    local kernel_major kernel_minor
    IFS='.' read -r kernel_major kernel_minor _ <<< "$(uname -r)"
    if (( kernel_major < 5 || ( kernel_major == 5 && kernel_minor < 4 ) )); then
        warn "Kernel $(uname -r) is older than 5.4. Some Neutron features may not work."
    fi

    case "${DISTRO_ID}" in
        ubuntu)
            local major="${DISTRO_VERSION%%.*}"
            if (( major < 20 )); then
                warn "Ubuntu ${DISTRO_VERSION} is old. 20.04+ recommended."
            fi ;;
        debian)
            local major="${DISTRO_VERSION%%.*}"
            if (( major < 11 )); then
                warn "Debian ${DISTRO_VERSION} is old. Debian 11+ recommended."
            fi ;;
        linuxmint|pop|elementary|zorin)
            warn "${DISTRO_ID} ${DISTRO_VERSION} — community-supported, not fully tested." ;;
        raspbian|raspi)
            warn "Raspberry Pi OS — ARM64 with 8 GB+ RAM recommended." ;;
    esac

    ok "Distro: ${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_CODENAME}) [${DISTRO_FAMILY}]"
}

require_internet() {
    local connected=false
    for host in 8.8.8.8 1.1.1.1 9.9.9.9; do
        if ping -c 1 -W 3 "${host}" &>/dev/null; then
            connected=true
            break
        fi
    done
    if [[ "${connected}" != "true" ]]; then
        error "No internet connection detected."
    fi
}

# ─── CONFIG VALIDATION ────────────────────────────────────────────────────────
validate_config() {
    section "Pre-flight config validation"
    local issues=0

    if [[ -z "${HOST_IP:-}" ]]; then
        error "HOST_IP is empty. Run the Setup Wizard to configure it."; issues=$(( issues + 1 ))
    elif [[ "${HOST_IP}" == "__CHANGE_ME__" ]]; then
        error "HOST_IP could not be auto-detected and has not been set. Run the Setup Wizard."
        issues=$(( issues + 1 ))
    elif ! validate_ip "${HOST_IP}"; then
        error "HOST_IP '${HOST_IP}' is not a valid IPv4 address."; issues=$(( issues + 1 ))
    fi

    if [[ ! "${DEPLOY_MODE:-}" =~ ^(all-in-one|multi-node)$ ]]; then
        error "DEPLOY_MODE must be 'all-in-one' or 'multi-node'."; issues=$(( issues + 1 ))
    fi

    for var in ADMIN_PASS DB_PASS RABBIT_PASS SERVICE_PASS; do
        local val="${!var:-}"
        if [[ -z "${val}" ]]; then
            error "${var} is not set."; issues=$(( issues + 1 ))
        elif [[ "${#val}" -lt 12 ]]; then
            warn "${var} is short (${#val} chars). 16+ recommended."
        fi
    done

    if [[ -n "${ACME_EMAIL:-}" && "${ACME_EMAIL}" != *@* ]]; then
        warn "ACME_EMAIL doesn't look like a valid email address."
    fi

    local expected_version="4.0"
    if [[ "${CONFIG_VERSION:-0}" != "${expected_version}" ]]; then
        warn "main.env CONFIG_VERSION='${CONFIG_VERSION:-unset}', expected '${expected_version}'. Re-run wizard if settings are missing."
    fi

    if (( issues > 0 )); then
        error "Validation failed (${issues} error(s)). Fix configs/main.env before deploying."
    fi

    ok "Config validation passed."
}

# ─── SECRETS LOADER ───────────────────────────────────────────────────────────
safe_source_secrets() {
    local path="${1:-${PROJ:-$(pwd)}/configs/.secrets.env}"
    local enc_path="${path%.env}.enc"

    if [[ -f "${path}" ]]; then
        local perms
        perms=$(stat -c "%a" "${path}" 2>/dev/null || stat -f "%Lp" "${path}" 2>/dev/null)
        if [[ "${perms}" != "600" ]]; then
            warn "Secrets file permissions are ${perms}. Fixing to 600..."
            chmod 600 "${path}"
        fi
        # shellcheck disable=SC1090
        source "${path}"
        ok "Secrets loaded from ${path}"
    elif [[ -f "${enc_path}" ]]; then
        log "Encrypted secrets found. Enter master password to decrypt."
        local decrypted
        if ! decrypted=$(openssl enc -aes-256-cbc -pbkdf2 -d -in "${enc_path}" 2>/dev/null); then
            error "Failed to decrypt ${enc_path}. Wrong password?"
        fi
        # shellcheck disable=SC1090
        source <(echo "${decrypted}")
        ok "Secrets decrypted and loaded from ${enc_path}"
    else
        warn "No secrets file at ${path}. Using passwords from main.env."
    fi
}

# ─── DATABASE HELPERS ─────────────────────────────────────────────────────────
create_db() {
    local db="$1"
    log "Creating database: ${db}..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would create DB '${db}'.${NC}"
        return 0
    fi

    mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "${DB_PASS}") \
          -u root 2>/dev/null << EOF
CREATE DATABASE IF NOT EXISTS ${db};
GRANT ALL PRIVILEGES ON ${db}.* TO '${db}'@'localhost' IDENTIFIED BY '${SERVICE_PASS}';
GRANT ALL PRIVILEGES ON ${db}.* TO '${db}'@'%'         IDENTIFIED BY '${SERVICE_PASS}';
FLUSH PRIVILEGES;
EOF
    ok "Database '${db}' ready."
}

# ─── KEYSTONE HELPERS ─────────────────────────────────────────────────────────
register_service() {
    local user="$1"; local type="$2"; local desc="$3"; local url="$4"
    log "Registering '${user}' in Keystone..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would register '${user}' (${type}).${NC}"
        return 0
    fi

    openstack user create --domain default --password "${SERVICE_PASS}" "${user}" 2>/dev/null \
        || warn "User '${user}' already exists."
    openstack role add --project service --user "${user}" admin 2>/dev/null || true
    openstack service create --name "${user}" --description "${desc}" "${type}" 2>/dev/null \
        || warn "Service '${user}' already registered."

    for endpoint_type in public internal admin; do
        openstack endpoint create --region "${REGION_NAME}" \
            "${type}" "${endpoint_type}" "${url}" 2>/dev/null || true
    done
    ok "Keystone registration done for '${user}'."
}

# ─── SYSTEMD HELPERS ──────────────────────────────────────────────────────────
: "${SERVICE_START_TIMEOUT:=15}"

start_services() {
    for svc in "$@"; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "  ${DIM}[DRY-RUN] Would start: ${svc}${NC}"
            continue
        fi

        systemctl enable "${svc}" 2>/dev/null || true

        local attempt
        for attempt in 1 2 3; do
            if systemctl restart "${svc}" 2>/dev/null; then
                break
            fi
            warn "Attempt ${attempt}/3 failed for ${svc}, retrying in 3s..."
            sleep 3
        done

        local elapsed=0
        while ! systemctl is-active --quiet "${svc}"; do
            sleep 1
            elapsed=$(( elapsed + 1 ))
            if (( elapsed >= SERVICE_START_TIMEOUT )); then
                warn "'${svc}' did not become active within ${SERVICE_START_TIMEOUT}s."
                break
            fi
        done

        if systemctl is-active --quiet "${svc}"; then
            ok "Service started: ${svc}"
        else
            warn "Could not start '${svc}'. Check: journalctl -u ${svc} -n 30 --no-pager"
        fi
    done
}

# ─── PROGRESS SPINNER ─────────────────────────────────────────────────────────
spinner() {
    local pid=$1; local msg="${2:-Working...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    trap 'printf "\r\033[K"; trap - INT TERM RETURN' INT TERM RETURN
    while kill -0 "${pid}" 2>/dev/null; do
        printf "\r  ${CYAN}${spin:i++%${#spin}:1}${NC}  ${msg}"
        sleep 0.1
    done
    printf "\r\033[K"
    trap - INT TERM RETURN
}

# ─── DEPLOYMENT CHECKPOINTS ───────────────────────────────────────────────────
: "${CHECKPOINT_FILE:=${LOG_DIR:-/tmp}/.deployment_checkpoint}"

step_done() { echo "$1" >> "${CHECKPOINT_FILE}"; }

step_ran() {
    if grep -qxF "$1" "${CHECKPOINT_FILE}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

clear_checkpoints() {
    if [[ -f "${CHECKPOINT_FILE}" ]]; then
        rm "${CHECKPOINT_FILE}"
    fi
    log "Checkpoint file cleared."
}

# ─── HOSTNAME CONFIRMATION (for destructive ops) ───────────────────────────────
confirm_hostname() {
    local current; current=$(hostname)
    echo -e "  ${YELLOW}Destructive operation on: ${BOLD}${current}${NC}"
    echo -ne "  Type this server's hostname to confirm: "
    read -r input
    if [[ "${input}" != "${current}" ]]; then
        echo "Hostname mismatch. Aborted."
        exit 1
    fi
}

# ─── TIMER ────────────────────────────────────────────────────────────────────
STEP_START=0
start_timer() { STEP_START=$(date +%s); }
elapsed()      { echo "$(( $(date +%s) - STEP_START ))s"; }

# ─── IP VALIDATION ────────────────────────────────────────────────────────────
validate_ip() {
    local ip="$1"
    local IFS='.'
    read -ra parts <<< "${ip}"
    if [[ ${#parts[@]} -ne 4 ]]; then return 1; fi
    for part in "${parts[@]}"; do
        if [[ ! "${part}" =~ ^[0-9]+$ ]]; then return 1; fi
        if (( part < 0 || part > 255 )); then return 1; fi
    done
    return 0
}

# ─── OPENSTACK SERVICE VERIFICATION ──────────────────────────────────────────
verify_service() {
    local name="$1"; local cmd="$2"
    if eval "${cmd}" &>/dev/null; then
        ok "${name} — OK"
    else
        warn "${name} — not responding (may still be starting)"
    fi
}
