#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Enhanced Multi-VM Manager v5.0
# Created by NexusTechPro
# Clean rewrite — DRY, modular, no duplicate logic
# ============================================================================

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[0;97m'; NC='\033[0m'

# --- Directories ---
BACKUP_DIR="${BACKUP_DIR:-/home/user/vms}"
SNAPSHOT_DIR="/nexusvms"
BASE_URL="https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main"

# ============================================================================
# LOGGING & UI
# ============================================================================

log()    { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
prompt() { echo -e "${WHITE}[INPUT]${NC} $*"; }

header() {
    clear
    echo -e "${BLUE}========================================================================"
    echo -e "  NexusTechPro — Enhanced Multi-VM Manager v5.0"
    echo -e "========================================================================${NC}"
    echo
}

wlog() {
    local vm=$1; shift
    echo "[$(date '+%H:%M:%S')] $*" >> "$BACKUP_DIR/$vm.watchdog.log"
}

# ============================================================================
# INPUT VALIDATION
# ============================================================================

validate() {
    local type=$1 value=$2
    case $type in
        number)   [[ "$value" =~ ^[0-9]+$ ]]               || { error "Must be a number";                    return 1; } ;;
        size)     [[ "$value" =~ ^[0-9]+[GgMm]$ ]]         || { error "Must be size with unit (e.g. 10G)";   return 1; } ;;
        port)     [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 23 && value <= 65535 )) \
                                                            || { error "Must be valid port (23-65535)";       return 1; } ;;
        name)     [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]       || { error "Letters, numbers, hyphens, underscores only"; return 1; } ;;
        username) [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]    || { error "Must start with letter/underscore";  return 1; } ;;
    esac
}

ask() {
    # ask <type> <prompt> <default> -> sets $REPLY
    local type=$1 msg=$2 default=${3:-}
    while true; do
        local display_default=""
        [[ -n "$default" ]] && display_default=" [$default]"
        read -rp "$(prompt "$msg$display_default: ")" REPLY
        REPLY="${REPLY:-$default}"
        [[ -z "$REPLY" ]] && { error "Value required"; continue; }
        validate "$type" "$REPLY" && break
    done
}

ask_password() {
    local msg=$1 default=${2:-}
    while true; do
        read -rsp "$(prompt "$msg [press Enter for default]: ")" REPLY; echo
        REPLY="${REPLY:-$default}"
        [[ -n "$REPLY" ]] && break
        error "Password cannot be empty"
    done
}

# ============================================================================
# DEPENDENCY & SPACE CHECKS
# ============================================================================

check_deps() {
    local missing=()
    for dep in qemu-system-x86_64 wget cloud-localds qemu-img; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    (( ${#missing[@]} == 0 )) || {
        error "Missing: ${missing[*]}"
        log  "Try: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    }
    command -v sshpass &>/dev/null || apt-get install -y sshpass &>/dev/null || true
}

check_space() {
    local path=$1 needed=$2
    local free=$(( $(df -k "$path" 2>/dev/null | awk 'NR==2{print $4}') / 1024 / 1024 ))
    (( free >= needed )) || { error "Need ${needed}G on $path, only ${free}G free"; return 1; }
}

# ============================================================================
# VM CONFIG
# ============================================================================

vm_conf()  { echo "$BACKUP_DIR/$1.conf"; }
vm_img()   { echo "$BACKUP_DIR/$1.img"; }
vm_seed()  { echo "$BACKUP_DIR/$1-seed.iso"; }
vm_pid()   { echo "$BACKUP_DIR/$1.pid"; }
vm_snap()  { echo "$SNAPSHOT_DIR/$1.img.compressed"; }
vm_serial(){ echo "$BACKUP_DIR/$1.serial.log"; }
vm_wlog()  { echo "$BACKUP_DIR/$1.watchdog.log"; }
vm_wpid()  { echo "$BACKUP_DIR/$1.watchdog.pid"; }
vm_lock()  { echo "$BACKUP_DIR/$1.recovery.lock"; }

list_vms() { find "$BACKUP_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort; }

load_vm() {
    local conf; conf=$(vm_conf "$1")
    [[ -f "$conf" ]] || { error "VM '$1' not found"; return 1; }
    unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD \
          DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS CREATED
    source "$conf"
}

save_vm() {
    cat > "$(vm_conf "$VM_NAME")" <<EOF
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
    ok "Config saved"
}

vm_running() {
    local pid_file; pid_file=$(vm_pid "$1")
    [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null
}

# ============================================================================
# QEMU
# ============================================================================

detect_accel() {
    if [[ -w /dev/kvm ]]; then
        QEMU_ACCEL="-enable-kvm"; QEMU_CPU="-cpu host,+x2apic"
    else
        QEMU_ACCEL="-accel tcg,thread=multi,tb-size=512"; QEMU_CPU="-cpu max"
        echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/governor &>/dev/null || true
        renice -n -5 $$ &>/dev/null || true
    fi
}

build_netdev() {
    # build_netdev <ssh_port> <port_forwards> -> sets $NETDEV_EXTRA
    local ssh_port=$1 forwards=${2:-}
    NETDEV_EXTRA=""
    if [[ -n "$forwards" ]]; then
        IFS=',' read -ra fwd_arr <<< "$forwards"
        for f in "${fwd_arr[@]}"; do
            IFS=':' read -r hp gp <<< "$f"
            NETDEV_EXTRA+=",hostfwd=tcp::${hp}-:${gp}"
        done
    fi
    echo "user,id=n0,hostfwd=tcp::${ssh_port}-:22,dns=8.8.4.4${NETDEV_EXTRA}"
}

run_qemu() {
    local vm=$1
    detect_accel
    local netdev; netdev=$(build_netdev "$SSH_PORT" "${PORT_FORWARDS:-}")
    qemu-system-x86_64 \
        $QEMU_ACCEL $QEMU_CPU \
        -machine q35,mem-merge=off,hpet=off \
        -m "$MEMORY" -smp "$CPUS" \
        -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1 \
        -device i6300esb -watchdog-action reset \
        -object iothread,id=io0 \
        -drive "id=hd0,file=$(vm_img "$vm"),format=qcow2,if=none,cache=writeback,discard=unmap,aio=threads" \
        -device "virtio-blk-pci,drive=hd0,iothread=io0" \
        -drive "file=$(vm_seed "$vm"),format=raw,if=virtio,cache=writeback" \
        -boot order=c \
        -device "virtio-net-pci,netdev=n0,rx_queue_size=256,tx_queue_size=256,romfile=,host_mtu=1280" \
        -netdev "$netdev" \
        -object rng-random,filename=/dev/urandom,id=rng0 \
        -device virtio-rng-pci,rng=rng0 \
        -device virtio-balloon-pci \
        -rtc base=utc,clock=host,driftfix=slew \
        -global kvm-pit.lost_tick_policy=delay \
        -serial "file:$(vm_serial "$vm")" \
        -monitor unix:"$BACKUP_DIR/$vm.monitor.sock",server,nowait \
        -display none -daemonize \
        -pidfile "$(vm_pid "$vm")"
}

kill_vm() {
    local vm=$1 pid
    pid=$(cat "$(vm_pid "$vm")" 2>/dev/null || true)
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 2; kill -9 "$pid" 2>/dev/null || true; }
    rm -f "$(vm_pid "$vm")"
    pkill -f "qemu-system-x86_64.*$BACKUP_DIR/$vm" 2>/dev/null || true
}

# ============================================================================
# SSH HELPERS
# ============================================================================

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=15 -o LogLevel=ERROR \
          -o PasswordAuthentication=yes -o PubkeyAuthentication=no \
          -o PreferredAuthentications=password"

ssh_ready() {
    local banner
    banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/localhost/$1 && cat <&3" 2>/dev/null | head -1)
    [[ "$banner" == SSH-* ]]
}

ssh_run() {
    # ssh_run <port> <user> <pass> <heredoc_body>
    local port=$1 user=$2 pass=$3
    shift 3
    sshpass -p "$pass" ssh $SSH_OPTS -p "$port" "${user}@localhost" bash <<< "$@"
}

wait_ssh() {
    local vm=$1 elapsed=0 max=300
    log "Waiting for SSH (max ${max}s)..."
    echo -n "   "
    while (( elapsed < max )); do
        ssh_ready "$SSH_PORT" && { echo; ok "SSH ready after ${elapsed}s"; return 0; }
        # Freeze detection
        if (( elapsed > 20 )); then
            local age=$(( $(date +%s) - $(stat -c %Y "$(vm_serial "$vm")" 2>/dev/null || echo "$(date +%s)") ))
            if (( age > 180 )); then
                echo; warn "Freeze detected (serial stale ${age}s)"
                wlog "$vm" "Boot freeze — running recovery"
                recover_vm "$vm" || return 1
                elapsed=0; echo -n "   "; continue
            fi
        fi
        sleep 2; (( elapsed+=2 )); echo -n "."
    done
    echo; error "SSH timeout after ${max}s"; return 1
}

# ============================================================================
# REMOTE SETUP SCRIPTS (defined once, called everywhere)
# ============================================================================

# All the content pushed to the VM on every boot/recovery
remote_user_setup() {
    local port=$1 user=$2 pass=$3
    sshpass -p "$pass" ssh $SSH_OPTS -p "$port" "${user}@localhost" bash <<'REMOTE'
set +euo pipefail 2>/dev/null || true

# Journald — volatile to prevent freeze
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/no-freeze.conf >/dev/null <<'EOF'
[Journal]
Storage=volatile
SyncIntervalSec=0
RateLimitBurst=0
EOF
sudo systemctl restart systemd-journald 2>/dev/null || true

# DNS — systemd-resolved, no stub
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/no-stub.conf >/dev/null <<'EOF'
[Resolve]
DNS=8.8.4.4 1.0.0.1
DNSStubListener=no
Domains=~.
EOF
sudo systemctl restart systemd-resolved 2>/dev/null || true
sudo systemctl unmask dnsmasq 2>/dev/null || true

# dnsmasq for container DNS
sudo tee /etc/dnsmasq.conf >/dev/null <<'EOF'
listen-address=172.18.0.1
bind-interfaces
no-resolv
server=8.8.4.4
server=1.0.0.1
server=1.1.1.1
server=9.9.9.9
cache-size=1000
domain-needed
bogus-priv
all-servers
EOF
sudo systemctl enable dnsmasq 2>/dev/null || true
sudo systemctl restart dnsmasq 2>/dev/null || true

# Docker
if command -v docker &>/dev/null; then
    sudo mkdir -p /etc/docker /etc/systemd/system/docker.service.d
    sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "dns": ["8.8.4.4", "1.0.0.1", "1.1.1.1", "9.9.9.9"],
  "mtu": 1280,
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "live-restore": true,
  "iptables": true,
  "ip-forward": true,
  "ip-masq": true,
  "storage-driver": "overlay2",
  "default-ulimits": {"nofile": {"Name": "nofile", "Hard": 65535, "Soft": 65535}}
}
EOF
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    PLATFORM="linux/arm64"
else
    PLATFORM="linux/amd64"
fi
sudo tee /etc/systemd/system/docker.service.d/platform.conf >/dev/null <<EOF
[Service]
Environment="DOCKER_DEFAULT_PLATFORM=${PLATFORM}"
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart docker 2>/dev/null || true
fi

# Network tuning
sudo tee /etc/sysctl.d/99-network-perf.conf >/dev/null <<'EOF'
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
EOF
sudo modprobe tcp_bbr 2>/dev/null || true
sudo sysctl -p /etc/sysctl.d/99-network-perf.conf 2>/dev/null || true

# Tailscale
sudo tailscale up 2>/dev/null || true

# sshx
sudo tee /etc/systemd/system/sshx.service >/dev/null <<'EOF'
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
EOF
sudo systemctl daemon-reload
sudo systemctl enable sshx
sudo systemctl restart sshx
sleep 4
SSHX_LINK=$(sudo journalctl -u sshx -n 10 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | tail -1)
echo "sshx: $SSHX_LINK"

# PHP-FPM
PHP_VER=""
for ver in 8.3 8.4 8.2 8.1; do
    { command -v "php${ver}" || [ -f "/usr/sbin/php-fpm${ver}" ]; } 2>/dev/null && PHP_VER=$ver && break
done
PHP_VER="${PHP_VER:-8.3}"

if [ -f "/etc/php/${PHP_VER}/fpm/pool.d/www.conf" ]; then
    sudo sed -i "s|^listen = .*|listen = /run/php/php${PHP_VER}-fpm.sock|" \
        "/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
    sudo sed -i 's|^listen\.\(owner\|group\) = .*|listen.\1 = www-data|' \
        "/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
fi

# OPcache
sudo apt-get install -y "php${PHP_VER}-opcache" 2>/dev/null || true
sudo tee "/etc/php/${PHP_VER}/mods-available/opcache.ini" >/dev/null <<EOF
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
EOF
sudo phpenmod -v "${PHP_VER}" opcache 2>/dev/null || true
sudo systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || true

# Pelican
PELICAN_FOUND=false
{ sudo test -f /root/.pelican.env || [ -f /var/www/pelican/.env ] || [ -d /var/www/pelican ]; } \
    2>/dev/null && PELICAN_FOUND=true || true

if [ "$PELICAN_FOUND" = "true" ]; then
    BASE_URL="https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main"
    echo "Pelican detected — running restart.sh..."
    if curl -fsSL "${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh 2>/dev/null; then
        chmod +x /tmp/nexus-restart.sh
        sudo bash /tmp/nexus-restart.sh </dev/null 2>&1 | tee /var/log/nexus-restart.log || true
        rm -f /tmp/nexus-restart.sh
        sudo systemctl restart cloudflared 2>/dev/null || true
    fi
fi
REMOTE
}

remote_root_setup() {
    local port=$1 pass=$2
    local vnc_pass="${pass:0:8}"
    sshpass -p "$pass" ssh $SSH_OPTS -p "$port" "root@localhost" bash <<REMOTE
set +euo pipefail 2>/dev/null || true
VNC_PASS="${vnc_pass}"
# Fix Docker bridge linkdown (QEMU hypervisor issue)
cat > /etc/systemd/system/fix-docker-bridges.service <<'EOF'
[Unit]
Description=Fix Docker bridge interfaces linkdown
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip link set docker0 up 2>/dev/null; ip link set pelican0 up 2>/dev/null'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable fix-docker-bridges 2>/dev/null || true
systemctl start fix-docker-bridges 2>/dev/null || true

# VNC — install TigerVNC if missing (faster than TightVNC)
apt-get install -y tigervnc-standalone-server novnc websockify 2>/dev/null || \
apt-get install -y tightvncserver novnc websockify 2>/dev/null || true

mkdir -p /root/.vnc
[ -f /root/.vnc/passwd ] || {
    # Password set from calling script via env
    echo "${VNC_PASS:-password}" | vncpasswd -f > /root/.vnc/passwd
    chmod 600 /root/.vnc/passwd
}

cat > /root/.vnc/xstartup <<'EOF'
#!/bin/bash
xrdb $HOME/.Xresources 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null || true
startxfce4 &
EOF
chmod +x /root/.vnc/xstartup

# VNC service
cat > /etc/systemd/system/vncserver.service <<'EOF'
[Unit]
Description=TigerVNC Server
After=network.target
[Service]
Type=forking
User=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1 2>/dev/null
ExecStartPre=/bin/sleep 1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 16
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# noVNC proxy service
cat > /etc/systemd/system/websockify.service <<'EOF'
[Unit]
Description=WebSockify noVNC proxy
After=vncserver.service
Requires=vncserver.service
[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ --compress-level=1 6080 localhost:5901
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# Firefox service — persistent profile, clean shutdown for tab save
cat > /etc/systemd/system/firefox-vnc.service <<'EOF'
[Unit]
Description=Firefox on VNC display
After=websockify.service vncserver.service
Requires=vncserver.service
[Service]
Type=simple
User=root
Environment=DISPLAY=:1
Environment=HOME=/root
Environment=MOZ_DISABLE_CRASHREPORTER=1
Environment=MOZ_CRASHREPORTER_DISABLE=1
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/firefox --display=:1 --no-remote --profile /root/.firefox-vnc-profile
ExecStop=/bin/bash -c 'pkill -SIGTERM -f "firefox.*firefox-vnc-profile"; sleep 4'
Restart=on-failure
RestartSec=10
TimeoutStopSec=15
[Install]
WantedBy=multi-user.target
EOF

# Firefox persistent profile — only initialise once
mkdir -p /root/.firefox-vnc-profile
if [ ! -f /root/.firefox-vnc-profile/places.sqlite ]; then
    cat > /root/.firefox-vnc-profile/user.js <<'EOF'
// Cache — memory only, no disk bloat
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.memory.capacity", 524288);
user_pref("browser.cache.offline.enable", false);

// Session restore — save once per hour, keep only 1 copy
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.interval", 3600000);
user_pref("browser.sessionstore.max_resumed_crashes", -1);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.sessionstore.resume_session_once", false);
user_pref("browser.sessionstore.restore_on_demand", false);
user_pref("browser.sessionstore.restore_pinned_tabs_on_demand", false);
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("browser.sessionstore.max_windows_undo", 0);
user_pref("browser.sessionstore.upgradeBackup.maxUpgradeBackups", 0);

// Performance
user_pref("layers.acceleration.force-enabled", true);
user_pref("gfx.webrender.all", true);
user_pref("gfx.webrender.enabled", true);
user_pref("media.hardware-video-decoding.enabled", false);
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("ui.prefersReducedMotion", 1);
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("network.http.max-connections", 900);
user_pref("network.http.max-connections-per-server", 30);
user_pref("network.prefetch-next", true);
user_pref("network.dns.disablePrefetch", false);
user_pref("dom.ipc.processCount", 1);
user_pref("browser.tabs.remote.autostart", false);
user_pref("toolkit.storage.synchronous", 0);

// Silence
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_override_url", "");
user_pref("startup.homepage_welcome_url", "");
EOF
fi

# Also write session-restore prefs to any existing real Firefox profile
for profile in $(find /root/.mozilla/firefox -maxdepth 1 -name "*.default*" -type d 2>/dev/null); do
    cat > "$profile/user.js" <<'EOF'
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.interval", 15000);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.sessionstore.max_resumed_crashes", -1);
user_pref("browser.sessionstore.resume_session_once", false);
user_pref("browser.sessionstore.restore_on_demand", false);
user_pref("browser.cache.disk.enable", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
EOF
done

systemctl daemon-reload
systemctl enable vncserver websockify firefox-vnc

# Start only if not already running
if systemctl is-active --quiet vncserver; then
    systemctl is-active --quiet websockify  || systemctl start websockify
    systemctl is-active --quiet firefox-vnc || systemctl start firefox-vnc
else
    systemctl start vncserver
    sleep 3
    systemctl start websockify
    sleep 5
    systemctl start firefox-vnc
fi
REMOTE
}

post_boot_setup() {
    local port=$1 user=$2 pass=$3
    log "Running post-boot setup..."
    # Pass VNC password via env substitution before heredoc
    VNC_PASS="${pass:0:8}" remote_user_setup "$port" "$user" "$pass"
    remote_root_setup "$port" "$pass"
    ok "Post-boot setup complete"
}

# ============================================================================
# FREEZE RECOVERY
# ============================================================================

recover_vm() {
    local vm=$1 skip_image=${2:-false}
    local live; live=$(vm_img "$vm")
    local snap; snap=$(vm_snap "$vm")
    local lock; lock=$(vm_lock "$vm")

    # Prevent concurrent recoveries
    if [[ -f "$lock" ]]; then
        local lpid; lpid=$(cat "$lock" 2>/dev/null || true)
        [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null && {
            wlog "$vm" "Recovery already running (PID $lpid) — skipping"
            return 0
        }
    fi
    echo $$ > "$lock"
    trap 'rm -f "$lock"' RETURN

    wlog "$vm" "===== RECOVERY STARTED ====="

    # Step 1 — Kill VM
    wlog "$vm" "Step 1: Killing VM..."
    kill_vm "$vm"
    sleep 2; fuser -k "$live" 2>/dev/null || true; sleep 3
    wlog "$vm" "Step 1: Write lock released"

    if [[ "$skip_image" != "true" ]]; then
        # Step 2 — Compress to tmpfs
        wlog "$vm" "Step 2: Compressing to tmpfs..."
        local tmp_c="${snap}.compressing"
        rm -f "$tmp_c" "$snap"
        qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M \
            "$live" "$tmp_c" || { wlog "$vm" "ERROR: Compress failed"; rm -f "$tmp_c"; return 1; }
        mv "$tmp_c" "$snap"
        wlog "$vm" "Compressed: $(du -sh "$snap" | awk '{print $1}')"

        # Step 3 — Restore from tmpfs
        wlog "$vm" "Step 3: Restoring from tmpfs..."
        rm -f "$live"
        cp "$snap" "$live" || { wlog "$vm" "ERROR: Copy failed"; return 1; }
        [[ $(stat -c%s "$live" 2>/dev/null || echo 0) -eq 0 ]] && {
            wlog "$vm" "ERROR: Empty image"; rm -f "$live"; return 1; }
        qemu-img check "$live" >> "$(vm_wlog "$vm")" 2>&1 || {
            wlog "$vm" "ERROR: Image corrupt"; rm -f "$live"; return 1; }
        wlog "$vm" "Image OK"

        # Step 4 — Clear tmpfs
        wlog "$vm" "Step 4: Clearing tmpfs..."
        rm -rf "${SNAPSHOT_DIR:?}"/*
    fi

    # Step 5 — Restart VM
    wlog "$vm" "Step 5: Restarting VM..."
    rm -f "$(vm_serial "$vm")"
    run_qemu "$vm" || { wlog "$vm" "ERROR: QEMU failed"; return 1; }
    sleep 3
    kill -0 "$(cat "$(vm_pid "$vm")" 2>/dev/null)" 2>/dev/null || {
        wlog "$vm" "ERROR: QEMU died immediately"; return 1; }
    wlog "$vm" "VM alive (PID $(cat "$(vm_pid "$vm")"))"

    # Step 6 — Wait for SSH and run setup
    local el=0
    while (( el < 120 )); do
        if ssh_ready "$SSH_PORT"; then
            wlog "$vm" "SSH ready — running setup..."
            sleep 10
            post_boot_setup "$SSH_PORT" "$USERNAME" "$PASSWORD"
            wlog "$vm" "===== RECOVERY COMPLETE ====="
            return 0
        fi
        sleep 5; (( el+=5 ))
    done
    wlog "$vm" "WARNING: SSH did not respond after recovery"
    return 1
}

# ============================================================================
# WATCHDOG (background process)
# ============================================================================

start_watchdog() {
    local vm=$1

    # Kill old watchdog first
    local wpid_file; wpid_file=$(vm_wpid "$vm")
    if [[ -f "$wpid_file" ]]; then
        kill "$(cat "$wpid_file" 2>/dev/null || true)" 2>/dev/null || true
        rm -f "$wpid_file"
    fi

    # Capture all needed vars for subshell
    local _BD="$BACKUP_DIR" _SD="$SNAPSHOT_DIR" _PORT="$SSH_PORT"
    local _USER="$USERNAME" _PASS="$PASSWORD" _MEM="$MEMORY" _CPU="$CPUS"

    (
        # Re-source helpers needed in subshell
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                  -o ConnectTimeout=15 -o LogLevel=ERROR \
                  -o PasswordAuthentication=yes -o PubkeyAuthentication=no \
                  -o PreferredAuthentications=password"

        _ssh_ready() { local b; b=$(timeout 5 bash -c "exec 3<>/dev/tcp/localhost/$1 && cat <&3" 2>/dev/null | head -1); [[ "$b" == SSH-* ]]; }
        _wlog()      { echo "[$(date '+%H:%M:%S')] $*" >> "$_BD/$vm.watchdog.log"; }
        _kill_vm()   {
            local pf="$_BD/$vm.pid" pid
            pid=$(cat "$pf" 2>/dev/null || true)
            [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 2; kill -9 "$pid" 2>/dev/null || true; }
            rm -f "$pf"
            pkill -f "qemu-system-x86_64.*$_BD/$vm" 2>/dev/null || true
        }
        _run_qemu() {
            if [[ -w /dev/kvm ]]; then
                ACCEL="-enable-kvm"; CPU="-cpu host,+x2apic"
            else
                ACCEL="-accel tcg,thread=multi,tb-size=512"; CPU="-cpu max"
            fi
            local pf_extra=""
            local pf_conf; pf_conf=$(grep ^PORT_FORWARDS "$_BD/$vm.conf" 2>/dev/null | cut -d'"' -f2)
            if [[ -n "$pf_conf" ]]; then
                IFS=',' read -ra arr <<< "$pf_conf"
                for f in "${arr[@]}"; do IFS=':' read -r h g <<< "$f"; pf_extra+=",hostfwd=tcp::${h}-:${g}"; done
            fi
            eval "qemu-system-x86_64 $ACCEL $CPU \
                -machine q35,mem-merge=off,hpet=off -m $_MEM -smp $_CPU \
                -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1 \
                -device i6300esb -watchdog-action reset \
                -object iothread,id=io0 \
                -drive id=hd0,file=$_BD/$vm.img,format=qcow2,if=none,cache=writeback,discard=unmap,aio=threads \
                -device virtio-blk-pci,drive=hd0,iothread=io0 \
                -drive file=$_BD/$vm-seed.iso,format=raw,if=virtio,cache=writeback \
                -boot order=c \
                -device virtio-net-pci,netdev=n0,rx_queue_size=256,tx_queue_size=256,romfile=,host_mtu=1280 \
                -netdev user,id=n0,hostfwd=tcp::${_PORT}-:22,dns=8.8.4.4${pf_extra} \
                -object rng-random,filename=/dev/urandom,id=rng0 \
                -device virtio-rng-pci,rng=rng0 -device virtio-balloon-pci \
                -rtc base=utc,clock=host,driftfix=slew \
                -global kvm-pit.lost_tick_policy=delay \
                -serial file:$_BD/$vm.serial.log \
                -display none -daemonize \
                -pidfile $_BD/$vm.pid" >> "$_BD/$vm.watchdog.log" 2>&1
        }
        _recover() {
            local skip=${1:-false}
            local live="$_BD/$vm.img" snap="$_SD/$vm.img.compressed" lock="$_BD/$vm.recovery.lock"
            [[ -f "$lock" ]] && {
                local lp; lp=$(cat "$lock" 2>/dev/null || true)
                [[ -n "$lp" ]] && kill -0 "$lp" 2>/dev/null && { _wlog "Recovery in progress — skip"; return 0; }
            }
            echo $$ > "$lock"
            _wlog "===== RECOVERY STARTED ====="
            _kill_vm; sleep 2; fuser -k "$live" 2>/dev/null || true; sleep 3
            if [[ "$skip" != "true" ]]; then
                local tmp="${snap}.compressing"; rm -f "$tmp" "$snap"
                qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M "$live" "$tmp" \
                    || { _wlog "ERROR: Compress failed"; rm -f "$tmp" "$lock"; return 1; }
                mv "$tmp" "$snap"
                rm -f "$live"; cp "$snap" "$live" \
                    || { _wlog "ERROR: Copy failed"; rm -f "$lock"; return 1; }
                [[ $(stat -c%s "$live" 2>/dev/null || echo 0) -eq 0 ]] && { _wlog "ERROR: Empty"; rm -f "$live" "$lock"; return 1; }
                qemu-img check "$live" >> "$_BD/$vm.watchdog.log" 2>&1 \
                    || { _wlog "ERROR: Corrupt"; rm -f "$live" "$lock"; return 1; }
                rm -rf "${_SD:?}"/*
            fi
            rm -f "$_BD/$vm.serial.log"
            _run_qemu
            sleep 3
            kill -0 "$(cat "$_BD/$vm.pid" 2>/dev/null)" 2>/dev/null \
                || { _wlog "ERROR: QEMU died"; rm -f "$lock"; return 1; }
            local el=0
            while (( el < 120 )); do
                if _ssh_ready "$_PORT"; then
                    _wlog "SSH ready — running setup..."
                    sleep 10
                    sshpass -p "$_PASS" ssh $SSH_OPTS -p "$_PORT" "${_USER}@localhost" bash \
                        < <(declare -f remote_user_setup; echo remote_user_setup) \
                        >> "$_BD/$vm.watchdog.log" 2>&1 || true
                    sshpass -p "$_PASS" ssh $SSH_OPTS -p "$_PORT" "root@localhost" bash \
                        < <(declare -f remote_root_setup; echo remote_root_setup) \
                        >> "$_BD/$vm.watchdog.log" 2>&1 || true
                    _wlog "===== RECOVERY COMPLETE ====="
                    rm -f "$lock"; return 0
                fi
                sleep 5; (( el+=5 ))
            done
            _wlog "SSH timeout after recovery"
            rm -f "$lock"; return 1
        }

        # Grace period
        sleep 120

        local recoveries=0 max_recoveries=5
        while true; do
            sleep 20
            local pid_file="$_BD/$vm.pid"

            # PID file missing
            if [[ ! -f "$pid_file" ]]; then
                _wlog "PID file missing"
                (( recoveries >= max_recoveries )) && { _wlog "Max recoveries reached"; exit 1; }
                (( recoveries++ )); _recover true; continue
            fi

            local pid; pid=$(cat "$pid_file" 2>/dev/null) || {
                _wlog "Cannot read PID"
                (( recoveries++ )); _recover true; continue
            }

            # QEMU died
            if ! kill -0 "$pid" 2>/dev/null; then
                _wlog "QEMU died (PID $pid)"
                (( recoveries >= max_recoveries )) && { _wlog "Max recoveries"; exit 1; }
                (( recoveries++ ))
                _recover true && { _wlog "Recovery OK"; recoveries=0; sleep 60; }
                continue
            fi

            # SSH check
            if ! _ssh_ready "$_PORT"; then
                local serial="$_BD/$vm.serial.log"
                local stale=0
                [[ -f "$serial" ]] && stale=$(( $(date +%s) - $(stat -c %Y "$serial" 2>/dev/null || echo "$(date +%s)") ))
                if (( stale > 400 )); then
                    _wlog "FREEZE — serial stale ${stale}s"
                    (( recoveries >= max_recoveries )) && { _wlog "Max recoveries"; exit 1; }
                    (( recoveries++ ))
                    _recover && { recoveries=0; sleep 120; } || { _wlog "Recovery failed"; exit 1; }
                else
                    _wlog "SSH down, serial active (${stale}s) — likely busy"
                fi
            else
                recoveries=0
            fi
        done
    ) >> "$(vm_wlog "$vm")" 2>&1 &

    echo $! > "$wpid_file"
    disown
    ok "Watchdog started (PID $!, checks every 20s)"
}

# ============================================================================
# CLOUD-INIT IMAGE SETUP
# ============================================================================

setup_image() {
    log "Downloading and preparing VM image..."
    mkdir -p "$BACKUP_DIR" "$SNAPSHOT_DIR"
    local base="$BACKUP_DIR/$VM_NAME-base.img"

    if [[ ! -f "$base" ]]; then
        log "Downloading $IMG_URL..."
        wget --progress=bar:force "$IMG_URL" -O "$base.tmp" && mv "$base.tmp" "$base" \
            || { error "Download failed"; exit 1; }
    fi

    qemu-img resize "$base" "$DISK_SIZE" &>/dev/null || true
    log "Compressing image..."
    qemu-img convert -p -O qcow2 -c -o compression_type=zstd,cluster_size=2M \
        "$base" "$(vm_img "$VM_NAME")"
    rm -f "$base"

    # Cloud-init user-data
    PASSWD_HASH=""
    if command -v openssl &>/dev/null; then
        PASSWD_HASH=$(openssl passwd -6 "$PASSWORD" | tr -d '\n')
    else
        OPENSSL_BIN=$(find /nix/store -name "openssl" -path "*/bin/openssl" 2>/dev/null | head -1)
        if [[ -n "$OPENSSL_BIN" ]]; then
            PASSWD_HASH=$($OPENSSL_BIN passwd -6 "$PASSWORD" | tr -d '\n')
        else
            PASSWD_HASH=$(python3 -c "import crypt; print(crypt.crypt('$PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null | tr -d '\n')
        fi
    fi

    if [[ -z "$PASSWD_HASH" ]]; then
        error "Could not generate password hash — openssl/python3 not found"
        exit 1
    fi

    cat > /tmp/vps-user-data <<'EOF'
#cloud-config
hostname: __HOSTNAME__
ssh_pwauth: true
disable_root: false
users:
  - name: __USERNAME__
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: __PASSWD_HASH__
chpasswd:
  list: |
    root:__PASSWORD__
    __USERNAME__:__PASSWORD__
  expire: false
write_files:
  - path: /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
  - path: /etc/ssh/sshd_config.d/99-nexus.conf
    content: |
      PasswordAuthentication yes
      PermitRootLogin yes
    permissions: '0644'
  - path: /etc/sudoers.d/__USERNAME__
    content: "__USERNAME__ ALL=(ALL) NOPASSWD:ALL"
    permissions: '0440'
  - path: /etc/systemd/journald.conf.d/no-freeze.conf
    content: |
      [Journal]
      Storage=volatile
      SyncIntervalSec=0
      RateLimitBurst=0
  - path: /etc/docker/daemon.json
    content: |
      {
        "dns": ["8.8.4.4","1.0.0.1","1.1.1.1","9.9.9.9"],
        "mtu": 1280,
        "log-driver": "json-file",
        "log-opts": {"max-size": "10m", "max-file": "3"},
        "live-restore": true,
        "iptables": true,
        "ip-forward": true,
        "ip-masq": true,
        "storage-driver": "overlay2",
        "default-ulimits": {"nofile": {"Name":"nofile","Hard":65535,"Soft":65535}}
      }
    permissions: '0644'
  - path: /etc/sysctl.d/99-vm-tweaks.conf
    content: |
      net.ipv4.ip_forward=1
      net.bridge.bridge-nf-call-iptables=1
      vm.dirty_ratio=10
      vm.dirty_background_ratio=5
      net.ipv4.tcp_congestion_control=bbr
      net.core.default_qdisc=fq
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - echo "127.0.1.1 __HOSTNAME__" >> /etc/hosts
  - id __USERNAME__ || useradd -m -s /bin/bash -G sudo __USERNAME__
  - echo "__USERNAME__:__PASSWORD__" | chpasswd
  - echo "root:__PASSWORD__" | chpasswd
  - systemctl restart ssh || systemctl restart sshd || true
  - systemctl restart systemd-journald
  - modprobe tcp_bbr 2>/dev/null || true
  - sysctl -p /etc/sysctl.d/99-vm-tweaks.conf 2>/dev/null || true
  - systemctl unmask dnsmasq 2>/dev/null || true
  - mkdir -p /etc/systemd/resolved.conf.d
  - printf '[Resolve]\nDNS=8.8.4.4 1.0.0.1\nDNSStubListener=no\nDomains=~.\n' > /etc/systemd/resolved.conf.d/no-stub.conf
  - systemctl restart systemd-resolved 2>/dev/null || true
  - mkdir -p /etc/systemd/system/docker.service.d
  - bash -c 'ARCH=$(uname -m); if [ "$ARCH" = "aarch64" ]; then printf "[Service]\nEnvironment=\"DOCKER_DEFAULT_PLATFORM=linux/arm64\"\n" > /etc/systemd/system/docker.service.d/platform.conf; else printf "[Service]\nEnvironment=\"DOCKER_DEFAULT_PLATFORM=linux/amd64\"\n" > /etc/systemd/system/docker.service.d/platform.conf; fi'
  - systemctl daemon-reload
  - systemctl disable snapd snapd.socket rsyslog avahi-daemon 2>/dev/null || true
  - groupadd docker 2>/dev/null || true
  - touch /etc/cloud/cloud-init.disabled
EOF

    sed -i \
        -e "s|__HOSTNAME__|${HOSTNAME}|g" \
        -e "s|__USERNAME__|${USERNAME}|g" \
        -e "s|__PASSWORD__|${PASSWORD}|g" \
        -e "s|__PASSWD_HASH__|${PASSWD_HASH}|g" \
        /tmp/vps-user-data

    cat > /tmp/vps-meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    cloud-localds "$(vm_seed "$VM_NAME")" /tmp/vps-user-data /tmp/vps-meta-data \
        || { error "Seed image creation failed"; exit 1; }
    ok "VM '$VM_NAME' image ready"
}

# ============================================================================
# VM OPERATIONS
# ============================================================================

create_vm() {
    check_space "$BACKUP_DIR" 3 || return 1
    check_space "/" 8           || return 1

    log "Select OS:"
    local keys=() i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"; keys[$i]="$os"; (( i++ ))
    done
    ask number "Choice" 1
    local os="${keys[$REPLY]}"
    IFS='|' read -r OS_TYPE CODENAME IMG_URL DEF_HOST DEF_USER DEF_PASS <<< "${OS_OPTIONS[$os]}"

    ask name     "VM name"   "$DEF_HOST";  VM_NAME="$REPLY"
    [[ -f "$(vm_conf "$VM_NAME")" ]] && { error "VM '$VM_NAME' already exists"; return 1; }
    ask name     "Hostname"  "$VM_NAME";   HOSTNAME="$REPLY"
    ask username "Username"  "$DEF_USER";  USERNAME="$REPLY"
    ask_password "Password"  "$DEF_PASS";  PASSWORD="$REPLY"
    ask size     "Disk size" "10G";        DISK_SIZE="$REPLY"
    ask number   "Memory MB" "4096";       MEMORY="$REPLY"
    ask number   "CPUs"      "2";          CPUS="$REPLY"
    ask port     "SSH port"  "2222";       SSH_PORT="$REPLY"
    ss -tln 2>/dev/null | grep -q ":$SSH_PORT " && { error "Port in use"; return 1; }
    read -rp "$(prompt "Extra port forwards (e.g. 8080:80) or Enter for none: ")" PORT_FORWARDS
    GUI_MODE=false; CREATED="$(date)"

    setup_image
    save_vm
}

start_vm() {
    local vm=$1
    load_vm "$vm" || return 1

    if vm_running "$vm"; then
        ok "Already running"
        ssh_into_vm "$vm"
        return
    fi

    [[ -f "$(vm_img "$vm")" ]] || { error "Image not found"; return 1; }

    # Recreate seed if missing
    if [[ ! -f "$(vm_seed "$vm")" ]]; then
        warn "Seed missing — recreating..."
        printf '#cloud-config\n' > /tmp/vps-user-data
        printf 'instance-id: iid-%s\nlocal-hostname: %s\n' "$vm" "$HOSTNAME" > /tmp/vps-meta-data
        cloud-localds "$(vm_seed "$vm")" /tmp/vps-user-data /tmp/vps-meta-data
    fi

    rm -f "$(vm_serial "$vm")" "$(vm_lock "$vm")"
    > "$(vm_wlog "$vm")"
    ssh-keygen -R "[localhost]:$SSH_PORT" &>/dev/null || true
    rm -rf "${SNAPSHOT_DIR:?}"/*

    log "Starting $vm (SSH :$SSH_PORT | $USERNAME)"
    run_qemu "$vm" || { error "QEMU failed to start"; return 1; }
    start_watchdog "$vm"

    if wait_ssh "$vm"; then
        sleep 10
        post_boot_setup "$SSH_PORT" "$USERNAME" "$PASSWORD"
        ssh_into_vm "$vm"
    else
        error "Boot failed — check logs:"
        log  "  Serial:   tail -30 $(vm_serial "$vm")"
        log  "  Watchdog: tail -30 $(vm_wlog "$vm")"
    fi
}

stop_vm() {
    local vm=$1
    load_vm "$vm" || return 1
    local wpf; wpf=$(vm_wpid "$vm")
    [[ -f "$wpf" ]] && { kill "$(cat "$wpf" 2>/dev/null || true)" 2>/dev/null || true; rm -f "$wpf"; }
    rm -f "$(vm_lock "$vm")"
    kill_vm "$vm"
    ok "VM '$vm' stopped"
}

ssh_into_vm() {
    local vm=$1
    load_vm "$vm" &>/dev/null || true   # already loaded in most paths
    vm_running "$vm" || { error "VM not running"; return 1; }
    ssh-keygen -R "[localhost]:$SSH_PORT" &>/dev/null || true
    sleep 2
    echo -e "\n${GREEN}=========================================="
    echo -e "  ${USERNAME}@localhost:${SSH_PORT}  |  pass: ${PASSWORD}"
    echo -e "==========================================${NC}\n"
    sshpass -p "$PASSWORD" ssh $SSH_OPTS \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -p "$SSH_PORT" "${USERNAME}@localhost"
}

show_info() {
    local vm=$1
    load_vm "$vm" || return 1
    local status; vm_running "$vm" && status="${GREEN}Running${NC}" || status="${RED}Stopped${NC}"
    local accel; [[ -w /dev/kvm ]] && accel="KVM" || accel="TCG"
    echo ""
    echo -e "${CYAN}VM: $vm${NC}"
    echo "=========================================="
    echo -e "Status:    $(echo -e $status)"
    printf "OS:        %s (%s)\n" "$OS_TYPE" "$CODENAME"
    printf "Hostname:  %s\n" "$HOSTNAME"
    printf "Username:  %s | Password: %s\n" "$USERNAME" "$PASSWORD"
    printf "SSH Port:  %s | Accel: %s\n" "$SSH_PORT" "$accel"
    printf "Resources: %sMB RAM | %s CPUs | %s disk\n" "$MEMORY" "$CPUS" "$DISK_SIZE"
    printf "Forwards:  %s\n" "${PORT_FORWARDS:-None}"
    printf "Created:   %s\n" "$CREATED"
    echo ""
    [[ -f "$(vm_img "$vm")" ]] && printf "Image:     %s\n" "$(du -sh "$(vm_img "$vm")" | awk '{print $1}')"
    echo "=========================================="
    if vm_running "$vm"; then
        read -rp "$(prompt "Connect via SSH? [Y/n]: ")" c
        [[ "${c:-Y}" =~ ^[Yy]$ ]] && ssh_into_vm "$vm"
    else
        read -rp "$(prompt "Press Enter to continue...")"
    fi
}

edit_vm() {
    local vm=$1
    load_vm "$vm" || return 1
    while true; do
        echo "Edit: 1)Hostname 2)Username 3)Password 4)SSH Port 5)Memory 6)CPUs 7)Forwards 0)Back"
        read -rp "$(prompt "Choice: ")" c
        case $c in
            1) ask name     "Hostname"  "$HOSTNAME"; HOSTNAME="$REPLY" ;;
            2) ask username "Username"  "$USERNAME"; USERNAME="$REPLY" ;;
            3) ask_password "Password"  "$PASSWORD"; PASSWORD="$REPLY" ;;
            4) ask port     "SSH Port"  "$SSH_PORT"; SSH_PORT="$REPLY" ;;
            5) ask number   "Memory MB" "$MEMORY";   MEMORY="$REPLY"  ;;
            6) ask number   "CPUs"      "$CPUS";     CPUS="$REPLY"    ;;
            7) read -rp "$(prompt "Forwards [${PORT_FORWARDS:-none}]: ")" v
               PORT_FORWARDS="${v:-$PORT_FORWARDS}" ;;
            0) return ;;
            *) error "Invalid"; continue ;;
        esac
        save_vm
        read -rp "$(prompt "Edit more? [y/N]: ")" m; [[ "$m" =~ ^[Yy]$ ]] || break
    done
}

delete_vm() {
    local vm=$1
    load_vm "$vm" || return 1
    warn "This permanently deletes '$vm' and all data!"
    read -rp "$(prompt "Are you sure? [y/N]: ")" -n 1; echo
    [[ "$REPLY" =~ ^[Yy]$ ]] || { log "Cancelled"; return; }
    stop_vm "$vm" 2>/dev/null || true
    rm -f "$(vm_img "$vm")" "$(vm_snap "$vm")" "$(vm_snap "$vm").compressing"
    rm -f "$(vm_seed "$vm")" "$(vm_conf "$vm")" "$(vm_pid "$vm")"
    rm -f "$(vm_serial "$vm")" "$(vm_wlog "$vm")" "$(vm_wpid "$vm")" "$(vm_lock "$vm")"
    ok "VM '$vm' deleted"
}

resize_vm() {
    local vm=$1
    load_vm "$vm" || return 1
    vm_running "$vm" && { error "Stop the VM first"; return 1; }
    log "Current size: $DISK_SIZE"
    ask size "New size" "15G"
    qemu-img resize "$(vm_img "$vm")" "$REPLY" && { DISK_SIZE="$REPLY"; save_vm; ok "Resized to $REPLY"; } \
        || error "Resize failed"
}

show_perf() {
    local vm=$1
    load_vm "$vm" || return 1
    echo ""; log "Performance: $vm"; echo "=========================================="
    if vm_running "$vm"; then
        local pid; pid=$(cat "$(vm_pid "$vm")" 2>/dev/null || true)
        [[ -n "$pid" ]] && ps -p "$pid" -o pid,%cpu,%mem,rss --no-headers 2>/dev/null || true
        echo ""; free -h
    else
        log "Not running — Config: ${MEMORY}MB | ${CPUS} CPUs | $DISK_SIZE"
    fi
    echo ""; df -h /home | tail -1 | awk '{print "/home: " $4 " free of " $2}'
    echo "=========================================="; read -rp "$(prompt "Enter to continue...")"
}

view_log() {
    local vm=$1 type=${2:-serial}
    load_vm "$vm" || return 1
    local f; [[ "$type" == "serial" ]] && f=$(vm_serial "$vm") || f=$(vm_wlog "$vm")
    [[ -f "$f" ]] && { echo "=========================================="
        tail -40 "$f"; echo "=========================================="; } \
        || warn "No log found"
    read -rp "$(prompt "Enter to continue...")"
}

attach_watchdog() {
    local vm=$1
    load_vm "$vm" || return 1
    vm_running "$vm" || { error "VM not running"; return 1; }
    start_watchdog "$vm"
    ok "Watchdog attached — monitor: tail -f $(vm_wlog "$vm")"
}

# ============================================================================
# MAIN MENU
# ============================================================================

main_menu() {
    while true; do
        header
        local accel; [[ -w /dev/kvm ]] && accel="${GREEN}KVM${NC}" || accel="${YELLOW}TCG${NC}"
        echo -e "${CYAN}Acceleration:${NC} $(echo -e "$accel")"
        df -h /home | tail -1 | awk '{print "  /home:  " $4 " free of " $2 " (" $5 " used)"}'
        df -h /     | tail -1 | awk '{print "  tmpfs:  " $4 " free of " $2 " (" $5 " used)"}'
        echo ""

        local vms=(); mapfile -t vms < <(list_vms)
        local n=${#vms[@]}
        if (( n > 0 )); then
            log "VMs ($n):"
            for i in "${!vms[@]}"; do
                local s; vm_running "${vms[$i]}" \
                    && s="${GREEN}Running${NC}" || s="${RED}Stopped${NC}"
                printf "  %2d) %s (" $(( i+1 )) "${vms[$i]}"
                echo -e "$s)"
            done
            echo ""
        fi

        echo "  1) Create VM"
        (( n > 0 )) && cat <<'MENU'
  2) Start VM
  3) Stop VM
  4) VM info / SSH
  5) Edit VM
  6) Delete VM
  7) Resize disk
  8) Performance
  9) Serial log
 10) Watchdog log
 11) Attach watchdog
MENU
        echo "  0) Exit"; echo

        read -rp "$(prompt "Choice: ")" choice
        if (( n > 0 && choice >= 2 && choice <= 11 )); then
            read -rp "$(prompt "VM number: ")" idx
            [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= n )) \
                || { error "Invalid"; read -rp "$(prompt "Enter...")"; continue; }
            local vm="${vms[$((idx-1))]}"
        fi

        case $choice in
            1)  create_vm ;;
            2)  start_vm "$vm" ;;
            3)  stop_vm "$vm" ;;
            4)  show_info "$vm" ;;
            5)  edit_vm "$vm" ;;
            6)  delete_vm "$vm" ;;
            7)  resize_vm "$vm" ;;
            8)  show_perf "$vm" ;;
            9)  view_log "$vm" serial ;;
            10) view_log "$vm" watchdog ;;
            11) attach_watchdog "$vm" ;;
            0)  log "Goodbye!"; exit 0 ;;
            *)  error "Invalid option" ;;
        esac
        read -rp "$(prompt "Enter to continue...")" 2>/dev/null || true
    done
}

# ============================================================================
# INIT
# ============================================================================

trap 'rm -f /tmp/vps-user-data /tmp/vps-meta-data 2>/dev/null' EXIT
check_deps
mkdir -p "$BACKUP_DIR"
mountpoint -q "$SNAPSHOT_DIR" 2>/dev/null || {
    mkdir -p "$SNAPSHOT_DIR"
    mount -t tmpfs -o size=16G tmpfs "$SNAPSHOT_DIR" 2>/dev/null || true
}

declare -A OS_OPTIONS=(
    ["Ubuntu 22.04 (minimal)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 (minimal)"]="ubuntu|noble|https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Ubuntu 22.04 (standard)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04 (standard)"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Ubuntu 22.04 (kvm-kernel)"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img|ubuntu22|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

main_menu
