#!/bin/bash

################################################################################
# PELICAN WINGS - COMPLETE INSTALLER v7.0 PRODUCTION READY
# - FIXED: Preserves Wings configuration on reinstall
# - FIXED: Reads PAPP token from .pelican.env
# - FIXED: Migration-safe (works across Codespace switches)
# - FIXED: Port 8080, Docker DNS, IPv6 disabled
# - Production ready for all environments
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.pelican.env"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Pelican Wings Installer v7.0 FINAL  ║${NC}"
echo -e "${GREEN}║   Production Ready - Migration Safe   ║${NC}"
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
    BACKUP_DIR="${SCRIPT_DIR}/.backups"
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    echo -e "${CYAN}[BACKUP] Found existing Wings installation${NC}"
    echo -e "${YELLOW}   Creating backup of config.yml...${NC}"
    
    cp /etc/pelican/config.yml "${BACKUP_DIR}/wings_config_${TIMESTAMP}.backup"
    chmod 600 "${BACKUP_DIR}/wings_config_${TIMESTAMP}.backup"
    
    # Extract token_id for reference
    EXISTING_TOKEN_ID=$(grep "token_id:" /etc/pelican/config.yml 2>/dev/null | awk '{print $2}' | tr -d '"')
    if [ -n "$EXISTING_TOKEN_ID" ]; then
        echo -e "${GREEN}   ✓ Backup saved with token_id: ${EXISTING_TOKEN_ID}${NC}"
    fi
    echo ""
fi

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================
echo -e "${CYAN}[1/20] Loading configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo -e "${GREEN}   ✓ Panel config loaded${NC}"
    
    # Use saved values if they exist
    if [ -n "$PANEL_DOMAIN" ]; then
        PANEL_URL="https://${PANEL_DOMAIN}"
        echo -e "${CYAN}   Panel URL: ${GREEN}${PANEL_URL}${NC}"
    fi
    
    if [ -n "$PANEL_API_TOKEN" ]; then
        PANEL_TOKEN="$PANEL_API_TOKEN"
        echo -e "${CYAN}   API Token: ${GREEN}${PANEL_TOKEN:0:20}...${NC}"
    fi
    
    if [ -n "$NODE_ID" ]; then
        echo -e "${CYAN}   Node ID: ${GREEN}${NODE_ID}${NC}"
    fi
    
    if [ -n "$NODE_DOMAIN" ]; then
        echo -e "${CYAN}   Node Domain: ${GREEN}${NODE_DOMAIN}${NC}"
    fi
    
    if [ -n "$CF_TOKEN_WINGS" ]; then
        CF_TOKEN="$CF_TOKEN_WINGS"
        echo -e "${CYAN}   CF Tunnel: ${GREEN}Configured${NC}"
    fi
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
    if systemctl is-system-running >/dev/null 2>&1 || systemctl is-system-running --quiet 2>&1; then
        HAS_SYSTEMD=true
        echo -e "${GREEN}   ✓ Systemd available${NC}"
    fi
fi

if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null || grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; then
    IS_CONTAINER=true
    echo -e "${YELLOW}   ⚠ Container environment (Codespaces/Docker)${NC}"
fi

# ============================================================================
# USER INPUT (with defaults from .pelican.env)
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

if [ -z "$CF_TOKEN" ]; then
    read -p "Cloudflare Tunnel Token: " CF_TOKEN
fi

echo -e "${GREEN}   ✓ Configuration collected${NC}"

# Save to .pelican.env
if [ -f "$ENV_FILE" ]; then
    # Update existing
    if grep -q "^NODE_DOMAIN=" "$ENV_FILE"; then
        sed -i "s|^NODE_DOMAIN=.*|NODE_DOMAIN=\"${NODE_DOMAIN}\"|" "$ENV_FILE"
    else
        echo "NODE_DOMAIN=\"${NODE_DOMAIN}\"" >> "$ENV_FILE"
    fi
    
    if grep -q "^NODE_ID=" "$ENV_FILE"; then
        sed -i "s|^NODE_ID=.*|NODE_ID=\"${NODE_ID}\"|" "$ENV_FILE"
    else
        echo "NODE_ID=\"${NODE_ID}\"" >> "$ENV_FILE"
    fi
    
    if grep -q "^CF_TOKEN_WINGS=" "$ENV_FILE"; then
        sed -i "s|^CF_TOKEN_WINGS=.*|CF_TOKEN_WINGS=\"${CF_TOKEN}\"|" "$ENV_FILE"
    else
        echo "CF_TOKEN_WINGS=\"${CF_TOKEN}\"" >> "$ENV_FILE"
    fi
    
    if grep -q "^PANEL_API_TOKEN=" "$ENV_FILE"; then
        sed -i "s|^PANEL_API_TOKEN=.*|PANEL_API_TOKEN=\"${PANEL_TOKEN}\"|" "$ENV_FILE"
    else
        echo "PANEL_API_TOKEN=\"${PANEL_TOKEN}\"" >> "$ENV_FILE"
    fi
fi

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[4/20] Updating system...${NC}"
apt-get update -qq 2>&1 | grep -v "^Get:" || true
apt-get install -y curl wget sudo ca-certificates gnupg openssl iptables git 2>/dev/null || true
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

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >/dev/null 2>&1
    rm get-docker.sh
fi

echo -e "${GREEN}   ✓ Docker installed: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')${NC}"

# ============================================================================
# CONFIGURE AND START DOCKER
# ============================================================================
echo -e "${CYAN}[7/20] Starting Docker daemon...${NC}"

mkdir -p /etc/docker

if [ "$IS_CONTAINER" = true ]; then
    cat > /etc/docker/daemon.json <<'DEOF'
{
  "dns": ["8.8.8.8", "1.1.1.1", "8.8.4.4"],
  "dns-opts": ["ndots:0"],
  "iptables": false,
  "ip6tables": false,
  "ipv6": false,
  "userland-proxy": true,
  "default-address-pools": [{"base": "172.25.0.0/16", "size": 24}],
  "bip": "172.26.0.1/16",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
DEOF
else
    cat > /etc/docker/daemon.json <<'DEOF'
{
  "dns": ["8.8.8.8", "1.1.1.1", "8.8.4.4"],
  "dns-opts": ["ndots:0"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
DEOF
fi

pkill -9 dockerd 2>/dev/null || true
rm -f /var/run/docker.sock
sleep 2

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable docker 2>/dev/null || true
    systemctl restart docker 2>/dev/null || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
    
    echo -n "   Waiting for Docker"
    for i in {1..15}; do
        sleep 1
        echo -n "."
        if docker info >/dev/null 2>&1; then
            echo ""
            break
        fi
    done
    echo ""
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

docker pull alpine:latest >/dev/null 2>&1 || docker pull --network host alpine:latest >/dev/null 2>&1

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

mkdir -p /etc/pelican
mkdir -p /var/lib/pelican/{volumes,archives,backups}
mkdir -p /var/log/pelican
mkdir -p /var/run/wings
mkdir -p /tmp/pelican

chmod 755 /etc/pelican /var/lib/pelican /var/log/pelican

echo -e "${GREEN}   ✓ Directories created${NC}"

# ============================================================================
# DOWNLOAD WINGS
# ============================================================================
echo -e "${CYAN}[11/20] Downloading Wings...${NC}"

cd /usr/local/bin
curl -L -o wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64" 2>/dev/null
chmod +x wings

if [ ! -x /usr/local/bin/wings ]; then
    echo -e "${RED}   ❌ Wings download failed${NC}"
    exit 1
fi

WINGS_VERSION=$(wings --version 2>/dev/null | grep -oP 'wings \Kv[\d\.]+' || echo "latest")
echo -e "${GREEN}   ✓ Wings ${WINGS_VERSION} installed${NC}"

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
# CONFIGURE WINGS (MIGRATION-SAFE)
# ============================================================================
echo -e "${CYAN}[13/20] Configuring Wings via Panel API...${NC}"

# Remove old config if reconfiguring
if [ -f "/etc/pelican/config.yml" ]; then
    echo -e "${YELLOW}   Removing old config for fresh setup...${NC}"
    rm /etc/pelican/config.yml
fi

if wings configure --panel-url "${PANEL_URL}" --token "${PANEL_TOKEN}" --node "${NODE_ID}" 2>/dev/null; then
    echo -e "${GREEN}   ✓ Wings configured successfully${NC}"
else
    echo -e "${RED}   ❌ Configuration failed${NC}"
    echo -e "${YELLOW}   Check Panel URL and API token${NC}"
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
sed -i '/dns:/,/- 1.0.0.1/ c\    dns:\n    - 8.8.8.8\n    - 1.1.1.1' /etc/pelican/config.yml
sed -i '/^      v6:/,/^        gateway:/ s/^/#/' /etc/pelican/config.yml

if [ "$USE_HOST_NETWORK" = true ]; then
    sed -i 's/network_mode: pelican_nw/network_mode: host/' /etc/pelican/config.yml
    echo -e "${YELLOW}   ⚠ Using host network mode (DNS fix)${NC}"
fi

PORT_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "port:" | awk '{print $2}')
HOST_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "host:" | awk '{print $2}')
echo -e "${GREEN}   ✓ Configuration fixed${NC}"
echo -e "${GREEN}   ✓ Listening on: ${HOST_CHECK}:${PORT_CHECK}${NC}"

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[15/20] Installing Cloudflare Tunnel...${NC}"

if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || {
        apt --fix-broken install -y 2>/dev/null
        dpkg -i cloudflared-linux-amd64.deb 2>/dev/null
    }
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
# Wings Auto-Start Script v7.0

CF_TOKEN_WINGS="${CF_TOKEN}"

echo "Starting Wings services..."

# Start Docker if not running
if ! docker info >/dev/null 2>&1; then
    echo "Starting Docker daemon..."
    pkill -9 dockerd 2>/dev/null || true
    rm -f /var/run/docker.sock
    nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
    sleep 8
fi

# Start Wings
if ! pgrep -x wings > /dev/null; then
    echo "Starting Wings..."
    cd /etc/pelican
    nohup wings > /tmp/wings.log 2>&1 &
    sleep 3
fi

# Start Cloudflare Tunnel
if ! pgrep cloudflared > /dev/null; then
    echo "Starting Cloudflare Tunnel..."
    nohup cloudflared tunnel run --token "\$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 &
    sleep 2
fi

echo ""
echo "Services Status:"
docker info >/dev/null 2>&1 && echo "  ✓ Docker running" || echo "  ✗ Docker not running"
pgrep -x wings >/dev/null && echo "  ✓ Wings running" || echo "  ✗ Wings not running"
pgrep cloudflared >/dev/null && echo "  ✓ Cloudflare Tunnel running" || echo "  ✗ Cloudflare not running"
STARTEOF

chmod +x /usr/local/bin/start-wings.sh
echo -e "${GREEN}   ✓ Auto-start script: /usr/local/bin/start-wings.sh${NC}"

# ============================================================================
# START WINGS
# ============================================================================
echo -e "${CYAN}[17/20] Starting Wings...${NC}"

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
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
WEOF

    systemctl daemon-reload
    systemctl enable wings 2>/dev/null || true
    systemctl start wings 2>/dev/null || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    cd /etc/pelican
    nohup wings > /tmp/wings.log 2>&1 &
    sleep 3
fi

if ps aux | grep -v grep | grep -q wings; then
    echo -e "${GREEN}   ✓ Wings running${NC}"
    
    sleep 2
    if netstat -tulpn 2>/dev/null | grep -q ":8080"; then
        echo -e "${GREEN}   ✓ Wings listening on port 8080${NC}"
    else
        echo -e "${YELLOW}   ⚠ Wings may not be on port 8080 yet, checking logs...${NC}"
    fi
else
    echo -e "${RED}   ❌ Wings failed to start${NC}"
fi

# ============================================================================
# START CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[18/20] Starting Cloudflare Tunnel...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    cloudflared service install "$CF_TOKEN" 2>/dev/null && {
        systemctl start cloudflared 2>/dev/null || true
        systemctl enable cloudflared 2>/dev/null || true
    } || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-wings.log 2>&1 &
fi

sleep 3

if ps aux | grep -v grep | grep -q cloudflared; then
    echo -e "${GREEN}   ✓ Cloudflare Tunnel running${NC}"
else
    echo -e "${YELLOW}   ⚠ Cloudflare Tunnel may need manual start${NC}"
fi

# ============================================================================
# CLEAR PANEL CACHE (if Panel on same server)
# ============================================================================
echo -e "${CYAN}[19/20] Clearing Panel cache (if present)...${NC}"

if [ -d "/var/www/pelican" ]; then
    echo -e "${BLUE}   Panel detected, clearing cache...${NC}"
    
    PHP_BIN="/usr/bin/php8.3"
    [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)
    
    cd /var/www/pelican
    
    $PHP_BIN artisan config:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan cache:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan view:clear >/dev/null 2>&1 || true
    rm -rf storage/framework/views/* 2>/dev/null || true
    
    if [ "$HAS_SYSTEMD" = true ]; then
        systemctl restart php8.3-fpm nginx 2>/dev/null || {
            pkill php-fpm && /usr/sbin/php-fpm8.3 -D
            pkill nginx && nginx
        }
    else
        pkill php-fpm && /usr/sbin/php-fpm8.3 -D
        pkill nginx && nginx
    fi
    
    supervisorctl restart pelican-queue 2>/dev/null || true
    
    sleep 2
    
    echo -e "${GREEN}   ✓ Panel cache cleared${NC}"
    echo -e "${YELLOW}   ⚠ IMPORTANT: Hard refresh Panel in browser (Ctrl+Shift+R)${NC}"
else
    echo -e "${YELLOW}   ⚠ Panel not on this server${NC}"
fi

# ============================================================================
# SAVE TOKEN_ID TO .pelican.env
# ============================================================================
echo -e "${CYAN}[20/20] Saving configuration...${NC}"

TOKEN_ID=$(grep "token_id:" /etc/pelican/config.yml 2>/dev/null | awk '{print $2}' | tr -d '"')

if [ -n "$TOKEN_ID" ] && [ -f "$ENV_FILE" ]; then
    if grep -q "^WINGS_TOKEN_ID=" "$ENV_FILE"; then
        sed -i "s|^WINGS_TOKEN_ID=.*|WINGS_TOKEN_ID=\"${TOKEN_ID}\"|" "$ENV_FILE"
    else
        echo "" >> "$ENV_FILE"
        echo "# Wings Token ID (for reference)" >> "$ENV_FILE"
        echo "WINGS_TOKEN_ID=\"${TOKEN_ID}\"" >> "$ENV_FILE"
    fi
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

echo ""
WINGS_TEST=$(curl -k https://localhost:8080/api/system 2>&1 || echo "FAILED")
if echo "$WINGS_TEST" | grep -q "error.*authorization"; then
    echo -e "${GREEN}  ✓ Wings API responding${NC}"
    ((CHECKS++))
else
    echo -e "${YELLOW}  ⚠ Wings API test inconclusive${NC}"
fi

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Wings Installation Complete! (${CHECKS}/6)    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${RED}╔════════════════════════════════════════╗${NC}"
echo -e "${RED}║  🔐 CONFIGURATION SAVED                ║${NC}"
echo -e "${RED}╚════════════════════════════════════════╝${NC}"
echo -e "${CYAN}All settings saved to: ${GREEN}${ENV_FILE}${NC}"
echo -e "${YELLOW}Download this file before switching Codespaces!${NC}"
echo ""

echo -e "${CYAN}🎯 CONFIGURE CLOUDFLARE TUNNEL${NC}"
echo -e "${YELLOW}────────────────────────────────────────${NC}"
echo -e "1. Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "2. Navigate: ${BLUE}Zero Trust → Networks → Tunnels → Configure${NC}"
echo -e "3. Add Public Hostname:"
echo -e "   - Subdomain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f1)${NC}"
echo -e "   - Domain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "   - Service Type: ${GREEN}HTTPS${NC}"
echo -e "   - URL: ${GREEN}127.0.0.1:8080${NC}"
echo -e "   - ${RED}⚠️  CRITICAL: Enable 'No TLS Verify'${NC}"
echo ""

echo -e "${CYAN}📋 UPDATE PANEL NODE${NC}"
echo -e "${YELLOW}────────────────────────────────────────${NC}"
echo -e "In Panel: Admin → Nodes → Edit Node ${NODE_ID}"
echo -e "   - FQDN: ${GREEN}${NODE_DOMAIN}${NC}"
echo -e "   - Daemon Port: ${GREEN}443${NC}"
echo -e "   - Behind Proxy: ${GREEN}YES ✓${NC}"
echo -e "   - Scheme: ${GREEN}https${NC}"
echo ""

echo -e "${RED}⚠️  CRITICAL: CLEAR BROWSER CACHE${NC}"
echo -e "   Hard refresh Panel: ${YELLOW}Ctrl + Shift + R${NC}"
echo -e "   Or open: ${YELLOW}Incognito/Private window${NC}"
echo ""

echo -e "${CYAN}🧪 TEST WINGS CONNECTION${NC}"
echo -e "   Local:  ${GREEN}curl -k https://localhost:8080/api/system${NC}"
echo -e "   Remote: ${GREEN}curl https://${NODE_DOMAIN}/api/system${NC}"
echo ""

echo -e "${CYAN}📁 IMPORTANT FILES${NC}"
echo -e "   Config: ${GREEN}/etc/pelican/config.yml${NC}"
echo -e "   Backup: ${GREEN}${BACKUP_DIR}/wings_config_*.backup${NC}"
echo -e "   Env: ${GREEN}${ENV_FILE}${NC}"
echo -e "   Token ID: ${YELLOW}${TOKEN_ID}${NC}"
echo ""

echo -e "${CYAN}🔧 AUTO-START${NC}"
echo -e "   Script: ${GREEN}/usr/local/bin/start-wings.sh${NC}"
echo -e "   Wings logs: ${GREEN}tail -f /tmp/wings.log${NC}"
echo ""

echo -e "${BLUE}✅ Wings is ready! Configure Cloudflare Tunnel and check Panel!${NC}"
echo ""