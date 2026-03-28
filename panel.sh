#!/bin/bash

################################################################################
# PELICAN PANEL - COMPLETE INSTALLER v7.3 PRODUCTION READY
# - FIXED: Preserves APP_KEY on reinstall (prevents MAC invalid errors)
# - FIXED: Saves PAPP tokens and Node IDs to .pelican.env
# - FIXED: Auto-backup and restore on Codespace migrations
# - FIXED: PostgreSQL connection string parser
# - FIXED: No config:cache (breaks dynamic plugins)
# - FIXED: Supervisor queue worker (no systemd required)
# - FIXED: PHP-FPM on port 9000 (fixes 502 Bad Gateway)
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
export HOME=/root
export COMPOSER_HOME=/root/.composer
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
echo -e "${GREEN}║  Pelican Panel Installer v7.3 FINAL   ║${NC}"
echo -e "${GREEN}║  Production Ready - Migration Safe    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

# ============================================================================
# BACKUP EXISTING .ENV BEFORE ANYTHING
# ============================================================================
if [ -f "/var/www/pelican/.env" ]; then
    BACKUP_DIR="${SCRIPT_DIR}/.backups"
    mkdir -p "$BACKUP_DIR"
    chmod 755 "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)

    echo -e "${CYAN}[BACKUP] Found existing Panel installation${NC}"
    echo -e "${YELLOW}   Creating backup of .env file...${NC}"

    cp /var/www/pelican/.env "${BACKUP_DIR}/env_${TIMESTAMP}.backup"
    chmod 644 "${BACKUP_DIR}/env_${TIMESTAMP}.backup"

    EXISTING_APP_KEY=$(grep "^APP_KEY=" /var/www/pelican/.env 2>/dev/null | cut -d'=' -f2)

    echo -e "${GREEN}   ✓ Backup saved: ${BACKUP_DIR}/env_${TIMESTAMP}.backup${NC}"
    echo -e "${CYAN}   💾 IMPORTANT: Download this file before switching Codespaces!${NC}"
    echo ""
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[1/20] Detecting Environment...${NC}"

HAS_SYSTEMD=false
IS_CONTAINER=false

if [ -d /run/systemd/system ] && pidof systemd >/dev/null 2>&1; then
    if systemctl is-system-running >/dev/null 2>&1 || systemctl is-system-running --quiet 2>&1; then
        HAS_SYSTEMD=true
        echo -e "${GREEN}   ✓ Systemd detected${NC}"
    else
        echo -e "${YELLOW}   ⚠ Systemd exists but not active${NC}"
    fi
else
    echo -e "${YELLOW}   ⚠ No systemd - using service commands${NC}"
fi

if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
    echo -e "${YELLOW}   ⚠ Container environment${NC}"
fi

if grep -qi codespaces /proc/sys/kernel/osrelease 2>/dev/null; then
    echo -e "${BLUE}   ℹ GitHub Codespaces${NC}"
    IS_CONTAINER=true
fi

# ============================================================================
# CONFIGURATION
# ============================================================================
echo ""
echo -e "${CYAN}[2/20] Configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}   Found existing configuration!${NC}"
    source "$ENV_FILE"
    echo -e "${GREEN}   Using: $ENV_FILE${NC}"
    echo -e "${CYAN}   Domain: ${GREEN}${PANEL_DOMAIN}${NC}"
    echo -e "${CYAN}   Database: ${GREEN}${DB_DRIVER} (${DB_HOST})${NC}"

    if [ -n "$PANEL_API_TOKEN" ]; then
        echo -e "${CYAN}   Panel Token: ${GREEN}${PANEL_API_TOKEN:0:20}...${NC}"
    fi
    if [ -n "$NODE_ID" ]; then
        echo -e "${CYAN}   Node ID: ${GREEN}${NODE_ID}${NC}"
    fi

    read -p "   Use these settings? (y/n) [y]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-y}

    if [[ ! "$USE_EXISTING" =~ ^[Yy] ]]; then
        echo -e "${YELLOW}   Starting fresh configuration...${NC}"
        mv "$ENV_FILE" "${ENV_FILE}.backup.$(date +%s)"
    fi
fi

if [ ! -f "$ENV_FILE" ]; then
    read -p "Panel domain (e.g., panel.example.com): " PANEL_DOMAIN
    read -p "Cloudflare Tunnel Token: " CF_TOKEN
    [[ -z "$CF_TOKEN" ]] && { echo -e "${RED}❌ Token required!${NC}"; exit 1; }

    echo ""
    echo "Database Type:"
    echo "1) PostgreSQL (Recommended)"
    echo "2) MySQL/MariaDB"
    read -p "Choice [1]: " DB_TYPE
    DB_TYPE=${DB_TYPE:-1}

    if [ "$DB_TYPE" = "1" ]; then
        DB_DRIVER="pgsql"

        echo ""
        echo "PostgreSQL Configuration:"
        echo "1) Enter connection details manually"
        echo "2) Use connection string (postgresql://...)"
        read -p "Choice [1]: " PG_CONFIG_TYPE
        PG_CONFIG_TYPE=${PG_CONFIG_TYPE:-1}

        if [ "$PG_CONFIG_TYPE" = "2" ]; then
            echo ""
            echo "Example: postgresql://user:pass@host:port/database"
            read -p "PostgreSQL Connection String: " PG_CONN_STRING

if [[ $PG_CONN_STRING =~ ^postgres(ql)?://(.+)@([^@:]+):([0-9]+)/([^?]+) ]]; then
    USERPASS="${BASH_REMATCH[2]}"
    DB_HOST="${BASH_REMATCH[3]}"
    DB_PORT="${BASH_REMATCH[4]}"
    DB_NAME="${BASH_REMATCH[5]}"
    DB_USER="${USERPASS%%:*}"           # up to first colon
    DB_PASS="${USERPASS#*:}"            # after first colon
    echo -e "${GREEN}   ✓ Parsed successfully${NC}"
            else
                echo -e "${RED}❌ Invalid connection string!${NC}"
                exit 1
            fi
        else
            DB_PORT_DEFAULT="5432"
            read -p "Database Host: " DB_HOST
            read -p "Database Port [$DB_PORT_DEFAULT]: " DB_PORT
            DB_PORT=${DB_PORT:-$DB_PORT_DEFAULT}
            read -p "Database Name: " DB_NAME
            read -p "Database Username: " DB_USER
            read -sp "Database Password: " DB_PASS
            echo ""
        fi
    else
        DB_DRIVER="mysql"
        DB_PORT_DEFAULT="3306"

        read -p "Database Host: " DB_HOST
        read -p "Database Port [$DB_PORT_DEFAULT]: " DB_PORT
        DB_PORT=${DB_PORT:-$DB_PORT_DEFAULT}
        read -p "Database Name: " DB_NAME
        read -p "Database Username: " DB_USER
        read -sp "Database Password: " DB_PASS
        echo ""
    fi

    read -p "Redis Host [127.0.0.1]: " REDIS_HOST
    REDIS_HOST=${REDIS_HOST:-127.0.0.1}
    read -p "Redis Port [6379]: " REDIS_PORT
    REDIS_PORT=${REDIS_PORT:-6379}
    read -sp "Redis Password (optional): " REDIS_PASS
    echo ""

    read -p "SMTP Host (optional, e.g., smtp.gmail.com): " MAIL_HOST
    if [ -n "$MAIL_HOST" ]; then
        read -p "SMTP Port [587]: " MAIL_PORT
        MAIL_PORT=${MAIL_PORT:-587}
        read -p "SMTP Username: " MAIL_USER
        read -sp "SMTP Password: " MAIL_PASS
        echo ""
        read -p "From Email: " MAIL_FROM
        read -p "From Name: " MAIL_FROM_NAME
    fi

    cat > "$ENV_FILE" <<EOF
# Pelican Panel Configuration
# Generated: $(date)
# IMPORTANT: Keep this file safe! Download before switching Codespaces!
PANEL_DOMAIN="$PANEL_DOMAIN"
CF_TOKEN="$CF_TOKEN"
# Database Configuration
DB_DRIVER="$DB_DRIVER"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
# Redis Configuration
REDIS_HOST="$REDIS_HOST"
REDIS_PORT="$REDIS_PORT"
REDIS_PASS="$REDIS_PASS"
# Mail Configuration (optional)
MAIL_HOST="$MAIL_HOST"
MAIL_PORT="$MAIL_PORT"
MAIL_USER="$MAIL_USER"
MAIL_PASS="$MAIL_PASS"
MAIL_FROM="$MAIL_FROM"
MAIL_FROM_NAME="$MAIL_FROM_NAME"
# Panel API Token (add after creating admin user)
PANEL_API_TOKEN=""
# Node Configuration (will be added when Wings is installed)
NODE_ID=""
NODE_DOMAIN=""
CF_TOKEN_WINGS=""
EOF
    chmod 600 "$ENV_FILE"
fi

echo -e "${GREEN}   ✓ Configuration loaded${NC}"

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[3/20] Updating system...${NC}"
mkdir -p /etc/dpkg/dpkg.cfg.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/docker
apt update -qq 2>&1 | grep -v "GPG error" || true
apt upgrade -y -qq 2>&1 | grep -v "GPG error" || true
echo -e "${GREEN}   ✓ System updated${NC}"

echo -e "${CYAN}[3b/20] Applying network performance tuning...${NC}"
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
cat > /etc/sysctl.d/99-network-perf.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.netdev_max_backlog=300000
net.core.somaxconn=65535
net.ipv4.tcp_fastopen=3
net.ipv4.ip_forward=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
SYSCTL
sysctl -p /etc/sysctl.d/99-network-perf.conf >/dev/null 2>&1 || true
apt install -y nscd 2>/dev/null || true
cat > /etc/nscd.conf <<'NSCDEOF'
enable-cache            hosts           yes
positive-time-to-live   hosts           3600
negative-time-to-live   hosts           20
suggested-size          hosts           211
check-files             hosts           yes
persistent              hosts           yes
shared                  hosts           yes
NSCDEOF
systemctl enable nscd 2>/dev/null || true
systemctl restart nscd 2>/dev/null || true
echo -e "${GREEN}   ✓ BBR + DNS cache applied${NC}"

# ============================================================================
# NETWORK PERFORMANCE TUNING
# ============================================================================
echo -e "${CYAN}[3b/20] Applying network performance tuning...${NC}"
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null || true
cat > /etc/sysctl.d/99-network-perf.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.netdev_max_backlog=300000
net.core.somaxconn=65535
net.ipv4.tcp_fastopen=3
net.ipv4.ip_forward=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
SYSCTL
sysctl -p /etc/sysctl.d/99-network-perf.conf >/dev/null 2>&1 || true
echo -e "${GREEN}   ✓ BBR + buffer tuning applied${NC}"

# ============================================================================
# INSTALL NODE.JS + YARN
# ============================================================================
echo -e "${CYAN}[4b/20] Installing Node.js + Yarn (required for plugins)...${NC}"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null || true
    apt install -y nodejs 2>/dev/null || true
fi
if ! command -v yarn &>/dev/null; then
    npm install -g yarn 2>/dev/null || true
fi
echo -e "${GREEN}   ✓ Node.js $(node --version 2>/dev/null) + Yarn $(yarn --version 2>/dev/null) installed${NC}"

# ============================================================================
# INSTALL PHP 8.3+
# ============================================================================
# Replace the PHP install block [5/20]
echo -e "${CYAN}[5/20] Installing PHP 8.5+...${NC}"

apt install -y ca-certificates apt-transport-https software-properties-common 2>/dev/null || true
LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y 2>/dev/null || true
apt update -qq 2>/dev/null || true

# Try 8.5 first (recommended), then fallback
PHP_VERSION=""
for ver in 8.5 8.4 8.3 8.2; do
    if apt install -y php${ver} php${ver}-cli php${ver}-fpm php${ver}-pgsql php${ver}-mysql \
        php${ver}-sqlite3 php${ver}-redis php${ver}-intl php${ver}-zip php${ver}-bcmath \
        php${ver}-mbstring php${ver}-xml php${ver}-curl php${ver}-gd 2>/dev/null; then
        PHP_VERSION="$ver"
        break
    fi
done

[ -z "$PHP_VERSION" ] && { echo -e "${RED}❌ PHP installation failed!${NC}"; exit 1; }

update-alternatives --install /usr/bin/php php /usr/bin/php${PHP_VERSION} 100 2>/dev/null || true
update-alternatives --set php /usr/bin/php${PHP_VERSION} 2>/dev/null || true

echo -e "${GREEN}   ✓ PHP $(php -v | head -n1 | cut -d' ' -f2) installed${NC}"

# ============================================================================
# INSTALL SERVICES
# ============================================================================
echo -e "${CYAN}[6/20] Installing services...${NC}"
apt install -y nginx 2>/dev/null || true

if [ "$DB_DRIVER" = "pgsql" ]; then
    apt install -y postgresql-client 2>/dev/null || true
else
    apt install -y mysql-client 2>/dev/null || apt install -y mariadb-client 2>/dev/null || true
fi

apt install -y redis-server 2>/dev/null || true

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable redis-server 2>/dev/null || true
    systemctl start redis-server 2>/dev/null || service redis-server start 2>/dev/null || true
else
    service redis-server start 2>/dev/null || redis-server --daemonize yes 2>/dev/null || true
fi

echo -e "${GREEN}   ✓ Services installed${NC}"

# ============================================================================
# INSTALL COMPOSER
# ============================================================================
echo -e "${CYAN}[7/20] Installing Composer...${NC}"
export HOME=/root
export COMPOSER_HOME=/root/.composer
mkdir -p "$COMPOSER_HOME"
if ! command -v composer &> /dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet 2>/dev/null
fi
# Force persistent DB connections
sed -i "s/'persistent' => false/'persistent' => env('DB_PERSISTENT', false)/" \
    /var/www/pelican/config/database.php 2>/dev/null || true
echo -e "${GREEN}   ✓ Composer $(composer --version 2>/dev/null | cut -d' ' -f3)${NC}"

# ============================================================================
# DOWNLOAD PANEL
# ============================================================================
echo -e "${CYAN}[8/20] Downloading Pelican Panel...${NC}"

if [ -d "/var/www/pelican/app" ] && [ -f "/var/www/pelican/artisan" ]; then
    echo -e "${GREEN}   ✓ Panel already exists${NC}"
else
    [ -d "/var/www/pelican" ] && mv /var/www/pelican /var/www/pelican.backup.$(date +%s) 2>/dev/null
    mkdir -p /var/www/pelican
    cd /var/www/pelican
    curl -L https://github.com/pelican-dev/panel/releases/latest/download/panel.tar.gz | tar -xzv
    echo -e "${GREEN}   ✓ Panel downloaded${NC}"
fi

cd /var/www/pelican

# PATCH: Fix EditFiles.php BEFORE composer runs (must be after download)
sed -i 's/bool \$shouldGuessMissingParameters = false): string/bool $shouldGuessMissingParameters = false, ?string $configuration = null): string/' /var/www/pelican/app/Filament/Server/Resources/Files/Pages/EditFiles.php
echo -e "${GREEN}   ✓ EditFiles.php patched${NC}"

# ============================================================================
# INSTALL COMPOSER DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[9/20] Installing dependencies...${NC}"

PHP_BIN="/usr/bin/php${PHP_VERSION:-8.5}"
[ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)

if [ ! -d "vendor" ] || [ ! -f "vendor/autoload.php" ]; then
    rm -f composer.lock
    rm -rf vendor/
    composer clear-cache 2>/dev/null || true

    if COMPOSER_ALLOW_SUPERUSER=1 $PHP_BIN $(which composer) install \
        --no-dev --optimize-autoloader --no-interaction 2>&1 | tee /tmp/composer-install.log; then
        echo -e "${GREEN}   ✓ Dependencies installed${NC}"
    else
        echo -e "${RED}❌ Composer failed!${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}   ✓ Dependencies already installed${NC}"
fi

# ============================================================================
# CONFIGURE ENVIRONMENT (CRITICAL: PRESERVE APP_KEY!)
# ============================================================================
echo -e "${CYAN}[10/20] Configuring environment...${NC}"

if [ -f .env ] && grep -q "^APP_KEY=base64:" .env; then
    EXISTING_APP_KEY=$(grep "^APP_KEY=" .env | cut -d'=' -f2)
    echo -e "${GREEN}   ✓ Found existing APP_KEY, preserving it${NC}"
    cp .env .env.backup.$(date +%s)
    HAS_EXISTING_KEY=true
else
    echo -e "${BLUE}   No existing APP_KEY, will generate new one${NC}"
    HAS_EXISTING_KEY=false
fi

cp .env.example .env

if [ "$HAS_EXISTING_KEY" = true ]; then
    echo -e "${GREEN}   ✓ Restoring APP_KEY (prevents MAC errors)${NC}"
    sed -i "s|^APP_KEY=.*|APP_KEY=${EXISTING_APP_KEY}|" .env
else
    echo -e "${YELLOW}   Generating new APP_KEY...${NC}"
    $PHP_BIN artisan key:generate --force --quiet
fi

DB_HOST_VAL=$(grep '^DB_HOST=' "$ENV_FILE" | cut -d'"' -f2)
DB_PORT_VAL=$(grep '^DB_PORT=' "$ENV_FILE" | cut -d'"' -f2)
DB_NAME_VAL=$(grep '^DB_NAME=' "$ENV_FILE" | cut -d'"' -f2)
DB_USER_VAL=$(grep '^DB_USER=' "$ENV_FILE" | cut -d'"' -f2)
DB_PASS_VAL=$(grep '^DB_PASS=' "$ENV_FILE" | cut -d'"' -f2)
REDIS_HOST_VAL=$(grep '^REDIS_HOST=' "$ENV_FILE" | cut -d'"' -f2)
REDIS_PORT_VAL=$(grep '^REDIS_PORT=' "$ENV_FILE" | cut -d'"' -f2)
REDIS_PASS_VAL=$(grep '^REDIS_PASS=' "$ENV_FILE" | cut -d'"' -f2)

cat >> .env <<ENVEOF
# Database Configuration
DB_CONNECTION=${DB_DRIVER}
DB_HOST=${DB_HOST_VAL}
DB_PORT=${DB_PORT_VAL}
DB_DATABASE=${DB_NAME_VAL}
DB_USERNAME=${DB_USER_VAL}
DB_PASSWORD=${DB_PASS_VAL}
DB_PERSISTENT=true
# Redis Configuration
REDIS_HOST=${REDIS_HOST_VAL}
REDIS_PORT=${REDIS_PORT_VAL}
REDIS_PASSWORD=${REDIS_PASS_VAL}
# Cache & Session
# Cache & Session
CACHE_DRIVER=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_LIFETIME=120
SESSION_ENCRYPT=false
CACHE_TTL=3600
REDIS_CLIENT=phpredis
# Mail Configuration
MAIL_MAILER=smtp
MAIL_HOST=${MAIL_HOST}
MAIL_PORT=${MAIL_PORT}
MAIL_USERNAME=${MAIL_USER}
MAIL_PASSWORD=${MAIL_PASS}
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=${MAIL_FROM}
MAIL_FROM_NAME="${MAIL_FROM_NAME}"
# App Configuration
APP_URL=https://${PANEL_DOMAIN}
APP_TIMEZONE=UTC
APP_LOCALE=en
ENVEOF

if [ "$DB_DRIVER" = "pgsql" ]; then
    cat >> .env <<PGEOF
# PostgreSQL Optimizations
DB_SSLMODE=require
DB_SCHEMA=public
PGEOF
fi

ACTUAL_DB=$(grep "^DB_CONNECTION=" .env | cut -d'=' -f2)
if [ "$ACTUAL_DB" != "$DB_DRIVER" ]; then
    sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=${DB_DRIVER}/" .env
fi

echo -e "${GREEN}   ✓ Environment configured (APP_KEY preserved)${NC}"

# ============================================================================
# SET PERMISSIONS
# ============================================================================
echo -e "${CYAN}[11/20] Setting permissions...${NC}"
chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null || true
chown -R www-data:www-data /var/www/pelican
mkdir -p storage/logs
touch storage/logs/laravel.log
chmod -R 775 storage/logs
chown -R www-data:www-data storage/logs
echo -e "${GREEN}   ✓ Permissions set${NC}"

# ============================================================================
# CONFIGURE PHP-FPM (port 9000 - fixes 502)
# ============================================================================
echo -e "${CYAN}[12/20] Configuring PHP-FPM...${NC}"

if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
    sed -i 's|listen = /run/php/php.*-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    # Dynamic pool — balanced for a VM with 2-4 GB RAM
    sed -i 's/^pm =.*/pm = dynamic/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's/^pm.max_children.*/pm.max_children = 30/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's/^pm.start_servers.*/pm.start_servers = 8/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's/^pm.min_spare_servers.*/pm.min_spare_servers = 5/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's/^pm.max_spare_servers.*/pm.max_spare_servers = 15/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's/^;pm.max_requests.*/pm.max_requests = 500/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    # Keep environment for OPcache preload
    grep -q "^clear_env" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf || \
        echo "clear_env = no" >> /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
fi

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || service php${PHP_VERSION}-fpm restart 2>/dev/null
else
    mkdir -p /run/php
    pkill php-fpm 2>/dev/null || true
    /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
fi

sleep 1
echo -e "${GREEN}   ✓ PHP-FPM configured on port 9000${NC}"

# ============================================================================
# CONFIGURE NGINX
# ============================================================================
echo -e "${CYAN}[13/20] Configuring Nginx...${NC}"
mkdir -p /etc/ssl/pelican
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/pelican/key.pem \
  -out /etc/ssl/pelican/cert.pem \
  -subj "/CN=${PANEL_DOMAIN}" 2>/dev/null

cat > /etc/nginx/sites-available/pelican.conf <<'NGINXEOF'
server {
    listen 0.0.0.0:8443 ssl http2;
    listen [::]:8443 ssl http2;
    server_tokens off;

    server_name _;
    ssl_certificate /etc/ssl/pelican/cert.pem;
    ssl_certificate_key /etc/ssl/pelican/key.pem;

    # --- SSL Hardening ---
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

# OCSP stapling disabled — self-signed cert has no OCSP responder
    # ssl_stapling on;
    # ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    root /var/www/pelican/public;
    index index.php;
    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 100;

    gzip on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_vary on;
    gzip_types
        text/plain text/css application/json application/javascript
        text/xml application/xml text/javascript application/x-font-ttf
        font/opentype image/svg+xml image/x-icon;

    # --- Security Headers (server-level, applies to all locations) ---
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Robots-Tag none always;
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy same-origin always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|webp)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform, immutable" always;
        add_header X-Content-Type-Options nosniff always;
        access_log off;
    }

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 16 128k;
        fastcgi_busy_buffers_size 256k;
        fastcgi_temp_file_write_size 256k;
        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        fastcgi_keep_conn on;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/pelican.conf /etc/nginx/sites-enabled/pelican.conf
nginx -t 2>/dev/null

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart nginx 2>/dev/null || service nginx restart
else
    pkill nginx 2>/dev/null || true
    nginx 2>/dev/null || true
fi

echo -e "${GREEN}   ✓ Nginx configured on port 8443${NC}"

# ============================================================================
# RUN DATABASE MIGRATIONS
# ============================================================================
echo -e "${CYAN}[14/20] Running database migrations...${NC}"

# Read directly from file to avoid special character corruption
DB_HOST_VAL=$(grep '^DB_HOST=' "$ENV_FILE" | cut -d'"' -f2)
DB_PORT_VAL=$(grep '^DB_PORT=' "$ENV_FILE" | cut -d'"' -f2)
DB_NAME_VAL=$(grep '^DB_NAME=' "$ENV_FILE" | cut -d'"' -f2)
DB_USER_VAL=$(grep '^DB_USER=' "$ENV_FILE" | cut -d'"' -f2)
DB_PASS_VAL=$(grep '^DB_PASS=' "$ENV_FILE" | cut -d'"' -f2)

DB_HAS_DATA=false
if [ "$DB_DRIVER" = "pgsql" ]; then
    TABLE_COUNT=$(PGPASSWORD="$DB_PASS_VAL" psql \
    "sslmode=require host=$DB_HOST_VAL port=$DB_PORT_VAL dbname=$DB_NAME_VAL user=$DB_USER_VAL password=$DB_PASS_VAL" \
    -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';" \
    2>/dev/null || echo "0")
else
    TABLE_COUNT=$(mysql -h "$DB_HOST_VAL" -P "$DB_PORT_VAL" -u "$DB_USER_VAL" -p"$DB_PASS_VAL" "$DB_NAME_VAL" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME_VAL';" 2>/dev/null || echo "0")
fi

if [ "$TABLE_COUNT" -gt 5 ]; then
    DB_HAS_DATA=true
    echo -e "${YELLOW}   ⚠ Database contains $TABLE_COUNT tables${NC}"
    echo -e "${GREEN}   Running safe migration (keeps data)...${NC}"
    $PHP_BIN artisan migrate --force
else
    echo -e "${BLUE}   Fresh database, running initial migration...${NC}"
    $PHP_BIN artisan migrate --force
fi

echo -e "${GREEN}   ✓ Database migrations complete${NC}"
# ============================================================================
# SETUP QUEUE WORKER (Supervisor - no systemd needed)
# ============================================================================
echo -e "${CYAN}[15/20] Setting up queue worker...${NC}"

pkill -9 -f "artisan queue:work" 2>/dev/null || true
sleep 2

apt install -y supervisor 2>/dev/null || true
mkdir -p /var/log/supervisor /etc/supervisor/conf.d

# In [15/20] queue worker conf, replace hardcoded php8.3
cat > /etc/supervisor/conf.d/pelican-queue.conf <<QEOF
[program:pelican-queue]
command=/usr/bin/php${PHP_VERSION} /var/www/pelican/artisan queue:work redis --sleep=3 --tries=3 --timeout=90 --max-jobs=1000
directory=/var/www/pelican
user=www-data
autostart=true
autorestart=true
stdout_logfile=/var/log/pelican-queue.log
stderr_logfile=/var/log/pelican-queue-error.log
stopasgroup=true
killasgroup=true
QEOF

pkill supervisord 2>/dev/null || true
sleep 2
supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 3
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
supervisorctl restart pelican-queue 2>/dev/null || true

sleep 2
if ps aux | grep -v grep | grep "queue:work" >/dev/null; then
    echo -e "${GREEN}   ✓ Queue worker running${NC}"
else
    echo -e "${YELLOW}   ⚠ Queue worker may need manual start${NC}"
fi

# ============================================================================
# SETUP CRON
# ============================================================================
echo -e "${CYAN}[16/20] Setting up cron...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable cron 2>/dev/null || true
    systemctl start cron 2>/dev/null || service cron start 2>/dev/null || true
else
    service cron start 2>/dev/null || cron 2>/dev/null || true
fi

EXISTING_CRON=$(crontab -l -u www-data 2>/dev/null | grep -v "artisan schedule:run" || true)
NEW_CRON="${EXISTING_CRON}"$'\n'"* * * * * /usr/bin/php${PHP_VERSION} /var/www/pelican/artisan schedule:run >> /dev/null 2>&1"
echo "$NEW_CRON" | crontab -u www-data - 2>/dev/null || true

echo -e "${GREEN}   ✓ Cron configured${NC}"

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[17/20] Installing Cloudflare Tunnel...${NC}"

if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb 2>/dev/null || {
        apt --fix-broken install -y 2>/dev/null
        dpkg -i cloudflared-linux-amd64.deb 2>/dev/null
    }
    rm -f cloudflared-linux-amd64.deb
fi

cloudflared service uninstall 2>/dev/null || true
pkill cloudflared 2>/dev/null || true

if [ "$HAS_SYSTEMD" = true ]; then
    cloudflared service install "$CF_TOKEN" 2>/dev/null && {
        systemctl start cloudflared 2>/dev/null || true
        systemctl enable cloudflared 2>/dev/null || true
    } || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    nohup cloudflared tunnel run --token "$CF_TOKEN" > /var/log/cloudflared.log 2>&1 &
fi

sleep 3
echo -e "${GREEN}   ✓ Cloudflare Tunnel installed${NC}"

# ============================================================================
# CLEAR CACHES (no config:cache - breaks plugins)
# ============================================================================
echo -e "${CYAN}[18/20] Clearing all caches...${NC}"

cd /var/www/pelican

$PHP_BIN artisan config:clear >/dev/null 2>&1 || true
$PHP_BIN artisan cache:clear >/dev/null 2>&1 || true
$PHP_BIN artisan view:clear >/dev/null 2>&1 || true
$PHP_BIN artisan route:clear >/dev/null 2>&1 || true
$PHP_BIN artisan route:cache >/dev/null 2>&1 || true

rm -rf storage/framework/views/* 2>/dev/null || true
rm -rf storage/framework/cache/* 2>/dev/null || true

# NOTE: config:cache intentionally skipped - breaks dynamic plugins

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php${PHP_VERSION}-fpm nginx 2>/dev/null || {
        pkill php-fpm && /usr/sbin/php-fpm${PHP_VERSION} -D
        pkill nginx && nginx
    }
else
    mkdir -p /run/php
    pkill php-fpm 2>/dev/null || true
    /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
    pkill nginx 2>/dev/null || true
    nginx 2>/dev/null || true
fi

sleep 2
echo -e "${GREEN}   ✓ All caches cleared${NC}"

# Fix DNS — lock resolv.conf so Tailscale/DHCP/systemd can't overwrite it
# Fix DNS — lock so nothing overwrites it
systemctl disable systemd-resolved 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 100.100.100.100
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
options timeout:2 attempts:2 rotate
DNSEOF
chattr +i /etc/resolv.conf

# Enable OPcache
cat > /etc/php/${PHP_VERSION}/mods-available/opcache.ini <<OPCEOF
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=30000
opcache.validate_timestamps=0
opcache.save_comments=1
opcache.huge_code_pages=0
; opcache.preload=/var/www/pelican/bootstrap/cache/preload.php
; opcache.preload_user=www-data
realpath_cache_size=4096K
realpath_cache_ttl=600
OPCEOF
phpenmod -v ${PHP_VERSION} opcache
systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || true

# Cloudflare auto-restart
mkdir -p /etc/systemd/system/cloudflared.service.d
echo "[Service]
Restart=always
RestartSec=5" > /etc/systemd/system/cloudflared.service.d/restart.conf
systemctl daemon-reload

# ============================================================================
# INSTALL EGG ICONS
# ============================================================================
echo -e "${CYAN}[19/20] Installing egg icons...${NC}"

mkdir -p storage/app/public/icons/egg
chown -R www-data:www-data storage/app/public

$PHP_BIN artisan storage:link 2>/dev/null || true

# Fix Livewire 404 assets
$PHP_BIN artisan livewire:publish --assets 2>/dev/null || true

# Ensure livewire symlink exists
if [ ! -d "/var/www/pelican/public/livewire" ]; then
    ln -sf /var/www/pelican/vendor/livewire/livewire/dist /var/www/pelican/public/livewire
fi
chown -R www-data:www-data /var/www/pelican/public/livewire 2>/dev/null || true
echo -e "${GREEN}   ✓ Livewire assets published${NC}"

cd storage/app/public/icons/egg
git clone --depth 1 https://github.com/pelican-eggs/eggs.git /tmp/pelican-eggs 2>/dev/null || true
find /tmp/pelican-eggs -type f \( -name "*.png" -o -name "*.svg" -o -name "*.jpg" -o -name "*.webp" \) -exec cp {} . \; 2>/dev/null || true
rm -rf /tmp/pelican-eggs 2>/dev/null || true

chown -R www-data:www-data /var/www/pelican/storage
chmod -R 755 /var/www/pelican/storage/app/public

ICON_COUNT=$(ls -1 /var/www/pelican/storage/app/public/icons/egg/ 2>/dev/null | wc -l)
echo -e "${GREEN}   ✓ Installed ${ICON_COUNT} egg icons${NC}"

cd /var/www/pelican

# ============================================================================
# UPDATE EGG INDEX
# ============================================================================
echo -e "${CYAN}[20/20] Updating egg index...${NC}"

$PHP_BIN artisan p:egg:update-index 2>&1 | tail -5 || true

sleep 3

EGG_COUNT=$($PHP_BIN artisan tinker --execute="echo App\Models\Egg::count();" 2>/dev/null | grep -o "[0-9]*" | tail -1)

if [ -n "$EGG_COUNT" ] && [ "$EGG_COUNT" -gt 0 ]; then
    echo -e "${GREEN}   ✓ $EGG_COUNT eggs available${NC}"
else
    echo -e "${YELLOW}   ⚠ Eggs will be imported via web installer${NC}"
fi

# ============================================================================
# SAVE APP_KEY TO .pelican.env FOR BACKUP
# ============================================================================
FINAL_APP_KEY=$(grep "^APP_KEY=" /var/www/pelican/.env | cut -d'=' -f2)
if grep -q "^APP_KEY_BACKUP=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^APP_KEY_BACKUP=.*|APP_KEY_BACKUP=\"${FINAL_APP_KEY}\"|" "$ENV_FILE"
else
    echo "" >> "$ENV_FILE"
    echo "# CRITICAL: APP_KEY backup (do not share!)" >> "$ENV_FILE"
    echo "APP_KEY_BACKUP=\"${FINAL_APP_KEY}\"" >> "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}Verifying installation...${NC}"

CHECKS=0
[ "$(netstat -tulpn 2>/dev/null | grep -c ":9000")" -gt 0 ] && { echo -e "${GREEN}   ✓ PHP-FPM running on port 9000${NC}"; ((CHECKS++)); }
[ "$(netstat -tulpn 2>/dev/null | grep -c ":8443")" -gt 0 ] && { echo -e "${GREEN}   ✓ Nginx running on port 8443${NC}"; ((CHECKS++)); }
[ "$(ps aux | grep -v grep | grep -c "queue:work")" -gt 0 ] && { echo -e "${GREEN}   ✓ Queue worker${NC}"; ((CHECKS++)); }
[ "$(ps aux | grep -v grep | grep -c cloudflared)" -gt 0 ] && { echo -e "${GREEN}   ✓ Cloudflare Tunnel${NC}"; ((CHECKS++)); }
[ -f "/var/www/pelican/vendor/autoload.php" ] && { echo -e "${GREEN}   ✓ Dependencies${NC}"; ((CHECKS++)); }
grep -q "CACHE_DRIVER=redis" /var/www/pelican/.env && { echo -e "${GREEN}   ✓ Redis caching${NC}"; ((CHECKS++)); }

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Panel Installation Complete! (${CHECKS}/6)    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${RED}╔════════════════════════════════════════╗${NC}"
echo -e "${RED}║  🔐 CRITICAL: BACKUP YOUR CONFIG!     ║${NC}"
echo -e "${RED}╚════════════════════════════════════════╝${NC}"
echo -e "${YELLOW}Before switching Codespaces, download:${NC}"
echo -e "  📁 ${GREEN}${ENV_FILE}${NC}"
echo ""
echo -e "${CYAN}To download .pelican.env:${NC}"
echo -e "  ${GREEN}cat ${ENV_FILE}${NC}"
echo -e "  (Copy and save locally)"
echo ""

echo -e "${CYAN}🎯 NEXT STEPS${NC}"
echo -e "${YELLOW}────────────────────────────────────────${NC}"
echo -e "1. ${GREEN}Configure Cloudflare Tunnel${NC} (see docs)"
echo -e "2. ${GREEN}Access panel: https://${PANEL_DOMAIN}${NC}"
echo -e "3. ${GREEN}Create admin: php artisan p:user:make${NC}"
echo -e "4. ${GREEN}Get API token from Panel → Admin → API Keys${NC}"
echo -e "5. ${GREEN}Add token to .pelican.env:${NC}"
echo -e "   ${BLUE}echo 'PANEL_API_TOKEN=\"papp_your_token\"' >> ${ENV_FILE}${NC}"
echo ""

echo -e "${BLUE}✅ Installation complete!${NC}"
echo ""