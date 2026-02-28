# 🌩️ OpenStack Homelab

**One project. One config file. One command.**

A full-stack OpenStack automation suite for Ubuntu Server 24.04 LTS — from bare-metal deployment to production operations. Everything you need is here.

---

## 🗂️ Project Structure

```
openstack-complete/
│
├── deploy.sh                    ← THE ENTRY POINT — start here
├── configs/
│   └── main.env                 ← THE ONLY CONFIG FILE — edit this first
│
└── scripts/
    ├── lib.sh                   ← Shared helpers (colours, logging, guards)
    ├── base/                    ← Core OpenStack (01–08)
    │   ├── 01_prerequisites.sh  │  MariaDB, RabbitMQ, Memcached, NTP, Etcd
    │   ├── 02_keystone.sh       │  Identity & Authentication
    │   ├── 03_glance.sh         │  VM Image Storage
    │   ├── 04_placement.sh      │  Resource Tracking
    │   ├── 05_nova.sh           │  Compute (VM lifecycle)
    │   ├── 06_neutron.sh        │  Virtual Networking
    │   ├── 07_horizon.sh        │  Web Dashboard
    │   └── 08_verify.sh         │  Health checks
    │
    ├── services/                ← Extra OpenStack Services (09–16)
    │   ├── 09_cinder.sh         │  Block Storage (like AWS EBS)
    │   ├── 10_swift.sh          │  Object Storage (like AWS S3)
    │   ├── 11_heat.sh           │  Orchestration / IaC (like CloudFormation)
    │   ├── 12_ceilometer.sh     │  Telemetry & Metrics (like CloudWatch)
    │   ├── 13_barbican.sh       │  Secrets Manager (like Vault)
    │   ├── 14_octavia.sh        │  Load Balancer (like AWS ELB)
    │   ├── 15_manila.sh         │  Shared Filesystems (like AWS EFS)
    │   └── 16_designate.sh      │  DNS Service (like Route53)
    │
    ├── multinode/               ← Multi-node cluster support
    │   ├── 00_preflight.sh      │  Hostname, hosts, NTP, firewall (all nodes)
    │   ├── 02_compute.sh        │  Nova + Neutron agent for Compute nodes
    │   └── 03_storage.sh        │  Cinder + Swift backend for Storage nodes
    │
    ├── monitoring/              ← Health Dashboard & Alerting
    │   ├── monitor.sh           │  Live colour dashboard + Slack/email alerts
    │   └── install-cron.sh      │  Schedule monitoring every 5 minutes
    │
    ├── backup/                  ← Backup & Disaster Recovery
    │   ├── backup.sh            │  Backup VMs, databases, configs, images
    │   └── restore.sh           │  Restore from any backup point
    │
    ├── k8s/
    │   └── deploy-k8s.sh        ← Kubernetes cluster on OpenStack VMs
    │
    ├── ssl/
    │   ├── ssl-manager.sh       ← Let's Encrypt cert management
    │   └── reload-services.sh   │  Post-renewal hook
    │
    └── hardening/
        └── server-harden.sh     ← CIS Benchmark security audit & auto-fix
```

---

## ⚡ Quick Start

### Step 1 — Run the deployment script
```bash
sudo bash deploy.sh
```

On the **very first launch**, if `HOST_IP` is still the factory default (`0.0.0.0`), the **Setup Wizard** runs automatically. It will ask you for:
- This server's IP address
- Deployment mode (all-in-one or multi-node)
- Which extra services to enable or disable

You can re-run the wizard at any time from the menu (**option 0**) or directly:
```bash
sudo bash deploy.sh --wizard
```

### Step 2 — Or edit the config manually (optional)
```bash
nano configs/main.env
```
Set your server's IP, passwords, network interface, and which services to install. That's the only file you ever need to touch.

### Step 3 — Use the interactive menu
```bash
sudo bash deploy.sh
```

You'll see the interactive menu:

```
  ── SETUP ───────────────────────────────────────────────
   0  Setup Wizard            Set IP address & choose services

  ── DEPLOYMENT ──────────────────────────────────────────
   1  Full Deployment         Deploy everything in order
   2  Base OpenStack          Keystone → Nova → Neutron → Horizon
   3  Extra Services          Cinder, Swift, Heat, Barbican, Designate…
   4  Custom Selection        Pick individual services

  ── INFRASTRUCTURE ──────────────────────────────────────
   5  Multi-Node Setup        Configure Controller / Compute / Storage
   6  Kubernetes on OpenStack Spin up a K8s cluster inside your cloud

  ── OPERATIONS ──────────────────────────────────────────
   7  Health Dashboard        Live monitoring dashboard
   8  Backup & DR             Backup VMs, databases, configs
   9  Restore                 Restore from a backup

  ── SECURITY ────────────────────────────────────────────
  10  Server Hardening        CIS Benchmark audit & auto-fix
  11  SSL Certificates        Issue/renew Let's Encrypt certs

  ── UTILITY ─────────────────────────────────────────────
  12  Verify Installation     Run health checks on all services
  13  Show Config             Display current configuration
  14  View Logs               Tail the latest deployment log
```

### Step 4 — Or skip the menu with flags

```bash
sudo bash deploy.sh --wizard     # Re-run the setup wizard
sudo bash deploy.sh --full       # Deploy everything configured in main.env
sudo bash deploy.sh --base       # Base OpenStack only
sudo bash deploy.sh --services   # Extra services only
sudo bash deploy.sh --monitor    # Open health dashboard
sudo bash deploy.sh --backup     # Run a backup
sudo bash deploy.sh --harden     # Harden + audit the server
sudo bash deploy.sh --ssl        # Manage SSL certs
sudo bash deploy.sh --k8s        # Deploy Kubernetes
sudo bash deploy.sh --verify     # Check all services
sudo bash deploy.sh --config     # Show current config
```

---

## 📋 System Requirements

| Resource | Minimum (AIO) | Recommended |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS | Ubuntu Server 24.04 LTS |
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16+ GB |
| Disk | 50 GB | 100+ GB |
| Network | 1 NIC | 2 NICs |

> ⚠️ Use a **fresh** Ubuntu 24.04 installation. Do not run on a production server.

---

## ⚙️ Configuration Reference

Everything lives in `configs/main.env`. Key settings:

```bash
# Deployment mode
DEPLOY_MODE="all-in-one"     # or "multi-node"

# Your server IP
HOST_IP="0.0.0.0"

# What to install
INSTALL_CINDER="true"
INSTALL_SWIFT="true"
INSTALL_HEAT="true"
INSTALL_BARBICAN="true"
INSTALL_DESIGNATE="true"
INSTALL_CEILOMETER="false"   # resource-heavy, off by default
INSTALL_OCTAVIA="false"      # complex, needs extra setup
INSTALL_MANILA="false"

# Monitoring
SLACK_WEBHOOK_URL="https://hooks.slack.com/..."
ALERT_EMAIL="ops@yourcompany.com"

# Backups
BACKUP_PATH="/var/backups/openstack"
BACKUP_KEEP_DAYS=7

# SSL
ACME_EMAIL="admin@yourdomain.com"
OPENSTACK_DOMAIN="cloud.yourdomain.com"
```

---

## 📖 Module Reference

### 🏗️ Base OpenStack
Deploys: Keystone, Glance, Placement, Nova, Neutron, Horizon

After deployment:
```bash
# Access dashboard
http://YOUR_IP/horizon   (admin / your ADMIN_PASS)

# CLI access
source configs/admin-openrc.sh
openstack service list
openstack compute service list
```

### 📦 Extra Services
Enable any in `main.env` with `INSTALL_*="true"`, then run option 3 or `--services`.

| Service | Quick test |
|---|---|
| Cinder | `openstack volume create --size 5 test-vol` |
| Swift | `openstack container create my-bucket` |
| Heat | `openstack stack create -t template.yaml my-stack` |
| Barbican | `openstack secret store --name pw --payload 'MyPass'` |
| Designate | `openstack zone create --email a@b.com example.com.` |

### 🖥️ Multi-Node
For real production: run `00_preflight.sh` on every node first, deploy base OpenStack on the controller, then run `02_compute.sh` on compute nodes and `03_storage.sh` on the storage node.

### 📊 Health Dashboard
```bash
sudo bash deploy.sh --monitor
# Choose: once / live-watch / alert / install-cron
```
Checks every service, API port, system resource, and NTP sync. Sends Slack/email alerts on failure.

### 💾 Backup & Restore
```bash
# Backup everything
sudo bash deploy.sh --backup     # choose option 1

# Restore
sudo bash deploy.sh --restore    # shows available backups, choose what to restore
```

### ☸️ Kubernetes
```bash
sudo bash deploy.sh --k8s
# Spins up VMs, bootstraps cluster, joins workers, gives you kubeconfig
export KUBECONFIG=scripts/k8s/configs/kubeconfig
kubectl get nodes
```

### 🔒 SSL Certificates
```bash
sudo bash deploy.sh --ssl
# Issue cert, renew all, view expiry, secure OpenStack with HTTPS
```

### 🛡️ Server Hardening
```bash
sudo bash deploy.sh --harden
# Audit (check only) or Harden (fix + check)
# Generates scored report: 47/52 (90%) — Grade: A
```

---

## 📝 Logs

All deployment output is saved to `logs/deploy_TIMESTAMP.log`.

```bash
sudo bash deploy.sh --menu       # option 14 to view latest log
tail -f logs/deploy_*.log        # follow live
```

---

## 🆘 Troubleshooting

**A service is down:**
```bash
systemctl status nova-api
journalctl -u nova-api -n 50 --no-pager
```

**Re-run a single step:**
```bash
sudo bash scripts/base/05_nova.sh
sudo bash scripts/services/09_cinder.sh
```

**Check all OpenStack services:**
```bash
source configs/admin-openrc.sh
openstack service list
openstack compute service list
openstack network agent list
```

**Full health check:**
```bash
sudo bash deploy.sh --verify
```

---

## 📚 Useful Resources
- [OpenStack Docs](https://docs.openstack.org)
- [Ubuntu OpenStack Guide](https://ubuntu.com/openstack/docs)
- [OpenStack 2024.1 Release Notes](https://releases.openstack.org/caracal/)

## 📄 License
MIT
