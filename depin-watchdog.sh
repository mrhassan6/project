#!/usr/bin/env bash
# ==============================================================================
# Self-Healing Watchdog & Resilience Daemon
# DePIN & Bandwidth Monetization Stack
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

LOG_FILE="/var/log/depin-watchdog.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_msg() {
    echo "[${TIMESTAMP}] $1" | tee -a "${LOG_FILE}" 2>/dev/null || echo "[${TIMESTAMP}] $1"
}

# ------------------------------------------------------------------------------
# 1. Docker Daemon Health Verification
# ------------------------------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
    log_msg "[ALERT] Docker daemon is unresponsive. Attempting systemctl restart docker..."
    systemctl restart docker || true
    sleep 5
    if ! docker info >/dev/null 2>&1; then
        log_msg "[FATAL] Docker daemon failed to recover."
        exit 1
    else
        log_msg "[RECOVERED] Docker daemon restarted successfully."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Container Health & Auto-Recovery (Exited, Dead, or Unhealthy)
# ------------------------------------------------------------------------------
UNHEALTHY=$(docker compose ps --filter "status=exited" --filter "status=dead" --filter "health=unhealthy" -q 2>/dev/null || true)

if [[ -n "${UNHEALTHY}" ]]; then
    log_msg "[ALERT] Detected crashed or unhealthy containers. Triggering stack self-healing..."
    docker compose up -d --remove-orphans >> "${LOG_FILE}" 2>&1 || true
    log_msg "[RECOVERED] Stack self-healing command executed."
fi

# ------------------------------------------------------------------------------
# 3. Disk Space Health & Auto-Pruning (Crash Prevention)
# ------------------------------------------------------------------------------
DISK_USAGE_PERCENT=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')

if [[ "${DISK_USAGE_PERCENT}" -ge 85 ]]; then
    log_msg "[WARN] Disk space critical: ${DISK_USAGE_PERCENT}% used on root partition. Performing auto-cleanup..."
    
    # Prune dangling Docker images, stopped containers, and build cache
    docker system prune -f >> "${LOG_FILE}" 2>&1 || true
    
    # Vacuum journald logs down to 50MB
    journalctl --vacuum-size=50M >> "${LOG_FILE}" 2>&1 || true
    
    # Clean apt caches
    apt-get clean >/dev/null 2>&1 || true
    
    NEW_DISK_USAGE=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')
    log_msg "[CLEANUP COMPLETE] Root partition usage reduced to ${NEW_DISK_USAGE}%."
fi

# ------------------------------------------------------------------------------
# 4. Out-of-Memory (OOM) Protection Check
# ------------------------------------------------------------------------------
# If free memory is critically low (< 256 MB) and swap is heavily burdened, drop caches
FREE_MEM_MB=$(free -m | awk '/^Mem:/ {print $7}')
if [[ "${FREE_MEM_MB}" -lt 256 ]]; then
    log_msg "[WARN] Available RAM critically low (${FREE_MEM_MB} MB). Reclaiming inactive kernel page cache..."
    sync && echo 3 > /proc/sys/vm/drop_caches || true
fi

# ------------------------------------------------------------------------------
# 5. Log Rotation for Watchdog Log
# ------------------------------------------------------------------------------
if [[ -f "${LOG_FILE}" ]]; then
    LOG_SIZE_KB=$(du -k "${LOG_FILE}" | cut -f1)
    if [[ "${LOG_SIZE_KB}" -ge 5120 ]]; then # Rotate if > 5 MB
        mv "${LOG_FILE}" "${LOG_FILE}.old"
        log_msg "[INFO] Rotated watchdog log."
    fi
fi
