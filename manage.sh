#!/usr/bin/env bash
# ==============================================================================
# Unified Management CLI: DePIN & Bandwidth Monetization Stack
# Target OS: Ubuntu 20.04 / 22.04 / 24.04 LTS (Contabo VPS)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

show_help() {
    echo -e "${CYAN}${BOLD}DePIN & Bandwidth Stack Management CLI${NC}"
    echo -e "Usage: ./manage.sh [command]"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo "  status        Display real-time system, memory, disk, and container health dashboard"
    echo "  stats         Stream real-time CPU, RAM, and Network I/O metrics"
    echo "  logs [svc]    View live logs (tail all, or specify service name e.g. './manage.sh logs earnfm')"
    echo "  restart [svc] Restart all services or a specific container"
    echo "  stop          Stop the entire stack cleanly"
    echo "  start         Start the entire stack"
    echo "  update        Pull latest images, rebuild containers with zero downtime, and clean cache"
    echo "  titan         Inspect Titan Network Edge node status, identity binding, and storage"
    echo "  watchdog      Display recent self-healing watchdog activity logs"
    echo "  clean         Perform safe Docker disk cleanup and vacuum system logs"
    echo "  help          Show this help message"
    echo ""
}

cmd_status() {
    echo -e "\n${CYAN}${BOLD}====================================================================="
    echo "            DEPIN & BANDWIDTH MONETIZATION STACK DASHBOARD"
    echo "=====================================================================${NC}"

    # 1. System Uptime & Load
    UPTIME_INFO=$(uptime -p 2>/dev/null || uptime)
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}')
    echo -e "${BOLD}System:${NC} Uptime: ${GREEN}${UPTIME_INFO}${NC} | Load Average:${YELLOW}${LOAD_AVG}${NC}"

    # 2. Memory & Swap Health
    echo -e "\n${BOLD}Memory & Swap Protection:${NC}"
    free -h | awk 'NR==1{print "  " $0} NR>1{print "  " $0}'

    # 3. Disk Space Health
    echo -e "\n${BOLD}Storage Health (100 GB SSD Target):${NC}"
    df -h / | awk 'NR==1{print "  " $0} NR==2{print "  " $0}'

    # 4. Container Status
    echo -e "\n${BOLD}Docker Containers (Compose V2):${NC}"
    docker compose ps

    # 5. Resource Utilization Snapshot
    echo -e "\n${BOLD}Resource Utilization (Capped at 20% CPU / 4 GB RAM):${NC}"
    docker stats --no-stream --format "table   {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}"

    # 6. Titan Network Quick Info
    echo -e "\n${BOLD}Titan Network Node Status:${NC}"
    if docker compose ps titan-edge | grep -i "Up" >/dev/null 2>&1; then
        docker compose exec -T titan-edge titan-edge info 2>/dev/null | grep -E "Node id|Storage size|Bind hash|Online" | sed 's/^/  /' || echo "  Titan daemon responsive (run './manage.sh titan' for details)"
    else
        echo -e "  ${RED}Titan Edge container is not running.${NC}"
    fi

    # 7. Watchdog Daemon Status
    echo -e "\n${BOLD}Self-Healing Watchdog Status:${NC}"
    if [[ -f "/var/log/depin-watchdog.log" ]]; then
        LAST_LOG=$(tail -n 1 /var/log/depin-watchdog.log 2>/dev/null || echo "No logs yet")
        echo -e "  Last Log: ${MAGENTA}${LAST_LOG}${NC}"
    else
        echo "  Watchdog active via cron (/etc/cron.d/depin-watchdog)."
    fi
    echo ""
}

cmd_stats() {
    echo -e "${CYAN}${BOLD}Streaming real-time container metrics (Press CTRL+C to exit)...${NC}"
    docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
}

cmd_logs() {
    local svc="${1:-}"
    if [[ -n "${svc}" ]]; then
        echo -e "${CYAN}Tailing logs for service: ${BOLD}${svc}${NC}"
        docker compose logs -f --tail=100 "${svc}"
    else
        echo -e "${CYAN}Tailing logs for all services (Press CTRL+C to exit)...${NC}"
        docker compose logs -f --tail=100
    fi
}

cmd_restart() {
    local svc="${1:-}"
    if [[ -n "${svc}" ]]; then
        echo -e "${YELLOW}Restarting service ${svc}...${NC}"
        docker compose restart "${svc}"
        echo -e "${GREEN}Service ${svc} restarted.${NC}"
    else
        echo -e "${YELLOW}Restarting entire stack...${NC}"
        docker compose restart
        echo -e "${GREEN}Entire stack restarted.${NC}"
    fi
}

cmd_update() {
    echo -e "${CYAN}${BOLD}Updating all container images to latest releases...${NC}"
    docker compose pull
    echo -e "${YELLOW}Recreating containers with new images (zero-downtime)...${NC}"
    docker compose up -d --remove-orphans
    echo -e "${YELLOW}Pruning obsolete images...${NC}"
    docker image prune -f
    echo -e "${GREEN}${BOLD}Stack update completed successfully!${NC}"
    docker compose ps
}

cmd_titan() {
    echo -e "${CYAN}${BOLD}Titan Network Edge Node Diagnostic Information:${NC}"
    if docker compose ps titan-edge | grep -i "Up" >/dev/null 2>&1; then
        echo -e "\n${YELLOW}=== Node Information ===${NC}"
        docker compose exec -T titan-edge titan-edge info || true
        echo -e "\n${YELLOW}=== Binding Information ===${NC}"
        docker compose exec -T titan-edge titan-edge show binding-info || true
    else
        echo -e "${RED}Titan Edge container is not running. Start with: ./manage.sh start${NC}"
    fi
}

cmd_watchdog() {
    echo -e "${CYAN}${BOLD}Recent Self-Healing Watchdog Activity (/var/log/depin-watchdog.log):${NC}"
    if [[ -f "/var/log/depin-watchdog.log" ]]; then
        tail -n 30 /var/log/depin-watchdog.log
    else
        echo "No watchdog log file found yet."
    fi
}

cmd_clean() {
    echo -e "${YELLOW}Performing routine maintenance & disk space reclamation...${NC}"
    docker system prune -f
    journalctl --vacuum-size=50M 2>/dev/null || true
    echo -e "${GREEN}Disk cleanup complete. Current disk space:${NC}"
    df -h /
}

# Main command dispatcher
COMMAND="${1:-status}"
shift || true

case "${COMMAND}" in
    status)
        cmd_status
        ;;
    stats)
        cmd_stats
        ;;
    logs)
        cmd_logs "${1:-}"
        ;;
    restart)
        cmd_restart "${1:-}"
        ;;
    start)
        echo -e "${GREEN}Starting stack...${NC}"
        docker compose up -d --remove-orphans
        docker compose ps
        ;;
    stop)
        echo -e "${YELLOW}Stopping stack cleanly...${NC}"
        docker compose down
        ;;
    update)
        cmd_update
        ;;
    titan)
        cmd_titan
        ;;
    watchdog)
        cmd_watchdog
        ;;
    clean)
        cmd_clean
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: ${COMMAND}${NC}\n"
        show_help
        exit 1
        ;;
esac
