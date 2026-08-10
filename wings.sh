#!/bin/bash
################################################################################
# PELICAN WINGS - COMPLETE INSTALLER v9.0
# Fixes from all sessions:
#   - auto_detect_dns: tests all candidates, removes blocked ones (e.g 8.8.4.4)
#   - dnsmasq: after-wings ordering fix, all-servers racing, only working DNS
#   - cloudflared: http2 protocol forced, simple type, 120s timeout, token-file
#   - Wings DNS: always points at 172.18.0.1 (dnsmasq), never public DNS
#   - Docker: never blindly killed if already running
#   - systemd: dnsmasq starts After=wings.service so pelican0 exists first
################################################################################

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

[[ $EUID -ne 0 ]] && { echo -e "${YELLOW}Switching to root...${NC}"; sudo "$0" "$@"; exit $?; }

ENV_FILE=""
for loc in "/root/.pelican.env" "$HOME/.pelican.env" "$(pwd)/.pelican.env"; do
    [[ -f "$loc" ]] && ENV_FILE="$loc" && break
done
[[ -z "$ENV_FILE" ]] && ENV_FILE="/root/.pelican.env"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Pelican Wings Installer v9.0        ║${NC}"
echo -e "${GREEN}║   Production Ready - VM Safe          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# BACKUP EXISTING CONFIG
# ============================================================================
if [[ -f /etc/pelican/config.yml ]]; then
    mkdir -p /root/.backups
    TS=$(date +%Y%m%d_%H%M%S)
    cp /etc/pelican/config.yml "/root/.backups/wings_config_${TS}.backup"
    chmod 600 "/root/.backups/wings_config_${TS}.backup"
    EXISTING_TOKEN_ID=$(grep "token_id:" /etc/pelican/config.yml 2>/dev/null | awk '{print $2}' | tr -d '"')
    [[ -n "$EXISTING_TOKEN_ID" ]] && echo -e "${GREEN}[BACKUP] ✓ Saved with token_id: ${EXISTING_TOKEN_ID}${NC}"
fi

# ============================================================================
# [1/20] LOAD CONFIGURATION
# ============================================================================
echo -e "${CYAN}[1/20] Loading configuration...${NC}"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" && echo -e "${GREEN}   ✓ Config loaded${NC}" || echo -e "${YELLOW}   ⚠ No saved config${NC}"
[[ -n "${PANEL_DOMAIN:-}" ]] && PANEL_URL="https://${PANEL_DOMAIN}"
[[ -n "${PANEL_API_TOKEN:-}" ]] && PANEL_TOKEN="$PANEL_API_TOKEN"
[[ -n "${CF_TOKEN_WINGS:-}" ]] && CF_TOKEN="$CF_TOKEN_WINGS"

# ============================================================================
# [2/20] DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[2/20] Detecting environment...${NC}"
IS_CONTAINER=false; HAS_SYSTEMD=false
[[ -d /run/systemd/system ]] && pidof systemd >/dev/null 2>&1 && HAS_SYSTEMD=true && echo -e "${GREEN}   ✓ Systemd available${NC}"
{ [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null || grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; } \
    && IS_CONTAINER=true && echo -e "${YELLOW}   ⚠ Container environment${NC}" \
    || echo -e "${GREEN}   ✓ VM/Bare-metal environment${NC}"

# ============================================================================
# [3/20] AUTO-DETECT WORKING DNS
# Tests every candidate from THIS VM — removes blocked ones like 8.8.4.4
# ============================================================================
echo -e "${CYAN}[3/20] Auto-detecting working DNS servers...${NC}"
auto_detect_dns() {
    local CANDIDATES=("1.1.1.1" "1.0.0.1" "8.8.8.8" "9.9.9.9" "8.8.4.4" "149.112.112.112")
    local TEST_HOST="google.com"
    local WORKING=()
    for dns in "${CANDIDATES[@]}"; do
        MS=$(dig +tries=1 +timeout=3 "$TEST_HOST" "@${dns}" 2>&1 | grep "Query time" | awk '{print $4}')
        if [[ -n "$MS" ]]; then
            WORKING+=("$MS $dns")
            echo -e "${GREEN}   ✓ ${dns} — ${MS}ms${NC}"
        else
            echo -e "${YELLOW}   ✗ ${dns} — blocked/timeout${NC}"
        fi
    done
    if [[ ${#WORKING[@]} -eq 0 ]]; then
        echo -e "${RED}   ✗ All DNS blocked — using fallback 1.1.1.1 + 8.8.8.8${NC}"
        DNS_PRIMARY="1.1.1.1"; DNS_SECONDARY="8.8.8.8"; DNS_ALL=("1.1.1.1" "8.8.8.8"); return
    fi
    mapfile -t SORTED < <(printf '%s\n' "${WORKING[@]}" | sort -n)
    DNS_PRIMARY=$(echo "${SORTED[0]}" | awk '{print $2}')
    DNS_SECONDARY=$(echo "${SORTED[1]:-${SORTED[0]}}" | awk '{print $2}')
    DNS_ALL=()
    for entry in "${SORTED[@]}"; do DNS_ALL+=("$(echo "$entry" | awk '{print $2}')"); done
    echo -e "${GREEN}   ✓ Primary: ${DNS_PRIMARY} | Secondary: ${DNS_SECONDARY}${NC}"
}
auto_detect_dns

# ============================================================================
# [4/20] USER INPUT
# ============================================================================
echo -e "${CYAN}[4/20] Wings configuration...${NC}"
if [[ -z "${NODE_DOMAIN:-}" ]]; then
    read -p "Node domain (e.g., node-1.example.com): " NODE_DOMAIN
else
    read -p "Node domain [$NODE_DOMAIN]: " _in; NODE_DOMAIN="${_in:-$NODE_DOMAIN}"
fi
if [[ -z "${PANEL_URL:-}" ]]; then
    read -p "Panel URL (e.g., https://panel.example.com): " PANEL_URL
else
    read -p "Panel URL [$PANEL_URL]: " _in; PANEL_URL="${_in:-$PANEL_URL}"
fi
if [[ -z "${PANEL_TOKEN:-}" ]]; then
    read -p "Panel API Token (starts with papp_): " PANEL_TOKEN
else
    read -p "Panel API Token [${PANEL_TOKEN:0:20}...]: " _in; PANEL_TOKEN="${_in:-$PANEL_TOKEN}"
fi
if [[ -z "${NODE_ID:-}" ]]; then
    read -p "Node ID [1]: " NODE_ID; NODE_ID=${NODE_ID:-1}
else
    read -p "Node ID [$NODE_ID]: " _in; NODE_ID="${_in:-$NODE_ID}"
fi
[[ -z "${CF_TOKEN:-}" ]] && read -p "Cloudflare Tunnel Token: " CF_TOKEN
echo -e "${GREEN}   ✓ Configuration collected${NC}"

# Save to .pelican.env
if [[ -f "$ENV_FILE" ]]; then
    _env_set() { grep -q "^$1=" "$ENV_FILE" && sed -i "s|^$1=.*|$1=\"$2\"|" "$ENV_FILE" || echo "$1=\"$2\"" >> "$ENV_FILE"; }
    _env_set NODE_DOMAIN "$NODE_DOMAIN"
    _env_set NODE_ID "$NODE_ID"
    _env_set CF_TOKEN_WINGS "$CF_TOKEN"
    _env_set PANEL_API_TOKEN "$PANEL_TOKEN"
fi

# ============================================================================
# [5/20] SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[5/20] Updating system...${NC}"
apt-get update -qq 2>&1 | grep -v "^Get:" || true
apt-get install -y curl wget sudo ca-certificates gnupg openssl iptables git \
    net-tools dnsutils dnsmasq bc 2>/dev/null || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# [6/20] REMOVE OLD DOCKER
# ============================================================================
echo -e "${CYAN}[6/20] Cleaning old Docker...${NC}"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done
apt-get autoremove -y 2>/dev/null || true
echo -e "${GREEN}   ✓ Cleanup complete${NC}"

# ============================================================================
# [7/20] INSTALL DOCKER
# ============================================================================
echo -e "${CYAN}[7/20] Installing Docker...${NC}"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >/dev/null 2>&1
    rm get-docker.sh
fi
echo -e "${GREEN}   ✓ Docker: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')${NC}"

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
StartLimitInterval=0
EOF
systemctl daemon-reload

# ============================================================================
# [8/20] CONFIGURE DNS + DOCKER DAEMON
# ============================================================================
echo -e "${CYAN}[8/20] Configuring DNS and Docker daemon...${NC}"

# Build dns array string for daemon.json from detected working DNS
DNS_JSON=$(printf '"%s",' "${DNS_ALL[@]}" | sed 's/,$//')

mkdir -p /etc/docker
if [[ "$IS_CONTAINER" == true ]]; then
    cat > /etc/docker/daemon.json <<DEOF
{
  "dns": [${DNS_JSON}],
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
  "default-ulimits": {"nofile": {"Name": "nofile", "Hard": 65535, "Soft": 65535}}
}
DEOF
else
    cat > /etc/docker/daemon.json <<DEOF
{
  "dns": [${DNS_JSON}],
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
DEOF
fi

tailscale set --accept-dns=false 2>/dev/null || true

if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/no-stub.conf <<EOF
[Resolve]
DNS=${DNS_PRIMARY} ${DNS_SECONDARY}
DNSStubListener=no
Domains=~.
EOF
    systemctl restart systemd-resolved
    echo -e "${GREEN}   ✓ DNS via systemd-resolved (${DNS_PRIMARY} + ${DNS_SECONDARY})${NC}"
else
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
EOF
    chattr +i /etc/resolv.conf 2>/dev/null && \
        echo -e "${GREEN}   ✓ DNS locked (${DNS_PRIMARY} + ${DNS_SECONDARY})${NC}" || \
        echo -e "${GREEN}   ✓ DNS set (${DNS_PRIMARY} + ${DNS_SECONDARY})${NC}"
fi

nslookup google.com >/dev/null 2>&1 && \
    echo -e "${GREEN}   ✓ DNS resolution verified${NC}" || \
    echo -e "${YELLOW}   ⚠ DNS verify failed — containers may still work${NC}"

# dnsmasq: NOTE — listen-address 172.18.0.1 (pelican0) may not exist yet at this point.
# The service is configured now but start is deferred until after Wings creates pelican0.
# The systemd drop-in After=wings.service handles this ordering.
_build_dnsmasq_servers() {
    for dns in "${DNS_ALL[@]}"; do echo "server=${dns}"; done
}
cat > /etc/dnsmasq.conf <<EOF
listen-address=172.18.0.1
bind-interfaces
no-resolv
$(_build_dnsmasq_servers)
cache-size=1000
domain-needed
bogus-priv
all-servers
EOF

# dnsmasq ordering fix: must start AFTER wings so pelican0 exists
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/after-wings.conf <<'EOF'
[Unit]
After=wings.service
Wants=wings.service
EOF
systemctl daemon-reload
systemctl enable dnsmasq 2>/dev/null || true
echo -e "${GREEN}   ✓ dnsmasq configured (will start after Wings creates pelican0)${NC}"

# TCP MSS clamping
iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# TCP BBR
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

# Persist iptables
[[ "$HAS_SYSTEMD" == true ]] && {
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

# Smart watchdog
cat > /usr/local/bin/pelican-watchdog.sh <<'WATCHDOG'
#!/bin/bash
LOG=/var/log/pelican-watchdog.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }
while true; do
    WINGS_OK=false
    echo "$(curl -s http://localhost:8080/api/system 2>/dev/null)" | grep -q "authorization" && WINGS_OK=true
    if [[ "$WINGS_OK" == true ]]; then
        iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        # Ensure dnsmasq is up (may have failed on boot before pelican0 existed)
        systemctl is-active --quiet dnsmasq || systemctl restart dnsmasq 2>/dev/null || true
        sleep 30; continue
    fi
    log "Wings not responding — diagnosing..."
    if ! docker info >/dev/null 2>&1; then
        log "Docker down — restarting"
        systemctl reset-failed docker 2>/dev/null || true
        rm -f /var/run/docker.pid /var/run/docker.sock
        systemctl start docker; sleep 10
        docker info >/dev/null 2>&1 || { log "Docker failed — skipping"; sleep 30; continue; }
        log "Docker recovered"
    fi
    if ! systemctl is-active --quiet wings; then
        log "Wings down — restarting"
        sed -i '/ssl:/,/key:/ s/enabled: true/enabled: false/' /etc/pelican/config.yml 2>/dev/null || true
        sed -i 's/port: 8443/port: 8080/' /etc/pelican/config.yml 2>/dev/null || true
        systemctl reset-failed wings 2>/dev/null || true
        systemctl start wings; sleep 10
        systemctl is-active --quiet wings && log "Wings recovered" || log "Wings failed"
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
[[ "$HAS_SYSTEMD" == true ]] && { systemctl daemon-reload; systemctl enable pelican-watchdog; systemctl start pelican-watchdog; }
echo -e "${GREEN}   ✓ Smart watchdog installed${NC}"

# ============================================================================
# [9/20] START DOCKER
# ============================================================================
echo -e "${CYAN}[9/20] Starting Docker daemon...${NC}"
if docker info >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker already running — skipping restart${NC}"
else
    rm -f /var/run/docker.pid /var/run/docker.sock
    systemctl reset-failed docker 2>/dev/null || true
    if [[ "$HAS_SYSTEMD" == true ]]; then
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null && sleep 3 || true
    fi
    if ! docker info >/dev/null 2>&1; then
        pkill -9 dockerd 2>/dev/null || true
        rm -f /var/run/docker.sock /var/run/docker.pid; sleep 2
        nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
        echo -n "   Waiting for Docker"
        for i in {1..20}; do sleep 1; echo -n "."; docker info >/dev/null 2>&1 && { echo ""; break; }; done
        echo ""
    fi
fi
docker info >/dev/null 2>&1 && echo -e "${GREEN}   ✓ Docker running${NC}" || { echo -e "${RED}   ❌ Docker failed${NC}"; exit 1; }

# ============================================================================
# [10/20] TEST DOCKER DNS
# ============================================================================
echo -e "${CYAN}[10/20] Testing Docker DNS...${NC}"
docker pull alpine:latest >/dev/null 2>&1 || true
USE_HOST_NETWORK=false
DNS_TEST=$(docker run --rm alpine nslookup deb.debian.org 2>&1 || echo "FAILED")
if echo "$DNS_TEST" | grep -q "Address:"; then
    echo -e "${GREEN}   ✓ DNS working (bridge mode)${NC}"
else
    HOST_DNS_TEST=$(docker run --rm --network host alpine nslookup deb.debian.org 2>&1 || echo "FAILED")
    if echo "$HOST_DNS_TEST" | grep -q "Address:"; then
        echo -e "${GREEN}   ✓ DNS working (host mode)${NC}"; USE_HOST_NETWORK=true
    else
        echo -e "${RED}   ❌ DNS completely blocked!${NC}"; exit 1
    fi
fi

# ============================================================================
# [11/20] KERNEL CONFIG
# ============================================================================
echo -e "${CYAN}[11/20] Kernel configuration...${NC}"
if [[ "$IS_CONTAINER" == false ]]; then
    cat > /etc/modules-load.d/pelican-wings.conf <<'EOF'
overlay
br_netfilter
EOF
    modprobe overlay 2>/dev/null || true; modprobe br_netfilter 2>/dev/null || true
    cat > /etc/sysctl.d/99-pelican-wings.conf <<'EOF'
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
# [12/20] CREATE DIRECTORIES
# ============================================================================
echo -e "${CYAN}[12/20] Creating directories...${NC}"
mkdir -p /etc/pelican /var/lib/pelican/{volumes,archives,backups} /var/log/pelican /var/run/wings /tmp/pelican
chmod 755 /etc/pelican /var/lib/pelican /var/log/pelican
echo -e "${GREEN}   ✓ Directories created${NC}"

# ============================================================================
# [13/20] DOWNLOAD WINGS
# ============================================================================
echo -e "${CYAN}[13/20] Downloading Wings...${NC}"
curl -L -o /usr/local/bin/wings "https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64" 2>/dev/null
chmod +x /usr/local/bin/wings
[[ ! -x /usr/local/bin/wings ]] && { echo -e "${RED}   ❌ Wings download failed${NC}"; exit 1; }
WINGS_VERSION=$(wings --version 2>/dev/null | grep -oP 'wings \Kv[\d\.]+' || echo "latest")
echo -e "${GREEN}   ✓ Wings ${WINGS_VERSION} installed${NC}"
mkdir -p /var/lib/pelican/volumes
chown -R pelican:pelican /var/lib/pelican 2>/dev/null || true
chmod 755 /var/lib/pelican

# ============================================================================
# [14/20] SSL CERTIFICATES
# ============================================================================
echo -e "${CYAN}[14/20] Creating SSL certificates...${NC}"
mkdir -p /etc/letsencrypt/live/${NODE_DOMAIN}
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem \
    -out /etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem \
    -subj "/CN=${NODE_DOMAIN}" 2>/dev/null
echo -e "${GREEN}   ✓ Self-signed certificate created${NC}"

# ============================================================================
# [15/20] CONFIGURE WINGS VIA PANEL API
# ============================================================================
echo -e "${CYAN}[15/20] Configuring Wings via Panel API...${NC}"
[[ -f /etc/pelican/config.yml ]] && rm /etc/pelican/config.yml
if wings configure --panel-url "${PANEL_URL}" --token "${PANEL_TOKEN}" --node "${NODE_ID}" 2>/dev/null; then
    echo -e "${GREEN}   ✓ Wings configured successfully${NC}"
else
    echo -e "${RED}   ❌ Configuration failed — check Panel URL and API token${NC}"; exit 1
fi

# ============================================================================
# [16/20] APPLY CRITICAL CONFIG FIXES
# ============================================================================
echo -e "${CYAN}[16/20] Applying critical fixes...${NC}"
cp /etc/pelican/config.yml /etc/pelican/config.yml.backup
sed -i 's/port: 443/port: 8080/' /etc/pelican/config.yml
sed -i 's/port: 8443/port: 8080/' /etc/pelican/config.yml
sed -i 's/host: 127.0.0.1/host: 0.0.0.0/' /etc/pelican/config.yml
sed -i 's/IPv6: true/IPv6: false/' /etc/pelican/config.yml
sed -i '/ssl:/,/key:/ s/enabled: true/enabled: false/' /etc/pelican/config.yml
sed -i 's/network_mtu: 1500/network_mtu: 1280/' /etc/pelican/config.yml
sed -i '/^      v6:/,/^        gateway:/ s/^/#/' /etc/pelican/config.yml
[[ "$USE_HOST_NETWORK" == true ]] && sed -i 's/network_mode: pelican_nw/network_mode: host/' /etc/pelican/config.yml
# Always point Wings DNS at dnsmasq — never public DNS directly
python3 -c "
import re
content = open('/etc/pelican/config.yml').read()
content = re.sub(r'(    dns:)(\n    - [^\n]+)+', '    dns:\n    - 172.18.0.1', content)
open('/etc/pelican/config.yml', 'w').write(content)
" 2>/dev/null || sed -i '/dns:/,/- 1.0.0.1/ c\    dns:\n    - 172.18.0.1' /etc/pelican/config.yml
PORT_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "port:" | awk '{print $2}')
HOST_CHECK=$(grep -A5 "^api:" /etc/pelican/config.yml | grep "host:" | awk '{print $2}')
echo -e "${GREEN}   ✓ Config fixed — listening on ${HOST_CHECK}:${PORT_CHECK}, DNS → dnsmasq${NC}"

# ============================================================================
# [17/20] INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[17/20] Installing Cloudflare Tunnel...${NC}"
if ! command -v cloudflared &>/dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || { apt --fix-broken install -y 2>/dev/null; dpkg -i cloudflared-linux-amd64.deb 2>/dev/null; }
    rm -f cloudflared-linux-amd64.deb
fi
# Write token file (avoids token appearing in process list)
mkdir -p /etc/cloudflared
echo -n "$CF_TOKEN" > /etc/cloudflared/token
chmod 600 /etc/cloudflared/token
pkill cloudflared 2>/dev/null || true
echo -e "${GREEN}   ✓ Cloudflare Tunnel installed, token saved${NC}"

# ============================================================================
# [18/20] START WINGS
# ============================================================================
echo -e "${CYAN}[18/20] Starting Wings...${NC}"
pkill -x wings 2>/dev/null || true; sleep 1

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

if [[ "$HAS_SYSTEMD" == true ]]; then
    systemctl daemon-reload
    systemctl enable wings 2>/dev/null || true
    systemctl start wings 2>/dev/null || { cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 & }
else
    cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 &
fi
sleep 5
ps aux | grep -v grep | grep -q wings && echo -e "${GREEN}   ✓ Wings running${NC}" || echo -e "${RED}   ❌ Wings failed — check: tail -20 /tmp/wings.log${NC}"
netstat -tulpn 2>/dev/null | grep -q ":8080" && echo -e "${GREEN}   ✓ Wings on port 8080${NC}" || echo -e "${YELLOW}   ⚠ Wings not on port 8080 yet${NC}"

# Now start dnsmasq — pelican0 should exist by now
sleep 3
systemctl restart dnsmasq 2>/dev/null || true
systemctl is-active --quiet dnsmasq && \
    echo -e "${GREEN}   ✓ dnsmasq running (DNS on 172.18.0.1)${NC}" || \
    echo -e "${YELLOW}   ⚠ dnsmasq not up — watchdog will retry${NC}"

# ============================================================================
# [19/20] START CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[19/20] Starting Cloudflare Tunnel...${NC}"
# Use simple type + http2 protocol + 120s timeout (QUIC/UDP is often blocked in IDX/GCP)
cat > /etc/systemd/system/cloudflared.service <<'CFEOF'
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target
[Service]
TimeoutStartSec=120
Type=simple
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --protocol http2 run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
CFEOF

if [[ "$HAS_SYSTEMD" == true ]]; then
    systemctl daemon-reload
    systemctl enable cloudflared 2>/dev/null || true
    systemctl restart cloudflared 2>/dev/null || true
else
    nohup cloudflared tunnel --protocol http2 run --token-file /etc/cloudflared/token > /var/log/cloudflared-wings.log 2>&1 &
fi
sleep 8
systemctl is-active --quiet cloudflared 2>/dev/null && \
    echo -e "${GREEN}   ✓ Cloudflare Tunnel running${NC}" || \
    echo -e "${YELLOW}   ⚠ Cloudflare still connecting — check: journalctl -u cloudflared -n 20${NC}"

# ============================================================================
# [20/20] SAVE CONFIG + VERIFY
# ============================================================================
echo -e "${CYAN}[20/20] Final save and verification...${NC}"
TOKEN_ID=$(grep "token_id:" /etc/pelican/config.yml 2>/dev/null | awk '{print $2}' | tr -d '"')
[[ -n "$TOKEN_ID" && -f "$ENV_FILE" ]] && {
    grep -q "^WINGS_TOKEN_ID=" "$ENV_FILE" && sed -i "s|^WINGS_TOKEN_ID=.*|WINGS_TOKEN_ID=\"${TOKEN_ID}\"|" "$ENV_FILE" \
        || echo -e "\nWINGS_TOKEN_ID=\"${TOKEN_ID}\"" >> "$ENV_FILE"
    echo -e "${GREEN}   ✓ Token ID saved: ${TOKEN_ID}${NC}"
}

# Clear panel cache if panel is on this server
if [[ -d /var/www/pelican ]]; then
    PANEL_PHP=$(for v in 8.3 8.4 8.2; do [[ -f "/usr/bin/php${v}" ]] && echo "/usr/bin/php${v}" && break; done)
    [[ -z "$PANEL_PHP" ]] && PANEL_PHP=$(which php)
    cd /var/www/pelican
    $PANEL_PHP artisan config:clear >/dev/null 2>&1 || true
    $PANEL_PHP artisan cache:clear >/dev/null 2>&1 || true
    $PANEL_PHP artisan view:clear >/dev/null 2>&1 || true
    rm -rf storage/framework/views/* 2>/dev/null || true
    PANEL_PHP_VER=$(ls /etc/php/ | sort -rV | head -1)
    systemctl restart php${PANEL_PHP_VER}-fpm nginx 2>/dev/null || true
    supervisorctl restart pelican-queue 2>/dev/null || true
    sleep 2; echo -e "${GREEN}   ✓ Panel cache cleared${NC}"
else
    echo -e "${YELLOW}   ⚠ Panel not on this server${NC}"
fi

echo ""
echo -e "${CYAN}Verifying installation...${NC}"
CHECKS=0
docker info >/dev/null 2>&1 && { echo -e "${GREEN}  ✓ Docker running${NC}"; ((CHECKS++)); }
ps aux | grep -v grep | grep -q wings && { echo -e "${GREEN}  ✓ Wings running${NC}"; ((CHECKS++)); }
systemctl is-active --quiet cloudflared 2>/dev/null && { echo -e "${GREEN}  ✓ Cloudflared running${NC}"; ((CHECKS++)); } || echo -e "${YELLOW}  ⚠ Cloudflared connecting...${NC}"
[[ -f /etc/pelican/config.yml ]] && { echo -e "${GREEN}  ✓ Config exists${NC}"; ((CHECKS++)); }
netstat -tulpn 2>/dev/null | grep -q 8080 && { echo -e "${GREEN}  ✓ Wings on :8080${NC}"; ((CHECKS++)); }
curl -s http://localhost:8080/api/system 2>&1 | grep -q "error.*authorization" && { echo -e "${GREEN}  ✓ Wings API responding${NC}"; ((CHECKS++)); } || echo -e "${YELLOW}  ⚠ Wings API test inconclusive${NC}"
systemctl is-active --quiet dnsmasq && { echo -e "${GREEN}  ✓ dnsmasq running (${DNS_PRIMARY})${NC}"; ((CHECKS++)); } || echo -e "${YELLOW}  ⚠ dnsmasq not up${NC}"
dig +short google.com @172.18.0.1 >/dev/null 2>&1 && { echo -e "${GREEN}  ✓ dnsmasq DNS resolving${NC}"; ((CHECKS++)); } || echo -e "${YELLOW}  ⚠ dnsmasq DNS check failed${NC}"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Wings Installation Complete! (${CHECKS}/8)   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}🎯 CONFIGURE CLOUDFLARE TUNNEL${NC}"
echo -e "1. Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "2. Zero Trust → Networks → Tunnels → Configure"
echo -e "3. Add Public Hostname:"
echo -e "   Subdomain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f1)${NC} | Domain: ${GREEN}$(echo $NODE_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "   Service: ${GREEN}HTTP → localhost:8080${NC} | ${RED}⚠️ Enable 'No TLS Verify'${NC}"
echo ""
echo -e "${CYAN}📋 UPDATE PANEL NODE${NC}"
echo -e "Admin → Nodes → Edit Node ${NODE_ID}"
echo -e "   FQDN: ${GREEN}${NODE_DOMAIN}${NC} | Port: ${GREEN}443${NC} | SSL: ${GREEN}HTTPS with (reverse) proxy${NC}"
echo ""
echo -e "${CYAN}🧪 TEST:    ${GREEN}curl http://localhost:8080/api/system${NC}"
echo -e "${CYAN}📋 LOGS:    ${GREEN}journalctl -u wings -f${NC}"
echo -e "${CYAN}🔧 RESTART: ${GREEN}systemctl restart wings dnsmasq cloudflared${NC}"
