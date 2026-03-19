#!/usr/bin/env bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager v3.2
# Created by NexusTechPro
# Architecture:
#   - /home/vms/name.img              = live running image (QEMU reads natively)
#   - /nexusvms/name.img              = uncompressed working copy (temporary)
#   - /nexusvms/name.img.compressed   = compressed snapshot (for freeze recovery)
#
# Startup:
#   1. Copy /home → /nexusvms/name.img (fast, 1-2 mins)
#   2. Boot VM from /home
#   3. Background: compress /nexusvms/name.img → .compressed (slow, 10-20 mins)
#   4. Delete /nexusvms/name.img when compression done
#
# Periodic backup loop (runs forever):
#   1. Wait for .compressed to exist
#   2. Delete .compressed (free space)
#   3. Copy /home → /nexusvms/name.img (fast)
#   4. Compress .img → .compressed (slow, background)
#   5. Delete .img when done
#   6. Repeat every cycle
#
# On freeze:
#   1. Detect freeze (SSH dead + serial stale)
#   2. Wait for .compressed to be ready (up to 20 mins)
#   3. Kill VM
#   4. Copy .compressed → /home/name.img.restoring
#   5. Verify image valid
#   6. Rename .restoring → name.img
#   7. Restart VM → tailscale + sshx + restart.sh
# =============================

# --- ANSI COLORS ---
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

# --- HEADER ---
display_header() {
    clear
    echo -e "${BLUE}========================================================================"
    echo -e "  Created by NexusTechPro"
    echo -e "  Enhanced Multi-VM Manager v3.2"
    echo -e "========================================================================${NC}"
    echo
}

# --- STATUS PRINT ---
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

# --- VALIDATE INPUT ---
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

# --- CHECK DEPENDENCIES ---
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

# --- CLEANUP ---
cleanup() {
    rm -f /tmp/vps-user-data /tmp/vps-meta-data 2>/dev/null || true
}

# --- CHECK FREE SPACE ---
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

# --- GET VM LIST ---
get_vm_list() {
    find "$BACKUP_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# --- LOAD VM CONFIG ---
load_vm_config() {
    local vm_name=$1
    local config_file="$BACKUP_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS CREATED
        source "$config_file"
        LIVE_IMG="$BACKUP_DIR/$vm_name.img"
        SNAPSHOT_IMG="$SNAPSHOT_DIR/$vm_name.img"
        SNAPSHOT_COMPRESSED="$SNAPSHOT_DIR/$vm_name.img.compressed"
        SEED_FILE="$BACKUP_DIR/$vm_name-seed.iso"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

# --- SAVE VM CONFIG ---
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

# --- ENSURE INITIAL SNAPSHOT ---
# On startup: copy /home → /nexusvms/name.img then trigger background compression
ensure_snapshot() {
    local vm_name=$1
    local live_img="$BACKUP_DIR/$vm_name.img"
    local snapshot_img="$SNAPSHOT_DIR/$vm_name.img"
    local snapshot_compressed="$SNAPSHOT_DIR/$vm_name.img.compressed"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    mkdir -p "$SNAPSHOT_DIR"

    # Already have compressed snapshot — good
    if [[ -f "$snapshot_compressed" ]] && [[ ! -f "${snapshot_compressed}.compressing" ]]; then
        print_status "INFO" "Compressed snapshot ready ($(du -sh "$snapshot_compressed" | awk '{print $1}'))"
        return 0
    fi

    # Compression already in progress — good
    if [[ -f "$snapshot_img" ]] || [[ -f "${snapshot_compressed}.compressing" ]]; then
        print_status "INFO" "Snapshot compression already in progress"
        return 0
    fi

    # Need to create fresh copy
    check_space "/" 8 || return 1

    print_status "INFO" "Copying live image to tmpfs for snapshot..."
    echo "[$(date '+%H:%M:%S')] Creating initial snapshot copy" >> "$watchdog_log"

    if cp "$live_img" "$snapshot_img"; then
        print_status "SUCCESS" "Snapshot copy done ($(du -sh "$snapshot_img" | awk '{print $1}'))"
        echo "[$(date '+%H:%M:%S')] Copy done — starting background compression" >> "$watchdog_log"
        start_background_compression "$vm_name"
        return 0
    else
        print_status "ERROR" "Failed to create snapshot copy"
        rm -f "$snapshot_img"
        return 1
    fi
}

# --- START BACKGROUND COMPRESSION ---
# Compresses /nexusvms/name.img → .compressed then deletes .img
start_background_compression() {
    local vm_name=$1
    local snapshot_img="$SNAPSHOT_DIR/$vm_name.img"
    local snapshot_compressed="$SNAPSHOT_DIR/$vm_name.img.compressed"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    (
        local wlog="$watchdog_log"
        local src="$snapshot_img"
        local dst="$snapshot_compressed"
        local dst_tmp="${dst}.compressing"

        echo "[$(date '+%H:%M:%S')] Background compression started..." >> "$wlog"

        if qemu-img convert -O qcow2 -c "$src" "$dst_tmp" >> "$wlog" 2>&1; then
            mv "$dst_tmp" "$dst"
            rm -f "$src"
            local sz
            sz=$(du -sh "$dst" 2>/dev/null | awk '{print $1}')
            echo "[$(date '+%H:%M:%S')] Compression complete: $sz" >> "$wlog"
        else
            rm -f "$dst_tmp"
            echo "[$(date '+%H:%M:%S')] Compression failed — uncompressed copy remains" >> "$wlog"
        fi
    ) &

    disown
    print_status "INFO" "Background compression started (10-20 mins)"
}

# --- CHECK SSH PORT OPEN ---
# Real SSH banner check — frozen VMs accept TCP but never send SSH-
check_ssh_port_open() {
    local port=$1
    local banner
    banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/localhost/$port && cat <&3" 2>/dev/null | head -1)
    [[ "$banner" == SSH-* ]] && return 0
    return 1
}

# --- KILL VM ---
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

# --- IS VM RUNNING ---
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

# --- BUILD QEMU COMMAND ---
build_qemu_cmd() {
    local vm_name=$1
    local live_img="$BACKUP_DIR/$vm_name.img"
    local seed_file="$BACKUP_DIR/$vm_name-seed.iso"
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"

    local kvm_flag="-enable-kvm -cpu host,+x2apic"
    if [[ ! -w /dev/kvm ]]; then
        print_status "WARN" "KVM not available — using TCG"
        kvm_flag="-accel tcg,thread=multi -cpu qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt"
    fi

    local cmd=(
        qemu-system-x86_64
        $kvm_flag
        -machine q35,mem-merge=off
        -m "$MEMORY"
        -smp "$CPUS"
        -cpu host,+x2apic
        -drive "file=$live_img,format=qcow2,if=virtio,cache=writeback,discard=unmap,aio=threads"
        -drive "file=$seed_file,format=raw,if=virtio,cache=writeback"
        -boot order=c
        -device virtio-net-pci,netdev=n0
        -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0
        -device virtio-balloon-pci
        -global kvm-pit.lost_tick_policy=delay
        -no-hpet
        -rtc base=utc,clock=host,driftfix=slew
        -watchdog-action reset
        -serial "file:$serial_log"
        -display none
        -daemonize
        -pidfile "$BACKUP_DIR/$vm_name.pid"
    )

    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        local idx=1
        for forward in "${forwards[@]}"; do
            IFS=':' read -r host_port guest_port <<< "$forward"
            cmd+=(-device "virtio-net-pci,netdev=n$idx")
            cmd+=(-netdev "user,id=n$idx,hostfwd=tcp::$host_port-:$guest_port")
            ((idx++))
        done
    fi

    echo "${cmd[@]}"
}

# --- APPLY POST BOOT FIXES ---
apply_post_boot_fixes() {
    local port=$1
    local user=$2
    local pass=$3

    if ! command -v sshpass &>/dev/null; then
        print_status "WARN" "sshpass not found — skipping"
        return 0
    fi

    print_status "INFO" "Applying post-boot hardening + starting services..."
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

    sshpass -p "$pass" ssh $ssh_opts -p "$port" "${user}@localhost" bash <<'REMOTE'
# Journald fix
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/no-freeze.conf > /dev/null <<'JF'
[Journal]
Storage=volatile
SyncIntervalSec=0
RateLimitBurst=0
JF
sudo systemctl restart systemd-journald || true

# Docker fix
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

# Start tailscale
sudo tailscale up || true

# Fix sshx service to run as nexus user
sudo systemctl stop sshx || true
sudo systemctl disable sshx || true
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

# Run restart script only if Pelican is configured
sleep 5
BASE_URL="https://raw.githubusercontent.com/Adexx-11234/newrepo/main"
if [[ -f /root/.pelican.env ]] || [[ -f /var/www/pelican/.env ]]; then
    curl -fsSL "${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh && sudo bash /tmp/nexus-restart.sh && rm -f /tmp/nexus-restart.sh
fi
REMOTE

    print_status "SUCCESS" "Post-boot setup done"
}

# --- WAIT FOR SSH WITH FREEZE DETECTION ---
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

# --- FREEZE RECOVERY ---
# Waits for compressed snapshot → kills VM → restores → restarts
freeze_recovery() {
    local vm_name=$1
    local live_img="$BACKUP_DIR/$vm_name.img"
    local snapshot_img="$SNAPSHOT_DIR/$vm_name.img"
    local snapshot_compressed="$SNAPSHOT_DIR/$vm_name.img.compressed"
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"

    echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY STARTED =====" >> "$watchdog_log"

    # Step 1 — Wait for compressed snapshot (up to 20 mins)
    echo "[$(date '+%H:%M:%S')] Step 1: Waiting for compressed snapshot..." >> "$watchdog_log"
    local wait_elapsed=0
    local use_snapshot=""

    while true; do
        if [[ -f "$snapshot_compressed" ]] && [[ ! -f "${snapshot_compressed}.compressing" ]]; then
            use_snapshot="$snapshot_compressed"
            echo "[$(date '+%H:%M:%S')] Compressed snapshot ready" >> "$watchdog_log"
            break
        fi
        if [[ $wait_elapsed -ge 1200 ]]; then
            if [[ -f "$snapshot_img" ]]; then
                use_snapshot="$snapshot_img"
                echo "[$(date '+%H:%M:%S')] Compression timeout — using uncompressed snapshot" >> "$watchdog_log"
                break
            else
                echo "[$(date '+%H:%M:%S')] ERROR: No snapshot available for recovery" >> "$watchdog_log"
                return 1
            fi
        fi
        echo "[$(date '+%H:%M:%S')] Waiting for compression... (${wait_elapsed}s elapsed)" >> "$watchdog_log"
        sleep 30
        wait_elapsed=$((wait_elapsed + 30))
    done

    # Step 2 — Kill frozen VM
    echo "[$(date '+%H:%M:%S')] Step 2: Killing frozen VM..." >> "$watchdog_log"
    kill_vm "$vm_name"
    sleep 2

    # Step 3 — Restore to /home (atomic swap)
    echo "[$(date '+%H:%M:%S')] Step 3: Restoring snapshot to /home..." >> "$watchdog_log"
    local tmp_live="${live_img}.restoring"

    if cp "$use_snapshot" "$tmp_live"; then
        if qemu-img check "$tmp_live" >> "$watchdog_log" 2>&1; then
            mv "$tmp_live" "$live_img"
            echo "[$(date '+%H:%M:%S')] Restore verified OK" >> "$watchdog_log"
        else
            rm -f "$tmp_live"
            echo "[$(date '+%H:%M:%S')] ERROR: Verification failed — keeping old image" >> "$watchdog_log"
            return 1
        fi
    else
        echo "[$(date '+%H:%M:%S')] ERROR: Copy failed" >> "$watchdog_log"
        return 1
    fi

    # Step 4 — Restart VM
    echo "[$(date '+%H:%M:%S')] Step 4: Restarting VM..." >> "$watchdog_log"
    rm -f "$serial_log"
    local qemu_cmd
    qemu_cmd=$(build_qemu_cmd "$vm_name")
    if ! eval "$qemu_cmd" >> "$watchdog_log" 2>&1; then
        echo "[$(date '+%H:%M:%S')] ERROR: Failed to restart VM" >> "$watchdog_log"
        return 1
    fi

    # Step 5 — Wait for SSH then post-recovery
    local elapsed=0
    while [[ $elapsed -lt 120 ]]; do
        if check_ssh_port_open "$SSH_PORT"; then
            echo "[$(date '+%H:%M:%S')] SSH ready — post-recovery setup..." >> "$watchdog_log"
            sleep 10
            apply_post_boot_fixes "$SSH_PORT" "$USERNAME" "$PASSWORD"
            echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY COMPLETE =====" >> "$watchdog_log"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "[$(date '+%H:%M:%S')] WARNING: SSH did not respond after recovery" >> "$watchdog_log"
    return 1
}

# --- BACKGROUND WATCHDOG ---
# All functions inlined to avoid subshell scope issues
start_freeze_watchdog() {
    local vm_name=$1
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    local _BACKUP_DIR="$BACKUP_DIR"
    local _SNAPSHOT_DIR="$SNAPSHOT_DIR"
    local _SSH_PORT="$SSH_PORT"
    local _PASSWORD="$PASSWORD"
    local _USERNAME="$USERNAME"

    (
        check_ssh_local() {
            local port=$1
            local banner
            banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/localhost/$port && cat <&3" 2>/dev/null | head -1)
            [[ "$banner" == SSH-* ]] && return 0
            return 1
        }

        kill_vm_local() {
            local vm=$1
            local pid_file="$_BACKUP_DIR/$vm.pid"
            if [[ -f "$pid_file" ]]; then
                local pid
                pid=$(cat "$pid_file" 2>/dev/null) || true
                [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 2; kill -9 "$pid" 2>/dev/null || true; }
                rm -f "$pid_file"
            fi
            pkill -f "qemu-system-x86_64.*$_BACKUP_DIR/$vm" 2>/dev/null || true
        }

        recover_local() {
            local vm=$1
            local live_img="$_BACKUP_DIR/$vm.img"
            local snap_compressed="$_SNAPSHOT_DIR/$vm.img.compressed"
            local snap_img="$_SNAPSHOT_DIR/$vm.img"
            local serial="$_BACKUP_DIR/$vm.serial.log"
            local wlog="$_BACKUP_DIR/$vm.watchdog.log"

            echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY STARTED =====" >> "$wlog"

            # Wait for compressed snapshot
            echo "[$(date '+%H:%M:%S')] Step 1: Waiting for compressed snapshot..." >> "$wlog"
            local waited=0
            local use_snap=""
            while true; do
                if [[ -f "$snap_compressed" ]] && [[ ! -f "${snap_compressed}.compressing" ]]; then
                    use_snap="$snap_compressed"
                    echo "[$(date '+%H:%M:%S')] Compressed snapshot ready" >> "$wlog"
                    break
                fi
                if [[ $waited -ge 1200 ]]; then
                    if [[ -f "$snap_img" ]]; then
                        use_snap="$snap_img"
                        echo "[$(date '+%H:%M:%S')] Timeout — using uncompressed" >> "$wlog"
                        break
                    else
                        echo "[$(date '+%H:%M:%S')] ERROR: No snapshot available" >> "$wlog"
                        return 1
                    fi
                fi
                echo "[$(date '+%H:%M:%S')] Waiting for compression... (${waited}s)" >> "$wlog"
                sleep 30
                waited=$((waited + 30))
            done

            # Kill VM
            echo "[$(date '+%H:%M:%S')] Step 2: Killing frozen VM..." >> "$wlog"
            kill_vm_local "$vm"
            sleep 2

            # Restore
            echo "[$(date '+%H:%M:%S')] Step 3: Restoring to /home..." >> "$wlog"
            local tmp="${live_img}.restoring"
            if cp "$use_snap" "$tmp"; then
                if qemu-img check "$tmp" >> "$wlog" 2>&1; then
                    mv "$tmp" "$live_img"
                    echo "[$(date '+%H:%M:%S')] Restore verified OK" >> "$wlog"
                else
                    rm -f "$tmp"
                    echo "[$(date '+%H:%M:%S')] ERROR: Verification failed" >> "$wlog"
                    return 1
                fi
            else
                echo "[$(date '+%H:%M:%S')] ERROR: Copy failed" >> "$wlog"
                return 1
            fi

            # Restart VM
            echo "[$(date '+%H:%M:%S')] Step 4: Restarting VM..." >> "$wlog"
            rm -f "$serial"

            local kvm_flag="-enable-kvm -cpu host,+x2apic"
            [[ ! -w /dev/kvm ]] && kvm_flag="-accel tcg,thread=multi -cpu qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt"
            local mem cpus ssh_port
            mem=$(grep ^MEMORY "$_BACKUP_DIR/$vm.conf" 2>/dev/null | cut -d'"' -f2)
            cpus=$(grep ^CPUS "$_BACKUP_DIR/$vm.conf" 2>/dev/null | cut -d'"' -f2)
            ssh_port=$(grep ^SSH_PORT "$_BACKUP_DIR/$vm.conf" 2>/dev/null | cut -d'"' -f2)

            local qcmd="qemu-system-x86_64 $kvm_flag -machine q35,mem-merge=off -m $mem -smp $cpus -cpu host,+x2apic"
            qcmd+=" -drive file=$live_img,format=qcow2,if=virtio,cache=writeback,discard=unmap,aio=threads"
            qcmd+=" -drive file=$_BACKUP_DIR/$vm-seed.iso,format=raw,if=virtio,cache=writeback"
            qcmd+=" -boot order=c -device virtio-net-pci,netdev=n0"
            qcmd+=" -netdev user,id=n0,hostfwd=tcp::${ssh_port}-:22"
            qcmd+=" -object rng-random,filename=/dev/urandom,id=rng0"
            qcmd+=" -device virtio-rng-pci,rng=rng0 -device virtio-balloon-pci"
            qcmd+=" -global kvm-pit.lost_tick_policy=delay -no-hpet"
            qcmd+=" -rtc base=utc,clock=host,driftfix=slew -watchdog-action reset"
            qcmd+=" -serial file:$serial -display none -daemonize"
            qcmd+=" -pidfile $_BACKUP_DIR/$vm.pid"

            if ! eval "$qcmd" >> "$wlog" 2>&1; then
                echo "[$(date '+%H:%M:%S')] ERROR: Restart failed" >> "$wlog"
                return 1
            fi

            # Wait for SSH then post-recovery
            local el=0
            while [[ $el -lt 120 ]]; do
                if check_ssh_local "$ssh_port"; then
                    echo "[$(date '+%H:%M:%S')] SSH ready — post-recovery setup..." >> "$wlog"
                    sleep 10
                    sshpass -p "$_PASSWORD" ssh \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        -o ConnectTimeout=15 \
                        -o LogLevel=ERROR \
                        -p "$ssh_port" "${_USERNAME}@localhost" bash <<REMOTE >> "$wlog" 2>&1
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
# Run restart script only if Pelican is configured
BASE_URL="https://raw.githubusercontent.com/Adexx-11234/newrepo/main"
if [[ -f /root/.pelican.env ]] || [[ -f /var/www/pelican/.env ]]; then
    curl -fsSL "\${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh && sudo bash /tmp/nexus-restart.sh && rm -f /tmp/nexus-restart.sh
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

# --- PERIODIC SNAPSHOT LOOP ---
# Continuously maintains compressed snapshot
# Flow: wait for .compressed → delete it → copy live → compress → repeat
start_periodic_snapshot() {
    local vm_name=$1
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    local _BACKUP_DIR="$BACKUP_DIR"
    local _SNAPSHOT_DIR="$SNAPSHOT_DIR"

    (
        is_running_local() {
            local vm=$1
            local pid_file="$_BACKUP_DIR/$vm.pid"
            [[ -f "$pid_file" ]] || return 1
            local pid
            pid=$(cat "$pid_file" 2>/dev/null) || return 1
            kill -0 "$pid" 2>/dev/null && return 0
            return 1
        }

        local wlog="$watchdog_log"
        local live_img="$_BACKUP_DIR/$vm_name.img"
        local snap_img="$_SNAPSHOT_DIR/$vm_name.img"
        local snap_compressed="$_SNAPSHOT_DIR/$vm_name.img.compressed"

# Wait for initial compression before starting loop
echo "[$(date '+%H:%M:%S')] Periodic snapshot: waiting for initial compression..." >> "$wlog"
while true; do
    if [[ -f "$snap_compressed" ]] && \
       [[ ! -f "${snap_compressed}.compressing" ]] && \
       [[ ! -f "$snap_img" ]]; then
        break
    fi
    sleep 60
    if ! is_running_local "$vm_name"; then
        echo "[$(date '+%H:%M:%S')] Periodic snapshot: VM stopped — exiting" >> "$wlog"
        exit 0
    fi
done

        echo "[$(date '+%H:%M:%S')] Periodic snapshot loop started" >> "$wlog"

        while true; do
            sleep 1200  # 20 mins between cycles

            if ! is_running_local "$vm_name"; then
                echo "[$(date '+%H:%M:%S')] Periodic snapshot: VM stopped — exiting" >> "$wlog"
                exit 0
            fi

            echo "[$(date '+%H:%M:%S')] === Periodic snapshot cycle ===" >> "$wlog"

            # Step 1 — Delete old compressed snapshot to free space
            echo "[$(date '+%H:%M:%S')] Deleting old compressed snapshot..." >> "$wlog"
            rm -f "$snap_compressed"

            # Step 2 — Check space then copy live image
            local free_kb
            free_kb=$(df -k "/" 2>/dev/null | awk 'NR==2{print $4}')
            local free_gb=$(( free_kb / 1024 / 1024 ))
            if [[ $free_gb -lt 8 ]]; then
                echo "[$(date '+%H:%M:%S')] Not enough tmpfs space (${free_gb}G free) — skipping cycle" >> "$wlog"
                continue
            fi

            echo "[$(date '+%H:%M:%S')] Copying live image to tmpfs..." >> "$wlog"
            if ! cp "$live_img" "$snap_img"; then
                echo "[$(date '+%H:%M:%S')] Copy failed — skipping cycle" >> "$wlog"
                continue
            fi
            echo "[$(date '+%H:%M:%S')] Copy done ($(du -sh "$snap_img" | awk '{print $1}'))" >> "$wlog"

            # Step 3 — Compress (blocking — we wait for it before next cycle)
            echo "[$(date '+%H:%M:%S')] Compressing snapshot..." >> "$wlog"
            local tmp_c="${snap_compressed}.compressing"
            if qemu-img convert -O qcow2 -c "$snap_img" "$tmp_c" >> "$wlog" 2>&1; then
                mv "$tmp_c" "$snap_compressed"
                rm -f "$snap_img"
                local sz
                sz=$(du -sh "$snap_compressed" 2>/dev/null | awk '{print $1}')
                echo "[$(date '+%H:%M:%S')] Snapshot updated: $sz compressed" >> "$wlog"
            else
                rm -f "$tmp_c"
                echo "[$(date '+%H:%M:%S')] Compression failed — keeping uncompressed copy" >> "$wlog"
            fi
        done
    ) >> "$watchdog_log" 2>&1 &

    disown
    print_status "SUCCESS" "Periodic snapshot loop started"
}

# --- SSH INTO VM ---
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

# --- SETUP VM IMAGE (first time) ---
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
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - systemctl restart systemd-journald
  - journalctl --vacuum-size=1M 2>/dev/null || true
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

# --- CREATE NEW VM ---
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
    SNAPSHOT_IMG="$SNAPSHOT_DIR/$VM_NAME.img"
    SNAPSHOT_COMPRESSED="$SNAPSHOT_DIR/$VM_NAME.img.compressed"
    SEED_FILE="$BACKUP_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    setup_vm_image
    save_vm_config
}

# --- START VM ---
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

    # Create initial snapshot and start background compression
    ensure_snapshot "$vm_name" || print_status "WARN" "Could not create snapshot — continuing without"

    rm -f "$BACKUP_DIR/$vm_name.serial.log"
    > "$BACKUP_DIR/$vm_name.watchdog.log"
    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true
    ssh-keygen -R "localhost" 2>/dev/null || true

    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "SSH: port $SSH_PORT | user: $USERNAME | pass: $PASSWORD"

    local qemu_cmd
    qemu_cmd=$(build_qemu_cmd "$vm_name")
    eval "$qemu_cmd" || {
        print_status "ERROR" "Failed to start QEMU"
        return 1
    }

    # Start watchdog and periodic snapshot loop
    start_freeze_watchdog "$vm_name"
    start_periodic_snapshot "$vm_name"

    if wait_for_ssh "$vm_name"; then
        sleep 10
        apply_post_boot_fixes "$SSH_PORT" "$USERNAME" "$PASSWORD"
        ssh_into_vm "$vm_name"
        print_status "INFO" "SSH session ended. Goodbye!"
        exit 0
    else
        print_status "ERROR" "VM failed to boot. Check logs:"
        print_status "INFO"  "  Serial:   tail -30 $BACKUP_DIR/$vm_name.serial.log"
        print_status "INFO"  "  Watchdog: tail -30 $BACKUP_DIR/$vm_name.watchdog.log"
    fi
}

# --- STOP VM ---
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

# --- ATTACH WATCHDOG ---
attach_watchdog() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if ! is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is not running"
        return 1
    fi

    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    echo "[$(date '+%H:%M:%S')] Watchdog manually attached" >> "$watchdog_log"
    ensure_snapshot "$vm_name" || true
    start_freeze_watchdog "$vm_name"
    start_periodic_snapshot "$vm_name"
    print_status "SUCCESS" "Watchdog + snapshot loop attached"
    print_status "INFO"    "Monitor: tail -f $watchdog_log"
}

# --- SHOW VM INFO ---
show_vm_info() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    local status="Stopped"
    is_vm_running "$vm_name" && status="Running"

    local snap_status="None"
    [[ -f "$SNAPSHOT_COMPRESSED" ]] && snap_status="Compressed ($(du -sh "$SNAPSHOT_COMPRESSED" | awk '{print $1}')) — ready"
    [[ -f "${SNAPSHOT_COMPRESSED}.compressing" ]] && snap_status="Compressing in progress..."
    [[ -f "$SNAPSHOT_IMG" ]] && [[ ! -f "${SNAPSHOT_COMPRESSED}.compressing" ]] && snap_status="Uncompressed copy exists — compression starting"

    echo ""
    print_status "INFO" "VM: $vm_name"
    echo "=========================================="
    echo "Status:        $status"
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

# --- DELETE VM ---
delete_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    print_status "WARN" "This permanently deletes VM '$vm_name' and ALL data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        is_vm_running "$vm_name" && kill_vm "$vm_name"
        rm -f "$LIVE_IMG" "$SNAPSHOT_IMG" "$SNAPSHOT_COMPRESSED"
        rm -f "${SNAPSHOT_COMPRESSED}.compressing" "$SEED_FILE"
        rm -f "$BACKUP_DIR/$vm_name.conf" "$BACKUP_DIR/$vm_name.pid"
        rm -f "$BACKUP_DIR/$vm_name.serial.log" "$BACKUP_DIR/$vm_name.watchdog.log"
        print_status "SUCCESS" "VM '$vm_name' deleted"
    else
        print_status "INFO" "Cancelled"
    fi
}

# --- EDIT VM CONFIG ---
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

# --- RESIZE VM DISK ---
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

# --- SHOW VM PERFORMANCE ---
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
    echo "Live image:  $(du -sh "$LIVE_IMG" 2>/dev/null | awk '{print $1}')"
    [[ -f "$SNAPSHOT_IMG" ]] && echo "Snapshot:    $(du -sh "$SNAPSHOT_IMG" 2>/dev/null | awk '{print $1}') (uncompressed — compressing...)"
    [[ -f "$SNAPSHOT_COMPRESSED" ]] && echo "Snapshot:    $(du -sh "$SNAPSHOT_COMPRESSED" 2>/dev/null | awk '{print $1}') (compressed — ready)"
    echo ""
    df -h /home | tail -1 | awk '{print "/home:   " $4 " free of " $2}'
    df -h /     | tail -1 | awk '{print "tmpfs:   " $4 " free of " $2}'
    echo "=========================================="
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# --- VIEW SERIAL LOG ---
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

# --- VIEW WATCHDOG LOG ---
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

# --- MAIN MENU ---
main_menu() {
    while true; do
        display_header

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
                [[ -f "$SNAPSHOT_DIR/${vms[$i]}.img.compressed" ]] && snap_indicator=" ${GREEN}[snapshot ready]${NC}"
                [[ -f "$SNAPSHOT_DIR/${vms[$i]}.img" ]] && snap_indicator=" ${YELLOW}[compressing...]${NC}"
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
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && start_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            3)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && stop_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            4)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && show_vm_info "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            5)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && edit_vm_config "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            6)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && delete_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            7)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && resize_vm_disk "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            8)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && show_vm_performance "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            9)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && view_serial_log "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            10)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && view_watchdog_log "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            11)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && attach_watchdog "${vms[$((n-1))]}" || print_status "ERROR" "Invalid"
                ;;
            0) print_status "INFO" "Goodbye!"; exit 0 ;;
            *) print_status "ERROR" "Invalid option" ;;
        esac

        read -p "$(print_status "INPUT" "Press Enter to continue...")" 2>/dev/null || true
    done
}

# --- INIT ---
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