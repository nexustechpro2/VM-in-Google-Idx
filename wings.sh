#!/bin/bash

################################################################################
# PELICAN WINGS - COMPLETE INSTALLER v8.0 PRODUCTION READY
# - FIXED: Docker uses systemd on VMs (no more manual dockerd killing)
# - FIXED: Falls back to manual only if systemd unavailable
# - FIXED: Never kills running Docker unnecessarily
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

ENV_FILE=""
for location in \
    "/root/.pelican.env" \
    "$HOME/.pelican.env" \
    "$(pwd)/.pelican.env"; do
    if [ -f "$location" ]; then
        ENV_FILE="$location"
        break
    fi
done
[ -z "$ENV_FILE" ] && ENV_FILE="/root/.pelican.env"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Pelican Wings Installer v8.0 FINAL  ║${NC}"
echo -e "${GREEN}║   Production Ready - VM Safe          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

# ============================================================================
# BACKUP EXISTING WINGS CONFIG
# ============================================================================
if [ -f "/etc/pelican/config.yml" ]; then
    BACKUP_DIR="/root/.backups"
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp /etc/pelican/config.yml "${BACKUP_DIR}/wings_config_${TIMESTAMP}.backup"
    chmod 600 "${BACKUP_DIR}/wings_config_${TIMESTAMP}.backup"
    EXISTING_TOKEN_ID=$(grep "token_id:" /etc/pelican/config.yml 2>/dev/null | awk '{print $2}' | tr -d '"')
    [ -n "$EXISTING_TOKEN_ID" ] && echo -e "${GREEN}[BACKUP] ✓ Backup saved with token_id: ${EXISTING_TOKEN_ID}${NC}"
    echo ""
fi

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================
echo -e "${CYAN}[1/20] Loading configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo -e "${GREEN}   ✓ Panel config loaded${NC}"
    [ -n "$PANEL_DOMAIN" ] && PANEL_URL="https://${PANEL_DOMAIN}" && echo -e "${CYAN}   Panel URL: ${GREEN}${PANEL_URL}${NC}"
    [ -n "$PANEL_API_TOKEN" ] && PANEL_TOKEN="$PANEL_API_TOKEN" && echo -e "${CYAN}   API Token: ${GREEN}${PANEL_TOKEN:0:20}...${NC}"
    [ -n "$NODE_ID" ] && echo -e "${CYAN}   Node ID: ${GREEN}${NODE_ID}${NC}"
    [ -n "$NODE_DOMAIN" ] && echo -e "${CYAN}   Node Domain: ${GREEN}${NODE_DOMAIN}${NC}"
    [ -n "$CF_TOKEN_WINGS" ] && CF_TOKEN="$CF_TOKEN_WINGS" && echo -e "${CYAN}   CF Tunnel: ${GREEN}Configured${NC}"
else
    echo -e "${YELLOW}   ⚠ No saved config found${NC}"
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[2/20] Detecting environment...${NC}"

IS_CONTAINER=false
HAS_SYSTEMD=false

if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
    HAS_SYSTEMD=true
    echo -e "${GREEN}   ✓ Systemd available${NC}"
fi

if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null || grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; then
    IS_CONTAINER=true
    echo -e "${YELLOW}   ⚠ Container environment${NC}"
else
    echo -e "${GREEN}   ✓ VM/Bare-metal environment${NC}"
fi

# ============================================================================
# USER INPUT
# ============================================================================
echo -e "${CYAN}[3/20] Wings configuration...${NC}"

if [ -z "$NODE_DOMAIN" ]; then
    read -p "Node domain (e.g., node-1.example.com): " NODE_DOMAIN
else
    read -p "Node domain [$NODE_DOMAIN]: " NODE_DOMAIN_INPUT
    NODE_DOMAIN="${NODE_DOMAIN_INPUT:-$NODE_DOMAIN}"
fi

if [ -z "$PANEL_URL" ]; then
    read -p "Panel URL (e.g., https://panel.example.com): " PANEL_URL
else
    read -p "Panel URL [$PANEL_URL]: " PANEL_URL_INPUT
    PANEL_URL="${PANEL_URL_INPUT:-$PANEL_URL}"
fi

if [ -z "$PANEL_TOKEN" ]; then
    read -p "Panel API Token (starts with papp_): " PANEL_TOKEN
else
    read -p "Panel API Token [${PANEL_TOKEN:0:20}...]: " PANEL_TOKEN_INPUT
    PANEL_TOKEN="${PANEL_TOKEN_INPUT:-$PANEL_TOKEN}"
fi

if [ -z "$NODE_ID" ]; then
    read -p "Node ID [1]: " NODE_ID
    NODE_ID=${NODE_ID:-1}
else
    read -p "Node ID [$NODE_ID]: " NODE_ID_INPUT
    NODE_ID="${NODE_ID_INPUT:-$NODE_ID}"
fi

[ -z "$CF_TOKEN" ] && read -p "Cloudflare Tunnel Token: " CF_TOKEN

echo -e "${GREEN}   ✓ Configuration collected${NC}"

# Save to .pelican.env
if [ -f "$ENV_FILE" ]; then
    grep -q "^NODE_DOMAIN=" "$ENV_FILE" && sed -i "s|^NODE_DOMAIN=.*|NODE_DOMAIN=\"${NODE_DOMAIN}\"|" "$ENV_FILE" || echo "NODE_DOMAIN=\"${NODE_DOMAIN}\"" >> "$ENV_FILE"
    grep -q "^NODE_ID=" "$ENV_FILE" && sed -i "s|^NODE_ID=.*|NODE_ID=\"${NODE_ID}\"|" "$ENV_FILE" || echo "NODE_ID=\"${NODE_ID}\"" >> "$ENV_FILE"
    grep -q "^CF_TOKEN_WINGS=" "$ENV_FILE" && sed -i "s|^CF_TOKEN_WINGS=.*|CF_TOKEN_WINGS=\"${CF_TOKEN}\"|" "$ENV_FILE" || echo "CF_TOKEN_WINGS=\"${CF_TOKEN}\"" >> "$ENV_FILE"
    grep -q "^PANEL_API_TOKEN=" "$ENV_FILE" && sed -i "s|^PANEL_API_TOKEN=.*|PANEL_API_TOKEN=\"${PANEL_TOKEN}\"|" "$ENV_FILE" || echo "PANEL_API_TOKEN=\"${PANEL_TOKEN}\"" >> "$ENV_FILE"
fi

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[4/20] Updating system...${NC}"
apt-get update -qq 2>&1 | grep -v "^Get:" || true
apt-get install -y curl wget sudo ca-certificates gnupg openssl iptables git net-tools 2>/dev/null || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# REMOVE OLD DOCKER
# ============================================================================
echo -e "${CYAN}[5/20] Cleaning old Docker...${NC}"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done
apt-get autoremove -y 2>/dev/null || true
echo -e "${GREEN}   ✓ Cleanup complete${NC}"

# ============================================================================
# INSTALL DOCKER
# ============================================================================
echo -e "${CYAN}[6/20] Installing Docker...${NC}"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >/dev/null 2>&1
    rm get-docker.sh
fi
echo -e "${GREEN}   ✓ Docker installed: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')${NC}"

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
StartLimitInterval=0
EOF
systemctl daemon-reload

# ============================================================================
# CONFIGURE AND START DOCKER
# ============================================================================
echo -e "${CYAN}[7/20] Starting Docker daemon...${NC}"

mkdir -p /etc/docker

if [ "$IS_CONTAINER" = true ]; then
    cat > /etc/docker/daemon.json <<'DEOF'
{
"dns": ["172.18.0.1"],
"dns-opts": ["ndots:0", "timeout:2", "attempts:2"],
"mtu": 1280,
  "iptables": true,
  "ip-masq": true,
  "ipv6": false,
  "userland-proxy": true,
  "default-address-pools": [{"base": "172.25.0.0/16", "size": 24}],
  "bip": "172.26.0.1/16",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "live-restore": true,
  "storage-driver": "overlay2",
  "default-ulimits": {
    "nofile": {"Name": "nofile", "Hard": 65535, "Soft": 65535}
  }
}
DEOF
else
    cat > /etc/docker/daemon.json <<'DEOF'
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
DEOF
fi

# TCP MSS clamping — fixes slow/broken downloads when ICMP is blocked
iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# Enable TCP BBR congestion control
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
cat >> /etc/sysctl.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
SYSCTL
sysctl -p >/dev/null 2>&1 || true

# TCP MSS clamping — fixes slow/broken downloads when ICMP is blocked
iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# Smart watchdog — only fixes what's actually broken, never blind restarts
cat > /usr/local/bin/pelican-watchdog.sh <<'WATCHDOG'
#!/bin/bash
LOG=/var/log/pelican-watchdog.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

while true; do
    # Check Wings
    WINGS_OK=false
    RESPONSE=$(curl -s http://localhost:8080/api/system 2>/dev/null)
    echo "$RESPONSE" | grep -q "authorization" && WINGS_OK=true

    if [ "$WINGS_OK" = true ]; then
        # Wings healthy — just ensure MSS clamp exists
        iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        sleep 30
        continue
    fi

    log "Wings not responding — diagnosing..."

    # Check Docker first
    if ! docker info >/dev/null 2>&1; then
        log "Docker is down — restarting Docker only"
        systemctl reset-failed docker 2>/dev/null || true
        rm -f /var/run/docker.pid /var/run/docker.sock
        systemctl start docker
        sleep 10
        if ! docker info >/dev/null 2>&1; then
            log "Docker failed to restart — giving up this cycle"
            sleep 30
            continue
        fi
        log "Docker recovered"
    fi

    # Docker fine but Wings down — restart Wings only
    if ! systemctl is-active --quiet wings; then
        log "Wings is down — restarting Wings"
        sed -i '/ssl:/,/key:/ s/enabled: true/enabled: false/' /etc/pelican/config.yml 2>/dev/null || true
        sed -i 's/port: 8443/port: 8080/' /etc/pelican/config.yml 2>/dev/null || true
        systemctl reset-failed wings 2>/dev/null || true
        systemctl start wings
        sleep 10
        systemctl is-active --quiet wings && log "Wings recovered" || log "Wings failed — check: journalctl -u wings -n 20"
    fi

    iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

    sleep 30
done
WATCHDOG
chmod +x /usr/local/bin/pelican-watchdog.sh

cat > /etc/systemd/system/pelican-watchdog.service <<'WDEOF'
[Unit]
Description=Pelican Wings/Docker Smart Watchdog
After=wings.service docker.service
Wants=wings.service docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pelican-watchdog.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
WDEOF

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl daemon-reload
    systemctl enable pelican-watchdog
    systemctl start pelican-watchdog
fi
echo -e "${GREEN}   ✓ Smart watchdog installed (checks every 30s, only fixes what's broken)${NC}"

# Persist iptables rule across reboots
if [ "$HAS_SYSTEMD" = true ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# KEY FIX: Check if Docker is already running BEFORE doing anything
if docker info >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker already running - skipping restart${NC}"
else
    echo -e "${YELLOW}   Docker not running, starting...${NC}"

rm -f /var/run/docker.pid
rm -f /var/run/docker.sock
systemctl reset-failed docker 2>/dev/null || true

    # Try systemd first (proper way on VMs)
    if [ "$HAS_SYSTEMD" = true ]; then
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null && sleep 3 || true
    fi

    # Only use manual dockerd if systemd failed
    if ! docker info >/dev/null 2>&1; then
        pkill -9 dockerd 2>/dev/null || true
        rm -f /var/run/docker.sock /var/run/docker.pid
        sleep 2
        nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &

        echo -n "   Waiting for Docker"
        for i in {1..20}; do
            sleep 1
            echo -n "."
            if docker info >/dev/null 2>&1; then
                echo ""
                break
            fi
        done
        echo ""
    fi
fi

if docker info >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker daemon running${NC}"
else
    echo -e "${RED}   ❌ Docker failed to start${NC}"
    exit 1
fi

# ============================================================================
# TEST DOCKER DNS
# ============================================================================
echo -e "${CYAN}[8/20] Testing Docker DNS...${NC}"
docker pull alpine:latest >/dev/null 2>&1 || true

DNS_TEST=$(docker run --rm alpine nslookup deb.debian.org 2>&1 || echo "FAILED")
if echo "$DNS_TEST" | grep -q "Address:"; then
    echo -e "${GREEN}   ✓ DNS working (bridge mode)${NC}"
    USE_HOST_NETWORK=false
else
    HOST_DNS_TEST=$(docker run --rm --network host alpine nslookup deb.debian.org 2>&1 || echo "FAILED")
    if echo "$HOST_DNS_TEST" | grep -q "Address:"; then
        echo -e "${GREEN}   ✓ DNS working (host mode)${NC}"
        USE_HOST_NETWORK=true
    else
        echo -e "${RED}   ❌ DNS completely blocked!${NC}"
        exit 1
    fi
fi

# ============================================================================
# KERNEL CONFIG
# ============================================================================
echo -e "${CYAN}[9/20] Kernel configuration...${NC}"
if [ "$IS_CONTAINER" = false ]; then
    cat > /etc/modules-load.d/pelican-wings.conf <<EOF
overlay
br_netfilter
EOF
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    cat > /etc/sysctl.d/99-pelican-wings.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 10
EOF
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}   ✓ Kernel configured${NC}"
else
    echo -e "${YELLOW}   ⚠ Skipped (container)${NC}"
fi

# ============================================================================
# CREATE DIRECTORIES
# ============================================================================
echo -e "${CYAN}[10/20] Creating directories...${NC}"
mkdir -p /etc/pelican /var/lib/pelican/{volumes,archives,backups} /var/log/pelican /var/run/wings /tmp/pelican
chmod 755 /etc/pelican /var/lib/pelican /var/log/pelican
echo -e "${GREEN}   ✓ Directories created${NC}"

# ============================================================================
# DOWNLOAD WINGS
# ============================================================================
echo -e "${CYAN}[11/20] Downloading Wings...${NC}"
cd /usr/local/bin
curl -L -o wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64" 2>/dev/null
chmod +x wings
[ ! -x /usr/local/bin/wings ] && echo -e "${RED}   ❌ Wings download failed${NC}" && exit 1
WINGS_VERSION=$(wings --version 2>/dev/null | grep -oP 'wings \Kv[\d\.]+' || echo "latest")
echo -e "${GREEN}   ✓ Wings ${WINGS_VERSION} installed${NC}"
mkdir -p /var/lib/pelican/volumes
chown -R pelican:pelican /var/lib/pelican 2>/dev/null || true
chmod 755 /var/lib/pelican

# ============================================================================
# SSL CERTIFICATES
# ============================================================================
echo -e "${CYAN}[12/20] Creating SSL certificates...${NC}"
mkdir -p /etc/letsencrypt/live/${NODE_DOMAIN}
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem \
  -out /etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem \
  -subj "/CN=${NODE_DOMAIN}" 2>/dev/null
echo -e "${GREEN}   ✓ Self-signed certificate created${NC}"

# ============================================================================
# CONFIGURE WINGS
# ============================================================================
echo -e "${CYAN}[13/20] Configuring Wings via Panel API...${NC}"
[ -f "/etc/pelican/config.yml" ] && rm /etc/pelican/config.yml

if wings configure --panel-url "${PANEL_URL}" --token "${PANEL_TOKEN}" --node "${NODE_ID}" 2>/dev/null; then
    echo -e "${GREEN}   ✓ Wings configured successfully${NC}"
else
    echo -e "${RED}   ❌ Configuration failed - check Panel URL and API token${NC}"
    exit 1
fi

# ============================================================================
# APPLY CRITICAL CONFIGURATION FIXES
# ============================================================================
echo -e "${CYAN}[14/20] Applying critical fixes...${NC}"
cp /etc/pelican/config.yml /etc/pelican/config.yml.backup
sed -i 's/port: 443/port: 8080/' /etc/pelican/config.yml
sed -i 's/port: 8443/port: 8080/' /etc/pelican/config.yml
sed -i 's/host: 127.0.0.1/host: 0.0.0.0/' /etc/pelican/config.yml
sed -i 's/IPv6: true/IPv6: false/' /etc/pelican/config.yml
sed -i '/ssl:/,/key:/ s/enabled: true/enabled: false/' /etc/pelican/config.yml
sed -i '/dns:/,/- 1.0.0.1/ c\    dns:\n    - 172.18.0.1' /etc/pelican/config.yml
sed -i 's/network_mtu: 1500/network_mtu: 1280/' /etc/pelican/config.yml
sed -i '/^      v6:/,/^        gateway:/ s/^/#/' /etc/pelican/config.yml
if [ "$USE_HOST_NETWORK" = true ]; then
    sed -i 's/network_mode: pelican_nw/network_mode: host/' /etc/pelican/config.yml
fi
PORT_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "port:" | awk '{print $2}')
HOST_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "host:" | awk '{print $2}')
echo -e "${GREEN}   ✓ Configuration fixed - listening on: ${HOST_CHECK}:${PORT_CHECK}${NC}"

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[15/20] Installing Cloudflare Tunnel...${NC}"
if ! command -v cloudflared &>/dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || { apt --fix-broken install -y 2>/dev/null; dpkg -i cloudflared-linux-amd64.deb 2>/dev/null; }
    rm -f cloudflared-linux-amd64.deb
fi
pkill cloudflared 2>/dev/null || true
echo -e "${GREEN}   ✓ Cloudflare Tunnel installed${NC}"

# ============================================================================
# CREATE AUTO-START SCRIPT
# ============================================================================
echo -e "${CYAN}[16/20] Creating auto-start script...${NC}"
cat > /usr/local/bin/start-wings.sh <<STARTEOF
#!/bin/bash
CF_TOKEN_WINGS="${CF_TOKEN}"
echo "Starting Wings services..."

# Start Docker via systemd if available, else manual
if ! docker info >/dev/null 2>&1; then
    if systemctl start docker 2>/dev/null; then
        sleep 5
    else
        pkill -9 dockerd 2>/dev/null || true
        rm -f /var/run/docker.sock /var/run/docker.pid
        nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
        sleep 10
    fi
fi

! pgrep -x wings > /dev/null && cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 & sleep 3
! pgrep cloudflared > /dev/null && nohup cloudflared tunnel run --token "\$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 & sleep 2

docker info >/dev/null 2>&1 && echo "  ✓ Docker running" || echo "  ✗ Docker not running"
pgrep -x wings >/dev/null && echo "  ✓ Wings running" || echo "  ✗ Wings not running"
pgrep cloudflared >/dev/null && echo "  ✓ Cloudflare running" || echo "  ✗ Cloudflare not running"
STARTEOF
chmod +x /usr/local/bin/start-wings.sh
echo -e "${GREEN}   ✓ Auto-start script created${NC}"

# ============================================================================
# START WINGS - Use systemd if available
# ============================================================================
echo -e "${CYAN}[17/20] Starting Wings...${NC}"
pkill -x wings 2>/dev/null || true
sleep 1

if [ "$HAS_SYSTEMD" = true ]; then
    cat > /etc/systemd/system/wings.service <<'WEOF'
[Unit]
Description=Pelican Wings Daemon
After=docker.service
Requires=docker.service
[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=always
RestartSec=5s
StartLimitInterval=0
[Install]
WantedBy=multi-user.target
WEOF
    systemctl daemon-reload
    systemctl enable wings 2>/dev/null || true
    systemctl start wings 2>/dev/null || {
        cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 &
    }
else
    cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 &
fi

sleep 5
ps aux | grep -v grep | grep -q wings && echo -e "${GREEN}   ✓ Wings running${NC}" || echo -e "${RED}   ❌ Wings failed - check: tail -20 /tmp/wings.log${NC}"
netstat -tulpn 2>/dev/null | grep -q ":8080" && echo -e "${GREEN}   ✓ Wings on port 8080${NC}" || echo -e "${YELLOW}   ⚠ Wings not on port 8080 yet${NC}"

# ============================================================================
# START CLOUDFLARE TUNNEL - Use systemd if available
# ============================================================================
echo -e "${CYAN}[18/20] Starting Cloudflare Tunnel...${NC}"
if [ "$HAS_SYSTEMD" = true ]; then
    cloudflared service install "$CF_TOKEN" 2>/dev/null && systemctl start cloudflared 2>/dev/null && systemctl enable cloudflared 2>/dev/null || \
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-wings.log 2>&1 &
else
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-wings.log 2>&1 &
fi
sleep 3
ps aux | grep -v grep | grep -q cloudflared && echo -e "${GREEN}   ✓ Cloudflare Tunnel running${NC}" || echo -e "${YELLOW}   ⚠ Cloudflare may need manual start${NC}"

# ============================================================================
# CLEAR PANEL CACHE
# ============================================================================
echo -e "${CYAN}[19/20] Clearing Panel cache (if present)...${NC}"
if [ -d "/var/www/pelican" ]; then
    PANEL_PHP=""
    for ver in 8.5 8.4 8.3 8.2; do
        [ -f "/usr/bin/php${ver}" ] && PANEL_PHP="/usr/bin/php${ver}" && break
    done
    [ -z "$PANEL_PHP" ] && PANEL_PHP=$(which php)
    cd /var/www/pelican
    $PANEL_PHP artisan config:clear >/dev/null 2>&1 || true
    $PANEL_PHP artisan cache:clear >/dev/null 2>&1 || true
    $PANEL_PHP artisan view:clear >/dev/null 2>&1 || true
    rm -rf storage/framework/views/* 2>/dev/null || true
    PANEL_PHP_VER=$(ls /etc/php/ | sort -rV | head -1)
    systemctl restart php${PANEL_PHP_VER}-fpm nginx 2>/dev/null || true
    supervisorctl restart pelican-queue 2>/dev/null || true
    sleep 2
    echo -e "${GREEN}   ✓ Panel cache cleared${NC}"
else
    echo -e "${YELLOW}   ⚠ Panel not on this server${NC}"
fi

# ============================================================================
# SAVE TOKEN_ID
# ============================================================================
echo -e "${CYAN}[20/20] Saving configuration...${NC}"
TOKEN_ID=$(grep "token_id:" /etc/pelican/config.yml 2>/dev/null | awk '{print $2}' | tr -d '"')
if [ -n "$TOKEN_ID" ] && [ -f "$ENV_FILE" ]; then
    grep -q "^WINGS_TOKEN_ID=" "$ENV_FILE" && sed -i "s|^WINGS_TOKEN_ID=.*|WINGS_TOKEN_ID=\"${TOKEN_ID}\"|" "$ENV_FILE" || echo -e "\nWINGS_TOKEN_ID=\"${TOKEN_ID}\"" >> "$ENV_FILE"
    echo -e "${GREEN}   ✓ Token ID saved: ${TOKEN_ID}${NC}"
fi

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}Verifying installation...${NC}"
CHECKS=0
docker info >/dev/null 2>&1 && { echo -e "${GREEN}  ✓ Docker running${NC}"; ((CHECKS++)); }
ps aux | grep -v grep | grep -q wings && { echo -e "${GREEN}  ✓ Wings running${NC}"; ((CHECKS++)); }
ps aux | grep -v grep | grep -q cloudflared && { echo -e "${GREEN}  ✓ Cloudflare Tunnel${NC}"; ((CHECKS++)); }
[ -f /etc/pelican/config.yml ] && { echo -e "${GREEN}  ✓ Configuration exists${NC}"; ((CHECKS++)); }
netstat -tulpn 2>/dev/null | grep -q 8080 && { echo -e "${GREEN}  ✓ Wings on port 8080${NC}"; ((CHECKS++)); }
WINGS_TEST=$(curl -s http://localhost:8080/api/system 2>&1 || echo "FAILED")
echo "$WINGS_TEST" | grep -q "error.*authorization" && { echo -e "${GREEN}  ✓ Wings API responding${NC}"; ((CHECKS++)); } || echo -e "${YELLOW}  ⚠ Wings API test inconclusive${NC}"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Wings Installation Complete! (${CHECKS}/6)    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}🎯 CONFIGURE CLOUDFLARE TUNNEL${NC}"
echo -e "1. Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "2. Zero Trust → Networks → Tunnels → Configure"
echo -e "3. Add Public Hostname:"
echo -e "   - Subdomain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f1)${NC}"
echo -e "   - Domain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "   - Service: ${GREEN}HTTPS → 127.0.0.1:8080${NC}"
echo -e "   - ${RED}⚠️  Enable 'No TLS Verify'${NC}"
echo ""
echo -e "${CYAN}📋 UPDATE PANEL NODE${NC}"
echo -e "Admin → Nodes → Edit Node ${NODE_ID}"
echo -e "   FQDN: ${GREEN}${NODE_DOMAIN}${NC} | Port: ${GREEN}8443${NC} | SSL: ${GREEN}HTTPS (SSL)${NC}"
echo ""
echo -e "${CYAN}🧪 TEST: ${GREEN}curl -k https://localhost:8080/api/system${NC}"
echo -e "${CYAN}📋 LOGS: ${GREEN}tail -f /tmp/wings.log${NC}"
echo -e "${CYAN}🔧 RESTART: ${GREEN}/usr/local/bin/start-wings.sh${NC}"
echo ""
echo -e "${BLUE}✅ Wings is ready!${NC}"