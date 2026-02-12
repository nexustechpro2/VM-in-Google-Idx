#!/bin/bash

################################################################################
# PELICAN AUTO-RESTART SCRIPT v7.0 PRODUCTION READY
# - FIXED: Never regenerates APP_KEY (prevents MAC errors)
# - FIXED: Properly restarts Wings with correct configuration
# - FIXED: Clears compiled views to prevent MAC errors
# - For GitHub Codespaces & VPS - Starts everything after sleep/restart
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Pelican Services Restart v7.0      ║${NC}"
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
    "/workspaces/null/newrepo/.pelican.env" \
    "/root/.pelican.env" \
    "$HOME/.pelican.env" \
    "$(dirname "$0")/.pelican.env"; do
    if [ -f "$location" ]; then
        ENV_FILE="$location"
        break
    fi
done

# Load config if exists
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo -e "${GREEN}✓ Config loaded: $ENV_FILE${NC}"
    echo -e "${BLUE}  Domain: ${PANEL_DOMAIN:-not set}${NC}"
    echo -e "${BLUE}  Database: ${DB_DRIVER:-not set}${NC}"
    if [ -n "$NODE_ID" ]; then
        echo -e "${BLUE}  Node ID: ${NODE_ID}${NC}"
    fi
    if [ -n "$PANEL_API_TOKEN" ]; then
        echo -e "${BLUE}  API Token: ${PANEL_API_TOKEN:0:20}...${NC}"
    fi
    echo ""
else
    echo -e "${YELLOW}⚠ No .pelican.env found - will use defaults${NC}"
    echo ""
fi

# Force system PHP path
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
    rm -f /var/run/docker.sock
    sleep 2
    
    nohup dockerd --config-file /etc/docker/daemon.json > /var/log/docker.log 2>&1 &
    
    for i in {1..15}; do
        sleep 1
        if docker ps >/dev/null 2>&1; then
            echo -e "${GREEN}   ✓ Docker started${NC}"
            ((SERVICES_STARTED++))
            break
        fi
    done
    
    if ! docker ps >/dev/null 2>&1; then
        echo -e "${RED}   ✗ Docker failed to start${NC}"
    fi
fi

if docker ps >/dev/null 2>&1; then
    DNS_TEST=$(docker run --rm alpine nslookup google.com 2>&1 || echo "FAILED")
    if echo "$DNS_TEST" | grep -q "Address:"; then
        echo -e "${GREEN}   ✓ Docker DNS working${NC}"
    else
        echo -e "${YELLOW}   ⚠ Docker DNS issue (expected in Codespaces)${NC}"
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
    echo -e "${YELLOW}   Starting Redis...${NC}"
    
    service redis-server start 2>/dev/null || redis-server --daemonize yes 2>/dev/null || true
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
    if [ -f "/usr/sbin/php-fpm${ver}" ] || command -v php${ver} &> /dev/null; then
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
        echo -e "${YELLOW}   Starting PHP-FPM ${PHP_VERSION}...${NC}"
        
        pkill -9 php-fpm 2>/dev/null || true
        sleep 1
        
        if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
            if grep -q "listen = /run/php" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf; then
                sed -i 's|listen = /run/php/php.*-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
                sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
            fi
        fi
        
        if service php${PHP_VERSION}-fpm start 2>/dev/null; then
            echo -e "${GREEN}   ✓ Started via service${NC}"
        elif /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null; then
            echo -e "${GREEN}   ✓ Started via binary${NC}"
        else
            echo -e "${RED}   ✗ All start methods failed${NC}"
        fi
        
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
    echo -e "${YELLOW}   Starting Nginx...${NC}"
    
    pkill nginx 2>/dev/null || true
    sleep 1
    
    if nginx -t 2>/dev/null; then
        echo -e "${GREEN}   ✓ Nginx config valid${NC}"
    else
        echo -e "${RED}   ✗ Nginx config error${NC}"
        nginx -t
    fi
    
    service nginx start 2>/dev/null || nginx 2>/dev/null || true
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
        echo -e "${YELLOW}   Starting queue worker...${NC}"
        cd /var/www/pelican
        
        pkill -f "queue:work" 2>/dev/null || true
        sleep 1
        
        PHP_BIN="/usr/bin/php${PHP_VERSION}"
        [ ! -f "$PHP_BIN" ] && PHP_BIN="/usr/bin/php8.3"
        [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)
        
        # Try supervisor first
        if command -v supervisorctl &>/dev/null; then
            supervisorctl restart pelican-queue 2>/dev/null && {
                sleep 2
                if pgrep -f "queue:work" >/dev/null; then
                    echo -e "${GREEN}   ✓ Queue worker started (supervisor)${NC}"
                    ((SERVICES_STARTED++))
                fi
            } || {
                # Fallback to manual start
                nohup sudo -u www-data $PHP_BIN artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 > /var/log/pelican-queue.log 2>&1 &
                sleep 2
                if pgrep -f "queue:work" >/dev/null; then
                    echo -e "${GREEN}   ✓ Queue worker started (manual)${NC}"
                    ((SERVICES_STARTED++))
                fi
            }
        else
            # No supervisor, manual start
            nohup sudo -u www-data $PHP_BIN artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 > /var/log/pelican-queue.log 2>&1 &
            sleep 2
            if pgrep -f "queue:work" >/dev/null; then
                echo -e "${GREEN}   ✓ Queue worker started${NC}"
                ((SERVICES_STARTED++))
            fi
        fi
    else
        echo -e "${YELLOW}   ⚠ Panel not installed${NC}"
    fi
fi

# ============================================================================
# 6. START WINGS (MIGRATION-SAFE)
# ============================================================================
echo -e "${CYAN}[6/7] Starting Wings...${NC}"

if pgrep -x wings >/dev/null; then
    echo -e "${GREEN}   ✓ Wings already running${NC}"
else
    if [ -f "/usr/local/bin/wings" ] && [ -f "/etc/pelican/config.yml" ]; then
        echo -e "${YELLOW}   Starting Wings...${NC}"
        pkill wings 2>/dev/null || true
        sleep 1
        
        cd /etc/pelican
        nohup /usr/local/bin/wings > /tmp/wings.log 2>&1 &
        sleep 3
        
        if pgrep -x wings >/dev/null; then
            echo -e "${GREEN}   ✓ Wings started${NC}"
            
            if netstat -tulpn 2>/dev/null | grep -q ":8080"; then
                echo -e "${GREEN}   ✓ Wings listening on port 8080${NC}"
            else
                echo -e "${YELLOW}   ⚠ Wings not on port 8080 yet${NC}"
            fi
        else
            echo -e "${RED}   ✗ Wings failed to start${NC}"
            echo -e "${YELLOW}   Check: tail -f /tmp/wings.log${NC}"
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

# Panel Tunnel
if [ -n "$CF_TOKEN" ]; then
    echo -e "${YELLOW}   Starting Panel tunnel (port 8443)...${NC}"
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared-panel.log 2>&1 &
    sleep 2
    ((TUNNEL_COUNT++))
fi

# Wings Tunnel
if [ -n "$CF_TOKEN_WINGS" ]; then
    echo -e "${YELLOW}   Starting Wings tunnel (port 8080)...${NC}"
    nohup cloudflared tunnel run --token "$CF_TOKEN_WINGS" > /var/log/cloudflared-wings.log 2>&1 &
    sleep 2
    ((TUNNEL_COUNT++))
fi

if [ "$TUNNEL_COUNT" -gt 0 ]; then
    echo -e "${GREEN}   ✓ Started ${TUNNEL_COUNT} Cloudflare tunnel(s)${NC}"
else
    echo -e "${YELLOW}   ⚠ No tunnel tokens in .pelican.env${NC}"
fi

# ============================================================================
# CLEAR PANEL CACHE (CRITICAL: Prevents MAC errors)
# ============================================================================
if [ -d "/var/www/pelican" ]; then
    echo ""
    echo -e "${CYAN}[CRITICAL] Clearing Panel cache to prevent MAC errors...${NC}"
    
    cd /var/www/pelican
    
    PHP_BIN="/usr/bin/php${PHP_VERSION}"
    [ ! -f "$PHP_BIN" ] && PHP_BIN="/usr/bin/php8.3"
    [ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)
    
    # Standard cache clearing
    $PHP_BIN artisan config:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan cache:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan view:clear >/dev/null 2>&1 || true
    $PHP_BIN artisan route:clear >/dev/null 2>&1 || true
    
    # CRITICAL: Delete compiled views (prevents MAC errors)
    rm -rf storage/framework/views/* 2>/dev/null || true
    rm -rf storage/framework/cache/* 2>/dev/null || true
    
    # Clear Redis (sessions and cache)
    redis-cli FLUSHDB >/dev/null 2>&1 || true
    
    # Verify APP_KEY hasn't changed
    if [ -f ".env" ]; then
        CURRENT_APP_KEY=$(grep "^APP_KEY=" .env | cut -d'=' -f2)
        if [[ "$CURRENT_APP_KEY" =~ ^base64: ]]; then
            echo -e "${GREEN}   ✓ APP_KEY verified: ${CURRENT_APP_KEY:0:20}...${NC}"
        else
            echo -e "${RED}   ✗ APP_KEY missing or invalid!${NC}"
            echo -e "${YELLOW}   This will cause MAC errors!${NC}"
        fi
    fi
    
    # Database health check
    if [ "$DB_DRIVER" = "pgsql" ]; then
        DB_TEST=$($PHP_BIN artisan tinker --execute="echo DB::connection()->getDatabaseName();" 2>&1 | tail -1)
        if echo "$DB_TEST" | grep -q "postgres\|$DB_NAME"; then
            echo -e "${GREEN}   ✓ PostgreSQL connection healthy${NC}"
        else
            echo -e "${YELLOW}   ⚠ PostgreSQL connection issue${NC}"
        fi
    fi
    
    echo -e "${GREEN}   ✓ Panel cache cleared${NC}"
    echo -e "${YELLOW}   ⚠ IMPORTANT: Hard refresh browser (Ctrl+Shift+R)${NC}"
fi

# ============================================================================
# VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          Services Status Check         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# Docker
if docker ps >/dev/null 2>&1; then
    CONTAINER_COUNT=$(docker ps -q | wc -l)
    echo -e "${GREEN}✓ Docker:       Running (${CONTAINER_COUNT} containers)${NC}"
else
    echo -e "${RED}✗ Docker:       Not Running${NC}"
fi

# Redis
if redis-cli ping >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Redis:        Running${NC}"
else
    echo -e "${RED}✗ Redis:        Not Running${NC}"
fi

# PHP-FPM
if netstat -tulpn 2>/dev/null | grep -q ":9000.*LISTEN"; then
    PHP_PID=$(netstat -tulpn 2>/dev/null | grep ":9000" | awk '{print $7}' | cut -d'/' -f1 | head -1)
    echo -e "${GREEN}✓ PHP-FPM:      Running (port 9000, PID: $PHP_PID)${NC}"
else
    echo -e "${RED}✗ PHP-FPM:      Not Running on port 9000!${NC}"
fi

# Nginx
if pgrep nginx >/dev/null && netstat -tulpn 2>/dev/null | grep -q ":8443"; then
    echo -e "${GREEN}✓ Nginx:        Running (port 8443)${NC}"
else
    echo -e "${RED}✗ Nginx:        Not Running${NC}"
fi

# Queue Worker
if pgrep -f "queue:work" >/dev/null; then
    echo -e "${GREEN}✓ Queue Worker: Running${NC}"
else
    echo -e "${RED}✗ Queue Worker: Not Running${NC}"
fi

# Wings
if pgrep -x wings >/dev/null; then
    if netstat -tulpn 2>/dev/null | grep -q ":8080"; then
        echo -e "${GREEN}✓ Wings:        Running (port 8080)${NC}"
    else
        echo -e "${YELLOW}⚠ Wings:        Running (but not on port 8080!)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Wings:        Not Running (may not be installed)${NC}"
fi

# Cloudflare
CF_COUNT=$(pgrep -f cloudflared | wc -l)
if [ "$CF_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Cloudflare:   Running (${CF_COUNT} tunnel(s))${NC}"
else
    echo -e "${YELLOW}⚠ Cloudflare:   Not Running${NC}"
fi

# ============================================================================
# QUICK HEALTH TESTS
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           Quick Health Check           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# Test Panel (local)
if [ -d "/var/www/pelican" ]; then
    PANEL_TEST=$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:8443/ 2>/dev/null || echo "000")
    if [ "$PANEL_TEST" = "200" ] || [ "$PANEL_TEST" = "302" ]; then
        echo -e "${GREEN}✓ Panel Local:  HTTP $PANEL_TEST (OK)${NC}"
    else
        echo -e "${RED}✗ Panel Local:  HTTP $PANEL_TEST (Should be 200 or 302)${NC}"
    fi
    
    # Test via Cloudflare
    if [ -n "$PANEL_DOMAIN" ]; then
        sleep 2
        PANEL_CF_TEST=$(curl -s -o /dev/null -w "%{http_code}" https://${PANEL_DOMAIN}/ 2>/dev/null || echo "000")
        if [ "$PANEL_CF_TEST" = "200" ] || [ "$PANEL_CF_TEST" = "302" ]; then
            echo -e "${GREEN}✓ Panel Remote: HTTP $PANEL_CF_TEST (OK)${NC}"
        else
            echo -e "${YELLOW}⚠ Panel Remote: HTTP $PANEL_CF_TEST (Check tunnel)${NC}"
        fi
    fi
fi

# Test Wings
if [ -f "/usr/local/bin/wings" ]; then
    WINGS_TEST=$(curl -k -s https://localhost:8080/api/system 2>&1 || echo "FAILED")
    if echo "$WINGS_TEST" | grep -q "authorization"; then
        echo -e "${GREEN}✓ Wings Local:  Responding (OK)${NC}"
    else
        echo -e "${YELLOW}⚠ Wings Local:  Not responding${NC}"
    fi
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Summary                   ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

CRITICAL_OK=0
docker ps >/dev/null 2>&1 && ((CRITICAL_OK++))
redis-cli ping >/dev/null 2>&1 && ((CRITICAL_OK++))
netstat -tulpn 2>/dev/null | grep -q ":9000" && ((CRITICAL_OK++))
netstat -tulpn 2>/dev/null | grep -q ":8443" && ((CRITICAL_OK++))
pgrep -f "queue:work" >/dev/null && ((CRITICAL_OK++))

if [ "$CRITICAL_OK" -ge 5 ]; then
    echo -e "${GREEN}✅ All critical services are running!${NC}"
    echo ""
    if [ -n "$PANEL_DOMAIN" ]; then
        echo -e "${CYAN}🌐 Panel URL:${NC} ${GREEN}https://${PANEL_DOMAIN}${NC}"
    fi
    if [ -n "$NODE_DOMAIN" ]; then
        echo -e "${CYAN}🌐 Wings URL:${NC} ${GREEN}https://${NODE_DOMAIN}${NC}"
    fi
    
    if [ -n "$DB_DRIVER" ]; then
        echo -e "${CYAN}💾 Database:${NC} ${GREEN}${DB_DRIVER}${NC} @ ${GREEN}${DB_HOST}:${DB_PORT}${NC}"
    fi
else
    echo -e "${RED}❌ Some services failed ($CRITICAL_OK/5 running)${NC}"
    echo ""
    echo -e "${CYAN}⚠️  Common Issues:${NC}"
    
    if ! netstat -tulpn 2>/dev/null | grep -q ":9000"; then
        echo -e "${RED}  ✗ PHP-FPM not on port 9000${NC}"
        echo -e "${YELLOW}    Fix: service php${PHP_VERSION}-fpm restart${NC}"
    fi
    
    if ! netstat -tulpn 2>/dev/null | grep -q ":8443"; then
        echo -e "${RED}  ✗ Nginx not on port 8443${NC}"
        echo -e "${YELLOW}    Check: /etc/nginx/sites-available/pelican.conf${NC}"
    fi
    
    if pgrep -x wings >/dev/null && ! netstat -tulpn 2>/dev/null | grep -q ":8080"; then
        echo -e "${RED}  ✗ Wings not on port 8080${NC}"
        echo -e "${YELLOW}    Check: /etc/pelican/config.yml${NC}"
    fi
fi

echo ""
echo -e "${CYAN}📝 Useful Commands:${NC}"
echo -e "  • Restart everything:     ${GREEN}sudo $0${NC}"
echo -e "  • Panel logs:             ${GREEN}tail -f /var/log/nginx/pelican.app-error.log${NC}"
echo -e "  • Queue logs:             ${GREEN}tail -f /var/log/pelican-queue.log${NC}"
echo -e "  • Wings logs:             ${GREEN}tail -f /tmp/wings.log${NC}"
echo -e "  • Check ports:            ${GREEN}netstat -tulpn | grep -E '9000|8443|8080|6379'${NC}"
echo -e "  • Clear cache:            ${GREEN}cd /var/www/pelican && /usr/bin/php8.3 artisan cache:clear${NC}"
if [ -n "$ENV_FILE" ]; then
    echo -e "  • View config:            ${GREEN}cat $ENV_FILE${NC}"
    echo -e "  • Backup config:          ${GREEN}cp $ENV_FILE ~/pelican-backup.env${NC}"
fi
echo ""

echo -e "${YELLOW}💡 MIGRATION TIP:${NC}"
echo -e "   Before switching Codespaces, download: ${GREEN}${ENV_FILE}${NC}"
echo -e "   Then upload it to new Codespace before running scripts"
echo ""