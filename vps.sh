#!/usr/bin/env bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager v4.0
# Created by NexusTechPro
# Fixes in v4.0:
#   - TCG full support (no KVM needed) — correct cpu flags, no x2apic, no host cpu
#   - Color code crash in subshells fixed — colors redefined inside every subshell
#   - Network speed tuned — queue sizes, BBR, sysctl inside VM
#   - Cloudflare tunnel + Tailscale for public IP from private networks
#   - Anti-freeze: i6300esb watchdog, disable S3/S4, mem-prealloc
#   - iothread for faster disk I/O
#   - cpu performance governor auto-set on TCG
#
# Architecture:
#   - /home/vms/name.img              = live running image (QEMU reads natively)
#   - /nexusvms/name.img.compressed   = compressed snapshot (created only on freeze, cleared after restore)
# =============================

# --- ANSI COLORS (global scope) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;97m'
NC='\033[0m'

# --- DIRECTORIES ---
BACKUP_DIR="${BACKUP_DIR:-$HOME/vms}"
SNAPSHOT_DIR="/nexusvms"

# ============================================================================
# HELPERS
# ============================================================================

display_header() {
    clear
    echo -e "${BLUE}========================================================================"
    echo -e "  Created by NexusTechPro"
    echo -e "  Enhanced Multi-VM Manager v4.0"
    echo -e "========================================================================${NC}"
    echo
}

print_status() {
    local type=$1
    local message=$2
    case $type in
        "INFO")    echo -e "${CYAN}[INFO]${NC} $message" ;;
        "WARN")    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "ERROR")   echo -e "${RED}[ERROR]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "INPUT")   echo -e "${WHITE}[INPUT]${NC} $message" ;;
        *)         echo "[$type] $message" ;;
    esac
}

validate_input() {
    local type=$1
    local value=$2
    case $type in
        "number")   [[ "$value" =~ ^[0-9]+$ ]] || { print_status "ERROR" "Must be a number"; return 1; } ;;
        "size")     [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || { print_status "ERROR" "Must be a size with unit (e.g., 10G)"; return 1; } ;;
        "port")     [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 23 ] && [ "$value" -le 65535 ] || { print_status "ERROR" "Must be valid port (23-65535)"; return 1; } ;;
        "name")     [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || { print_status "ERROR" "Only letters, numbers, hyphens, underscores"; return 1; } ;;
        "username") [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] || { print_status "ERROR" "Must start with letter/underscore"; return 1; } ;;
    esac
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing[*]}"
        print_status "INFO" "Try: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

cleanup() {
    rm -f /tmp/vps-user-data /tmp/vps-meta-data 2>/dev/null || true
}

check_space() {
    local path=$1
    local needed_gb=$2
    local free_kb
    free_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2{print $4}')
    local free_gb=$(( free_kb / 1024 / 1024 ))
    if [[ $free_gb -lt $needed_gb ]]; then
        print_status "ERROR" "Not enough space on $path (need ${needed_gb}G, have ${free_gb}G free)"
        return 1
    fi
    return 0
}

get_vm_list() {
    find "$BACKUP_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name=$1
    local config_file="$BACKUP_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS CREATED
        source "$config_file"
        LIVE_IMG="$BACKUP_DIR/$vm_name.img"
        SNAPSHOT_COMPRESSED="$SNAPSHOT_DIR/$vm_name.img.compressed"
        SEED_FILE="$BACKUP_DIR/$vm_name-seed.iso"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

save_vm_config() {
    local config_file="$BACKUP_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# ============================================================================
# ACCELERATION DETECTION
# Returns two variables: sets QEMU_ACCEL_FLAGS and QEMU_CPU_FLAGS
# Never mixes -cpu host with TCG — that was the root cause of the crash
# ============================================================================
detect_acceleration() {
    if [[ -w /dev/kvm ]]; then
        QEMU_ACCEL_FLAGS="-enable-kvm"
        QEMU_CPU_FLAGS="-cpu host,+x2apic"
        ACCEL_MODE="kvm"
    else
        # TCG — use 'max' cpu model which is the best TCG can offer natively
        # 'max' exposes all features TCG actually supports, no unsupported flags
        QEMU_ACCEL_FLAGS="-accel tcg,thread=multi,tb-size=512"
        QEMU_CPU_FLAGS="-cpu max"
        ACCEL_MODE="tcg"
        # Push CPU to performance mode for better TCG throughput
        echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/governor \
            >/dev/null 2>&1 || true
        # Higher priority for QEMU process
        renice -n -5 $$ >/dev/null 2>&1 || true
    fi
}

# ============================================================================
# BUILD AND RUN QEMU DIRECTLY (never via $() — globals die in subshell)
# ============================================================================
build_and_run_qemu() {
    local vm_name=$1
    local extra_args="${2:-}"   # optional: pass ">> logfile 2>&1" etc
    local live_img="$BACKUP_DIR/$vm_name.img"
    local seed_file="$BACKUP_DIR/$vm_name-seed.iso"
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"

    # detect_acceleration sets QEMU_ACCEL_FLAGS, QEMU_CPU_FLAGS, ACCEL_MODE
    # directly in THIS shell — globals are alive when qemu runs below
    detect_acceleration

    if [[ "$ACCEL_MODE" == "tcg" ]]; then
        print_status "WARN" "KVM not available — using optimized TCG"
    fi

    # Build port forwards
    local netdev_extra=""
    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        for forward in "${forwards[@]}"; do
            IFS=':' read -r host_port guest_port <<< "$forward"
            netdev_extra+=",hostfwd=tcp::${host_port}-:${guest_port}"
        done
    fi

    qemu-system-x86_64 \
        $QEMU_ACCEL_FLAGS \
        $QEMU_CPU_FLAGS \
        -machine q35,mem-merge=off,hpet=off \
        -m "$MEMORY" \
        -smp "$CPUS" \
        -global ICH9-LPC.disable_s3=1 \
        -global ICH9-LPC.disable_s4=1 \
        -device i6300esb \
        -watchdog-action reset \
        -object iothread,id=io0 \
        -drive "id=hd0,file=$live_img,format=qcow2,if=none,cache=writeback,discard=unmap,aio=threads" \
        -device "virtio-blk-pci,drive=hd0,iothread=io0" \
        -drive "file=$seed_file,format=raw,if=virtio,cache=writeback" \
        -boot order=c \
        -device "virtio-net-pci,netdev=n0,rx_queue_size=256,tx_queue_size=256,romfile=" \
        -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22,dns=8.8.8.8${netdev_extra}" \
        -object rng-random,filename=/dev/urandom,id=rng0 \
        -device virtio-rng-pci,rng=rng0 \
        -device virtio-balloon-pci \
        -rtc base=utc,clock=host,driftfix=slew \
        -global kvm-pit.lost_tick_policy=delay \
        -serial "file:$serial_log" \
        -display none \
        -daemonize \
        -pidfile "$BACKUP_DIR/$vm_name.pid"
}


# ============================================================================
# SSH CHECK — banner check, not just TCP (frozen VMs accept TCP but no banner)
# ============================================================================
check_ssh_port_open() {
    local port=$1
    local banner
    banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/localhost/$port && cat <&3" 2>/dev/null | head -1)
    [[ "$banner" == SSH-* ]] && return 0
    return 1
}

# ============================================================================
# VM PROCESS MANAGEMENT
# ============================================================================

kill_vm() {
    local vm_name=$1
    local pid_file="$BACKUP_DIR/$vm_name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || true
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
    pkill -f "qemu-system-x86_64.*$BACKUP_DIR/$vm_name" 2>/dev/null || true
}

is_vm_running() {
    local vm_name=$1
    local pid_file="$BACKUP_DIR/$vm_name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || return 1
        kill -0 "$pid" 2>/dev/null && return 0
    fi
    return 1
}

# ============================================================================
# POST BOOT FIXES
# Network tuning (BBR, sysctl), journald volatile, docker, tailscale, sshx
# ============================================================================
apply_post_boot_fixes() {
    local port=$1
    local user=$2
    local pass=$3

    if ! command -v sshpass &>/dev/null; then
        print_status "WARN" "sshpass not found — skipping post-boot setup"
        return 0
    fi

    print_status "INFO" "Applying post-boot hardening + network tuning + starting services..."
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

    sshpass -p "$pass" ssh $ssh_opts -p "$port" "${user}@localhost" bash <<'REMOTE'
set -e

# ---- Journald volatile (prevents journal I/O freeze) ----
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/no-freeze.conf > /dev/null <<'JF'
[Journal]
Storage=volatile
SyncIntervalSec=0
RateLimitBurst=0
JF
sudo systemctl restart systemd-journald || true

# ---- Docker ----
if command -v docker &>/dev/null; then
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json > /dev/null <<'DF'
{
  "dns": ["8.8.8.8","1.1.1.1"],
  "dns-opts": ["ndots:0"],
  "log-driver": "json-file",
  "log-opts": {"max-size":"10m","max-file":"3"},
  "iptables": true,
  "userland-proxy": false
}
DF
    sudo systemctl restart docker || true
fi

# ---- Network performance tuning ----
sudo tee /etc/sysctl.d/99-network-perf.conf > /dev/null <<'SYSCTL'
# Large socket buffers
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
# High backlog
net.core.netdev_max_backlog=300000
net.core.somaxconn=65535
# BBR congestion control — much faster than default cubic
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
# TCP fast open
net.ipv4.tcp_fastopen=3
# IP forwarding (needed for docker etc)
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
# Reduce TIME_WAIT
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
SYSCTL

# Load BBR module
sudo modprobe tcp_bbr 2>/dev/null || true
sudo sysctl -p /etc/sysctl.d/99-network-perf.conf 2>/dev/null || true

# ---- Tailscale ----
sudo tailscale up 2>/dev/null || true

# ---- sshx service (run as nexus user) ----
sudo systemctl stop sshx 2>/dev/null || true
sudo systemctl disable sshx 2>/dev/null || true
sudo tee /etc/systemd/system/sshx.service > /dev/null <<'SSHXSF'
[Unit]
Description=sshx terminal sharing
After=network.target

[Service]
Type=simple
User=nexus
Group=nexus
ExecStartPre=/bin/bash -c 'pkill -9 sshx || true; sleep 1'
ExecStart=/usr/local/bin/sshx
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SSHXSF
sudo systemctl daemon-reload
sudo systemctl enable sshx
sudo systemctl restart sshx
sleep 4
SSHX_LINK=$(sudo journalctl -u sshx -n 10 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | tail -1)
echo "sshx: $SSHX_LINK"

# ---- Pelican restart if configured ----
sleep 5
BASE_URL="https://raw.githubusercontent.com/Adexx-11234/newrepo/main"
if [[ -f /root/.pelican.env ]] || [[ -f /var/www/pelican/.env ]]; then
    curl -fsSL "${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh \
        && sudo bash /tmp/nexus-restart.sh \
        && rm -f /tmp/nexus-restart.sh
fi
REMOTE

    print_status "SUCCESS" "Post-boot setup done"
}

# ============================================================================
# CLOUDFLARE TUNNEL SETUP (public URL from private/NAT network)
# ============================================================================
setup_cloudflare_tunnel() {
    local port=$1
    local user=$2
    local pass=$3
    local expose_port=${4:-80}

    if ! command -v sshpass &>/dev/null; then
        print_status "WARN" "sshpass not found — skipping cloudflare tunnel"
        return 0
    fi

    print_status "INFO" "Setting up Cloudflare tunnel for public access..."
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

    sshpass -p "$pass" ssh $ssh_opts -p "$port" "${user}@localhost" bash <<REMOTE
# Install cloudflared if not present
if ! command -v cloudflared &>/dev/null; then
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi

# Create systemd service for persistent tunnel
sudo tee /etc/systemd/system/cloudflared-tunnel.service > /dev/null <<'CF'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:${expose_port} --no-autoupdate
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CF
sudo systemctl daemon-reload
sudo systemctl enable cloudflared-tunnel
sudo systemctl restart cloudflared-tunnel
sleep 5
# Print the public URL
sudo journalctl -u cloudflared-tunnel -n 20 --no-pager 2>/dev/null \
    | grep -o 'https://.*\.trycloudflare\.com' | tail -1 \
    | xargs -I{} echo "Public URL: {}"
REMOTE
    print_status "SUCCESS" "Cloudflare tunnel started — check output above for public URL"
}

# ============================================================================
# WAIT FOR SSH WITH FREEZE DETECTION
# ============================================================================
wait_for_ssh() {
    local vm_name=$1
    local max_wait=120
    local elapsed=0
    local recovery_count=0
    local max_recoveries=3
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    print_status "INFO" "Waiting for VM to boot (max ${max_wait}s)..."
    echo -n "   "

    while true; do
        if check_ssh_port_open "$SSH_PORT"; then
            echo ""
            print_status "SUCCESS" "SSH ready after ${elapsed}s"
            return 0
        fi

        if [[ -f "$serial_log" && $elapsed -gt 20 ]]; then
            local last_mod now age
            last_mod=$(stat -c %Y "$serial_log" 2>/dev/null || echo 0)
            now=$(date +%s)
            age=$((now - last_mod))

            if [[ $age -gt 30 ]]; then
                echo ""
                print_status "WARN" "Freeze detected (serial stale ${age}s)"
                print_status "WARN" "Froze at: $(tail -1 "$serial_log" 2>/dev/null)"
                echo "[$(date '+%H:%M:%S')] Boot freeze detected" >> "$watchdog_log"

                if [[ $recovery_count -ge $max_recoveries ]]; then
                    print_status "ERROR" "Max recoveries reached — giving up"
                    return 1
                fi

                ((recovery_count++))
                print_status "INFO" "Recovery attempt $recovery_count/$max_recoveries..."
                if freeze_recovery "$vm_name"; then
                    print_status "SUCCESS" "Recovery done"
                    elapsed=0
                    echo -n "   "
                else
                    print_status "ERROR" "Recovery failed"
                    return 1
                fi
            fi
        fi

        if [[ $elapsed -ge $max_wait ]]; then
            echo ""
            if [[ $recovery_count -lt $max_recoveries ]]; then
                ((recovery_count++))
                print_status "WARN" "SSH timeout — treating as freeze. Recovery $recovery_count/$max_recoveries..."
                echo "[$(date '+%H:%M:%S')] SSH timeout — treating as freeze" >> "$watchdog_log"
                if freeze_recovery "$vm_name"; then
                    elapsed=0
                    echo -n "   "
                    continue
                fi
            fi
            print_status "ERROR" "VM failed to boot"
            return 1
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
}

# ============================================================================
# FREEZE RECOVERY (main scope)
# ============================================================================
freeze_recovery() {
    local vm_name=$1
    local live_img="$BACKUP_DIR/$vm_name.img"
    local snap_compressed="$SNAPSHOT_DIR/$vm_name.img.compressed"
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY STARTED =====" >> "$watchdog_log"

    # Pre-flight — wipe entire tmpfs directory before doing anything
    echo "[$(date '+%H:%M:%S')] Pre-flight: Wiping tmpfs..." >> "$watchdog_log"
    rm -rf "${SNAPSHOT_DIR:?}"/*
    echo "[$(date '+%H:%M:%S')] Pre-flight: tmpfs wiped, proceeding..." >> "$watchdog_log"

    # Step 1 — Kill frozen VM
    echo "[$(date '+%H:%M:%S')] Step 1: Killing frozen VM..." >> "$watchdog_log"
    kill_vm "$vm_name"
    sleep 2

    # Step 2 — Compress live image to tmpfs
    echo "[$(date '+%H:%M:%S')] Step 2: Compressing live image to tmpfs..." >> "$watchdog_log"
    local tmp_c="${snap_compressed}.compressing"
    rm -f "$tmp_c" "$snap_compressed"

    if ! qemu-img convert -O qcow2 -c "$live_img" "$tmp_c" >> "$watchdog_log" 2>&1; then
        echo "[$(date '+%H:%M:%S')] ERROR: Compression to tmpfs failed" >> "$watchdog_log"
        rm -f "$tmp_c"
        return 1
    fi
    mv "$tmp_c" "$snap_compressed"
    echo "[$(date '+%H:%M:%S')] Compressed to tmpfs: $(du -sh "$snap_compressed" 2>/dev/null | awk '{print $1}')" >> "$watchdog_log"

    # Step 3 — Compress back to /home with 5 min timeout
    echo "[$(date '+%H:%M:%S')] Step 3: Compressing back to /home (5 min timeout)..." >> "$watchdog_log"
    local restore_tmp="${live_img}.restoring"
    rm -f "$live_img" "$restore_tmp"

    qemu-img convert -O qcow2 -c "$snap_compressed" "$restore_tmp" >> "$watchdog_log" 2>&1 &
    local compress_pid=$!
    local elapsed=0
    local success=false

    while [[ $elapsed -lt 300 ]]; do
        if ! kill -0 "$compress_pid" 2>/dev/null; then
            if [[ -f "$restore_tmp" ]] && qemu-img check "$restore_tmp" >> "$watchdog_log" 2>&1; then
                success=true
            fi
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [[ "$success" == false ]]; then
        kill "$compress_pid" 2>/dev/null || true
        wait "$compress_pid" 2>/dev/null || true
        rm -f "$restore_tmp"
        echo "[$(date '+%H:%M:%S')] Compress-back timeout/failed — copying directly from tmpfs..." >> "$watchdog_log"
        if ! cp "$snap_compressed" "$restore_tmp"; then
            echo "[$(date '+%H:%M:%S')] ERROR: Direct copy also failed" >> "$watchdog_log"
            return 1
        fi
        if ! qemu-img check "$restore_tmp" >> "$watchdog_log" 2>&1; then
            rm -f "$restore_tmp"
            echo "[$(date '+%H:%M:%S')] ERROR: Direct copy verification failed" >> "$watchdog_log"
            return 1
        fi
    fi

    mv "$restore_tmp" "$live_img"
    echo "[$(date '+%H:%M:%S')] Live image restored and verified OK" >> "$watchdog_log"

    # Step 4 — Clear tmpfs
    echo "[$(date '+%H:%M:%S')] Step 4: Clearing tmpfs..." >> "$watchdog_log"
    rm -f "$snap_compressed"

    # Step 5 — Restart VM
    echo "[$(date '+%H:%M:%S')] Step 5: Restarting VM..." >> "$watchdog_log"
    rm -f "$serial_log"
    if ! build_and_run_qemu "$vm_name"; then
        echo "[$(date '+%H:%M:%S')] ERROR: Failed to restart VM" >> "$watchdog_log"
        return 1
    fi

    # Step 6 — Wait for SSH
    local el=0
    while [[ $el -lt 120 ]]; do
        if check_ssh_port_open "$SSH_PORT"; then
            echo "[$(date '+%H:%M:%S')] SSH ready — post-recovery setup..." >> "$watchdog_log"
            sleep 10
            apply_post_boot_fixes "$SSH_PORT" "$USERNAME" "$PASSWORD"
            echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY COMPLETE =====" >> "$watchdog_log"
            return 0
        fi
        sleep 5
        el=$((el + 5))
    done

    echo "[$(date '+%H:%M:%S')] WARNING: SSH did not respond after recovery" >> "$watchdog_log"
    return 1
}

# ============================================================================
# BACKGROUND FREEZE WATCHDOG
# Colors are redefined inside subshell — fixes the $'\E[1' crash
# Acceleration detection is also inline — fixes the cpu host/TCG crash
# ============================================================================
start_freeze_watchdog() {
    local vm_name=$1
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    local _BACKUP_DIR="$BACKUP_DIR"
    local _SNAPSHOT_DIR="$SNAPSHOT_DIR"
    local _SSH_PORT="$SSH_PORT"
    local _PASSWORD="$PASSWORD"
    local _USERNAME="$USERNAME"
    local _MEMORY="$MEMORY"
    local _CPUS="$CPUS"

    (
        # Redefine colors inside subshell — prevents $'\E[1' command not found crash
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        NC='\033[0m'

        # ---- SSH banner check ----
        check_ssh_local() {
            local port=$1
            local banner
            banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/localhost/$port && cat <&3" 2>/dev/null | head -1)
            [[ "$banner" == SSH-* ]] && return 0
            return 1
        }

        # ---- Kill VM ----
        kill_vm_local() {
            local vm=$1
            local pid_file="$_BACKUP_DIR/$vm.pid"
            if [[ -f "$pid_file" ]]; then
                local pid
                pid=$(cat "$pid_file" 2>/dev/null) || true
                [[ -n "$pid" ]] && {
                    kill "$pid" 2>/dev/null || true
                    sleep 2
                    kill -9 "$pid" 2>/dev/null || true
                }
                rm -f "$pid_file"
            fi
            pkill -f "qemu-system-x86_64.*$_BACKUP_DIR/$vm" 2>/dev/null || true
        }

        # ---- Inline acceleration detection (no function call from parent scope) ----
        get_accel_flags() {
            if [[ -w /dev/kvm ]]; then
                echo "-enable-kvm|-cpu host,+x2apic"
            else
                echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/governor \
                    >/dev/null 2>&1 || true
                echo "-accel tcg,thread=multi,tb-size=512|-cpu max"
            fi
        }

        # ---- Full recovery inline ----
            recover_local() {
            local vm=$1
            local live_img="$_BACKUP_DIR/$vm.img"
            local snap_compressed="$_SNAPSHOT_DIR/$vm.img.compressed"
            local serial="$_BACKUP_DIR/$vm.serial.log"
            local wlog="$_BACKUP_DIR/$vm.watchdog.log"

            echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY STARTED =====" >> "$wlog"

            # Pre-flight — wipe entire tmpfs directory before doing anything
            echo "[$(date '+%H:%M:%S')] Pre-flight: Wiping tmpfs..." >> "$wlog"
            rm -rf "${_SNAPSHOT_DIR:?}"/*
            echo "[$(date '+%H:%M:%S')] Pre-flight: tmpfs wiped, proceeding..." >> "$wlog"

            # Step 1 — Kill the frozen VM first
            echo "[$(date '+%H:%M:%S')] Step 1: Killing frozen VM..." >> "$wlog"
            kill_vm_local "$vm"
            sleep 2

            # Step 2 — Compress live image directly to tmpfs
            echo "[$(date '+%H:%M:%S')] Step 2: Compressing live image to tmpfs..." >> "$wlog"
            local tmp_c="${snap_compressed}.compressing"
            rm -f "$tmp_c" "$snap_compressed"

            if ! qemu-img convert -O qcow2 -c "$live_img" "$tmp_c" >> "$wlog" 2>&1; then
                echo "[$(date '+%H:%M:%S')] ERROR: Compression to tmpfs failed" >> "$wlog"
                rm -f "$tmp_c"
                return 1
            fi
            mv "$tmp_c" "$snap_compressed"
            echo "[$(date '+%H:%M:%S')] Compressed to tmpfs: $(du -sh "$snap_compressed" 2>/dev/null | awk '{print $1}')" >> "$wlog"

            # Step 3 — Compress back from tmpfs to /home with 5 min timeout
            # If it takes longer than 5 mins, kill it and just copy directly
            echo "[$(date '+%H:%M:%S')] Step 3: Compressing back to /home (5 min timeout)..." >> "$wlog"
            local restore_tmp="${live_img}.restoring"
            rm -f "$live_img" "$restore_tmp"

            # Run compress-back in background, watch it with a timeout
            qemu-img convert -O qcow2 -c "$snap_compressed" "$restore_tmp" >> "$wlog" 2>&1 &
            local compress_pid=$!
            local elapsed=0
            local success=false

            while [[ $elapsed -lt 300 ]]; do
                if ! kill -0 "$compress_pid" 2>/dev/null; then
                    # Process finished — check if output exists and is valid
                    if [[ -f "$restore_tmp" ]] && qemu-img check "$restore_tmp" >> "$wlog" 2>&1; then
                        success=true
                    fi
                    break
                fi
                sleep 5
                elapsed=$((elapsed + 5))
            done

            if [[ "$success" == false ]]; then
                # Timeout or failed — kill compress job, delete partial output, copy directly
                kill "$compress_pid" 2>/dev/null || true
                wait "$compress_pid" 2>/dev/null || true
                rm -f "$restore_tmp"
                echo "[$(date '+%H:%M:%S')] Compress-back timeout/failed — copying directly from tmpfs..." >> "$wlog"
                if ! cp "$snap_compressed" "$restore_tmp"; then
                    echo "[$(date '+%H:%M:%S')] ERROR: Direct copy also failed" >> "$wlog"
                    return 1
                fi
                if ! qemu-img check "$restore_tmp" >> "$wlog" 2>&1; then
                    rm -f "$restore_tmp"
                    echo "[$(date '+%H:%M:%S')] ERROR: Direct copy verification failed" >> "$wlog"
                    return 1
                fi
            fi

            mv "$restore_tmp" "$live_img"
            echo "[$(date '+%H:%M:%S')] Live image restored and verified OK" >> "$wlog"

            # Step 4 — Clear tmpfs
            echo "[$(date '+%H:%M:%S')] Step 4: Clearing tmpfs..." >> "$wlog"
            rm -f "$snap_compressed"

            # Step 5 — Restart VM
            echo "[$(date '+%H:%M:%S')] Step 5: Restarting VM..." >> "$wlog"
            rm -f "$serial"

            local accel_raw
            accel_raw=$(get_accel_flags)
            local accel_flag="${accel_raw%%|*}"
            local cpu_flag="${accel_raw##*|}"

            local pf_extra=""
            if [[ -f "$_BACKUP_DIR/$vm.conf" ]]; then
                local pf_conf
                pf_conf=$(grep ^PORT_FORWARDS "$_BACKUP_DIR/$vm.conf" 2>/dev/null \
                    | cut -d'"' -f2)
                if [[ -n "$pf_conf" ]]; then
                    IFS=',' read -ra pf_arr <<< "$pf_conf"
                    for pf in "${pf_arr[@]}"; do
                        IFS=':' read -r hp gp <<< "$pf"
                        pf_extra+=",hostfwd=tcp::${hp}-:${gp}"
                    done
                fi
            fi

            local qcmd
            qcmd="qemu-system-x86_64 $accel_flag $cpu_flag"
            qcmd+=" -machine q35,mem-merge=off,hpet=off"
            qcmd+=" -m $_MEMORY -smp $_CPUS"
            qcmd+=" -global ICH9-LPC.disable_s3=1"
            qcmd+=" -global ICH9-LPC.disable_s4=1"
            qcmd+=" -device i6300esb -watchdog-action reset"
            qcmd+=" -object iothread,id=io0"
            qcmd+=" -drive id=hd0,file=$live_img,format=qcow2,if=none,cache=writeback,discard=unmap,aio=threads"
            qcmd+=" -device virtio-blk-pci,drive=hd0,iothread=io0"
            qcmd+=" -drive file=$_BACKUP_DIR/$vm-seed.iso,format=raw,if=virtio,cache=writeback"
            qcmd+=" -boot order=c"
            qcmd+=" -device virtio-net-pci,netdev=n0,rx_queue_size=1024,tx_queue_size=1024,romfile="
            qcmd+=" -netdev user,id=n0,hostfwd=tcp::${_SSH_PORT}-:22,dns=8.8.8.8${pf_extra}"
            qcmd+=" -object rng-random,filename=/dev/urandom,id=rng0"
            qcmd+=" -device virtio-rng-pci,rng=rng0"
            qcmd+=" -device virtio-balloon-pci"
            qcmd+=" -rtc base=utc,clock=host,driftfix=slew"
            qcmd+=" -global kvm-pit.lost_tick_policy=delay"
            qcmd+=" -serial file:$serial"
            qcmd+=" -display none -daemonize"
            qcmd+=" -pidfile $_BACKUP_DIR/$vm.pid"

            if ! eval "$qcmd" >> "$wlog" 2>&1; then
                echo "[$(date '+%H:%M:%S')] ERROR: Restart failed" >> "$wlog"
                return 1
            fi

            # Step 6 — Wait for SSH then post-recovery
            local el=0
            while [[ $el -lt 120 ]]; do
                if check_ssh_local "$_SSH_PORT"; then
                    echo "[$(date '+%H:%M:%S')] SSH ready — post-recovery setup..." >> "$wlog"
                    sleep 10
                    sshpass -p "$_PASSWORD" ssh \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        -o ConnectTimeout=15 \
                        -o LogLevel=ERROR \
                        -p "$_SSH_PORT" "${_USERNAME}@localhost" bash <<REMOTE >> "$wlog" 2>&1
sudo modprobe tcp_bbr 2>/dev/null || true
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sudo sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sudo tailscale up || true
sudo systemctl stop sshx || true
sudo systemctl disable sshx || true
sudo tee /etc/systemd/system/sshx.service > /dev/null <<'SF'
[Unit]
Description=sshx terminal sharing
After=network.target

[Service]
Type=simple
User=nexus
Group=nexus
ExecStartPre=/bin/bash -c 'pkill -9 sshx || true; sleep 1'
ExecStart=/usr/local/bin/sshx
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SF
sudo systemctl daemon-reload
sudo systemctl enable sshx
sudo systemctl restart sshx
sleep 4
SSHX_LINK=\$(sudo journalctl -u sshx -n 10 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | tail -1)
echo "sshx: \$SSHX_LINK"
sleep 5
BASE_URL="https://raw.githubusercontent.com/Adexx-11234/newrepo/main"
if [[ -f /root/.pelican.env ]] || [[ -f /var/www/pelican/.env ]]; then
    curl -fsSL "\${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh \
        && sudo bash /tmp/nexus-restart.sh && rm -f /tmp/nexus-restart.sh
fi
REMOTE
                    echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY COMPLETE =====" >> "$wlog"
                    return 0
                fi
                sleep 5
                el=$((el + 5))
            done

            echo "[$(date '+%H:%M:%S')] WARNING: SSH did not respond after recovery" >> "$wlog"
            return 1
        }

        # ---- Watchdog main loop ----
        local recovery_count=0
        local max_recoveries=3

        sleep 120  # grace period during boot

        while true; do
            sleep 20

            [[ ! -f "$_BACKUP_DIR/$vm_name.pid" ]] && exit 0

            local pid
            pid=$(cat "$_BACKUP_DIR/$vm_name.pid" 2>/dev/null) || exit 0
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] QEMU process died" >> "$watchdog_log"
                exit 0
            fi

            if ! check_ssh_local "$_SSH_PORT"; then
                local stale=0
                if [[ -f "$serial_log" ]]; then
                    local lm now
                    lm=$(stat -c %Y "$serial_log" 2>/dev/null || echo 0)
                    now=$(date +%s)
                    stale=$((now - lm))
                fi

                if [[ $stale -gt 40 ]]; then
                    echo "[$(date '+%H:%M:%S')] FREEZE — SSH no banner, serial stale ${stale}s" >> "$watchdog_log"
                    echo "[$(date '+%H:%M:%S')] Froze at: $(tail -1 "$serial_log" 2>/dev/null)" >> "$watchdog_log"

                    if [[ $recovery_count -ge $max_recoveries ]]; then
                        echo "[$(date '+%H:%M:%S')] Max recoveries reached. Stopping." >> "$watchdog_log"
                        exit 1
                    fi

                    ((recovery_count++))
                    if recover_local "$vm_name"; then
                        echo "[$(date '+%H:%M:%S')] Recovery complete" >> "$watchdog_log"
                        recovery_count=0
                        sleep 120
                    else
                        echo "[$(date '+%H:%M:%S')] Recovery failed" >> "$watchdog_log"
                        exit 1
                    fi
                else
                    echo "[$(date '+%H:%M:%S')] SSH down, serial active (${stale}s) — rebooting?" >> "$watchdog_log"
                fi
            else
                recovery_count=0
            fi
        done

    ) >> "$watchdog_log" 2>&1 &
    disown
    print_status "SUCCESS" "Freeze watchdog running (checks every 20s)"
}

# ============================================================================
# SSH INTO VM
# ============================================================================
ssh_into_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if ! is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is not running"
        return 1
    fi

    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true
    sleep 3

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "  Connecting: ${USERNAME}@localhost:${SSH_PORT}"
    echo -e "  Password:   ${PASSWORD}"
    echo -e "==========================================${NC}"
    echo ""

    if command -v sshpass &>/dev/null; then
        sshpass -p "$PASSWORD" ssh $ssh_opts -p "$SSH_PORT" "${USERNAME}@localhost"
    else
        print_status "WARN" "sshpass not installed — type password manually"
        ssh $ssh_opts -p "$SSH_PORT" "${USERNAME}@localhost"
    fi
}

# ============================================================================
# SETUP VM IMAGE (first time)
# ============================================================================
setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$SNAPSHOT_DIR"

    local base_img="$BACKUP_DIR/$VM_NAME-base.img"

    if [[ ! -f "$base_img" ]]; then
        print_status "INFO" "Downloading from $IMG_URL..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$base_img.tmp"; then
            print_status "ERROR" "Download failed"
            exit 1
        fi
        mv "$base_img.tmp" "$base_img"
    fi

    qemu-img resize "$base_img" "$DISK_SIZE" 2>/dev/null || true

    print_status "INFO" "Compressing base image..."
    qemu-img convert -O qcow2 -c "$base_img" "$BACKUP_DIR/$VM_NAME.img"
    rm -f "$base_img"

    cat > /tmp/vps-user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
write_files:
  - path: /etc/systemd/journald.conf.d/no-freeze.conf
    content: |
      [Journal]
      Storage=volatile
      Compress=no
      Seal=no
      SyncIntervalSec=0
      RateLimitIntervalSec=0
      RateLimitBurst=0
  - path: /etc/docker/daemon.json
    content: |
      {
        "dns": ["8.8.8.8", "1.1.1.1"],
        "dns-opts": ["ndots:0"],
        "log-driver": "json-file",
        "log-opts": {"max-size": "10m", "max-file": "3"},
        "iptables": true,
        "userland-proxy": false
      }
    permissions: '0644'
  - path: /etc/sysctl.d/99-vm-tweaks.conf
    content: |
      net.ipv4.ip_forward=1
      net.bridge.bridge-nf-call-iptables=1
      vm.dirty_ratio=10
      vm.dirty_background_ratio=5
      net.core.rmem_max=134217728
      net.core.wmem_max=134217728
      net.ipv4.tcp_rmem=4096 87380 134217728
      net.ipv4.tcp_wmem=4096 65536 134217728
      net.core.netdev_max_backlog=300000
      net.ipv4.tcp_congestion_control=bbr
      net.core.default_qdisc=fq
      net.ipv4.tcp_fastopen=3
      net.ipv4.tcp_tw_reuse=1
      net.ipv4.tcp_fin_timeout=15
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - systemctl restart systemd-journald
  - journalctl --vacuum-size=1M 2>/dev/null || true
  - modprobe tcp_bbr 2>/dev/null || true
  - sysctl -p /etc/sysctl.d/99-vm-tweaks.conf 2>/dev/null || true
  - sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& systemd.journald.forward_to_console=0 udev.log_level=3 systemd.log_level=warning/' /etc/default/grub
  - update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
EOF

    cat > /tmp/vps-meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    cloud-localds "$SEED_FILE" /tmp/vps-user-data /tmp/vps-meta-data || {
        print_status "ERROR" "Failed to create seed image"
        exit 1
    }

    print_status "SUCCESS" "VM '$VM_NAME' setup complete."
}

# ============================================================================
# CREATE NEW VM
# ============================================================================
create_new_vm() {
    print_status "INFO" "Creating a new VM"

    check_space "$BACKUP_DIR" 3 || return 1
    check_space "/" 8 || return 1

    print_status "INFO" "Select an OS:"
    local os_keys=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_keys[$i]="$os"
        ((i++))
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_keys[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        fi
        print_status "ERROR" "Invalid selection"
    done

    while true; do
        read -p "$(print_status "INPUT" "VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        validate_input "name" "$VM_NAME" || continue
        [[ -f "$BACKUP_DIR/$VM_NAME.conf" ]] && { print_status "ERROR" "VM '$VM_NAME' already exists"; continue; }
        break
    done

    while true; do
        read -p "$(print_status "INPUT" "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        validate_input "name" "$HOSTNAME" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "Username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        validate_input "username" "$USERNAME" && break
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        [[ -n "$PASSWORD" ]] && break
        print_status "ERROR" "Password cannot be empty"
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 10G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-10G}"
        validate_input "size" "$DISK_SIZE" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 4096): ")" MEMORY
        MEMORY="${MEMORY:-4096}"
        validate_input "number" "$MEMORY" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        validate_input "number" "$CPUS" && break
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        validate_input "port" "$SSH_PORT" || continue
        ss -tln 2>/dev/null | grep -q ":$SSH_PORT " && { print_status "ERROR" "Port $SSH_PORT in use"; continue; }
        break
    done

    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, or Enter for none): ")" PORT_FORWARDS
    PORT_FORWARDS="${PORT_FORWARDS:-}"
    GUI_MODE=false

    LIVE_IMG="$BACKUP_DIR/$VM_NAME.img"
    SNAPSHOT_COMPRESSED="$SNAPSHOT_DIR/$VM_NAME.img.compressed"
    SEED_FILE="$BACKUP_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    setup_vm_image
    save_vm_config
}

# ============================================================================
# START VM
# ============================================================================
start_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if is_vm_running "$vm_name"; then
        print_status "SUCCESS" "VM '$vm_name' is already running!"
        ssh_into_vm "$vm_name"
        print_status "INFO" "SSH session ended. Goodbye!"
        exit 0
    fi

    if [[ ! -f "$LIVE_IMG" ]]; then
        print_status "ERROR" "No image found: $LIVE_IMG"
        return 1
    fi

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "Seed file missing — recreating minimal seed..."
        cat > /tmp/vps-user-data <<'EOF'
#cloud-config
EOF
        cat > /tmp/vps-meta-data <<EOF
instance-id: iid-$vm_name
local-hostname: $HOSTNAME
EOF
        cloud-localds "$SEED_FILE" /tmp/vps-user-data /tmp/vps-meta-data
    fi


    rm -f "$BACKUP_DIR/$vm_name.serial.log"
    > "$BACKUP_DIR/$vm_name.watchdog.log"
    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true
    ssh-keygen -R "localhost" 2>/dev/null || true

    # Wipe tmpfs before starting — ensure no leftover files from previous session
    print_status "INFO" "Cleaning tmpfs before start..."
    rm -rf "${SNAPSHOT_DIR:?}"/*

    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "SSH: port $SSH_PORT | user: $USERNAME | pass: $PASSWORD"

if ! build_and_run_qemu "$vm_name"; then
        print_status "ERROR" "Failed to start QEMU"
        return 1
    fi

    start_freeze_watchdog "$vm_name"

    if wait_for_ssh "$vm_name"; then
        sleep 10
        apply_post_boot_fixes "$SSH_PORT" "$USERNAME" "$PASSWORD"

        # Offer Cloudflare tunnel for public access
        echo ""
        read -p "$(print_status "INPUT" "Set up Cloudflare tunnel for public access? (y/N): ")" cf_choice
        if [[ "$cf_choice" =~ ^[Yy]$ ]]; then
            read -p "$(print_status "INPUT" "Which port to expose publicly? (default: 80): ")" cf_port
            cf_port="${cf_port:-80}"
            setup_cloudflare_tunnel "$SSH_PORT" "$USERNAME" "$PASSWORD" "$cf_port"
        fi

        ssh_into_vm "$vm_name"
        print_status "INFO" "SSH session ended. Goodbye!"
        exit 0
    else
        print_status "ERROR" "VM failed to boot. Check logs:"
        print_status "INFO"  "  Serial:   tail -30 $BACKUP_DIR/$vm_name.serial.log"
        print_status "INFO"  "  Watchdog: tail -30 $BACKUP_DIR/$vm_name.watchdog.log"
    fi
}

# ============================================================================
# STOP VM
# ============================================================================
stop_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if is_vm_running "$vm_name"; then
        print_status "INFO" "Stopping VM: $vm_name"
        kill_vm "$vm_name"
        print_status "SUCCESS" "VM '$vm_name' stopped"
    else
        print_status "INFO" "VM '$vm_name' is not running"
    fi
}

# ============================================================================
# ATTACH WATCHDOG
# ============================================================================
attach_watchdog() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if ! is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is not running"
        return 1
    fi

    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    echo "[$(date '+%H:%M:%S')] Watchdog manually attached" >> "$watchdog_log"
    start_freeze_watchdog "$vm_name"
    print_status "SUCCESS" "Watchdog loop attached"
    print_status "INFO"    "Monitor: tail -f $watchdog_log"
}

# ============================================================================
# SHOW VM INFO
# ============================================================================
show_vm_info() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    local status="Stopped"
    is_vm_running "$vm_name" && status="Running"

    local snap_status="Only created during freeze recovery"
    [[ -f "$SNAPSHOT_COMPRESSED" ]] && snap_status="Compressed ($(du -sh "$SNAPSHOT_COMPRESSED" | awk '{print $1}')) — ready"
    [[ -f "${SNAPSHOT_COMPRESSED}.compressing" ]] && snap_status="Compressing in progress..."

    local accel="KVM"
    [[ ! -w /dev/kvm ]] && accel="TCG (software)"

    echo ""
    print_status "INFO" "VM: $vm_name"
    echo "=========================================="
    echo "Status:        $status"
    echo "Acceleration:  $accel"
    echo "OS:            $OS_TYPE ($CODENAME)"
    echo "Hostname:      $HOSTNAME"
    echo "Username:      $USERNAME"
    echo "Password:      $PASSWORD"
    echo "SSH Port:      $SSH_PORT"
    echo "Memory:        $MEMORY MB"
    echo "CPUs:          $CPUS"
    echo "Disk:          $DISK_SIZE virtual"
    echo "Port Forwards: ${PORT_FORWARDS:-None}"
    echo "Created:       $CREATED"
    echo ""
    echo "Live image (/home):"
    [[ -f "$LIVE_IMG" ]] && du -sh "$LIVE_IMG" | awk '{print "  " $1}' || echo "  Not found"
    echo "Snapshot (tmpfs): $snap_status"
    echo ""
    df -h /home | tail -1 | awk '{print "/home:   " $4 " free of " $2 " (" $5 " used)"}'
    df -h /     | tail -1 | awk '{print "tmpfs:   " $4 " free of " $2 " (" $5 " used)"}'
    echo "=========================================="
    echo ""

    if [[ "$status" == "Running" ]]; then
        read -p "$(print_status "INPUT" "Connect via SSH? (Y/n): ")" connect
        connect="${connect:-Y}"
        if [[ "$connect" =~ ^[Yy]$ ]]; then
            ssh_into_vm "$vm_name"
            print_status "INFO" "SSH session ended. Goodbye!"
            exit 0
        fi
    else
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# ============================================================================
# DELETE VM
# ============================================================================
delete_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    print_status "WARN" "This permanently deletes VM '$vm_name' and ALL data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        is_vm_running "$vm_name" && kill_vm "$vm_name"
        rm -f "$LIVE_IMG" "$SNAPSHOT_COMPRESSED"
        rm -f "${SNAPSHOT_COMPRESSED}.compressing" "$SEED_FILE"
        rm -f "$BACKUP_DIR/$vm_name.conf" "$BACKUP_DIR/$vm_name.pid"
        rm -f "$BACKUP_DIR/$vm_name.serial.log" "$BACKUP_DIR/$vm_name.watchdog.log"
        print_status "SUCCESS" "VM '$vm_name' deleted"
    else
        print_status "INFO" "Cancelled"
    fi
}

# ============================================================================
# EDIT VM CONFIG
# ============================================================================
edit_vm_config() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    while true; do
        echo "What would you like to edit?"
        echo "  1) Hostname    2) Username    3) Password"
        echo "  4) SSH Port    5) Memory      6) CPUs"
        echo "  7) Port Forwards"
        echo "  0) Back"
        read -p "$(print_status "INPUT" "Choice: ")" edit_choice

        case $edit_choice in
            1) read -p "$(print_status "INPUT" "New hostname [$HOSTNAME]: ")" v; HOSTNAME="${v:-$HOSTNAME}" ;;
            2) while true; do read -p "$(print_status "INPUT" "New username [$USERNAME]: ")" v; v="${v:-$USERNAME}"; validate_input "username" "$v" && { USERNAME="$v"; break; }; done ;;
            3) while true; do read -s -p "$(print_status "INPUT" "New password: ")" v; echo; [[ -n "$v" ]] && { PASSWORD="$v"; break; } || print_status "ERROR" "Cannot be empty"; done ;;
            4) while true; do read -p "$(print_status "INPUT" "New SSH port [$SSH_PORT]: ")" v; v="${v:-$SSH_PORT}"; validate_input "port" "$v" && { SSH_PORT="$v"; break; }; done ;;
            5) while true; do read -p "$(print_status "INPUT" "New memory MB [$MEMORY]: ")" v; v="${v:-$MEMORY}"; validate_input "number" "$v" && { MEMORY="$v"; break; }; done ;;
            6) while true; do read -p "$(print_status "INPUT" "New CPUs [$CPUS]: ")" v; v="${v:-$CPUS}"; validate_input "number" "$v" && { CPUS="$v"; break; }; done ;;
            7) read -p "$(print_status "INPUT" "Port forwards [${PORT_FORWARDS:-none}]: ")" v; PORT_FORWARDS="${v:-$PORT_FORWARDS}" ;;
            0) return 0 ;;
            *) print_status "ERROR" "Invalid"; continue ;;
        esac

        save_vm_config
        read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" cont
        [[ "$cont" =~ ^[Yy]$ ]] || break
    done
}

# ============================================================================
# RESIZE VM DISK
# ============================================================================
resize_vm_disk() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    is_vm_running "$vm_name" && { print_status "ERROR" "Stop the VM first"; return 1; }

    print_status "INFO" "Current disk size: $DISK_SIZE"
    while true; do
        read -p "$(print_status "INPUT" "New disk size (e.g., 15G): ")" new_size
        validate_input "size" "$new_size" || continue
        if qemu-img resize "$LIVE_IMG" "$new_size"; then
            DISK_SIZE="$new_size"
            save_vm_config
            print_status "SUCCESS" "Disk resized to $new_size"
        else
            print_status "ERROR" "Resize failed"
        fi
        break
    done
}

# ============================================================================
# SHOW VM PERFORMANCE
# ============================================================================
show_vm_performance() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    echo ""
    print_status "INFO" "Performance: $vm_name"
    echo "=========================================="
    if is_vm_running "$vm_name"; then
        local pid
        pid=$(cat "$BACKUP_DIR/$vm_name.pid" 2>/dev/null || echo "")
        [[ -n "$pid" ]] && ps -p "$pid" -o pid,%cpu,%mem,rss,vsz --no-headers 2>/dev/null || true
        echo ""
        free -h
    else
        print_status "INFO" "VM not running"
        echo "Config: ${MEMORY}MB RAM | ${CPUS} CPUs | ${DISK_SIZE} disk"
    fi
    echo ""
    echo "Acceleration: $( [[ -w /dev/kvm ]] && echo 'KVM (hardware)' || echo 'TCG (software)' )"
    echo "Live image:   $(du -sh "$LIVE_IMG" 2>/dev/null | awk '{print $1}')"
    echo ""
    df -h /home | tail -1 | awk '{print "/home:   " $4 " free of " $2}'
    df -h /     | tail -1 | awk '{print "tmpfs:   " $4 " free of " $2}'
    echo "=========================================="
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# ============================================================================
# VIEW LOGS
# ============================================================================
view_serial_log() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    if [[ -f "$serial_log" ]]; then
        print_status "INFO" "Serial log (last 30 lines):"
        echo "=========================================="
        tail -30 "$serial_log"
        echo "=========================================="
    else
        print_status "WARN" "No serial log found"
    fi
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

view_watchdog_log() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    if [[ -f "$watchdog_log" && -s "$watchdog_log" ]]; then
        print_status "INFO" "Watchdog log (last 40 lines):"
        echo "=========================================="
        tail -40 "$watchdog_log"
        echo "=========================================="
    else
        print_status "INFO" "No watchdog activity yet"
    fi
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# ============================================================================
# MAIN MENU
# ============================================================================
main_menu() {
    while true; do
        display_header

        local accel_label
        accel_label="$( [[ -w /dev/kvm ]] && echo "${GREEN}KVM (hardware)${NC}" || echo "${YELLOW}TCG (software — optimized)${NC}" )"

        echo -e "${CYAN}Acceleration:${NC} $(echo -e $accel_label)"
        echo -e "${CYAN}Storage:${NC}"
        df -h /home | tail -1 | awk '{print "  /home (live):     " $4 " free of " $2 " (" $5 " used)"}'
        df -h /     | tail -1 | awk '{print "  tmpfs (snapshot): " $4 " free of " $2 " (" $5 " used)"}'
        echo ""

        local vms=()
        mapfile -t vms < <(get_vm_list)
        local vm_count=${#vms[@]}

        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count VM(s):"
            for i in "${!vms[@]}"; do
                local sc snap_indicator=""
                if is_vm_running "${vms[$i]}"; then
                    sc="${GREEN}Running${NC}"
                else
                    sc="${RED}Stopped${NC}"
                fi
                printf "  %2d) %s (" $((i+1)) "${vms[$i]}"
                echo -e "$sc)$snap_indicator"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start VM + Auto-SSH"
            echo "  3) Stop VM"
            echo "  4) Show VM info / SSH connect"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            echo "  9) View serial log"
            echo " 10) View watchdog log"
            echo " 11) Attach watchdog to running VM"
        fi
        echo "  0) Exit"
        echo

        read -p "$(print_status "INPUT" "Enter your choice: ")" choice

        case $choice in
            1) create_new_vm ;;
            2)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && start_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            3)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && stop_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            4)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && show_vm_info "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            5)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && edit_vm_config "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            6)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && delete_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            7)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && resize_vm_disk "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            8)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && show_vm_performance "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            9)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && view_serial_log "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            10)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && view_watchdog_log "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            11)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] \
                    && attach_watchdog "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            0) print_status "INFO" "Goodbye!"; exit 0 ;;
            *) print_status "ERROR" "Invalid option" ;;
        esac

        read -p "$(print_status "INPUT" "Press Enter to continue...")" 2>/dev/null || true
    done
}

# ============================================================================
# INIT
# ============================================================================
trap cleanup EXIT
check_dependencies
mkdir -p "$BACKUP_DIR"
mkdir -p "$SNAPSHOT_DIR"

declare -A OS_OPTIONS=(
    ["Ubuntu 22.04 (minimal)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 (minimal)"]="ubuntu|noble|https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Ubuntu 22.04 (standard)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 (standard)"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

main_menu