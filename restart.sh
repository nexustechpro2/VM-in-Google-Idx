#!/bin/bash

################################################################################
# PELICAN AUTO-RESTART SCRIPT v8.0 PRODUCTION READY
# - FIXED: Docker starts via systemd on VMs with systemd
# - FIXED: Falls back to manual dockerd if systemd fails
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Pelican Services Restart v8.0      ║${NC}"
echo -e "${CYAN}║     Migration-Safe Restart             ║${NC}"
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

# ============================================================================
# 1. START DOCKER
# ============================================================================
echo -e "${CYAN}[1/7] Starting Docker...${NC}"

if docker ps >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Docker already running${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${YELLOW}   Starting Docker daemon...${NC}"
    pkill -9 dockerd 2>/dev/null || true
    rm -f /var/run/docker.sock /var/run/docker.pid
    sleep 2

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

# ============================================================================
# 2. START REDIS
# ============================================================================
echo -e "${CYAN}[2/7] Starting Redis...${NC}"

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
# 3. START PHP-FPM
# ============================================================================
echo -e "${CYAN}[3/7] Starting PHP-FPM...${NC}"

PHP_VERSION=""
for ver in 8.3 8.4 8.2 8.1; do
    if [ -f "/usr/sbin/php-fpm${ver}" ] || command -v php${ver} &>/dev/null; then
        PHP_VERSION=$ver
        break
    fi
done

if [ -z "$PHP_VERSION" ]; then
    echo -e "${RED}   ✗ PHP-FPM not found${NC}"
else
    if netstat -tulpn 2>/dev/null | grep -q ":9000.*LISTEN"; then
        echo -e "${GREEN}   ✓ PHP-FPM already running (port 9000)${NC}"
        ((SERVICES_STARTED++))
    else
        pkill -9 php-fpm 2>/dev/null || true
        sleep 1

        if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
            if grep -q "listen = /run/php" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf; then
                sed -i 's|listen = /run/php/php.*-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
                sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
            fi
        fi

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
echo -e "${CYAN}[4/7] Starting Nginx...${NC}"

if pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":8443"; then
    echo -e "${GREEN}   ✓ Nginx already running (port 8443)${NC}"
    ((SERVICES_STARTED++))
else
    pkill nginx 2>/dev/null || true
    sleep 1
    systemctl start nginx 2>/dev/null || \
    service nginx start 2>/dev/null || \
    nginx 2>/dev/null || true
    sleep 2

    if pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":8443"; then
        echo -e "${GREEN}   ✓ Nginx started (port 8443)${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ Nginx failed to start${NC}"
    fi
fi

# ============================================================================
# 5. START PANEL QUEUE WORKER
# ============================================================================
echo -e "${CYAN}[5/7] Starting Panel Queue Worker...${NC}"

if pgrep -f "queue:work" >/dev/null; then
    echo -e "${GREEN}   ✓ Queue worker already running${NC}"
    ((SERVICES_STARTED++))
else
    if [ -d "/var/www/pelican" ]; then
        cd /var/www/pelican
        pkill -f "queue:work" 2>/dev/null || true
        sleep 1

        PHP_BIN="/usr/bin/php${PHP_VERSION}"
        [ ! -f "$PHP_BIN" ] && PHP_BIN="/usr/bin/php8.3"
        [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)

        if command -v supervisorctl &>/dev/null; then
            supervisorctl restart pelican-queue 2>/dev/null || \
            nohup sudo -u www-data $PHP_BIN artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 > /var/log/pelican-queue.log 2>&1 &
        else
            nohup sudo -u www-data $PHP_BIN artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 > /var/log/pelican-queue.log 2>&1 &
        fi
        sleep 2
        pgrep -f "queue:work" >/dev/null && { echo -e "${GREEN}   ✓ Queue worker started${NC}"; ((SERVICES_STARTED++)); } || echo -e "${RED}   ✗ Queue worker failed${NC}"
    else
        echo -e "${YELLOW}   ⚠ Panel not installed${NC}"
    fi
fi

# ============================================================================
# 6. START WINGS
# ============================================================================
echo -e "${CYAN}[6/7] Starting Wings...${NC}"

if pgrep -x wings >/dev/null; then
    echo -e "${GREEN}   ✓ Wings already running${NC}"
else
    if [ -f "/usr/local/bin/wings" ] && [ -f "/etc/pelican/config.yml" ]; then
        pkill wings 2>/dev/null || true
        sleep 1
        cd /etc/pelican
        nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &
        sleep 5
        if pgrep -x wings >/dev/null; then
            echo -e "${GREEN}   ✓ Wings started${NC}"
            netstat -tulpn 2>/dev/null | grep -q ":8080" && echo -e "${GREEN}   ✓ Wings on port 8080${NC}" || echo -e "${YELLOW}   ⚠ Wings not on port 8080 yet${NC}"
        else
            echo -e "${RED}   ✗ Wings failed - check: tail -20 /tmp/wings.log${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠ Wings not installed${NC}"
    fi
fi

# ============================================================================
# 7. START CLOUDFLARE TUNNELS
# ============================================================================
echo -e "${CYAN}[7/7] Starting Cloudflare Tunnels...${NC}"

pkill cloudflared 2>/dev/null || true
sleep 2
TUNNEL_COUNT=0

if [ -n "$CF_TOKEN" ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-panel.log 2>&1 &
    sleep 2
    ((TUNNEL_COUNT++))
fi

if [ -n "$CF_TOKEN_WINGS" ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 &
    sleep 2
    ((TUNNEL_COUNT++))
fi

[ "$TUNNEL_COUNT" -gt 0 ] && echo -e "${GREEN}   ✓ Started ${TUNNEL_COUNT} Cloudflare tunnel(s)${NC}" || echo -e "${YELLOW}   ⚠ No tunnel tokens found${NC}"

# ============================================================================
# CLEAR PANEL CACHE
# ============================================================================
if [ -d "/var/www/pelican" ]; then
    echo ""
    echo -e "${CYAN}[CACHE] Clearing Panel cache...${NC}"
    cd /var/www/pelican
    PHP_BIN="/usr/bin/php${PHP_VERSION:-8.3}"
    [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)
    $PHP_BIN artisan config:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan cache:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan view:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan route:clear >/dev/null 2>&1 || true
    rm -rf storage/framework/views/* storage/framework/cache/* 2>/dev/null || true
    redis-cli FLUSHDB >/dev/null 2>&1 || true
    echo -e "${GREEN}   ✓ Cache cleared${NC}"
fi

# ============================================================================
# STATUS CHECK
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          Services Status               ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

docker ps >/dev/null 2>&1 && echo -e "${GREEN}✓ Docker:       Running ($(docker ps -q | wc -l) containers)${NC}" || echo -e "${RED}✗ Docker:       Not Running${NC}"
redis-cli ping >/dev/null 2>&1 && echo -e "${GREEN}✓ Redis:        Running${NC}" || echo -e "${RED}✗ Redis:        Not Running${NC}"
netstat -tulpn 2>/dev/null | grep -q ":9000" && echo -e "${GREEN}✓ PHP-FPM:      Running (port 9000)${NC}" || echo -e "${RED}✗ PHP-FPM:      Not Running${NC}"
pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":8443" && echo -e "${GREEN}✓ Nginx:        Running (port 8443)${NC}" || echo -e "${RED}✗ Nginx:        Not Running${NC}"
pgrep -f "queue:work" >/dev/null && echo -e "${GREEN}✓ Queue Worker: Running${NC}" || echo -e "${RED}✗ Queue Worker: Not Running${NC}"
pgrep -x wings >/dev/null && echo -e "${GREEN}✓ Wings:        Running${NC}" || echo -e "${YELLOW}⚠ Wings:        Not Running${NC}"
CF_COUNT=$(pgrep -f cloudflared | wc -l)
[ "$CF_COUNT" -gt 0 ] && echo -e "${GREEN}✓ Cloudflare:   Running (${CF_COUNT} tunnel(s))${NC}" || echo -e "${YELLOW}⚠ Cloudflare:   Not Running${NC}"

echo ""
[ -n "$PANEL_DOMAIN" ] && echo -e "${CYAN}🌐 Panel:${NC} ${GREEN}https://${PANEL_DOMAIN}${NC}"
[ -n "$NODE_DOMAIN" ] && echo -e "${CYAN}🌐 Wings:${NC} ${GREEN}https://${NODE_DOMAIN}${NC}"
echo ""
echo -e "${CYAN}📝 Logs:${NC}"
echo -e "  Wings:  ${GREEN}tail -f /tmp/wings.log${NC}"
echo -e "  Panel:  ${GREEN}tail -f /var/log/nginx/pelican.app-error.log${NC}"
echo -e "  Docker: ${GREEN}tail -f /var/log/docker.log${NC}"
echo ""
echo "restart.sh updated!"