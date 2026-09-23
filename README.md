# Production-Ready Headless DePIN & Bandwidth Monetization Stack

Fully automated, headless deployment stack using Docker and Docker Compose V2 for an **Ubuntu Contabo VPS** (4 vCPU Cores, 8 GB RAM, 100 GB SSD Storage, Static Datacenter IPv4).

Features **Triple-Layer Crash Resilience**, **Fail2ban SSH Protection**, **OOM Shielding**, **55 GB Enhanced Titan Storage**, and a **Unified Management CLI (`./manage.sh`)**.

---

## 1. Architecture & Hardware Budget

Contabo enforces a strict "Fair Use" policy that automatically throttles or flags VPS accounts if continuous CPU usage exceeds ~20–30%. Furthermore, Docker logs and DePIN cache daemons can easily fill a 100 GB SSD if left unbounded.

This stack is architected to guarantee that total consumption **never exceeds 0.7 vCPU (under 18% of 4 cores)** and uses **less than 3.2 GB of RAM**, leaving >82% CPU and >4.8 GB of memory completely free for the Linux kernel, networking buffers, and SSH access.

### Hardware Allocation Matrix

| Service | Container Name | Image | CPU Limit | RAM Limit | Network Mode | Storage Path |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **TraffMonetizer** | `traffmonetizer` | `traffmonetizer/cli_v2:latest` | 0.10 vCPU | 256 MB | Bridge (DNS 1.1.1.1) | Ephemeral |
| **EarnFM** | `earnfm` | `earnfm/earnfm-client:latest` | 0.10 vCPU | 256 MB | Bridge (DNS 1.1.1.1) | Ephemeral |
| **ProxyRack Peer** | `proxyrack` | `proxyrack/pop:latest` | 0.10 vCPU | 256 MB | Bridge (DNS 1.1.1.1) | Ephemeral |
| **BitPing** | `bitping` | `bitping/bitpingd:latest` | 0.10 vCPU | 384 MB | Bridge (DNS 1.1.1.1) | `./data/bitpingd` |
| **Titan Network** | `titan-edge` | `nezha123/titan-edge:latest` | 0.30 vCPU | 2048 MB | **Host** (Port 1234) | `./data/titanedge` (**55 GB Cap**) |
| **TOTAL (5 Active)** | — | — | **0.70 vCPU (~18%)** | **3200 MB (~3.1 GB)** | — | **Strict 55 GB Max Disk** |
| **Host System Reserve**| Ubuntu OS & Kernel | — | 3.30 vCPU (82%) | ~4.9 GB Free RAM | — | **~35 GB Free SSD Space** |

---

## 2. Bulletproof Crash Resilience & Security Hardening

To ensure the server and stack never stay down after power outages, hypervisor migrations, kernel panics, or memory surges, the stack implements six enterprise-grade protection layers:

### 1. Fail2ban SSH Botnet Shield
* Automatically installs and enables `fail2ban` configured with a 1-hour ban jail on your active SSH port, keeping Contabo auth logs clean and preventing brute-force compromises.

### 2. Out-of-Memory (OOM) Protection (4 GB Swap Shield)
* Automatically provisions a dedicated **4 GB swapfile** (`/swapfile`) with `vm.swappiness=10` and `vm.vfs_cache_pressure=50`. Physical RAM is prioritized while the swap acts as an emergency shock-absorber against OOM kernel panics.

### 3. Kernel Panic Auto-Reboot
* Configured `kernel.panic=10` and `kernel.panic_on_oops=1` via sysctl. If a kernel panic occurs, the VPS **automatically reboots itself within 10 seconds** instead of freezing permanently.

### 4. Systemd Boot Auto-Recovery (`depin-stack.service`)
* A native systemd unit (`/etc/systemd/system/depin-stack.service`) manages the stack lifecycle. It orders startup strictly after `network-online.target` and `docker.service`. On host shutdown, it cleanly stops containers (`docker compose down`), preventing database corruption in `./data/titanedge` and `./data/bitpingd`.

### 5. Autonomous Self-Healing Watchdog (`depin-watchdog.sh`)
* A cron watchdog runs every 5 minutes:
  1. Verifies Docker daemon health (restarts `docker.service` if down).
  2. Inspects for `exited`, `dead`, or `unhealthy` containers and restarts them automatically.
  3. Checks root partition usage; if usage exceeds **85%**, it automatically executes `docker system prune -f`, vacuums systemd journal logs to 50 MB, and cleans apt caches.
  4. Checks available RAM; if critically low (< 256 MB), it drops inactive page caches (`sysctl -w vm.drop_caches=3`).
  5. Logs all actions to `/var/log/depin-watchdog.log` (auto-rotated weekly).

### 6. SSD Overflow Prevention
* **Systemd Journal Cap**: Capped at 100 MB max via `/etc/systemd/journald.conf.d/max-size.conf`.
* **Docker Log Rotation**: All containers locked to `max-size: 20m` and `max-file: 3` (360 MB total max).
* **Titan Storage Ceiling**: Capped strictly at 55 GB (boosted for maximum reward point generation).
* **Core Dumps Disabled**: Core dump creation disabled in limits and sysctl (`fs.suid_dumpable=0`).

---

## 3. Quick Start (Deployment on Contabo VPS)

### Step 1: Upload or Clone
Transfer the directory to your VPS:
```bash
cd ~
git clone <your-repo-url> depin-stack
cd depin-stack
```

### Step 2: Configure Credentials
Generate and populate your `.env` file (your `.env` already contains your 5 active keys):
```bash
cp .env.example .env
nano .env
```

| Variable | Description | Status |
| :--- | :--- | :--- |
| `TRAFFMONETIZER_TOKEN` | Token from [app.traffmonetizer.com](https://app.traffmonetizer.com/) | Configured |
| `EARNFM_TOKEN` | API UUID key from [app.earn.fm](https://app.earn.fm/) | Configured |
| `PROXYRACK_API_KEY` | API key from [peer.proxyrack.com](https://peer.proxyrack.com/) | Configured |
| `BITPING_EMAIL` | Account email from [app.bitping.com](https://app.bitping.com/) | Configured |
| `BITPING_PASSWORD` | Account password from [app.bitping.com](https://app.bitping.com/) | Configured |
| `TITAN_IDENTITY_CODE` | Device Identity Hash from [titannet.io](https://titannet.io/) | Configured |
| `TITAN_STORAGE_SIZE` | Storage ceiling (enhanced: `55GB`) | Configured |

### Step 3: Run Automated Deployment
```bash
chmod +x setup.sh manage.sh depin-watchdog.sh
sudo ./setup.sh
```

---

## 4. Unified CLI Operations (`./manage.sh`)

```bash
# 1. View complete stack dashboard (Uptime, RAM, Swap, Disk, CPU, Containers, Titan status)
./manage.sh status

# 2. Stream live container resource metrics (CPU %, RAM, Net I/O)
./manage.sh stats

# 3. View live logs (all containers)
./manage.sh logs

# 4. View live logs for a specific daemon
./manage.sh logs proxyrack
./manage.sh logs earnfm
./manage.sh logs titan-edge

# 5. Restart an individual service or the whole stack
./manage.sh restart proxyrack
./manage.sh restart

# 6. One-command zero-downtime stack update & image refresh
./manage.sh update

# 7. Inspect Titan Network Edge node details and device binding
./manage.sh titan

# 8. View self-healing watchdog activity
./manage.sh watchdog

# 9. Perform routine disk cleanup and log vacuuming
./manage.sh clean
```
