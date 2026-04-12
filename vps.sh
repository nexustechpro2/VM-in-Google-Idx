#!/usr/bin/env bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager v4.2
# Created by NexusTechPro
# Fixes in v4.2:
#   - Single watchdog enforcement — kills old watchdog before spawning new
#   - Recovery lock file — prevents concurrent recoveries
#   - BASE_URL / PHP_VER unbound variable fixed in watchdog SSH block
#   - sudo mkdir/vncpasswd fixed in watchdog VNC block
#   - Pelican detection fixed — PELICAN_FOUND pattern, sudo bash, log tail
#   - set +euo pipefail added to all remote SSH heredocs in watchdog
#   - _recover_done() helper cleans lock on every return path
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
BACKUP_DIR="${BACKUP_DIR:-/home/user/vms}"
SNAPSHOT_DIR="/nexusvms"

# ============================================================================
# HELPERS
# ============================================================================

display_header() {
    clear
    echo -e "${BLUE}========================================================================"
    echo -e "  Created by NexusTechPro"
    echo -e "  Enhanced Multi-VM Manager v4.2"
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
    if ! command -v sshpass &>/dev/null; then
        print_status "INFO" "Installing sshpass..."
        apt-get install -y sshpass 2>/dev/null || true
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
# ============================================================================
detect_acceleration() {
    if [[ -w /dev/kvm ]]; then
        QEMU_ACCEL_FLAGS="-enable-kvm"
        QEMU_CPU_FLAGS="-cpu host,+x2apic"
        ACCEL_MODE="kvm"
    else
        QEMU_ACCEL_FLAGS="-accel tcg,thread=multi,tb-size=512"
        QEMU_CPU_FLAGS="-cpu max"
        ACCEL_MODE="tcg"
        echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/governor \
            >/dev/null 2>&1 || true
        renice -n -5 $$ >/dev/null 2>&1 || true
    fi
}

# ============================================================================
# BUILD AND RUN QEMU
# ============================================================================
build_and_run_qemu() {
    local vm_name=$1
    local live_img="$BACKUP_DIR/$vm_name.img"
    local seed_file="$BACKUP_DIR/$vm_name-seed.iso"
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"

    detect_acceleration

    if [[ "$ACCEL_MODE" == "tcg" ]]; then
        print_status "WARN" "KVM not available — using optimized TCG"
    fi

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
        -device "virtio-net-pci,netdev=n0,rx_queue_size=256,tx_queue_size=256,romfile=,host_mtu=1500" \
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
# SSH CHECK
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

    sshpass -p "$pass" ssh $ssh_opts -p "$port" "${user}@localhost" bash <<REMOTE
set +euo pipefail 2>/dev/null || true

# ---- Journald volatile ----
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
"dns": ["172.18.0.1"],
"dns-opts": ["ndots:0", "timeout:2", "attempts:2"],
"mtu": 1280,
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "live-restore": true,
  "iptables": true,
  "ip-forward": true,
  "ip-masq": true,
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": {"Name": "nofile", "Hard": 65535, "Soft": 65535}
  }
}
DF
    sudo systemctl restart docker || true
fi

# ---- Network performance tuning ----
sudo tee /etc/sysctl.d/99-network-perf.conf > /dev/null <<'SYSCTL'
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.netdev_max_backlog=300000
net.core.somaxconn=65535
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
SYSCTL
sudo modprobe tcp_bbr 2>/dev/null || true
sudo sysctl -p /etc/sysctl.d/99-network-perf.conf 2>/dev/null || true

# ---- Tailscale ----
sudo tailscale up 2>/dev/null || true

# ---- sshx service ----
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
SSHX_LINK=\$(sudo journalctl -u sshx -n 10 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | tail -1)
echo "sshx: \$SSHX_LINK"

# ---- PHP detection ----
sleep 5
BASE_URL="https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main"

PHP_VER=""
for ver in 8.3 8.4 8.2 8.1; do
    if command -v php\${ver} &>/dev/null || [ -f "/usr/sbin/php-fpm\${ver}" ]; then
        PHP_VER=\$ver
        break
    fi
done
[ -z "\$PHP_VER" ] && PHP_VER="8.3"

# ---- PHP-FPM socket mode ----
if [ -f "/etc/php/\${PHP_VER}/fpm/pool.d/www.conf" ]; then
    sudo sed -i "s|^listen = .*|listen = /run/php/php\${PHP_VER}-fpm.sock|" /etc/php/\${PHP_VER}/fpm/pool.d/www.conf
    sudo sed -i 's|^listen.owner = .*|listen.owner = www-data|' /etc/php/\${PHP_VER}/fpm/pool.d/www.conf
    sudo sed -i 's|^listen.group = .*|listen.group = www-data|' /etc/php/\${PHP_VER}/fpm/pool.d/www.conf
fi

# ---- Enable OPcache ----
sudo apt install -y php\${PHP_VER}-opcache 2>/dev/null || true
sudo tee /etc/php/\${PHP_VER}/mods-available/opcache.ini > /dev/null <<OPCEOF
zend_extension=opcache
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=30000
opcache.validate_timestamps=0
opcache.save_comments=1
opcache.huge_code_pages=0
realpath_cache_size=4096K
realpath_cache_ttl=600
OPCEOF
sudo phpenmod -v \${PHP_VER} opcache 2>/dev/null || true
sudo systemctl restart php\${PHP_VER}-fpm 2>/dev/null || true

# ---- Pelican restart ----
PELICAN_FOUND=false
sudo test -f /root/.pelican.env 2>/dev/null && PELICAN_FOUND=true || true
[ -f /var/www/pelican/.env ] && PELICAN_FOUND=true || true
[ -d /var/www/pelican ] && PELICAN_FOUND=true || true

if [ "\$PELICAN_FOUND" = "true" ]; then
    echo "Pelican detected — downloading and running restart.sh..."
    if curl -fsSL "\${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh 2>/dev/null; then
        chmod +x /tmp/nexus-restart.sh
        sudo bash /tmp/nexus-restart.sh </dev/null > /var/log/nexus-restart.log 2>&1 &
        RESTART_PID=\$!
        echo "restart.sh launched (PID \$RESTART_PID)"
        sleep 8
        echo "=== restart.sh log ==="
        sudo tail -30 /var/log/nexus-restart.log 2>/dev/null || echo "(log empty)"
        echo "======================"
        rm -f /tmp/nexus-restart.sh
        sudo systemctl restart cloudflared 2>/dev/null || true
    else
        echo "ERROR: Failed to download restart.sh from \${BASE_URL}"
    fi
else
    echo "Pelican not detected — skipping restart.sh"
fi
REMOTE

    # ---- VNC + websockify + Firefox via root SSH ----
    print_status "INFO" "Setting up VNC + Firefox auto-restore..."
    sshpass -p "$pass" ssh $ssh_opts -p "$port" "root@localhost" bash <<REMOTE
set +euo pipefail 2>/dev/null || true

# ---- Fix Docker bridge linkdown ----
if [ ! -f /etc/systemd/system/fix-docker-bridges.service ]; then
    cat > /etc/systemd/system/fix-docker-bridges.service <<'BRIDGESVC'
[Unit]
Description=Fix Docker bridge interfaces linkdown
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip link set docker0 up 2>/dev/null || true; ip link set pelican0 up 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BRIDGESVC
    systemctl daemon-reload
    systemctl enable fix-docker-bridges
    systemctl start fix-docker-bridges
    echo "fix-docker-bridges service installed"
fi

# ---- Firefox session restore ----
FIREFOX_PROFILE=\$(find /root/.config/mozilla/firefox -maxdepth 1 -name "*.default-release" -type d 2>/dev/null | head -1)
if [[ -n "\$FIREFOX_PROFILE" ]]; then
    cat > "\$FIREFOX_PROFILE/user.js" <<'USERJS'
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.sessionstore.max_resumed_crashes", -1);
user_pref("browser.sessionstore.resume_session_once", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);
USERJS
    echo "Firefox user.js written to \$FIREFOX_PROFILE"
fi

# ---- VNC setup ----
mkdir -p /root/.vnc
if ! command -v vncserver &>/dev/null || ! command -v websockify &>/dev/null; then
    apt-get install -y xfce4 xfce4-goodies tightvncserver novnc websockify 2>/dev/null || true
fi

if [ ! -f /root/.vnc/passwd ]; then
    VNC_PASS="${pass:0:8}"
    echo "\$VNC_PASS" | vncpasswd -f > /root/.vnc/passwd
    chmod 600 /root/.vnc/passwd
fi

cat > /root/.vnc/xstartup <<'XSTART'
#!/bin/bash
xrdb \$HOME/.Xresources 2>/dev/null || true
startxfce4 &
XSTART
chmod +x /root/.vnc/xstartup

tee /etc/systemd/system/vncserver.service > /dev/null <<'VNCSVC'
[Unit]
Description=TightVNC Server
After=network.target
After=systemd-user-sessions.service

[Service]
Type=forking
User=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1 2>/dev/null
ExecStartPre=/bin/sleep 1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 24
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
VNCSVC

tee /etc/systemd/system/websockify.service > /dev/null <<'WEBSVC'
[Unit]
Description=WebSockify noVNC proxy
After=network.target
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
WEBSVC

tee /etc/systemd/system/firefox-vnc.service > /dev/null <<'FFVSVC'
[Unit]
Description=Firefox on VNC display
After=network.target
After=websockify.service
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=root
Environment=DISPLAY=:1
Environment=HOME=/root
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/firefox --display=:1
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
FFVSVC

systemctl daemon-reload
systemctl enable vncserver websockify firefox-vnc

if ! systemctl is-active --quiet vncserver 2>/dev/null; then
    systemctl stop vncserver websockify firefox-vnc 2>/dev/null || true
    sleep 2
    systemctl start vncserver
    sleep 3
    systemctl start websockify
    sleep 5
    systemctl start firefox-vnc
    echo "VNC + websockify + Firefox services started"
else
    echo "VNC already running — skipping restart"
    systemctl is-active --quiet websockify || systemctl start websockify
    systemctl is-active --quiet firefox-vnc || systemctl start firefox-vnc
fi
REMOTE

    print_status "SUCCESS" "Post-boot setup done"
}

# ============================================================================
# CLOUDFLARE TUNNEL SETUP
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
set +euo pipefail 2>/dev/null || true
if ! command -v cloudflared &>/dev/null; then
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi
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
    local max_recoveries=5
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

    trap 'echo "[$(date +%H:%M:%S)] FATAL: freeze_recovery crashed" >> "$watchdog_log"' EXIT
    echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY STARTED =====" >> "$watchdog_log"

    echo "[$(date '+%H:%M:%S')] Pre-flight: Wiping tmpfs..." >> "$watchdog_log"
    rm -rf "${SNAPSHOT_DIR:?}"/*
    mkdir -p "${SNAPSHOT_DIR:?}"
    echo "[$(date '+%H:%M:%S')] Pre-flight: tmpfs wiped" >> "$watchdog_log"

    echo "[$(date '+%H:%M:%S')] Step 1: Killing frozen VM..." >> "$watchdog_log"
    kill_vm "$vm_name"
    sleep 2
    fuser -k "$live_img" 2>/dev/null || true
    sleep 3
    rm -f "$BACKUP_DIR/$vm_name.pid"
    sleep 2
    echo "[$(date '+%H:%M:%S')] Step 1: QEMU write lock released" >> "$watchdog_log"

    echo "[$(date '+%H:%M:%S')] Step 2: Compressing live image to tmpfs..." >> "$watchdog_log"
    local tmp_c="${snap_compressed}.compressing"
    rm -f "$tmp_c" "$snap_compressed"
    if ! qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M "$live_img" "$tmp_c" >> "$watchdog_log" 2>&1; then
        echo "[$(date '+%H:%M:%S')] ERROR: Compression to tmpfs failed" >> "$watchdog_log"
        rm -f "$tmp_c"
        trap - EXIT
        return 1
    fi
    mv "$tmp_c" "$snap_compressed"
    echo "[$(date '+%H:%M:%S')] Compressed: $(du -sh "$snap_compressed" 2>/dev/null | awk '{print $1}')" >> "$watchdog_log"

    echo "[$(date '+%H:%M:%S')] Step 3: Compressing back to /home..." >> "$watchdog_log"
    local restore_tmp="${live_img}.restoring"
    rm -f "$restore_tmp"
    qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M "$snap_compressed" "$restore_tmp" >> "$watchdog_log" 2>&1 &
    local compress_pid=$!
    local elapsed=0
    local success=false

    while [[ $elapsed -lt 1200 ]]; do
        if ! kill -0 "$compress_pid" 2>/dev/null; then
            if [[ -f "$restore_tmp" ]] && [[ $(stat -c%s "$restore_tmp" 2>/dev/null || echo 0) -gt 0 ]] && \
               qemu-img check "$restore_tmp" >> "$watchdog_log" 2>&1; then
                success=true
            else
                echo "[$(date '+%H:%M:%S')] Step 3: Output invalid — falling back to direct copy" >> "$watchdog_log"
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
        echo "[$(date '+%H:%M:%S')] Copying directly from tmpfs..." >> "$watchdog_log"
        if ! cp "$snap_compressed" "$restore_tmp"; then
            echo "[$(date '+%H:%M:%S')] ERROR: Direct copy failed" >> "$watchdog_log"
            trap - EXIT
            return 1
        fi
        if [[ $(stat -c%s "$restore_tmp" 2>/dev/null || echo 0) -eq 0 ]]; then
            echo "[$(date '+%H:%M:%S')] ERROR: Direct copy produced 0 byte file" >> "$watchdog_log"
            rm -f "$restore_tmp"
            trap - EXIT
            return 1
        fi
        if ! qemu-img check "$restore_tmp" >> "$watchdog_log" 2>&1; then
            rm -f "$restore_tmp"
            echo "[$(date '+%H:%M:%S')] ERROR: Direct copy verification failed" >> "$watchdog_log"
            trap - EXIT
            return 1
        fi
    fi

    rm -f "$live_img"
    mv "$restore_tmp" "$live_img"
    echo "[$(date '+%H:%M:%S')] Live image restored and verified OK" >> "$watchdog_log"
    trap - EXIT

    echo "[$(date '+%H:%M:%S')] Step 4: Clearing tmpfs..." >> "$watchdog_log"
    rm -rf "${SNAPSHOT_DIR:?}"/*

    echo "[$(date '+%H:%M:%S')] Step 5: Restarting VM..." >> "$watchdog_log"
    rm -f "$serial_log"
    build_and_run_qemu "$vm_name"
    sleep 3
    if [[ ! -f "$BACKUP_DIR/$vm_name.pid" ]] || ! kill -0 "$(cat "$BACKUP_DIR/$vm_name.pid" 2>/dev/null)" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] ERROR: QEMU process dead after start" >> "$watchdog_log"
        return 1
    fi
    echo "[$(date '+%H:%M:%S')] VM alive (PID $(cat "$BACKUP_DIR/$vm_name.pid"))" >> "$watchdog_log"

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
# ============================================================================
start_freeze_watchdog() {
    local vm_name=$1
    local serial_log="$BACKUP_DIR/$vm_name.serial.log"
    local watchdog_log="$BACKUP_DIR/$vm_name.watchdog.log"
    local watchdog_pid_file="$BACKUP_DIR/$vm_name.watchdog.pid"

    # Kill any existing watchdog before spawning a new one
    if [[ -f "$watchdog_pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$watchdog_pid_file" 2>/dev/null || true)
        if [[ -n "$old_pid" ]]; then
            kill "$old_pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$watchdog_pid_file"
    fi

    local _BACKUP_DIR="$BACKUP_DIR"
    local _SNAPSHOT_DIR="$SNAPSHOT_DIR"
    local _SSH_PORT="$SSH_PORT"
    local _PASSWORD="$PASSWORD"
    local _USERNAME="$USERNAME"
    local _MEMORY="$MEMORY"
    local _CPUS="$CPUS"
    local _BASE_URL="https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main"

    (
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        NC='\033[0m'

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
                [[ -n "$pid" ]] && {
                    kill "$pid" 2>/dev/null || true
                    sleep 2
                    kill -9 "$pid" 2>/dev/null || true
                }
                rm -f "$pid_file"
            fi
            pkill -f "qemu-system-x86_64.*$_BACKUP_DIR/$vm" 2>/dev/null || true
        }

        get_accel_flags() {
            if [[ -w /dev/kvm ]]; then
                echo "-enable-kvm|-cpu host,+x2apic"
            else
                echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/governor \
                    >/dev/null 2>&1 || true
                echo "-accel tcg,thread=multi,tb-size=512|-cpu max"
            fi
        }

        recover_local() {
            local vm=$1
            local skip_image=${2:-false}
            local live_img="$_BACKUP_DIR/$vm.img"
            local snap_compressed="$_SNAPSHOT_DIR/$vm.img.compressed"
            local serial="$_BACKUP_DIR/$vm.serial.log"
            local wlog="$_BACKUP_DIR/$vm.watchdog.log"
            local lock_file="$_BACKUP_DIR/$vm.recovery.lock"

            # Prevent concurrent recoveries
            if [[ -f "$lock_file" ]]; then
                local lock_pid
                lock_pid=$(cat "$lock_file" 2>/dev/null || true)
                if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                    echo "[$(date '+%H:%M:%S')] Recovery already in progress (PID $lock_pid) — skipping" >> "$wlog"
                    return 0
                fi
            fi
            echo $$ > "$lock_file"

            # Helper to clean lock on every exit path
            _recover_done() {
                rm -f "$lock_file"
                trap - EXIT
            }
            trap '_recover_done; echo "[$(date +%H:%M:%S)] FATAL: Recovery crashed" >> "$wlog"' EXIT

            echo "[$(date '+%H:%M:%S')] ===== FREEZE RECOVERY STARTED =====" >> "$wlog"

            # Step 1 — Kill frozen VM
            echo "[$(date '+%H:%M:%S')] Step 1: Killing frozen VM..." >> "$wlog"
            kill_vm_local "$vm"
            sleep 2
            fuser -k "$live_img" 2>/dev/null || true
            sleep 3
            rm -f "$_BACKUP_DIR/$vm.pid"
            sleep 2
            echo "[$(date '+%H:%M:%S')] Step 1: QEMU write lock released" >> "$wlog"

            if [[ "$skip_image" != "true" ]]; then
                # Step 2 — Compress to tmpfs
                echo "[$(date '+%H:%M:%S')] Step 2: Compressing live image to tmpfs..." >> "$wlog"
                local tmp_c="${snap_compressed}.compressing"
                rm -f "$tmp_c" "$snap_compressed"
                if ! qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M "$live_img" "$tmp_c" >> "$wlog" 2>&1; then
                    echo "[$(date '+%H:%M:%S')] ERROR: Compression to tmpfs failed" >> "$wlog"
                    rm -f "$tmp_c"
                    _recover_done
                    return 1
                fi
                mv "$tmp_c" "$snap_compressed"
                echo "[$(date '+%H:%M:%S')] Compressed: $(du -sh "$snap_compressed" 2>/dev/null | awk '{print $1}')" >> "$wlog"

                # Step 3 — Compress back to /home
                echo "[$(date '+%H:%M:%S')] Step 3: Compressing back to /home (20 min timeout)..." >> "$wlog"
                local restore_tmp="${live_img}.restoring"
                rm -f "$restore_tmp"
                qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M "$snap_compressed" "$restore_tmp" >> "$wlog" 2>&1 &
                local compress_pid=$!
                local elapsed=0
                local success=false

                while [[ $elapsed -lt 1200 ]]; do
                    if ! kill -0 "$compress_pid" 2>/dev/null; then
                        if [[ -f "$restore_tmp" ]] && [[ $(stat -c%s "$restore_tmp" 2>/dev/null || echo 0) -gt 0 ]] && \
                           qemu-img check "$restore_tmp" >> "$wlog" 2>&1; then
                            success=true
                        else
                            echo "[$(date '+%H:%M:%S')] Step 3: Output invalid — falling back to direct copy" >> "$wlog"
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
                    echo "[$(date '+%H:%M:%S')] Copying directly from tmpfs..." >> "$wlog"
                    if ! cp "$snap_compressed" "$restore_tmp"; then
                        echo "[$(date '+%H:%M:%S')] ERROR: Direct copy failed" >> "$wlog"
                        _recover_done
                        return 1
                    fi
                    if [[ $(stat -c%s "$restore_tmp" 2>/dev/null || echo 0) -eq 0 ]]; then
                        echo "[$(date '+%H:%M:%S')] ERROR: Direct copy produced 0 byte file" >> "$wlog"
                        rm -f "$restore_tmp"
                        _recover_done
                        return 1
                    fi
                    if ! qemu-img check "$restore_tmp" >> "$wlog" 2>&1; then
                        rm -f "$restore_tmp"
                        echo "[$(date '+%H:%M:%S')] ERROR: Direct copy verification failed" >> "$wlog"
                        _recover_done
                        return 1
                    fi
                fi

                rm -f "$live_img"
                mv "$restore_tmp" "$live_img"
                echo "[$(date '+%H:%M:%S')] Live image restored and verified OK" >> "$wlog"
                _recover_done

                # Step 4 — Clear tmpfs
                echo "[$(date '+%H:%M:%S')] Step 4: Clearing tmpfs..." >> "$wlog"
                rm -rf "${_SNAPSHOT_DIR:?}"/*
            fi

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
                pf_conf=$(grep ^PORT_FORWARDS "$_BACKUP_DIR/$vm.conf" 2>/dev/null | cut -d'"' -f2)
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
            qcmd+=" -device virtio-net-pci,netdev=n0,rx_queue_size=256,tx_queue_size=256,romfile=,host_mtu=1500"
            qcmd+=" -netdev user,id=n0,hostfwd=tcp::${_SSH_PORT}-:22,dns=8.8.8.8${pf_extra}"
            qcmd+=" -object rng-random,filename=/dev/urandom,id=rng0"
            qcmd+=" -device virtio-rng-pci,rng=rng0"
            qcmd+=" -device virtio-balloon-pci"
            qcmd+=" -rtc base=utc,clock=host,driftfix=slew"
            qcmd+=" -global kvm-pit.lost_tick_policy=delay"
            qcmd+=" -serial file:$serial"
            qcmd+=" -display none -daemonize"
            qcmd+=" -pidfile $_BACKUP_DIR/$vm.pid"

            eval "$qcmd" >> "$wlog" 2>&1
            sleep 3
            if [[ ! -f "$_BACKUP_DIR/$vm.pid" ]] || ! kill -0 "$(cat "$_BACKUP_DIR/$vm.pid" 2>/dev/null)" 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] ERROR: QEMU failed to start" >> "$wlog"
                _recover_done
                return 1
            fi
            echo "[$(date '+%H:%M:%S')] VM confirmed alive (PID $(cat "$_BACKUP_DIR/$vm.pid"))" >> "$wlog"

            # Step 6 — Wait for SSH then post-recovery
            local el=0
            while [[ $el -lt 120 ]]; do
                if check_ssh_local "$_SSH_PORT"; then
                    echo "[$(date '+%H:%M:%S')] SSH ready — running post-boot setup..." >> "$wlog"
                    sleep 10

                    # ---- User fixes ----
                    sshpass -p "$_PASSWORD" ssh \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        -o ConnectTimeout=15 \
                        -o LogLevel=ERROR \
                        -p "$_SSH_PORT" "${_USERNAME}@localhost" bash <<REMOTE >> "$wlog" 2>&1
set +euo pipefail 2>/dev/null || true

sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/no-freeze.conf > /dev/null <<'JF'
[Journal]
Storage=volatile
SyncIntervalSec=0
RateLimitBurst=0
JF
sudo systemctl restart systemd-journald || true

if command -v docker &>/dev/null; then
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json > /dev/null <<'DF'
{
"dns": ["172.18.0.1"],
"dns-opts": ["ndots:0", "timeout:2", "attempts:2"],
"mtu": 1280,
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "live-restore": true,
  "iptables": true,
  "ip-forward": true,
  "ip-masq": true,
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": {"Name": "nofile", "Hard": 65535, "Soft": 65535}
  }
}
DF
    sudo systemctl restart docker || true
fi

sudo tee /etc/sysctl.d/99-network-perf.conf > /dev/null <<'SYSCTL'
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.netdev_max_backlog=300000
net.core.somaxconn=65535
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
SYSCTL
sudo modprobe tcp_bbr 2>/dev/null || true
sudo sysctl -p /etc/sysctl.d/99-network-perf.conf 2>/dev/null || true

sudo tailscale up 2>/dev/null || true

sudo systemctl stop sshx 2>/dev/null || true
sudo systemctl disable sshx 2>/dev/null || true
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
BASE_URL="${_BASE_URL}"

PHP_VER=""
for ver in 8.3 8.4 8.2 8.1; do
    if command -v php\${ver} &>/dev/null || [ -f "/usr/sbin/php-fpm\${ver}" ]; then
        PHP_VER=\$ver
        break
    fi
done
[ -z "\$PHP_VER" ] && PHP_VER="8.3"

if [ -f "/etc/php/\${PHP_VER}/fpm/pool.d/www.conf" ]; then
    sudo sed -i "s|^listen = .*|listen = /run/php/php\${PHP_VER}-fpm.sock|" /etc/php/\${PHP_VER}/fpm/pool.d/www.conf
    sudo sed -i 's|^listen.owner = .*|listen.owner = www-data|' /etc/php/\${PHP_VER}/fpm/pool.d/www.conf
    sudo sed -i 's|^listen.group = .*|listen.group = www-data|' /etc/php/\${PHP_VER}/fpm/pool.d/www.conf
fi

sudo apt install -y php\${PHP_VER}-opcache 2>/dev/null || true
sudo tee /etc/php/\${PHP_VER}/mods-available/opcache.ini > /dev/null <<OPCEOF
zend_extension=opcache
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=30000
opcache.validate_timestamps=0
opcache.save_comments=1
opcache.huge_code_pages=0
realpath_cache_size=4096K
realpath_cache_ttl=600
OPCEOF
sudo phpenmod -v \${PHP_VER} opcache 2>/dev/null || true
sudo systemctl restart php\${PHP_VER}-fpm 2>/dev/null || true

PELICAN_FOUND=false
sudo test -f /root/.pelican.env 2>/dev/null && PELICAN_FOUND=true || true
[ -f /var/www/pelican/.env ] && PELICAN_FOUND=true || true
[ -d /var/www/pelican ] && PELICAN_FOUND=true || true

if [ "\$PELICAN_FOUND" = "true" ]; then
    echo "Pelican detected — running restart.sh..."
    if curl -fsSL "\${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh 2>/dev/null; then
        chmod +x /tmp/nexus-restart.sh
        sudo bash /tmp/nexus-restart.sh </dev/null > /var/log/nexus-restart.log 2>&1 &
        RESTART_PID=\$!
        echo "restart.sh launched (PID \$RESTART_PID)"
        sleep 8
        echo "=== restart.sh log ==="
        sudo tail -30 /var/log/nexus-restart.log 2>/dev/null || echo "(log empty)"
        echo "======================"
        rm -f /tmp/nexus-restart.sh
        sudo systemctl restart cloudflared 2>/dev/null || true
    else
        echo "ERROR: Failed to download restart.sh"
    fi
else
    echo "Pelican not detected — skipping restart.sh"
fi
REMOTE

                    # ---- Root fixes (VNC + websockify + Firefox) ----
                    sshpass -p "$_PASSWORD" ssh \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        -o ConnectTimeout=15 \
                        -o LogLevel=ERROR \
                        -p "$_SSH_PORT" "root@localhost" bash <<REMOTE >> "$wlog" 2>&1
set +euo pipefail 2>/dev/null || true

FIREFOX_PROFILE=\$(find /root/.config/mozilla/firefox -maxdepth 1 -name "*.default-release" -type d 2>/dev/null | head -1)
if [[ -n "\$FIREFOX_PROFILE" ]]; then
    cat > "\$FIREFOX_PROFILE/user.js" <<'USERJS'
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.sessionstore.max_resumed_crashes", -1);
user_pref("browser.sessionstore.resume_session_once", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);
USERJS
fi

mkdir -p /root/.vnc
if ! command -v vncserver &>/dev/null || ! command -v websockify &>/dev/null; then
    apt-get install -y xfce4 xfce4-goodies tightvncserver novnc websockify 2>/dev/null || true
fi

if [ ! -f /root/.vnc/passwd ]; then
    VNC_PASS="${_PASSWORD:0:8}"
    echo "\$VNC_PASS" | vncpasswd -f > /root/.vnc/passwd
    chmod 600 /root/.vnc/passwd
fi

cat > /root/.vnc/xstartup <<'XSTART'
#!/bin/bash
xrdb \$HOME/.Xresources 2>/dev/null || true
startxfce4 &
XSTART
chmod +x /root/.vnc/xstartup

tee /etc/systemd/system/vncserver.service > /dev/null <<'VNCSVC'
[Unit]
Description=TightVNC Server
After=network.target
After=systemd-user-sessions.service

[Service]
Type=forking
User=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1 2>/dev/null
ExecStartPre=/bin/sleep 1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 24
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
VNCSVC

tee /etc/systemd/system/websockify.service > /dev/null <<'WEBSVC'
[Unit]
Description=WebSockify noVNC proxy
After=network.target
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
WEBSVC

tee /etc/systemd/system/firefox-vnc.service > /dev/null <<'FFVSVC'
[Unit]
Description=Firefox on VNC display
After=network.target
After=websockify.service
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=root
Environment=DISPLAY=:1
Environment=HOME=/root
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/firefox --display=:1
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
FFVSVC

systemctl daemon-reload
systemctl enable vncserver websockify firefox-vnc

if ! systemctl is-active --quiet vncserver 2>/dev/null; then
    systemctl stop vncserver websockify firefox-vnc 2>/dev/null || true
    sleep 2
    systemctl start vncserver
    sleep 3
    systemctl start websockify
    sleep 5
    systemctl start firefox-vnc
    echo "VNC + websockify + Firefox started"
else
    echo "VNC already running — skipping restart"
    systemctl is-active --quiet websockify || systemctl start websockify
    systemctl is-active --quiet firefox-vnc || systemctl start firefox-vnc
fi
REMOTE
                    _recover_done
                    return 0
                fi
                sleep 5
                el=$((el + 5))
            done

            echo "[$(date '+%H:%M:%S')] WARNING: SSH did not respond after recovery" >> "$wlog"
            _recover_done
            return 1
        }

        # ---- Watchdog main loop ----
        local recovery_count=0
        local max_recoveries=5

        sleep 120  # grace period during boot

        while true; do
            sleep 20

            if [[ ! -f "$_BACKUP_DIR/$vm_name.pid" ]]; then
                echo "[$(date '+%H:%M:%S')] PID file missing — restarting..." >> "$watchdog_log"
                if [[ $recovery_count -ge $max_recoveries ]]; then
                    echo "[$(date '+%H:%M:%S')] Max recoveries reached. Stopping." >> "$watchdog_log"
                    exit 1
                fi
                ((recovery_count++))
                recover_local "$vm_name" "true"
                continue
            fi

            local pid
            pid=$(cat "$_BACKUP_DIR/$vm_name.pid" 2>/dev/null) || {
                echo "[$(date '+%H:%M:%S')] Could not read PID file — restarting..." >> "$watchdog_log"
                if [[ $recovery_count -ge $max_recoveries ]]; then
                    echo "[$(date '+%H:%M:%S')] Max recoveries reached. Stopping." >> "$watchdog_log"
                    exit 1
                fi
                ((recovery_count++))
                recover_local "$vm_name" "true"
                continue
            }

            if ! kill -0 "$pid" 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] QEMU process died — restarting..." >> "$watchdog_log"
                if [[ $recovery_count -ge $max_recoveries ]]; then
                    echo "[$(date '+%H:%M:%S')] Max recoveries reached. Stopping." >> "$watchdog_log"
                    exit 1
                fi
                ((recovery_count++))
                if recover_local "$vm_name" "true"; then
                    echo "[$(date '+%H:%M:%S')] Recovery complete" >> "$watchdog_log"
                    recovery_count=0
                    sleep 120
                fi
                continue
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
                    echo "[$(date '+%H:%M:%S')] SSH down, serial active (${stale}s) — booting?" >> "$watchdog_log"
                fi
            else
                recovery_count=0
            fi
        done

    ) >> "$watchdog_log" 2>&1 &
    echo $! > "$watchdog_pid_file"
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
# SETUP VM IMAGE
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
    qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M "$base_img" "$BACKUP_DIR/$VM_NAME.img"
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
    lock_passwd: false
    passwd: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
write_files:
  - path: /etc/ssh/sshd_config.d/99-nexus-pwauth.conf
    content: |
      PasswordAuthentication yes
      PermitRootLogin yes
    permissions: '0644'
  - path: /etc/sudoers.d/$USERNAME
    content: |
      $USERNAME ALL=(ALL) NOPASSWD:ALL
    permissions: '0440'
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
"dns": ["172.18.0.1"],
"dns-opts": ["ndots:0", "timeout:2", "attempts:2"],
"mtu": 1280,
        "log-driver": "json-file",
        "log-opts": {"max-size": "10m", "max-file": "3"},
        "live-restore": true,
        "iptables": true,
        "ip-forward": true,
        "ip-masq": true,
        "storage-driver": "overlay2",
        "default-ulimits": {
          "nofile": {"Name": "nofile", "Hard": 65535, "Soft": 65535}
        }
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
  - for f in /etc/ssh/sshd_config.d/*.conf; do sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "\$f" 2>/dev/null || true; done
  - id $USERNAME || useradd -m -s /bin/bash -G sudo $USERNAME
  - echo "$USERNAME:$PASSWORD" | chpasswd
  - echo "root:$PASSWORD" | chpasswd
  - echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
  - chmod 440 /etc/sudoers.d/$USERNAME
  - systemctl restart ssh || systemctl restart sshd || true
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
    rm -f "$BACKUP_DIR/$vm_name.recovery.lock"
    > "$BACKUP_DIR/$vm_name.watchdog.log"
    ssh-keygen -R "[localhost]:$SSH_PORT" 2>/dev/null || true
    ssh-keygen -R "localhost" 2>/dev/null || true

    print_status "INFO" "Cleaning tmpfs before start..."
    rm -rf "${SNAPSHOT_DIR:?}"/*
    mkdir -p "${SNAPSHOT_DIR:?}"

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

    local watchdog_pid_file="$BACKUP_DIR/$vm_name.watchdog.pid"
    if [[ -f "$watchdog_pid_file" ]]; then
        local wpid
        wpid=$(cat "$watchdog_pid_file" 2>/dev/null || true)
        [[ -n "$wpid" ]] && kill "$wpid" 2>/dev/null || true
        rm -f "$watchdog_pid_file"
    fi

    rm -f "$BACKUP_DIR/$vm_name.recovery.lock"
    kill_vm "$vm_name"
    print_status "SUCCESS" "VM '$vm_name' stopped"
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
    print_status "SUCCESS" "Watchdog attached"
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
    [[ -f "$SNAPSHOT_COMPRESSED" ]] && snap_status="Compressed ($(du -sh "$SNAPSHOT_COMPRESSED" | awk '{print $1}')) — active recovery"
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
        local watchdog_pid_file="$BACKUP_DIR/$vm_name.watchdog.pid"
        if [[ -f "$watchdog_pid_file" ]]; then
            kill "$(cat "$watchdog_pid_file" 2>/dev/null)" 2>/dev/null || true
            rm -f "$watchdog_pid_file"
        fi
        is_vm_running "$vm_name" && kill_vm "$vm_name"
        rm -f "$LIVE_IMG" "$SNAPSHOT_COMPRESSED"
        rm -f "${SNAPSHOT_COMPRESSED}.compressing" "$SEED_FILE"
        rm -f "$BACKUP_DIR/$vm_name.conf" "$BACKUP_DIR/$vm_name.pid"
        rm -f "$BACKUP_DIR/$vm_name.serial.log" "$BACKUP_DIR/$vm_name.watchdog.log"
        rm -f "$BACKUP_DIR/$vm_name.watchdog.pid" "$BACKUP_DIR/$vm_name.recovery.lock"
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

if ! mountpoint -q "$SNAPSHOT_DIR" 2>/dev/null; then
    mkdir -p "$SNAPSHOT_DIR"
    mount -t tmpfs -o size=16G tmpfs "$SNAPSHOT_DIR" 2>/dev/null || true
fi

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