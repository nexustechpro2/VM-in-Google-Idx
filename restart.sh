#!/bin/bash

################################################################################
# PELICAN AUTO-RESTART SCRIPT v9.4 PRODUCTION READY
# Fixes from v9.3:
#   - CRITICAL: Removed sed lines that overwrote Wings port 8080 on every restart
#   - CRITICAL: Added Wings port 8080 wait loop before starting Cloudflare
#   - MINOR: Added Redis retry on first-boot failure
#   - Added local PostgreSQL start before Docker (step 0.5)
#   - Added DB backup cron registration in Phase 5
#   - Added DB backup status in status check
#   - Added backup lock file cleanup in Phase 0
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Pelican Services Restart v9.4      ║${NC}"
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

# ============================================================================
# PHASE 0 — HARD STOP EVERYTHING FIRST
# ============================================================================
echo -e "${CYAN}[0/8] Stopping all services cleanly...${NC}"

# Stop all high-level services first
systemctl stop wings cloudflared pelican-watchdog supervisor cron 2>/dev/null || true
echo -e "${GREEN}   ✓ Panel services stopped${NC}"

# Stop web stack
systemctl stop nginx 2>/dev/null || true
PHP_VER_STOP=""
for ver in 8.3 8.4 8.2 8.1; do
    [ -f "/usr/sbin/php-fpm${ver}" ] && PHP_VER_STOP=$ver && break
done
[ -n "$PHP_VER_STOP" ] && systemctl stop php${PHP_VER_STOP}-fpm 2>/dev/null || true
systemctl stop redis-server 2>/dev/null || true
echo -e "${GREEN}   ✓ Web stack stopped${NC}"

# Stop all Docker scoped unit slices (game server containers)
echo -e "${YELLOW}   Stopping Docker container scopes...${NC}"
systemctl list-units --type=scope --state=running 2>/dev/null \
    | grep -o 'docker-[a-f0-9]*.scope' \
    | while read scope; do
        systemctl stop "$scope" 2>/dev/null || true
    done

# Stop Docker fully
systemctl stop docker.socket docker containerd 2>/dev/null || true
sleep 2

# Force kill anything still alive
pkill -9 dockerd 2>/dev/null || true
pkill -9 cloudflared 2>/dev/null || true
pkill -x wings 2>/dev/null || true
pkill -9 php-fpm 2>/dev/null || true
pkill -9 nginx 2>/dev/null || true
pkill -f supervisord 2>/dev/null || true
sleep 2

# Clean up stale socket/pid files
rm -f /var/run/docker.sock /var/run/docker.pid
rm -f /var/run/supervisor.sock /var/run/supervisord.pid
rm -f /tmp/pelican-backup.lock

echo -e "${GREEN}   ✓ Everything stopped — clean slate${NC}"
echo ""

# ============================================================================
# Lock DNS — only Cloudflare/Google DNS, no Tailscale override
# ============================================================================
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
options timeout:2 attempts:2 rotate
DNSEOF
chattr +i /etc/resolv.conf

# ============================================================================
# 0.5. START LOCAL POSTGRESQL (only if using local pgsql)
# ============================================================================
echo -e "${CYAN}[0.5/8] Starting local PostgreSQL...${NC}"

DB_HOST_VAL=$(grep "^DB_HOST=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2)
DB_CONN_VAL=$(grep "^DB_CONNECTION=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2)
DB_NAME_VAL=$(grep "^DB_DATABASE=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2)
DB_USER_VAL=$(grep "^DB_USERNAME=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2)
DB_PASS_VAL=$(grep "^DB_PASSWORD=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2-)

if [ "$DB_CONN_VAL" = "pgsql" ] && \
   { [ "$DB_HOST_VAL" = "127.0.0.1" ] || [ "$DB_HOST_VAL" = "localhost" ]; }; then
    systemctl start postgresql 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet postgresql; then
        echo -e "${GREEN}   ✓ PostgreSQL started${NC}"
        PGPASSWORD="$DB_PASS_VAL" psql \
            -h 127.0.0.1 -U "$DB_USER_VAL" -d "$DB_NAME_VAL" \
            -c "ANALYZE;" >/dev/null 2>&1 && \
            echo -e "${GREEN}   ✓ PostgreSQL stats refreshed${NC}" || true
    else
        echo -e "${RED}   ✗ PostgreSQL failed to start${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠ Using remote/non-pgsql DB — skipping local PostgreSQL${NC}"
fi

# ============================================================================
# 1. START DOCKER
# ============================================================================
echo -e "${CYAN}[1/8] Starting Docker...${NC}"

systemctl reset-failed docker 2>/dev/null || true

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

HAS_SYSTEMD=false
if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
    systemctl start docker 2>/dev/null && HAS_SYSTEMD=true
fi

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

systemctl restart dnsmasq 2>/dev/null || true

# ============================================================================
# 2. START REDIS
# ============================================================================
echo -e "${CYAN}[2/8] Starting Redis...${NC}"

systemctl start redis-server 2>/dev/null || \
service redis-server start 2>/dev/null || \
redis-server --daemonize yes 2>/dev/null || true
sleep 2

if ! redis-cli ping >/dev/null 2>&1; then
    echo -e "${YELLOW}   Redis not ready yet — retrying...${NC}"
    sleep 3
    systemctl restart redis-server 2>/dev/null || true
    sleep 2
fi

if redis-cli ping >/dev/null 2>&1; then
    echo -e "${GREEN}   ✓ Redis started${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${RED}   ✗ Redis failed to start${NC}"
fi

# ============================================================================
# 3. START PHP-FPM (Unix socket mode)
# ============================================================================
echo -e "${CYAN}[3/8] Starting PHP-FPM...${NC}"

# Detect PHP version — prefer 8.3, skip 8.5
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
    SOCKET_PATH="/run/php/php${PHP_VERSION}-fpm.sock"

    # Ensure socket mode in pool config
    if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
        sed -i "s|^listen = .*|listen = ${SOCKET_PATH}|" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
        sed -i 's|^listen.owner = .*|listen.owner = www-data|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
        sed -i 's|^listen.group = .*|listen.group = www-data|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    fi

    systemctl enable php${PHP_VERSION}-fpm 2>/dev/null || true
    systemctl start php${PHP_VERSION}-fpm 2>/dev/null || \
    service php${PHP_VERSION}-fpm start 2>/dev/null || \
    /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
    sleep 2

    if [ -S "$SOCKET_PATH" ]; then
        echo -e "${GREEN}   ✓ PHP-FPM listening on socket: $SOCKET_PATH${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ PHP-FPM socket not found at $SOCKET_PATH${NC}"
    fi
fi

# ============================================================================
# 4. START NGINX
# ============================================================================
echo -e "${CYAN}[4/8] Starting Nginx...${NC}"

# Ensure fastcgi_pass uses socket not TCP (never force TCP 9000)
if [ -f "/etc/nginx/sites-available/pelican.conf" ] && [ -n "$PHP_VERSION" ]; then
    SOCKET_PATH="/run/php/php${PHP_VERSION}-fpm.sock"
    if ! grep -q "fastcgi_pass unix:${SOCKET_PATH}" /etc/nginx/sites-available/pelican.conf 2>/dev/null; then
        sed -i "s|fastcgi_pass unix:/run/php/php.*-fpm.sock;|fastcgi_pass unix:${SOCKET_PATH};|g" \
            /etc/nginx/sites-available/pelican.conf 2>/dev/null || true
        sed -i "s|fastcgi_pass 127.0.0.1:9000;|fastcgi_pass unix:${SOCKET_PATH};|g" \
            /etc/nginx/sites-available/pelican.conf 2>/dev/null || true
    fi
fi

nginx -t 2>/dev/null && {
    systemctl start nginx 2>/dev/null || \
    service nginx start 2>/dev/null || \
    nginx 2>/dev/null || true
} || {
    echo -e "${RED}   ✗ Nginx config test failed — check /etc/nginx/sites-available/pelican.conf${NC}"
}
sleep 2

if pgrep nginx >/dev/null && (ss -tlnp 2>/dev/null | grep -q ":443"); then
    echo -e "${GREEN}   ✓ Nginx started (port 443)${NC}"
    ((SERVICES_STARTED++))
else
    echo -e "${RED}   ✗ Nginx failed to start${NC}"
fi

# ============================================================================
# 5. CRON, SUPERVISOR & AUTO-LIMITS
# ============================================================================
echo -e "${CYAN}[5/8] Starting Cron, Supervisor & Auto-Limits...${NC}"

# Cron
service cron start 2>/dev/null || cron 2>/dev/null || true
pgrep cron >/dev/null && \
    echo -e "${GREEN}   ✓ Cron running${NC}" || \
    echo -e "${RED}   ✗ Cron failed${NC}"

# Register DB backup cron if script exists and not already registered
if [ -f "/usr/local/bin/pelican-db-backup.sh" ]; then
    if ! crontab -l 2>/dev/null | grep -q "pelican-db-backup"; then
        (crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/pelican-db-backup.sh") | crontab -
        echo -e "${GREEN}   ✓ DB backup cron registered (every 15 mins)${NC}"
    else
        echo -e "${GREEN}   ✓ DB backup cron already active${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠ DB backup script not found - skipping${NC}"
fi

# Supervisor
systemctl start supervisor 2>/dev/null || \
supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 3

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
supervisorctl start pelican-queue 2>/dev/null || \
supervisorctl restart pelican-queue 2>/dev/null || true
sleep 2
pgrep -f "queue:work" >/dev/null && \
    echo -e "${GREEN}   ✓ Queue worker running${NC}" || \
    echo -e "${RED}   ✗ Queue worker failed${NC}"

# Auto-Limits
if [ -f "/usr/local/bin/pelican-auto-resource-limits.sh" ]; then
    /usr/local/bin/pelican-auto-resource-limits.sh && \
        echo -e "${GREEN}   ✓ Resource limits assigned${NC}" || \
        echo -e "${YELLOW}   ⚠ Could not assign limits${NC}"
    pkill -f "pelican-auto-resource-limits-fast.sh" 2>/dev/null || true
    sleep 1
    nohup /usr/local/bin/pelican-auto-resource-limits-fast.sh \
        > /var/log/pelican-auto-limits-fast.log 2>&1 &
    echo -e "${GREEN}   ✓ Fast auto-limit service restarted${NC}"
else
    echo -e "${YELLOW}   ⚠ Resource limits script not found - run plugin setup first${NC}"
fi
((SERVICES_STARTED++))

# ============================================================================
# 6. START WINGS (via systemd only — prevents port 8080 conflicts)
# ============================================================================
echo -e "${CYAN}[6/8] Starting Wings...${NC}"

if [ -f "/usr/local/bin/wings" ] && [ -f "/etc/pelican/config.yml" ]; then
    # Ensure Docker is running before Wings
    if ! docker info >/dev/null 2>&1; then
        systemctl reset-failed docker 2>/dev/null || true
        rm -f /var/run/docker.pid /var/run/docker.sock
        systemctl start docker
        sleep 5
    fi
    systemctl reset-failed wings 2>/dev/null || true
    systemctl start wings 2>/dev/null

    # Wait for Wings to actually bind on port 8080 before starting Cloudflare
    echo -n "   Waiting for Wings on port 8080"
    for i in {1..15}; do
        sleep 2
        echo -n "."
        ss -tlnp 2>/dev/null | grep -q ":8080" && { echo ""; break; }
    done
    if systemctl is-active --quiet wings; then
        echo -e "${GREEN}   ✓ Wings started${NC}"
        ss -tlnp 2>/dev/null | grep -q ":8080" && \
            echo -e "${GREEN}   ✓ Wings on port 8080${NC}" || \
            echo -e "${YELLOW}   ⚠ Wings not on port 8080 yet${NC}"
        ((SERVICES_STARTED++))
    else
        echo -e "${RED}   ✗ Wings failed - check: journalctl -u wings -n 20${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠ Wings not installed${NC}"
fi

# ============================================================================
# 7. START CLOUDFLARE TUNNELS
# ============================================================================
echo -e "${CYAN}[7/8] Starting Cloudflare Tunnels...${NC}"

TUNNEL_COUNT=0

if [ -n "${CF_TOKEN:-}" ]; then
    systemctl start cloudflared 2>/dev/null || \
    nohup cloudflared tunnel run --token "$CF_TOKEN" \
        > /var/log/cloudflared-panel.log 2>&1 &
    sleep 3
    ((TUNNEL_COUNT++))
fi

if [ -n "${CF_TOKEN_WINGS:-}" ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN_WINGS" \
        > /var/log/cloudflared-wings.log 2>&1 &
    sleep 3
    ((TUNNEL_COUNT++))
fi

[ "$TUNNEL_COUNT" -gt 0 ] && \
    echo -e "${GREEN}   ✓ Started ${TUNNEL_COUNT} Cloudflare tunnel(s)${NC}" || \
    echo -e "${YELLOW}   ⚠ No tunnel tokens found in .pelican.env${NC}"

systemctl start pelican-watchdog 2>/dev/null || true

# ============================================================================
# 8. CLEAR PANEL CACHE + LOCAL POSTGRESQL ANALYZE (pgsql+local only)
# ============================================================================
echo -e "${CYAN}[8/8] Clearing Panel cache...${NC}"

if [ -d "/var/www/pelican" ]; then
    cd /var/www/pelican
    PHP_BIN="/usr/bin/php${PHP_VERSION}"
    [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)

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

    $PHP_BIN artisan view:cache >/dev/null 2>&1 || true
    $PHP_BIN artisan event:cache >/dev/null 2>&1 || true

    echo -e "${GREEN}   ✓ Cache cleared and rebuilt${NC}"

    # Run ANALYZE on local PostgreSQL only — skips if remote/mysql/sqlite
    DB_HOST_VAL=$(grep "^DB_HOST=" .env 2>/dev/null | cut -d'=' -f2)
    DB_DRIVER_VAL=$(grep "^DB_CONNECTION=" .env 2>/dev/null | cut -d'=' -f2)
    DB_NAME_VAL=$(grep "^DB_DATABASE=" .env 2>/dev/null | cut -d'=' -f2)
    DB_USER_VAL=$(grep "^DB_USERNAME=" .env 2>/dev/null | cut -d'=' -f2)
    DB_PASS_VAL=$(grep "^DB_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2-)

    if [ "$DB_DRIVER_VAL" = "pgsql" ] && \
       { [ "$DB_HOST_VAL" = "127.0.0.1" ] || [ "$DB_HOST_VAL" = "localhost" ]; }; then
        echo -e "${YELLOW}   Running ANALYZE on local PostgreSQL...${NC}"
        PGPASSWORD="$DB_PASS_VAL" psql \
            -h 127.0.0.1 -U "$DB_USER_VAL" -d "$DB_NAME_VAL" \
            -c "ANALYZE;" >/dev/null 2>&1 && \
            echo -e "${GREEN}   ✓ PostgreSQL stats refreshed${NC}" || \
            echo -e "${YELLOW}   ⚠ ANALYZE skipped (local PostgreSQL not reachable)${NC}"
    fi
fi

# ============================================================================
# BONUS: REPAIR DOCKER NETWORKING IF BROKEN
# ============================================================================
echo -e "${CYAN}[BONUS] Checking Docker network health...${NC}"
if docker info >/dev/null 2>&1; then
    if ! iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        echo -e "${YELLOW}   ⚠ Docker iptables chains missing — restarting Docker...${NC}"
        systemctl restart docker 2>/dev/null || true
        sleep 5
    fi
    iptables -I FORWARD -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
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

SOCKET_PATH="/run/php/php${PHP_VERSION:-8.3}-fpm.sock"
[ -S "$SOCKET_PATH" ] && \
    echo -e "${GREEN}✓ PHP-FPM:      Running (socket: $SOCKET_PATH)${NC}" || \
    echo -e "${RED}✗ PHP-FPM:      Not Running${NC}"

pgrep nginx >/dev/null && ss -tlnp 2>/dev/null | grep -q ":443" && \
    echo -e "${GREEN}✓ Nginx:        Running (port 443)${NC}" || \
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
    echo -e "${GREEN}✓ Wings:        Running (port 8080)${NC}" || \
    echo -e "${YELLOW}⚠ Wings:        Not Running${NC}"

CF_COUNT=$(pgrep -c cloudflared 2>/dev/null || echo 0)
[ "$CF_COUNT" -gt 0 ] && \
    echo -e "${GREEN}✓ Cloudflare:   Running (${CF_COUNT} process)${NC}" || \
    echo -e "${YELLOW}⚠ Cloudflare:   Not Running${NC}"

# Show PostgreSQL status only if using local pgsql
DB_HOST_CHECK=$(grep "^DB_HOST=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2)
DB_CONN_CHECK=$(grep "^DB_CONNECTION=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2)
if [ "$DB_CONN_CHECK" = "pgsql" ] && \
   { [ "$DB_HOST_CHECK" = "127.0.0.1" ] || [ "$DB_HOST_CHECK" = "localhost" ]; }; then
    systemctl is-active --quiet postgresql && \
        echo -e "${GREEN}✓ PostgreSQL:   Running (local)${NC}" || \
        echo -e "${RED}✗ PostgreSQL:   Not Running${NC}"
fi

if [ -f "/usr/local/bin/pelican-db-backup.sh" ]; then
    LAST_SYNC=$(grep "Sync completed" /var/log/pelican-db-backup.log 2>/dev/null | tail -1)
    [ -n "$LAST_SYNC" ] && \
        echo -e "${GREEN}✓ DB Backup:    Active (last: $(echo "$LAST_SYNC" | grep -o '\[.*\]'))${NC}" || \
        echo -e "${YELLOW}⚠ DB Backup:    Script found but never run${NC}"
fi

PANEL_CODE=$(curl -sk https://${PANEL_DOMAIN:-localhost} \
    -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
[ "$PANEL_CODE" = "200" ] || [ "$PANEL_CODE" = "302" ] && \
    echo -e "${GREEN}✓ Panel:        Responding (HTTP $PANEL_CODE)${NC}" || \
    echo -e "${RED}✗ Panel:        Not Responding (HTTP $PANEL_CODE)${NC}"

echo ""
[ -n "${PANEL_DOMAIN:-}" ] && \
    echo -e "${CYAN}🌐 Panel:${NC} ${GREEN}https://${PANEL_DOMAIN}${NC}"
[ -n "${NODE_DOMAIN:-}"  ] && \
    echo -e "${CYAN}🌐 Wings:${NC} ${GREEN}https://${NODE_DOMAIN}${NC}"
echo ""
echo -e "${CYAN}📝 Logs:${NC}"
echo -e "  Wings:       ${GREEN}journalctl -u wings -f${NC}"
echo -e "  Panel:       ${GREEN}tail -f /var/log/nginx/pelican.app-error.log${NC}"
echo -e "  Docker:      ${GREEN}journalctl -u docker -f${NC}"
echo -e "  Queue:       ${GREEN}supervisorctl tail -f pelican-queue${NC}"
echo -e "  Auto-Limits: ${GREEN}tail -f /var/log/pelican-auto-limits-fast.log${NC}"
echo -e "  DB Backup:   ${GREEN}tail -f /var/log/pelican-db-backup.log${NC}"
echo ""
echo "restart.sh v9.4"
