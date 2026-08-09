#!/bin/bash
################################################################################
# PELICAN AUTO-RESTART SCRIPT v10.0
# Fixes from all sessions:
#   - auto_detect_dns: tests all candidates, skips blocked ones (e.g. 8.8.4.4)
#   - dnsmasq: after-wings ordering drop-in, all-servers racing, only working DNS
#   - cloudflared: http2 protocol forced, simple type, 120s timeout, token-file
#   - Wings DNS: always 172.18.0.1 (dnsmasq), never public DNS
#   - Phase 0: never blindly kills dockerd — checks stale PID only
#   - dnsmasq restart deferred until after Wings starts (pelican0 must exist)
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
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true
[[ -n "${CF_TOKEN_WINGS:-}" ]] && CF_TOKEN="$CF_TOKEN_WINGS"

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Pelican Auto-Restart v10.0          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# PHASE 0 — SAFE CLEANUP (never kill running Docker blindly)
# ============================================================================
echo -e "${CYAN}[Phase 0] Safe cleanup...${NC}"

# Only kill dockerd if PID file is stale
if [[ -f /var/run/docker.pid ]]; then
    DOCKER_PID=$(cat /var/run/docker.pid 2>/dev/null || true)
    if [[ -n "$DOCKER_PID" ]] && ! kill -0 "$DOCKER_PID" 2>/dev/null; then
        echo -e "${YELLOW}   Stale Docker PID — removing${NC}"
        rm -f /var/run/docker.pid /var/run/docker.sock
    fi
fi

pkill -x wings 2>/dev/null || true
pkill cloudflared 2>/dev/null || true
sleep 2
echo -e "${GREEN}   ✓ Cleanup done${NC}"

# ============================================================================
# PHASE 1 — AUTO-DETECT WORKING DNS
# ============================================================================
echo -e "${CYAN}[Phase 1] Auto-detecting working DNS servers...${NC}"
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
        echo -e "${RED}   ✗ All DNS blocked — fallback 1.1.1.1 + 8.8.8.8${NC}"
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
# PHASE 2 — FIX SYSTEM DNS
# ============================================================================
echo -e "${CYAN}[Phase 2] Fixing system DNS...${NC}"
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
    echo -e "${GREEN}   ✓ systemd-resolved updated (${DNS_PRIMARY} + ${DNS_SECONDARY})${NC}"
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

# ============================================================================
# PHASE 3 — FIX DOCKER
# ============================================================================
echo -e "${CYAN}[Phase 3] Fixing Docker...${NC}"

DNS_JSON=$(printf '"%s",' "${DNS_ALL[@]}" | sed 's/,$//')
mkdir -p /etc/docker
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

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/restart.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
StartLimitInterval=0
EOF

if docker info >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker already running${NC}"
    # Reload config without full restart (live-restore handles this)
    systemctl daemon-reload
    systemctl reload-or-restart docker 2>/dev/null || true
    sleep 3
else
    systemctl daemon-reload
    systemctl reset-failed docker 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null && sleep 5 || {
        pkill -9 dockerd 2>/dev/null || true
        rm -f /var/run/docker.sock /var/run/docker.pid; sleep 2
        nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
        echo -n "   Waiting for Docker"
        for i in {1..20}; do sleep 1; echo -n "."; docker info >/dev/null 2>&1 && { echo ""; break; }; done
        echo ""
    }
fi

docker info >/dev/null 2>&1 && echo -e "${GREEN}   ✓ Docker running${NC}" || { echo -e "${RED}   ❌ Docker failed${NC}"; exit 1; }

# Fix Docker bridge linkdown (common in QEMU VMs)
ip link set docker0 up 2>/dev/null || true
ip link set pelican0 up 2>/dev/null || true

# ============================================================================
# PHASE 4 — FIX WINGS CONFIG
# ============================================================================
echo -e "${CYAN}[Phase 4] Fixing Wings configuration...${NC}"
if [[ ! -f /etc/pelican/config.yml ]]; then
    echo -e "${RED}   ❌ No Wings config found — run wings.sh first${NC}"; exit 1
fi

cp /etc/pelican/config.yml /etc/pelican/config.yml.restart-backup
sed -i 's/port: 443/port: 8080/' /etc/pelican/config.yml
sed -i 's/port: 8443/port: 8080/' /etc/pelican/config.yml
sed -i 's/host: 127.0.0.1/host: 0.0.0.0/' /etc/pelican/config.yml
sed -i 's/IPv6: true/IPv6: false/' /etc/pelican/config.yml
sed -i '/ssl:/,/key:/ s/enabled: true/enabled: false/' /etc/pelican/config.yml
sed -i 's/network_mtu: 1500/network_mtu: 1280/' /etc/pelican/config.yml
# Always point Wings DNS at dnsmasq — never public DNS directly
python3 -c "
import re
content = open('/etc/pelican/config.yml').read()
content = re.sub(r'(    dns:)(\n    - [^\n]+)+', '    dns:\n    - 172.18.0.1', content)
open('/etc/pelican/config.yml', 'w').write(content)
" 2>/dev/null || sed -i '/dns:/,/name:/ { /- /d }; s/dns:/dns:\n    - 172.18.0.1/' /etc/pelican/config.yml
sed -i 's/network_mode: host/network_mode: pelican_nw/' /etc/pelican/config.yml
echo -e "${GREEN}   ✓ Wings config fixed — DNS → 172.18.0.1 (dnsmasq)${NC}"

# ============================================================================
# PHASE 5 — CONFIGURE DNSMASQ (start deferred until after Wings)
# ============================================================================
echo -e "${CYAN}[Phase 5] Configuring dnsmasq...${NC}"
_build_dnsmasq_servers() { for dns in "${DNS_ALL[@]}"; do echo "server=${dns}"; done; }
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

# Ordering fix: dnsmasq must start AFTER wings so pelican0 exists
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/after-wings.conf <<'EOF'
[Unit]
After=wings.service
Wants=wings.service
EOF
systemctl daemon-reload
systemctl enable dnsmasq 2>/dev/null || true
echo -e "${GREEN}   ✓ dnsmasq configured (will start after Wings)${NC}"

# ============================================================================
# PHASE 6 — START WINGS
# ============================================================================
echo -e "${CYAN}[Phase 6] Starting Wings...${NC}"
[[ ! -f /etc/systemd/system/wings.service ]] && cat > /etc/systemd/system/wings.service <<'WEOF'
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
systemctl reset-failed wings 2>/dev/null || true
systemctl start wings 2>/dev/null || { cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 &; }
sleep 5
systemctl is-active --quiet wings && echo -e "${GREEN}   ✓ Wings running${NC}" || { echo -e "${RED}   ❌ Wings failed — check: journalctl -u wings -n 30${NC}"; exit 1; }
netstat -tulpn 2>/dev/null | grep -q ":8080" && echo -e "${GREEN}   ✓ Wings on :8080${NC}" || echo -e "${YELLOW}   ⚠ Wings not on :8080 yet${NC}"

# Now start dnsmasq — pelican0 should exist
sleep 3
systemctl restart dnsmasq 2>/dev/null || true
systemctl is-active --quiet dnsmasq && \
    echo -e "${GREEN}   ✓ dnsmasq running on 172.18.0.1${NC}" || \
    echo -e "${YELLOW}   ⚠ dnsmasq failed — check: journalctl -u dnsmasq -n 10${NC}"

# Verify DNS chain: system → dnsmasq → containers
DNS_HOST_OK=false; DNS_DNSMASQ_OK=false; DNS_CONTAINER_OK=false
nslookup google.com >/dev/null 2>&1 && DNS_HOST_OK=true
dig +short google.com @172.18.0.1 >/dev/null 2>&1 && DNS_DNSMASQ_OK=true
docker run --rm --dns 172.18.0.1 alpine nslookup google.com >/dev/null 2>&1 && DNS_CONTAINER_OK=true
echo -e "${GREEN}   DNS chain: host=${DNS_HOST_OK} | dnsmasq=${DNS_DNSMASQ_OK} | container=${DNS_CONTAINER_OK}${NC}"

# ============================================================================
# PHASE 7 — CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[Phase 7] Starting Cloudflare Tunnel...${NC}"

# Ensure token file exists
if [[ ! -f /etc/cloudflared/token ]]; then
    if [[ -n "${CF_TOKEN:-}" ]]; then
        mkdir -p /etc/cloudflared
        echo -n "$CF_TOKEN" > /etc/cloudflared/token
        chmod 600 /etc/cloudflared/token
        echo -e "${GREEN}   ✓ Token file written from env${NC}"
    else
        echo -e "${RED}   ❌ No CF_TOKEN in env and no token file — skipping cloudflared${NC}"
    fi
fi

if [[ -f /etc/cloudflared/token ]]; then
    # Rewrite service unit with correct settings
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
    systemctl daemon-reload
    systemctl enable cloudflared 2>/dev/null || true
    systemctl restart cloudflared 2>/dev/null || true
    sleep 8
    systemctl is-active --quiet cloudflared && \
        echo -e "${GREEN}   ✓ Cloudflared running${NC}" || \
        echo -e "${YELLOW}   ⚠ Cloudflared connecting — check: journalctl -u cloudflared -n 20${NC}"
fi

# ============================================================================
# PHASE 8 — IPTABLES + VERIFY
# ============================================================================
echo -e "${CYAN}[Phase 8] Final checks...${NC}"
iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo ""
CHECKS=0
docker info >/dev/null 2>&1 && { echo -e "${GREEN}  ✓ Docker${NC}"; ((CHECKS++)); }
systemctl is-active --quiet wings && { echo -e "${GREEN}  ✓ Wings${NC}"; ((CHECKS++)); }
systemctl is-active --quiet dnsmasq && { echo -e "${GREEN}  ✓ dnsmasq (${DNS_PRIMARY})${NC}"; ((CHECKS++)); }
systemctl is-active --quiet cloudflared 2>/dev/null && { echo -e "${GREEN}  ✓ Cloudflared${NC}"; ((CHECKS++)); } || echo -e "${YELLOW}  ⚠ Cloudflared connecting${NC}"
netstat -tulpn 2>/dev/null | grep -q 8080 && { echo -e "${GREEN}  ✓ Wings :8080${NC}"; ((CHECKS++)); }
curl -s http://localhost:8080/api/system 2>&1 | grep -q "error.*authorization" && { echo -e "${GREEN}  ✓ Wings API${NC}"; ((CHECKS++)); } || echo -e "${YELLOW}  ⚠ Wings API pending${NC}"
dig +short google.com @172.18.0.1 >/dev/null 2>&1 && { echo -e "${GREEN}  ✓ dnsmasq resolving${NC}"; ((CHECKS++)); }

echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Restart Complete! (${CHECKS}/7)              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}🧪 TEST:  ${GREEN}curl http://localhost:8080/api/system${NC}"
echo -e "${CYAN}📋 WINGS: ${GREEN}journalctl -u wings -f${NC}"
echo -e "${CYAN}📋 CF:    ${GREEN}journalctl -u cloudflared -n 20${NC}"
echo -e "${CYAN}📋 DNS:   ${GREEN}dig google.com @172.18.0.1${NC}"
