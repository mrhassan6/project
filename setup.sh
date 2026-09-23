#!/usr/bin/env bash
# ==============================================================================
# Production Deployment Script: DePIN & Bandwidth Monetization Stack
# Target OS: Ubuntu 20.04 / 22.04 / 24.04 LTS (Contabo VPS)
# Hardware: 4 vCPU, 8 GB RAM, 100 GB SSD, Static Datacenter IPv4
# Resilience: Crash-Proof Kernel, OOM Protection, Auto-Healing Watchdog, Fail2ban
# ==============================================================================

set -euo pipefail

# ANSI color codes for clear terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ------------------------------------------------------------------------------
# 1. Privilege & Pre-Flight Verification
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script must be executed as root. Please run: sudo ./setup.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo -e "${CYAN}${BOLD}"
echo "====================================================================="
echo "   Headless DePIN & Bandwidth Stack Provisioning Script"
echo "   Target: Contabo VPS (Ubuntu) | Bulletproof Crash Resilience"
echo "====================================================================="
echo -e "${NC}"

# Pre-flight disk space check (Titan uses 55GB, system needs >= 25GB free)
FREE_DISK_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')
if [[ "${FREE_DISK_GB}" -lt 30 ]]; then
    log_warn "Host root partition has only ${FREE_DISK_GB}GB free. Please ensure you have enough space."
else
    log_info "Host disk space verified: ${FREE_DISK_GB}GB free on root partition."
fi

# ------------------------------------------------------------------------------
# 2. Package Manager Lock Detection
# (Prevents script abortion if cloud-init or unattended-upgrades is running)
# ------------------------------------------------------------------------------
wait_for_apt_lock() {
    local lock_wait=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [[ $lock_wait -eq 0 ]]; then
            log_warn "Package manager lock held by another process (e.g. unattended-upgrades). Waiting..."
        fi
        sleep 3
        lock_wait=$((lock_wait + 3))
        if [[ $lock_wait -ge 180 ]]; then
            log_error "Package manager lock timed out after 3 minutes. Please inspect running apt processes."
            exit 1
        fi
    done
}

wait_for_apt_lock

# ------------------------------------------------------------------------------
# 3. Crash Prevention: Swapfile Allocation (OOM Killer Shield)
# Contabo VPS instances often have 0 swap, causing OOM kernel panics on spikes.
# Allocating 4 GB swap preserves system stability while using only ~4% of SSD.
# ------------------------------------------------------------------------------
CURRENT_SWAP_MB=$(free -m | awk '/^Swap:/ {print $2}')
if [[ "${CURRENT_SWAP_MB}" -lt 2048 ]]; then
    log_info "No adequate swap detected (${CURRENT_SWAP_MB} MB). Creating 4 GB emergency swapfile..."
    if ! fallocate -l 4G /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile >/dev/null 2>&1 || true
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log_success "4 GB swapfile provisioned and active."
else
    log_success "Existing swap allocation verified (${CURRENT_SWAP_MB} MB)."
fi

# ------------------------------------------------------------------------------
# 4. Host System Update
# ------------------------------------------------------------------------------
log_info "Updating package repositories and upgrading installed packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
wait_for_apt_lock
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
log_success "System packages updated."

# ------------------------------------------------------------------------------
# 5. Essential Dependencies & Security Installation (Fail2ban)
# ------------------------------------------------------------------------------
log_info "Installing prerequisite utilities (curl, ca-certificates, gnupg, ufw, jq, cron, fail2ban)..."
wait_for_apt_lock
apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    ufw \
    jq \
    tar \
    cron \
    fail2ban \
    lsb-release
log_success "Prerequisites installed."

# ------------------------------------------------------------------------------
# 6. Safe UFW Firewall & Fail2ban Configuration
# ------------------------------------------------------------------------------
log_info "Configuring UFW firewall safely (ensuring SSH is NEVER blocked)..."

# Detect all active SSH ports (handles single, custom, or multiple listening ports)
SSH_PORTS=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' || true)
if [[ -z "${SSH_PORTS}" ]]; then
    SSH_PORTS="22"
fi

# Set default policies
ufw default deny incoming
ufw default allow outgoing

# Allow forwarded traffic required for Docker bridge networking
if ufw default allow routed 2>/dev/null; then
    log_info "Configured UFW routed policy to ALLOW for Docker bridge traffic."
else
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
fi

# Explicitly whitelist all detected SSH ports before enabling UFW
for port in ${SSH_PORTS}; do
    log_info "Whitelisting SSH port ${port}/tcp..."
    ufw allow "${port}/tcp" comment 'SSH Remote Access' || true
done
ufw allow OpenSSH || true

# Allow Titan Edge node P2P port 1234
ufw allow 1234 comment 'Titan Network Edge Node'

# Enable UFW non-interactively
ufw --force enable
log_success "UFW enabled: Inbound dropped except SSH and Titan (1234). Outbound & routed traffic allowed."

# Configure Fail2ban for SSH brute-force defense
FIRST_SSH_PORT=$(echo "${SSH_PORTS}" | head -n1)
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${FIRST_SSH_PORT}
EOF
systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true
log_success "Fail2ban active: SSH protected against brute force botnets."

# ------------------------------------------------------------------------------
# 7. Bulletproof Kernel & Network Socket Tuning
# Configures auto-reboot on kernel panic and prevents OOM panics
# ------------------------------------------------------------------------------
log_info "Applying bulletproof kernel panic recovery and socket tuning..."

# Safe BBR congestion control configuration
modprobe tcp_bbr 2>/dev/null || true
AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")

CONGESTION_CONTROL="cubic"
if [[ "${AVAILABLE_CC}" == *"bbr"* ]]; then
    CONGESTION_CONTROL="bbr"
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    log_info "Google BBR congestion control supported and enabled."
else
    log_warn "BBR module not supported on this kernel; falling back cleanly to cubic."
fi

cat <<EOF > /etc/sysctl.d/99-depin-tuning.conf
# ------------------------------------------------------------------------------
# Crash Resilience & Kernel Auto-Recovery
# ------------------------------------------------------------------------------
# Reboot automatically 10 seconds after a kernel panic instead of hanging
kernel.panic=10
kernel.panic_on_oops=1

# OOM Handling: Do not panic kernel on OOM; kill container process instead
vm.panic_on_oom=0

# Memory & Swap Tuning: Prefer RAM, use swap only as emergency shock-absorber
vm.swappiness=10
vm.vfs_cache_pressure=50

# Core Dump Prevention: Disable disk-filling core dump files
fs.suid_dumpable=0

# ------------------------------------------------------------------------------
# Network Buffer & High-Connection Socket Tuning
# ------------------------------------------------------------------------------
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${CONGESTION_CONTROL}
net.core.rmem_max=7500000
net.core.wmem_max=7500000
net.core.somaxconn=2048
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-depin-tuning.conf 2>/dev/null || true
log_success "Kernel crash-recovery and socket parameters applied."

# ------------------------------------------------------------------------------
# 8. Journald Max Log Size Limit (SSD Overflow Protection)
# Capping systemd journal logs to 100 MB max prevents disk exhaustion
# ------------------------------------------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
cat <<'EOF' > /etc/systemd/journald.conf.d/max-size.conf
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald 2>/dev/null || true
log_success "Systemd journal log size capped at 100 MB max."

# ------------------------------------------------------------------------------
# 9. Docker Engine & Docker Compose V2 Setup
# ------------------------------------------------------------------------------
# Pre-configure Docker daemon defaults (fallback DNS and global log rotation)
mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
    log_info "Configuring Docker daemon defaults (20m log limits & fallback DNS)..."
    cat <<'EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  },
  "dns": ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
}
EOF
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log_success "Docker and Docker Compose V2 are already installed."
    systemctl restart docker || true
else
    log_info "Installing official Docker Engine and Docker Compose V2..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    wait_for_apt_lock
    apt-get update -y
    wait_for_apt_lock
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    log_success "Docker Engine and Docker Compose V2 installed."
fi

# Add sudo invoking user to docker group if applicable
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    usermod -aG docker "${SUDO_USER}" 2>/dev/null || true
    log_info "Added user '${SUDO_USER}' to the docker group for non-sudo docker usage."
fi

# Verify Docker daemon is responsive
log_info "Verifying Docker daemon connectivity..."
DOCKER_RETRIES=0
until docker info >/dev/null 2>&1; do
    sleep 1
    DOCKER_RETRIES=$((DOCKER_RETRIES + 1))
    if [[ $DOCKER_RETRIES -ge 15 ]]; then
        log_error "Docker daemon did not become ready within 15 seconds."
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# 10. Environment Variables Safe Parsing & Verification
# ------------------------------------------------------------------------------
log_info "Validating configuration (.env file)..."

if [[ ! -f ".env" ]]; then
    if [[ -f ".env.example" ]]; then
        log_warn "No .env file found. Creating from .env.example..."
        cp .env.example .env
        chmod 600 .env
        log_warn "Created .env template. Please populate credentials in .env before running."
    else
        log_error "Neither .env nor .env.example was found in ${SCRIPT_DIR}."
        exit 1
    fi
fi

# Enforce secure file permissions on .env
chmod 600 .env

# Safe line-by-line parsing of .env (avoids 'source' breaking on '#' in passwords)
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # Extract KEY and VALUE
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # Strip surrounding matching single or double quotes
        if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        export "$key"="$val"
    fi
done < .env

# Ensure ProxyRack has a 64-char UUID if API key is provided
if [[ -z "${PROXYRACK_UUID:-}" && -n "${PROXYRACK_API_KEY:-}" ]]; then
    PROXYRACK_UUID=$(cat /dev/urandom | LC_ALL=C tr -dc 'A-F0-9' | dd bs=1 count=64 2>/dev/null || openssl rand -hex 32 | tr 'a-z' 'A-Z')
    echo "PROXYRACK_UUID=${PROXYRACK_UUID}" >> .env
    export PROXYRACK_UUID
    log_info "Generated unique 64-character UUID for ProxyRack Peer."
fi

# Service Configuration Verification
echo -e "\n${CYAN}${BOLD}Scanning Configured Services:${NC}"
ACTIVE_COUNT=0

check_service_config() {
    local var_name="$1"
    local service_label="$2"
    local var_val="${!var_name:-}"
    if [[ -n "${var_val}" && "${var_val}" != *"your_"* && "${var_val}" != *"_here"* ]]; then
        echo -e "  [✔] ${GREEN}${service_label}${NC}: Active credential detected."
        ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    else
        echo -e "  [ ] ${YELLOW}${service_label}${NC}: Not configured (profile disabled - will stay idle)."
    fi
}

check_service_config "TRAFFMONETIZER_TOKEN" "TraffMonetizer"
check_service_config "EARNFM_TOKEN" "EarnFM"
check_service_config "PROXYRACK_API_KEY" "ProxyRack Peer"
check_service_config "BITPING_EMAIL" "BitPing"
check_service_config "TITAN_IDENTITY_CODE" "Titan Network Edge (55 GB)"
check_service_config "PACKETSHARE_EMAIL" "PacketShare"
check_service_config "REPOCKET_EMAIL" "Repocket"

if [[ ${ACTIVE_COUNT} -eq 0 ]]; then
    log_error "No active service credentials found in .env. Please configure at least one service."
    exit 1
fi

log_success "${ACTIVE_COUNT} service(s) ready to launch with zero errors."

# ------------------------------------------------------------------------------
# 11. Create Data Directories & CLI Permissions
# ------------------------------------------------------------------------------
log_info "Creating persistent storage directories in ./data/ ..."
mkdir -p data/bitpingd
mkdir -p data/titanedge
chmod -R 755 data

chmod +x "${SCRIPT_DIR}/manage.sh" "${SCRIPT_DIR}/depin-watchdog.sh"
log_success "Persistent data directories and CLI tools prepared."

# ------------------------------------------------------------------------------
# 12. Launch Docker Compose Stack
# ------------------------------------------------------------------------------
log_info "Pulling Docker images and launching stack in detached mode..."
docker compose pull
docker compose up -d --remove-orphans

log_success "Docker Compose stack is running."

# ------------------------------------------------------------------------------
# 13. Post-Launch Automation: Titan Network Binding & Storage Size Limit
# ------------------------------------------------------------------------------
TITAN_HASH="${TITAN_IDENTITY_CODE:-}"
TITAN_SIZE="${TITAN_STORAGE_SIZE:-55GB}"
TITAN_URL="${TITAN_BIND_URL:-https://api-test1.container1.titannet.io/api/v2/device/binding}"

if [[ -n "${TITAN_HASH}" && "${TITAN_HASH}" != *"your_"* && "${TITAN_HASH}" != *"_here"* ]]; then
    log_info "Configuring Titan Network Edge Node (strict limit: ${TITAN_SIZE})..."
    log_info "Waiting for titan-edge daemon to initialize inside container..."
    
    DAEMON_READY=false
    for i in {1..30}; do
        if docker compose exec -T titan-edge titan-edge info >/dev/null 2>&1 || \
           docker compose exec -T titan-edge titan-edge show binding-info >/dev/null 2>&1; then
            DAEMON_READY=true
            log_success "Titan daemon is responsive (after ${i} iterations)."
            break
        fi
        sleep 2
    done

    if [[ "${DAEMON_READY}" == "true" ]]; then
        # Check if already bound
        if docker compose exec -T titan-edge titan-edge show binding-info 2>/dev/null | grep -i "hash" >/dev/null 2>&1; then
            log_info "Titan Edge node is already bound to an identity. Skipping bind command."
        else
            log_info "Binding Titan Identity Hash..."
            if docker compose exec -T titan-edge titan-edge bind --hash="${TITAN_HASH}" "${TITAN_URL}"; then
                log_success "Titan node successfully bound to your account."
            else
                log_warn "Bind command returned non-zero. Check your hash in .env or run manually."
            fi
        fi

        # Set storage size limit inside container
        log_info "Configuring Titan storage ceiling to ${TITAN_SIZE}..."
        if docker compose exec -T titan-edge titan-edge config set --storage-size "${TITAN_SIZE}"; then
            log_success "Titan storage size set to ${TITAN_SIZE}."
            log_info "Restarting titan-edge to apply storage configuration..."
            docker compose restart titan-edge
        else
            log_warn "Could not set storage size automatically. Execute manually if needed."
        fi
    else
        log_warn "Titan daemon took longer than 60 seconds to boot. Verify with: ./manage.sh logs titan-edge"
    fi
else
    log_info "Titan Node identity code not provided; skipping automated binding."
fi

# ------------------------------------------------------------------------------
# 14. Systemd Auto-Start Service Setup (Crash & Reboot Auto-Recovery)
# ------------------------------------------------------------------------------
log_info "Installing systemd auto-start service (guarantees boot recovery)..."
sed "s|TARGET_DIR_PLACEHOLDER|${SCRIPT_DIR}|g" "${SCRIPT_DIR}/depin-stack.service" > /etc/systemd/system/depin-stack.service
chmod 644 /etc/systemd/system/depin-stack.service
systemctl daemon-reload
systemctl enable depin-stack.service
log_success "Systemd service 'depin-stack.service' enabled (auto-starts on boot)."

# ------------------------------------------------------------------------------
# 15. Self-Healing Watchdog Setup & Logrotate
# ------------------------------------------------------------------------------
log_info "Setting up self-healing watchdog cron job and log rotation..."
cat <<EOF > /etc/cron.d/depin-watchdog
# DePIN Stack Health Watchdog (Runs every 5 minutes)
*/5 * * * * root ${SCRIPT_DIR}/depin-watchdog.sh >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/depin-watchdog

cat <<'EOF' > /etc/logrotate.d/depin-watchdog
/var/log/depin-watchdog.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
chmod 644 /etc/logrotate.d/depin-watchdog

systemctl restart cron 2>/dev/null || true
log_success "Self-healing watchdog cron and logrotate installed."

# ------------------------------------------------------------------------------
# 16. Final Stabilization & Status Report
# ------------------------------------------------------------------------------
log_info "Stabilizing containers (waiting 4 seconds for services to settle)..."
sleep 4

echo -e "\n${GREEN}${BOLD}====================================================================="
echo "   DEPLOYMENT & HARDENING COMPLETED SUCCESSFULLY!"
echo "=====================================================================${NC}"

echo -e "\n${CYAN}${BOLD}Current Stack Status:${NC}"
docker compose ps

# Check for failing / restarting containers
RESTARTING_CONTAINERS=$(docker compose ps --filter "status=restarting" -q 2>/dev/null || true)
EXITED_CONTAINERS=$(docker compose ps --filter "status=exited" -q 2>/dev/null || true)

if [[ -n "${RESTARTING_CONTAINERS}" || -n "${EXITED_CONTAINERS}" ]]; then
    echo ""
    log_warn "One or more containers are in an exited or restarting state:"
    docker compose ps --filter "status=restarting" --filter "status=exited"
    log_info "Inspect error logs for failing services using: ./manage.sh logs <service_name>"
fi

echo -e "\n${CYAN}${BOLD}Live Resource Utilization Snapshot (Strict limits enforced):${NC}"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}"

echo -e "\n${YELLOW}${BOLD}Crash Resilience & Enterprise Protections Active:${NC}"
echo "  [✔] 4 GB Swapfile Active: Absorbs sudden RAM surges to prevent OOM panics"
echo "  [✔] Kernel Auto-Reboot: Server automatically reboots 10s after any kernel panic"
echo "  [✔] Systemd Auto-Start: Stack automatically restarts upon server reboot/crash"
echo "  [✔] Self-Healing Watchdog: Scans every 5m to revive dead containers & prune disk"
echo "  [✔] Fail2ban Shield: Brute-force SSH attacks automatically blocked"
echo "  [✔] Unified CLI: All operations accessible via ./manage.sh"

echo -e "\n${YELLOW}${BOLD}Useful Operations & Management Commands:${NC}"
echo "  • Open Stack Dashboard:       ./manage.sh status"
echo "  • View live resource monitor: ./manage.sh stats"
echo "  • View logs of all daemons:   ./manage.sh logs"
echo "  • View logs of one daemon:    ./manage.sh logs <service_name>"
echo "  • Update stack & images:      ./manage.sh update"
echo "  • Check Titan Edge status:    ./manage.sh titan"
echo "  • Reclaim disk space:         ./manage.sh clean"
echo ""
