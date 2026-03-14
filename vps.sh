#!/usr/bin/env bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager v2.4
# Created by NexusTechPro
# - FIXED: virtio drivers (prevents freeze)
# - FIXED: Boot detection via TCP port check (no SSH key auth needed)
# - FIXED: Already-running VM recognized immediately
# - FIXED: Default RAM 4096 MB
# - FIXED: Nested-VM / container host optimizations (IDX/Nix)
# - FIXED: journald volatile storage (no fsync freeze)
# - FIXED: cache=writeback QEMU I/O (stable in nested virt)
# - FIXED: Docker daemon.json pre-configured (no NIC conflicts)
# - FIXED: SSH host key auto-cleared on every start (no MITM warning)
# - NEW:   Auto-SSH into VM after boot (no manual ssh command needed)
# - NEW:   SSH fingerprint auto-accepted (no yes/no prompt ever)
# - NEW:   Post-boot hardening applied automatically via SSH
# - NEW:   Menu exits cleanly after connecting to VM
# - NEW:   Auto-backup to /tmp on freeze (SSH timeout < 60s)
# =============================

# --- ANSI COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;97m'
NC='\033[0m'

# --- HEADER ---
display_header() {
    clear
    echo -e "${BLUE}========================================================================"
    echo -e "  Created by NexusTechPro"
    echo -e "  Enhanced Multi-VM Manager v2.4"
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
        "size")     [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || { print_status "ERROR" "Must be a size with unit (e.g., 20G)"; return 1; } ;;
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

# --- GET VM LIST ---
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# --- LOAD VM CONFIG ---
load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

# --- SAVE VM CONFIG ---
save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
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
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# --- BACKUP VM IMAGE TO /tmp ---
backup_vm_to_tmp() {
    local vm_name=$1
    local img_file="$VM_DIR/$vm_name.img"
    local backup_file="/tmp/${vm_name}-backup.img"

    local img_size
    img_size=$(du -sm "$img_file" 2>/dev/null | awk '{print $1}')
    local tmp_free
    tmp_free=$(df -m /tmp 2>/dev/null | awk 'NR==2{print $4}')

    if [[ -z "$img_size" || -z "$tmp_free" ]]; then
        print_status "WARN" "Could not check space — skipping backup"
        return 1
    fi

    if [[ $tmp_free -lt $img_size ]]; then
        print_status "WARN" "Not enough space in /tmp (need ${img_size}MB, have ${tmp_free}MB)"
        return 1
    fi

    print_status "INFO" "Backing up VM image to /tmp (${img_size}MB)..."
    if qemu-img convert -O qcow2 -c "$img_file" "$backup_file" 2>/dev/null; then
        print_status "SUCCESS" "Backup saved: $backup_file ($(du -sh "$backup_file" | awk '{print $1}'))"
        return 0
    else
        rm -f "$backup_file" 2>/dev/null || true
        print_status "WARN" "Backup failed"
        return 1
    fi
}

# --- RESTORE VM FROM /tmp BACKUP ---
restore_vm_from_tmp() {
    local vm_name=$1
    local backup_file="/tmp/${vm_name}-backup.img"
    local img_file="$VM_DIR/$vm_name.img"

    if [[ ! -f "$backup_file" ]]; then
        print_status "ERROR" "No backup found at $backup_file"
        return 1
    fi

    print_status "INFO" "Restoring VM from backup..."
    kill_vm "$vm_name" 2>/dev/null || true
    sleep 2

    if cp "$backup_file" "$img_file"; then
        print_status "SUCCESS" "VM restored from backup"
        return 0
    else
        print_status "ERROR" "Restore failed"
        return 1
    fi
}

# --- SETUP VM IMAGE ---
setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    mkdir -p "$VM_DIR"

    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image file already exists. Skipping download."
    else
        print_status "INFO" "Downloading image from $IMG_URL..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Failed to download image"
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi

    qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null || true

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
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    }

    print_status "SUCCESS" "VM '$VM_NAME' image ready."
}

# --- BUILD QEMU COMMAND ---
build_qemu_cmd() {
    local vm_name=$1
    local serial_log="$VM_DIR/$vm_name.serial.log"

    local kvm_flag="-enable-kvm"
    if [[ ! -w /dev/kvm ]]; then
        print_status "WARN" "KVM not available — using TCG (slower but stable)"
        kvm_flag="-accel tcg,thread=multi"
    fi

    local cmd=(
        qemu-system-x86_64
        $kvm_flag
        -machine q35,mem-merge=off
        -m "$MEMORY"
        -smp "$CPUS"
        -cpu host,+x2apic
        -drive "file=$IMG_FILE,format=qcow2,if=virtio,cache=writeback,discard=unmap,aio=threads"
        -drive "file=$SEED_FILE,format=raw,if=virtio,cache=writeback"
        -boot order=c
        -device virtio-net-pci,netdev=n0
        -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        -object rng-random,filename=/dev/urandom,id=rng0
        -device virtio-rng-pci,rng=rng0
        -device virtio-balloon-pci
        -serial "file:$serial_log"
        -display none
        -daemonize
        -pidfile "$VM_DIR/$vm_name.pid"
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

# --- CHECK SSH PORT OPEN ---
check_ssh_port_open() {
    local port=$1
    if (echo >/dev/tcp/localhost/"$port") 2>/dev/null; then
        return 0
    elif command -v nc &>/dev/null && nc -z -w2 localhost "$port" 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- APPLY POST-BOOT FIXES ---
apply_post_boot_fixes() {
    local port=$1
    local user=$2
    local pass=$3

    if ! command -v sshpass &>/dev/null; then
        print_status "WARN" "sshpass not found — skipping auto-fixes"
        return 0
    fi

    print_status "INFO" "Applying post-boot hardening..."

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

    sshpass -p "$pass" ssh $ssh_opts -p "$port" "${user}@localhost" bash <<'REMOTE' 2>/dev/null || true
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/no-freeze.conf <<'JF'
[Journal]
Storage=volatile
SyncIntervalSec=0
RateLimitBurst=0
JF
systemctl restart systemd-journald 2>/dev/null || true
journalctl --vacuum-size=1M 2>/dev/null || true
if command -v docker &>/dev/null; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'DF'
{
  "dns": ["8.8.8.8", "1.1.1.1"],
  "dns-opts": ["ndots:0"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "iptables": true,
  "userland-proxy": false
}
DF
    systemctl restart docker 2>/dev/null || true
fi
REMOTE

    print_status "SUCCESS" "Post-boot hardening applied"
}

# --- WAIT FOR SSH WITH FREEZE DETECTION + AUTO BACKUP ---
wait_for_ssh() {
    local vm_name=$1
    local max_wait=60
    local elapsed=0
    local freeze_recovery=0

    print_status "INFO" "Waiting for VM to boot (max ${max_wait}s)..."
    echo -n "   "

    while [[ $elapsed -lt $max_wait ]]; do
        if check_ssh_port_open "$SSH_PORT"; then
            echo ""
            print_status "SUCCESS" "SSH port open after ${elapsed}s"
            return 0
        fi

        # Freeze detection via serial log staleness
        local serial_log="$VM_DIR/$vm_name.serial.log"
        if [[ -f "$serial_log" ]]; then
            local last_modified now age
            last_modified=$(stat -c %Y "$serial_log" 2>/dev/null || echo 0)
            now=$(date +%s)
            age=$((now - last_modified))

            if [[ $age -gt 30 ]]; then
                local last_line
                last_line=$(tail -1 "$serial_log" 2>/dev/null || echo "")
                if echo "$last_line" | grep -q "journal\|bridge\|udevd\|Starting systemd"; then
                    echo ""
                    print_status "WARN" "Freeze detected at: $last_line"

                    if [[ $freeze_recovery -ge 2 ]]; then
                        print_status "ERROR" "VM frozen 3 times — giving up"
                        return 1
                    fi

                    # Auto-backup to /tmp before recovery attempt
                    print_status "INFO" "Auto-backing up VM image to /tmp before recovery..."
                    kill_vm "$vm_name" 2>/dev/null || true
                    sleep 2
                    backup_vm_to_tmp "$vm_name" || true

                    # Restart VM
                    rm -f "$serial_log"
                    local qemu_cmd
                    qemu_cmd=$(build_qemu_cmd "$vm_name")
                    eval "$qemu_cmd" || true
                    ((freeze_recovery++))
                    elapsed=0
                    print_status "INFO" "VM restarted (attempt $freeze_recovery), waiting again..."
                    echo -n "   "
                fi
            fi
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done

    echo ""

    # SSH timeout after 60s = freeze likely — backup now
    if ! check_ssh_port_open "$SSH_PORT"; then
        print_status "WARN" "SSH did not respond within ${max_wait}s — possible freeze"
        print_status "INFO" "Auto-backing up VM image to /tmp..."
        kill_vm "$vm_name" 2>/dev/null || true
        sleep 2
        backup_vm_to_tmp "$vm_name" || true
        print_status "INFO" "Backup done. Restart the VM to try again."
        return 1
    fi

    if is_vm_running "$vm_name"; then
        print_status "SUCCESS" "VM is running (boot took >${max_wait}s)"
        return 0
    fi

    print_status "ERROR" "VM process died before boot completed"
    return 1
}

# --- KILL VM ---
kill_vm() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
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
    pkill -f "qemu-system-x86_64.*$VM_DIR/$vm_name" 2>/dev/null || true
}

# --- IS VM RUNNING ---
is_vm_running() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || return 1
        kill -0 "$pid" 2>/dev/null && return 0
    fi
    return 1
}

# --- SSH INTO VM ---
ssh_into_vm() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    if ! is_vm_running "$vm_name"; then
        print_status "ERROR" "VM '$vm_name' is not running. Start it first (option 2)."
        return 1
    fi

    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true

    sleep 7

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
        print_status "INFO" "Password: ${PASSWORD}"
        ssh $ssh_opts -p "$SSH_PORT" "${USERNAME}@localhost"
    fi
}

# --- CREATE NEW VM ---
create_new_vm() {
    print_status "INFO" "Creating a new VM"

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
        [[ -f "$VM_DIR/$VM_NAME.conf" ]] && { print_status "ERROR" "VM '$VM_NAME' already exists"; continue; }
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
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
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

    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, or press Enter for none): ")" PORT_FORWARDS
    PORT_FORWARDS="${PORT_FORWARDS:-}"
    GUI_MODE=false

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
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

    if [[ ! -f "$IMG_FILE" ]]; then
        local backup_file="/tmp/${vm_name}-backup.img"
        if [[ -f "$backup_file" ]]; then
            print_status "WARN" "VM image missing but backup found in /tmp"
            read -p "$(print_status "INPUT" "Restore from /tmp backup? (Y/n): ")" restore_choice
            restore_choice="${restore_choice:-Y}"
            if [[ "$restore_choice" =~ ^[Yy]$ ]]; then
                restore_vm_from_tmp "$vm_name" || { print_status "ERROR" "Restore failed"; return 1; }
            else
                print_status "ERROR" "VM image not found: $IMG_FILE"
                return 1
            fi
        else
            print_status "ERROR" "VM image not found: $IMG_FILE"
            return 1
        fi
    fi

    if [[ ! -f "$SEED_FILE" ]]; then
        print_status "WARN" "Seed file missing, recreating..."
        setup_vm_image
    fi

    rm -f "$VM_DIR/$vm_name.serial.log"
    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true
    ssh-keygen -R "localhost" 2>/dev/null || true

    print_status "INFO" "Starting VM: $vm_name"
    print_status "INFO" "SSH port: $SSH_PORT | User: ${USERNAME} | Password: ${PASSWORD}"

    local qemu_cmd
    qemu_cmd=$(build_qemu_cmd "$vm_name")
    eval "$qemu_cmd" || {
        print_status "ERROR" "Failed to start QEMU"
        return 1
    }

    if wait_for_ssh "$vm_name"; then
        apply_post_boot_fixes "$SSH_PORT" "$USERNAME" "$PASSWORD"
        ssh_into_vm "$vm_name"
        print_status "INFO" "SSH session ended. Goodbye!"
        exit 0
    else
        print_status "ERROR" "VM failed to boot. Check serial log:"
        print_status "INFO" "  tail -30 $VM_DIR/$vm_name.serial.log"
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

# --- SHOW VM INFO ---
show_vm_info() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    local status="Stopped"
    is_vm_running "$vm_name" && status="Running"

    local backup_status="None"
    [[ -f "/tmp/${vm_name}-backup.img" ]] && backup_status="Available (/tmp/${vm_name}-backup.img)"

    echo ""
    print_status "INFO" "VM Information: $vm_name"
    echo "=========================================="
    echo "Status:        $status"
    echo "OS:            $OS_TYPE ($CODENAME)"
    echo "Hostname:      $HOSTNAME"
    echo "Username:      $USERNAME"
    echo "Password:      $PASSWORD"
    echo "SSH Port:      $SSH_PORT"
    echo "Memory:        $MEMORY MB"
    echo "CPUs:          $CPUS"
    echo "Disk:          $DISK_SIZE"
    echo "Port Forwards: ${PORT_FORWARDS:-None}"
    echo "Created:       $CREATED"
    echo "Image:         $IMG_FILE"
    echo "Seed:          $SEED_FILE"
    echo "Serial Log:    $VM_DIR/$vm_name.serial.log"
    echo "Backup (/tmp): $backup_status"
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

    print_status "WARN" "This will permanently delete VM '$vm_name' and all its data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        is_vm_running "$vm_name" && kill_vm "$vm_name"
        rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf" "$VM_DIR/$vm_name.pid" "$VM_DIR/$vm_name.serial.log"
        rm -f "/tmp/${vm_name}-backup.img" 2>/dev/null || true
        print_status "SUCCESS" "VM '$vm_name' deleted"
    else
        print_status "INFO" "Deletion cancelled"
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
        echo "  7) Disk Size   8) Port Forwards"
        echo "  0) Back"
        read -p "$(print_status "INPUT" "Choice: ")" edit_choice

        case $edit_choice in
            1) read -p "$(print_status "INPUT" "New hostname [$HOSTNAME]: ")" v; HOSTNAME="${v:-$HOSTNAME}" ;;
            2) while true; do read -p "$(print_status "INPUT" "New username [$USERNAME]: ")" v; v="${v:-$USERNAME}"; validate_input "username" "$v" && { USERNAME="$v"; break; }; done ;;
            3) while true; do read -s -p "$(print_status "INPUT" "New password: ")" v; echo; [[ -n "$v" ]] && { PASSWORD="$v"; break; } || print_status "ERROR" "Cannot be empty"; done ;;
            4) while true; do read -p "$(print_status "INPUT" "New SSH port [$SSH_PORT]: ")" v; v="${v:-$SSH_PORT}"; validate_input "port" "$v" && { SSH_PORT="$v"; break; }; done ;;
            5) while true; do read -p "$(print_status "INPUT" "New memory MB [$MEMORY]: ")" v; v="${v:-$MEMORY}"; validate_input "number" "$v" && { MEMORY="$v"; break; }; done ;;
            6) while true; do read -p "$(print_status "INPUT" "New CPUs [$CPUS]: ")" v; v="${v:-$CPUS}"; validate_input "number" "$v" && { CPUS="$v"; break; }; done ;;
            7) while true; do read -p "$(print_status "INPUT" "New disk size [$DISK_SIZE]: ")" v; v="${v:-$DISK_SIZE}"; validate_input "size" "$v" && { DISK_SIZE="$v"; break; }; done ;;
            8) read -p "$(print_status "INPUT" "Port forwards [${PORT_FORWARDS:-none}]: ")" v; PORT_FORWARDS="${v:-$PORT_FORWARDS}" ;;
            0) return 0 ;;
            *) print_status "ERROR" "Invalid selection"; continue ;;
        esac

        [[ "$edit_choice" =~ ^[123]$ ]] && setup_vm_image
        save_vm_config
        read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" cont
        [[ "$cont" =~ ^[Yy]$ ]] || break
    done
}

# --- RESIZE VM DISK ---
resize_vm_disk() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    print_status "INFO" "Current disk size: $DISK_SIZE"
    while true; do
        read -p "$(print_status "INPUT" "New disk size (e.g., 50G): ")" new_size
        validate_input "size" "$new_size" || continue
        if qemu-img resize "$IMG_FILE" "$new_size"; then
            DISK_SIZE="$new_size"
            save_vm_config
            print_status "SUCCESS" "Disk resized to $new_size"
        else
            print_status "ERROR" "Failed to resize disk"
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
        pid=$(cat "$VM_DIR/$vm_name.pid" 2>/dev/null || pgrep -f "qemu.*$vm_name" | head -1)
        [[ -n "$pid" ]] && ps -p "$pid" -o pid,%cpu,%mem,rss,vsz --no-headers 2>/dev/null || true
        echo ""
        free -h
        echo ""
        du -h "$IMG_FILE" 2>/dev/null || true
        if [[ -f "$VM_DIR/$vm_name.serial.log" ]]; then
            echo ""
            echo "Last boot messages:"
            tail -5 "$VM_DIR/$vm_name.serial.log"
        fi
    else
        print_status "INFO" "VM not running"
        echo "Config: ${MEMORY}MB RAM | ${CPUS} CPUs | ${DISK_SIZE} Disk"
    fi
    echo "=========================================="
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# --- VIEW SERIAL LOG ---
view_serial_log() {
    local vm_name=$1
    if ! load_vm_config "$vm_name"; then return 1; fi

    local serial_log="$VM_DIR/$vm_name.serial.log"
    if [[ -f "$serial_log" ]]; then
        print_status "INFO" "Serial log for $vm_name (last 30 lines):"
        echo "=========================================="
        tail -30 "$serial_log"
        echo "=========================================="
    else
        print_status "WARN" "No serial log found for $vm_name"
    fi
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# --- MAIN MENU ---
main_menu() {
    while true; do
        display_header

        local vms=()
        mapfile -t vms < <(get_vm_list)
        local vm_count=${#vms[@]}

        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count existing VM(s):"
            for i in "${!vms[@]}"; do
                local status_color
                if is_vm_running "${vms[$i]}"; then
                    status_color="${GREEN}Running${NC}"
                else
                    status_color="${RED}Stopped${NC}"
                fi
                local backup_indicator=""
                [[ -f "/tmp/${vms[$i]}-backup.img" ]] && backup_indicator=" ${YELLOW}[backup in /tmp]${NC}"
                printf "  %2d) %s (" $((i+1)) "${vms[$i]}"
                echo -e "$status_color)$backup_indicator"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start VM + Auto-SSH in"
            echo "  3) Stop a VM"
            echo "  4) Show VM info / SSH connect"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            echo "  9) View serial log (freeze diagnosis)"
        fi
        echo "  0) Exit"
        echo

        read -p "$(print_status "INPUT" "Enter your choice: ")" choice

        case $choice in
            1) create_new_vm ;;
            2)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number to start: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && start_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
                ;;
            3)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number to stop: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && stop_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
                ;;
            4)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && show_vm_info "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
                ;;
            5)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number to edit: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && edit_vm_config "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
                ;;
            6)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number to delete: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && delete_vm "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
                ;;
            7)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number to resize: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && resize_vm_disk "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
                ;;
            8)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number for performance: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && show_vm_performance "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
                ;;
            9)
                [ $vm_count -eq 0 ] && continue
                read -p "$(print_status "INPUT" "VM number for serial log: ")" n
                [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $vm_count ] && view_serial_log "${vms[$((n-1))]}" || print_status "ERROR" "Invalid selection"
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

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

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