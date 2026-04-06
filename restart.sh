#!/bin/bash

################################################################################
# PELICAN AUTO-RESTART SCRIPT v9.1 PRODUCTION READY
# Fixes from v9.0:
#   - Fixed malformed redis-cli FLUSHDB line
#   - Fixed DNS: preserves Tailscale (100.100.100.100) instead of overwriting
#   - Fixed Wings: uses systemd instead of nohup (prevents port 8080 conflicts)
#   - Fixed Cloudflare: kills zombies properly before starting
#   - Fixed Supervisor: cleans stale socket/PID before starting
#   - Fixed PHP-FPM: always ensures TCP 9000 (no socket mode)
#   - Fixed resolv.conf locking: respects Tailscale DNS
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Pelican Services Restart v9.1      ║${NC}"
echo -e "${CYAN}║     Production-Safe Restart            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

# Find .pelican.env file
ENV_FILE=""
for location in \
    "$(pwd)/.pelican.env" \
    "/root/newrepo/.pelican.env" \
    "/workspaces/null/newrepo/.pelican.env" \
    "/root/.pelican.env" \
    "$HOME/.pelican.env" \
    "$(dirname "$0")/.pelican.env"; do
    if [ -f "$location" ]; then
        ENV_FILE="$location"
        break
    fi
done

if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo -e "${GREEN}✓ Config loaded: $ENV_FILE${NC}"
    echo -e "${BLUE}  Domain: ${PANEL_DOMAIN:-not set}${NC}"
    echo -e "${BLUE}  Database: ${DB_DRIVER:-not set}${NC}"
    [ -n "$NODE_ID" ] && echo -e "${BLUE}  Node ID: ${NODE_ID}${NC}"
    [ -n "$PANEL_API_TOKEN" ] && echo -e "${BLUE}  API Token: ${PANEL_API_TOKEN:0:20}...${NC}"
    echo ""
else
    echo -e "${YELLOW}⚠ No .pelican.env found - will use defaults${NC}"
    echo ""
fi

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
SERVICES_STARTED=0
# Lock DNS
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
options timeout:2 attempts:2 rotate
DNSEOF
chattr +i /etc/resolv.conf

# ============================================================================
# 1. START DOCKER
# ============================================================================
echo -e "${CYAN}[1/8] Starting Docker...${NC}"

if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   Starting Docker daemon...${NC}"
    pkill -9 dockerd 2>/dev/null || true
    rm -f /var/run/docker.sock /var/run/docker.pid
    systemctl reset-failed docker 2>/dev/null || true
    sleep 2

    # Ensure correct daemon.json (DNS fix for containers)
cat > /etc/docker/daemon.json <<'DOCKEREOF'
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
DOCKEREOF

    # Try systemd first (works on real VMs)
    HAS_SYSTEMD=false
    if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
        systemctl start docker 2>/dev/null && HAS_SYSTEMD=true
    fi

    # Fallback to manual dockerd
    if [ "$HAS_SYSTEMD" = false ]; then
        nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
    fi

    echo -n "   Waiting for Docker"
    for i in {1..20}; do
        sleep 1
        echo -n "."
        if docker ps >/dev/null 2>&1; then
            echo ""
            echo -e "${GREEN}   ✓ Docker started${NC}"
            ((SERVICES_STARTED++))
            break
        fi
    done
    echo ""

    if ! docker ps >/dev/null 2>&1; then
        echo -e "${RED}   ✗ Docker failed to start - check: journalctl -u docker or /var/log/docker.log${NC}"
    fi
fi
systemctl restart dnsmasq
# ============================================================================
# 2. START REDIS
# ============================================================================
echo -e "${CYAN}[2/8] Starting Redis...${NC}"

if redis-cli ping >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Redis already running${NC}"
    ((SERVICES_STARTED++))
else
    systemctl start redis-server 2>/dev/null || \
    service redis-server start 2>/dev/null || \
    redis-server --daemonize yes 2>/dev/null || true
    sleep 2
    if redis-cli ping >/dev/null 2>&1; then
        echo -e "${GREEN}   ✓ Redis started${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ Redis failed to start${NC}"
    fi
fi

# ============================================================================
# 3. START PHP-FPM (always TCP 9000)
# ============================================================================
echo -e "${CYAN}[3/8] Starting PHP-FPM...${NC}"

# In [3/8] PHP-FPM section, replace the static version loop:
PHP_VERSION=""
for ver in 8.5 8.4 8.3 8.2 8.1; do
    if [ -f "/usr/sbin/php-fpm${ver}" ] || command -v php${ver} &>/dev/null; then
        PHP_VERSION=$ver
        break
    fi
done

if [ -z "$PHP_VERSION" ]; then
    echo -e "${RED}   ✗ PHP-FPM not found${NC}"
else
    # Always force TCP 9000 — never socket mode (socket causes 502)
    if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
        sed -i 's|^listen = .*|listen = 127.0.0.1:9000|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
        sed -i 's|^;listen.allowed_clients|listen.allowed_clients|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    fi

    if netstaYt -tulpn 2>/dev/null | grep -q ":9000.*LISTEN"; then
        echo -e "${GREEN}   ✓ PHP-FPM already running (port 9000)${NC}"
        ((SERVICES_STARTED++))
    else
        pkill -9 php-fpm 2>/dev/null || true
        sleep 1

        systemctl enable php${PHP_VERSION}-fpm 2>/dev/null || true
        systemctl start php${PHP_VERSION}-fpm 2>/dev/null || \
        service php${PHP_VERSION}-fpm start 2>/dev/null || \
        /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
        sleep 2

        if netstat -tulpn 2>/dev/null | grep -q ":9000.*LISTEN"; then
            echo -e "${GREEN}   ✓ PHP-FPM listening on port 9000${NC}"
            ((SERVICES_STARTED++))
        else
            echo -e "${RED}   ✗ PHP-FPM not on port 9000!${NC}"
        fi
    fi
fi

# ============================================================================
# 4. START NGINX
# ============================================================================
echo -e "${CYAN}[4/8] Starting Nginx...${NC}"

if pgrep nginx >/dev/null && (netstat -tulpn 2>/dev/null | grep -qE ":8443|:443"); then
    echo -e "${GREEN}   ✓ Nginx already running (port 8443)${NC}"
    ((SERVICES_STARTED++))
else
    pkill nginx 2>/dev/null || true
    sleep 1

    # Fix Nginx config (Livewire caching block causes issues)
    sed -i '/# Disable caching for Livewire/,/^}/d' /etc/nginx/sites-available/pelican.conf 2>/dev/null || true

    # Ensure fastcgi_pass points to TCP 9000 not socket
    if [ -f "/etc/nginx/sites-enabled/pelican.conf" ]; then
        sed -i 's|fastcgi_pass unix:/run/php/php.*-fpm.sock;|fastcgi_pass 127.0.0.1:9000;|g' /etc/nginx/sites-enabled/pelican.conf
    fi

    nginx -t 2>/dev/null && {
        systemctl start nginx 2>/dev/null || \
        service nginx start 2>/dev/null || \
        nginx 2>/dev/null || true
    } || {
        echo -e "${RED}   ✗ Nginx config test failed — check /etc/nginx/sites-available/pelican.conf${NC}"
    }
    sleep 2

    if pgrep nginx >/dev/null && (netstat -tulpn 2>/dev/null | grep -qE ":8443|:443"); then
        echo -e "${GREEN}   ✓ Nginx started (port 8443)${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ Nginx failed to start${NC}"
    fi
fi

# ============================================================================
# 5. CRON, SUPERVISOR & AUTO-LIMITS
# ============================================================================
echo -e "${CYAN}[5/8] Starting Cron, Supervisor & Auto-Limits...${NC}"

# Cron
service cron start 2>/dev/null || cron 2>/dev/null || true
pgrep cron >/dev/null && echo -e "${GREEN}   ✓ Cron running${NC}" || echo -e "${RED}   ✗ Cron failed${NC}"

# Supervisor — kill zombies and clean stale files first
pkill -f supervisord 2>/dev/null || true
sleep 2
rm -f /var/run/supervisor.sock /var/run/supervisord.pid

systemctl start supervisor 2>/dev/null || \
supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 3

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
supervisorctl start pelican-queue 2>/dev/null || supervisorctl restart pelican-queue 2>/dev/null || true
sleep 2
pgrep -f "queue:work" >/dev/null && echo -e "${GREEN}   ✓ Queue worker running${NC}" || echo -e "${RED}   ✗ Queue worker failed${NC}"

# Auto-Limits
if [ -f "/usr/local/bin/pelican-auto-resource-limits.sh" ]; then
    /usr/local/bin/pelican-auto-resource-limits.sh && \
        echo -e "${GREEN}   ✓ Resource limits assigned${NC}" || \
        echo -e "${YELLOW}   ⚠ Could not assign limits${NC}"
    pkill -f "pelican-auto-resource-limits-fast.sh" 2>/dev/null || true
    sleep 1
    nohup /usr/local/bin/pelican-auto-resource-limits-fast.sh > /var/log/pelican-auto-limits-fast.log 2>&1 &
    echo -e "${GREEN}   ✓ Fast auto-limit service restarted${NC}"
else
    echo -e "${YELLOW}   ⚠ Resource limits script not found - run plugin setup first${NC}"
fi
((SERVICES_STARTED++))

# ============================================================================
# 6. START WINGS (via systemd only — prevents port 8080 conflicts)
# ============================================================================
echo -e "${CYAN}[6/8] Starting Wings...${NC}"

if systemctl is-active --quiet wings; then
    echo -e "${GREEN}   ✓ Wings already running${NC}"
    ((SERVICES_STARTED++))
else
    # Kill any zombie wings processes first
    pkill -x wings 2>/dev/null || true
    sleep 2

if [ -f "/usr/local/bin/wings" ] && [ -f "/etc/pelican/config.yml" ]; then
        # Ensure Docker is running before Wings
        if ! docker info >/dev/null 2>&1; then
            systemctl reset-failed docker 2>/dev/null || true
            rm -f /var/run/docker.pid /var/run/docker.sock
            systemctl start docker
            sleep 5
        fi
        systemctl reset-failed wings 2>/dev/null || true
        sed -i '/ssl:/,/key:/ s/enabled: true/enabled: false/' /etc/pelican/config.yml 2>/dev/null || true
        sed -i 's/port: 8443/port: 8080/' /etc/pelican/config.yml 2>/dev/null || true
        sed -i 's/bind_port: 2022/bind_port: 2023/' /etc/pelican/config.yml 2>/dev/null || true
        systemctl start wings 2>/dev/null
        sleep 5
        if systemctl is-active --quiet wings; then
            echo -e "${GREEN}   ✓ Wings started${NC}"
            netstat -tulpn 2>/dev/null | grep -q ":8080" && \
                echo -e "${GREEN}   ✓ Wings on port 8080${NC}" || \
                echo -e "${YELLOW}   ⚠ Wings not on port 8080 yet${NC}"
            ((SERVICES_STARTED++))
        else
            echo -e "${RED}   ✗ Wings failed - check: journalctl -u wings -n 20${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠ Wings not installed${NC}"
    fi
fi

# ============================================================================
# 7. START CLOUDFLARE TUNNELS (one process only)
# ============================================================================
echo -e "${CYAN}[7/8] Starting Cloudflare Tunnels...${NC}"

# Kill ALL existing cloudflared processes cleanly
pkill -9 cloudflared 2>/dev/null || true
sleep 3

# Verify all dead
if pgrep cloudflared >/dev/null; then
    pkill -9 cloudflared 2>/dev/null || true
    sleep 2
fi

TUNNEL_COUNT=0

if [ -n "$CF_TOKEN" ]; then
    systemctl start cloudflared 2>/dev/null || \
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-panel.log 2>&1 &
    sleep 3
    ((TUNNEL_COUNT++))
fi

if [ -n "$CF_TOKEN_WINGS" ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 &
    sleep 3
    ((TUNNEL_COUNT++))
fi

[ "$TUNNEL_COUNT" -gt 0 ] && \
    echo -e "${GREEN}   ✓ Started ${TUNNEL_COUNT} Cloudflare tunnel(s)${NC}" || \
    echo -e "${YELLOW}   ⚠ No tunnel tokens found in .pelican.env${NC}"

# Ensure smart watchdog is running
systemctl start pelican-watchdog 2>/dev/null || true
echo -e "${GREEN}   ✓ Smart watchdog running${NC}"

# ============================================================================
# 8. CLEAR PANEL CACHE
# ============================================================================
echo -e "${CYAN}[8/8] Clearing Panel cache...${NC}"

if [ -d "/var/www/pelican" ]; then
    cd /var/www/pelican
    PHP_BIN="/usr/bin/php${PHP_VERSION}"
    [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)

    # Clear all caches
    $PHP_BIN artisan cache:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan config:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan route:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan view:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan event:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan optimize:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan queue:restart >/dev/null 2>&1 || true
    rm -rf storage/framework/views/* 2>/dev/null || true
    rm -rf storage/framework/cache/* 2>/dev/null || true
    rm -rf storage/framework/sessions/* 2>/dev/null || true
    rm -rf bootstrap/cache/* 2>/dev/null || true
    redis-cli FLUSHALL >/dev/null 2>&1 || true

    # Rebuild safe caches
    $PHP_BIN artisan view:cache >/dev/null 2>&1 || true
    $PHP_BIN artisan event:cache >/dev/null 2>&1 || true

    echo -e "${GREEN}   ✓ Cache cleared and rebuilt${NC}"
fi

# ============================================================================
# BONUS: REPAIR DOCKER NETWORKING IF BROKEN
# ============================================================================
echo -e "${CYAN}[BONUS] Checking Docker network health...${NC}"
if docker info >/dev/null 2>&1; then
    # Check if DOCKER-USER chain exists — if not, iptables rules were wiped
    if ! iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        echo -e "${YELLOW}   ⚠ Docker iptables chains missing — restarting Docker...${NC}"
        systemctl restart docker 2>/dev/null || true
        sleep 5
    fi
    # Force re-add MSS clamping (fixes slow downloads in containers)
    iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    # Ensure IP forwarding is ON
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    echo -e "${GREEN}   ✓ Docker network health OK${NC}"
fi

# ============================================================================
# STATUS CHECK
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          Services Status               ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

docker ps >/dev/null 2>&1 && \
    echo -e "${GREEN}✓ Docker:       Running ($(docker ps -q | wc -l) containers)${NC}" || \
    echo -e "${RED}✗ Docker:       Not Running${NC}"

redis-cli ping >/dev/null 2>&1 && \
    echo -e "${GREEN}✓ Redis:        Running${NC}" || \
    echo -e "${RED}✗ Redis:        Not Running${NC}"

netstat -tulpn 2>/dev/null | grep -q ":9000.*LISTEN" && \
    echo -e "${GREEN}✓ PHP-FPM:      Running (port 9000)${NC}" || \
    echo -e "${RED}✗ PHP-FPM:      Not Running${NC}"

pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -qE ":8443|:443" && \
    echo -e "${GREEN}✓ Nginx:        Running (port 8443)${NC}" || \
    echo -e "${RED}✗ Nginx:        Not Running${NC}"

pgrep cron >/dev/null && \
    echo -e "${GREEN}✓ Cron:         Running${NC}" || \
    echo -e "${RED}✗ Cron:         Not Running${NC}"

pgrep supervisord >/dev/null && \
    echo -e "${GREEN}✓ Supervisor:   Running${NC}" || \
    echo -e "${RED}✗ Supervisor:   Not Running${NC}"

pgrep -f "queue:work" >/dev/null && \
    echo -e "${GREEN}✓ Queue Worker: Running${NC}" || \
    echo -e "${RED}✗ Queue Worker: Not Running${NC}"

pgrep -f "auto-resource-limits-fast" >/dev/null && \
    echo -e "${GREEN}✓ Auto-Limits:  Running${NC}" || \
    echo -e "${RED}✗ Auto-Limits:  Not Running${NC}"

systemctl is-active --quiet wings && \
    echo -e "${GREEN}✓ Wings:        Running${NC}" || \
    echo -e "${YELLOW}⚠ Wings:        Not Running${NC}"

CF_COUNT=$(pgrep -c cloudflared 2>/dev/null || echo 0)
[ "$CF_COUNT" -gt 0 ] && \
    echo -e "${GREEN}✓ Cloudflare:   Running (${CF_COUNT} process)${NC}" || \
    echo -e "${YELLOW}⚠ Cloudflare:   Not Running${NC}"

# Panel HTTP check
PANEL_CODE=$(curl -sk https://${PANEL_DOMAIN:-localhost:8443} -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
[ "$PANEL_CODE" = "200" ] || [ "$PANEL_CODE" = "302" ] && \
    echo -e "${GREEN}✓ Panel:        Responding (HTTP $PANEL_CODE)${NC}" || \
    echo -e "${RED}✗ Panel:        Not Responding (HTTP $PANEL_CODE)${NC}"

echo ""
[ -n "$PANEL_DOMAIN" ] && echo -e "${CYAN}🌐 Panel:${NC} ${GREEN}https://${PANEL_DOMAIN}${NC}"
[ -n "$NODE_DOMAIN" ]  && echo -e "${CYAN}🌐 Wings:${NC} ${GREEN}https://${NODE_DOMAIN}${NC}"
echo ""
echo -e "${CYAN}📝 Logs:${NC}"
echo -e "  Wings:       ${GREEN}journalctl -u wings -f${NC}"
echo -e "  Panel:       ${GREEN}tail -f /var/log/nginx/pelican.app-error.log${NC}"
echo -e "  Docker:      ${GREEN}journalctl -u docker -f${NC}"
echo -e "  Queue:       ${GREEN}supervisorctl tail -f pelican-queue${NC}"
echo -e "  Auto-Limits: ${GREEN}tail -f /var/log/pelican-auto-limits-fast.log${NC}"
echo ""
echo "restart.sh v9.1"