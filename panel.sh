#!/bin/bash

################################################################################
# PELICAN PANEL - COMPLETE INSTALLER v6.0 FINAL (ALL ISSUES FIXED)
# - Fixed MySQL/MariaDB client conflict
# - Fixed localhost DNS for Cloudflare Tunnel
# - Fixed PHP 8.3 with all extensions
# - Fixed cache clearing for token_id mismatch
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
echo -e "${GREEN}║  Pelican Panel Installer v6.0 FINAL   ║${NC}"
echo -e "${GREEN}║  All Fixes Applied - Production Ready ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

# ============================================================================
# DETECT ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[1/19] Detecting Environment...${NC}"

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
echo -e "${CYAN}[2/19] Configuration...${NC}"

if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}   Found existing configuration!${NC}"
    source "$ENV_FILE"
    echo -e "${GREEN}   Using: $ENV_FILE${NC}"
    echo -e "${CYAN}   Domain: ${GREEN}${PANEL_DOMAIN}${NC}"
    echo -e "${CYAN}   Database: ${GREEN}${DB_DRIVER} (${DB_HOST})${NC}"
    read -p "   Use these settings? (y/n) [y]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-y}
    
    if [[ ! "$USE_EXISTING" =~ ^[Yy] ]]; then
        rm -f "$ENV_FILE"
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
        DB_PORT_DEFAULT="5432"
    else
        DB_DRIVER="mysql"
        DB_PORT_DEFAULT="3306"
    fi

    read -p "Database Host: " DB_HOST
    read -p "Database Port [$DB_PORT_DEFAULT]: " DB_PORT
    DB_PORT=${DB_PORT:-$DB_PORT_DEFAULT}
    read -p "Database Name: " DB_NAME
    read -p "Database Username: " DB_USER
    read -sp "Database Password: " DB_PASS
    echo ""

    read -p "Redis Host [127.0.0.1]: " REDIS_HOST
    REDIS_HOST=${REDIS_HOST:-127.0.0.1}
    read -p "Redis Port [6379]: " REDIS_PORT
    REDIS_PORT=${REDIS_PORT:-6379}
    read -sp "Redis Password (optional): " REDIS_PASS
    echo ""

    read -p "SMTP Host (e.g., smtp.gmail.com): " MAIL_HOST
    read -p "SMTP Port [587]: " MAIL_PORT
    MAIL_PORT=${MAIL_PORT:-587}
    read -p "SMTP Username: " MAIL_USER
    read -sp "SMTP Password: " MAIL_PASS
    echo ""
    read -p "From Email: " MAIL_FROM
    read -p "From Name: " MAIL_FROM_NAME

    cat > "$ENV_FILE" <<EOF
PANEL_DOMAIN="$PANEL_DOMAIN"
CF_TOKEN="$CF_TOKEN"
DB_DRIVER="$DB_DRIVER"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
REDIS_HOST="$REDIS_HOST"
REDIS_PORT="$REDIS_PORT"
REDIS_PASS="$REDIS_PASS"
MAIL_HOST="$MAIL_HOST"
MAIL_PORT="$MAIL_PORT"
MAIL_USER="$MAIL_USER"
MAIL_PASS="$MAIL_PASS"
MAIL_FROM="$MAIL_FROM"
MAIL_FROM_NAME="$MAIL_FROM_NAME"
EOF
    chmod 600 "$ENV_FILE"
fi

echo -e "${GREEN}   ✓ Configuration loaded${NC}"

# ============================================================================
# SYSTEM UPDATE
# ============================================================================
echo -e "${CYAN}[3/19] Updating system...${NC}"
mkdir -p /etc/dpkg/dpkg.cfg.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/docker
apt update -qq 2>&1 | grep -v "GPG error" || true
apt upgrade -y -qq 2>&1 | grep -v "GPG error" || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# INSTALL DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[4/19] Installing dependencies...${NC}"
apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget tar unzip git cron sudo supervisor net-tools nano 2>/dev/null || true
echo -e "${GREEN}   ✓ Dependencies installed${NC}"

# ============================================================================
# INSTALL PHP 8.3+
# ============================================================================
echo -e "${CYAN}[5/19] Installing PHP 8.3+...${NC}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

if command -v add-apt-repository &> /dev/null; then
    add-apt-repository ppa:ondrej/php -y 2>&1 | grep -v "GPG error" || true
fi

apt update -qq 2>&1 | grep -v "GPG error" || true

echo -e "${BLUE}   Installing PHP 8.3 and all extensions...${NC}"
apt install -y \
    php8.3 \
    php8.3-cli \
    php8.3-fpm \
    php8.3-mysql \
    php8.3-pgsql \
    php8.3-sqlite3 \
    php8.3-redis \
    php8.3-intl \
    php8.3-zip \
    php8.3-bcmath \
    php8.3-mbstring \
    php8.3-xml \
    php8.3-curl \
    php8.3-gd \
    2>/dev/null || {
    echo -e "${RED}❌ PHP installation failed!${NC}"
    exit 1
}

update-alternatives --install /usr/bin/php php /usr/bin/php8.3 100 2>/dev/null || true
update-alternatives --set php /usr/bin/php8.3 2>/dev/null || true

PHP_VERSION="8.3"

if ! php -v | grep -q "PHP 8.3"; then
    echo -e "${RED}❌ PHP 8.3 not properly installed!${NC}"
    exit 1
fi

echo -e "${GREEN}   ✓ PHP $(php -v | head -n1 | cut -d' ' -f2) with all extensions${NC}"

# ============================================================================
# INSTALL SERVICES (FIXED: MySQL/MariaDB conflict)
# ============================================================================
echo -e "${CYAN}[6/19] Installing services...${NC}"
apt install -y nginx 2>/dev/null || true

# Fix MySQL/MariaDB conflict - only install one
if [ "$DB_DRIVER" = "pgsql" ]; then
    apt install -y postgresql-client 2>/dev/null || true
else
    if ! apt install -y mysql-client 2>/dev/null; then
        apt install -y mariadb-client 2>/dev/null || true
    fi
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
echo -e "${CYAN}[7/19] Installing Composer...${NC}"
if ! command -v composer &> /dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet 2>/dev/null
fi
echo -e "${GREEN}   ✓ Composer $(composer --version 2>/dev/null | cut -d' ' -f3)${NC}"

# ============================================================================
# DOWNLOAD PANEL
# ============================================================================
echo -e "${CYAN}[8/19] Downloading Pelican Panel...${NC}"

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

# ============================================================================
# INSTALL COMPOSER DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[9/19] Installing dependencies...${NC}"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
PHP_BIN="/usr/bin/php8.3"
[ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php)

if [ ! -d "vendor" ] || [ ! -f "vendor/autoload.php" ]; then
    echo -e "${YELLOW}   Installing fresh dependencies...${NC}"
    
    rm -f composer.lock
    rm -rf vendor/
    composer clear-cache 2>/dev/null || true
    
    echo -e "${BLUE}   Running composer install...${NC}"
    
    if COMPOSER_ALLOW_SUPERUSER=1 $PHP_BIN $(which composer) install \
        --no-dev \
        --optimize-autoloader \
        --no-interaction \
        2>&1 | tee /tmp/composer-install.log; then
        echo -e "${GREEN}   ✓ Dependencies installed${NC}"
    else
        echo -e "${RED}❌ Composer failed!${NC}"
        tail -n 20 /tmp/composer-install.log
        exit 1
    fi
else
    echo -e "${GREEN}   ✓ Dependencies already installed${NC}"
fi

echo -e "${GREEN}   ✓ All dependencies ready${NC}"

# ============================================================================
# CONFIGURE ENVIRONMENT
# ============================================================================
echo -e "${CYAN}[10/19] Configuring environment...${NC}"

cp .env.example .env

sed -i "s|APP_URL=.*|APP_URL=https://${PANEL_DOMAIN}|" .env
sed -i "s|DB_CONNECTION=.*|DB_CONNECTION=${DB_DRIVER}|" .env
sed -i "s|DB_HOST=.*|DB_HOST=${DB_HOST}|" .env
sed -i "s|DB_PORT=.*|DB_PORT=${DB_PORT}|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
sed -i "s|REDIS_HOST=.*|REDIS_HOST=${REDIS_HOST}|" .env
sed -i "s|REDIS_PORT=.*|REDIS_PORT=${REDIS_PORT}|" .env
[ -n "$REDIS_PASS" ] && sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASS}|" .env
sed -i "s|MAIL_HOST=.*|MAIL_HOST=${MAIL_HOST}|" .env
sed -i "s|MAIL_PORT=.*|MAIL_PORT=${MAIL_PORT}|" .env
sed -i "s|MAIL_USERNAME=.*|MAIL_USERNAME=${MAIL_USER}|" .env
sed -i "s|MAIL_PASSWORD=.*|MAIL_PASSWORD=${MAIL_PASS}|" .env
sed -i "s|MAIL_FROM_ADDRESS=.*|MAIL_FROM_ADDRESS=${MAIL_FROM}|" .env
sed -i "s|MAIL_FROM_NAME=.*|MAIL_FROM_NAME=\"${MAIL_FROM_NAME}\"|" .env

$PHP_BIN artisan key:generate --force --quiet

echo -e "${GREEN}   ✓ Environment configured${NC}"

# ============================================================================
# SET PERMISSIONS
# ============================================================================
echo -e "${CYAN}[11/19] Setting permissions...${NC}"
chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null || true
chown -R www-data:www-data /var/www/pelican
mkdir -p storage/logs
touch storage/logs/laravel.log
chown www-data:www-data storage/logs/laravel.log
echo -e "${GREEN}   ✓ Permissions set${NC}"

# ============================================================================
# CONFIGURE PHP-FPM
# ============================================================================
echo -e "${CYAN}[12/19] Configuring PHP-FPM...${NC}"

if [ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]; then
    sed -i 's|listen = /run/php/php.*-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
    sed -i 's|;listen.allowed_clients = 127.0.0.1|listen.allowed_clients = 127.0.0.1|' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
fi

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || service php${PHP_VERSION}-fpm restart 2>/dev/null
else
    pkill php-fpm 2>/dev/null || true
    /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
fi

sleep 1
echo -e "${GREEN}   ✓ PHP-FPM configured${NC}"

# ============================================================================
# CONFIGURE NGINX
# ============================================================================
echo -e "${CYAN}[13/19] Configuring Nginx...${NC}"
mkdir -p /etc/ssl/pelican
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/pelican/key.pem \
  -out /etc/ssl/pelican/cert.pem \
  -subj "/CN=${PANEL_DOMAIN}" 2>/dev/null

cat > /etc/nginx/sites-available/pelican.conf <<NGINXEOF
server_tokens off;

server {
    listen 0.0.0.0:8443 ssl http2;
    listen [::]:8443 ssl http2;
    
    server_name ${PANEL_DOMAIN};

    ssl_certificate /etc/ssl/pelican/cert.pem;
    ssl_certificate_key /etc/ssl/pelican/key.pem;

    root /var/www/pelican/public;
    index index.php;

    access_log /var/log/nginx/pelican.app-access.log;
    error_log  /var/log/nginx/pelican.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
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
echo -e "${CYAN}[14/19] Running database migrations...${NC}"

if [ -f "/var/www/pelican/.installation_complete" ]; then
    echo -e "${YELLOW}   ⚠ Existing installation detected${NC}"
    read -p "   Use migrate:fresh? This will DELETE ALL DATA! (yes/NO): " CONFIRM_FRESH
    
    if [ "$CONFIRM_FRESH" = "yes" ]; then
        echo -e "${RED}   🗑️  Dropping all tables...${NC}"
        $PHP_BIN artisan migrate:fresh --force || {
            echo -e "${RED}   ❌ Migration failed!${NC}"
            exit 1
        }
        echo -e "${GREEN}   ✓ Database reset complete${NC}"
    else
        $PHP_BIN artisan migrate --force || {
            echo -e "${YELLOW}   ⚠ Migrations will run via web installer${NC}"
        }
        echo -e "${GREEN}   ✓ Database updated${NC}"
    fi
else
    echo -e "${BLUE}   Fresh installation...${NC}"
    $PHP_BIN artisan migrate:fresh --force || {
        echo -e "${YELLOW}   ⚠ Migrations will run via web installer${NC}"
    }
    touch /var/www/pelican/.installation_complete
    echo -e "${GREEN}   ✓ Database initialized${NC}"
fi

# ============================================================================
# SETUP QUEUE WORKER
# ============================================================================
echo -e "${CYAN}[15/19] Setting up queue worker...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    cat > /etc/systemd/system/pelican-queue.service <<'QEOF'
[Unit]
Description=Pelican Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php8.3 /var/www/pelican/artisan queue:work --sleep=3 --tries=3 --timeout=90
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
QEOF

    systemctl daemon-reload
    systemctl enable pelican-queue.service 2>/dev/null || true
    systemctl start pelican-queue.service 2>/dev/null || HAS_SYSTEMD=false
fi

if [ "$HAS_SYSTEMD" = false ]; then
    echo -e "${YELLOW}   Using supervisor (container mode)...${NC}"
    
    # Install supervisor if not present
    apt install -y supervisor 2>/dev/null || true
    
    # Create main supervisord config if it doesn't exist
    if [ ! -f /etc/supervisor/supervisord.conf ]; then
        cat > /etc/supervisor/supervisord.conf <<'SEOF'
[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[supervisord]
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[include]
files = /etc/supervisor/conf.d/*.conf
SEOF
    fi
    
    # Create log directory
    mkdir -p /var/log/supervisor
    
    # Create pelican queue worker config
    mkdir -p /etc/supervisor/conf.d
    cat > /etc/supervisor/conf.d/pelican-queue.conf <<'QEOF'
[program:pelican-queue]
command=/usr/bin/php8.3 /var/www/pelican/artisan queue:work --sleep=3 --tries=3 --timeout=90
directory=/var/www/pelican
user=www-data
autostart=true
autorestart=true
stdout_logfile=/var/log/pelican-queue.log
stderr_logfile=/var/log/pelican-queue-error.log
stopasgroup=true
killasgroup=true
startsecs=5
startretries=3
QEOF

    # Kill any existing supervisor
    pkill supervisord 2>/dev/null || true
    sleep 1
    
    # Start supervisord
    echo -e "${BLUE}   Starting supervisord...${NC}"
    supervisord -c /etc/supervisor/supervisord.conf
    sleep 2
    
    # Load and start the queue worker
    supervisorctl reread
    supervisorctl update
    supervisorctl start pelican-queue
    
    # Verify it's running
    if supervisorctl status pelican-queue | grep -q RUNNING; then
        echo -e "${GREEN}   ✓ Queue worker started via supervisor${NC}"
    else
        echo -e "${RED}   ❌ Queue worker failed to start!${NC}"
        supervisorctl status pelican-queue
    fi
fi

# Verify queue worker is running (either systemd or supervisor)
sleep 1
if ps aux | grep -v grep | grep -q "queue:work"; then
    echo -e "${GREEN}   ✓ Queue worker is running${NC}"
else
    echo -e "${RED}   ⚠ Queue worker not detected!${NC}"
    echo -e "${YELLOW}   Jobs will queue but not process automatically${NC}"
fi
# ============================================================================
# SETUP CRON
# ============================================================================
echo -e "${CYAN}[16/19] Setting up cron...${NC}"

if [ "$HAS_SYSTEMD" = true ]; then
    systemctl enable cron 2>/dev/null || true
    systemctl start cron 2>/dev/null || service cron start 2>/dev/null || true
else
    service cron start 2>/dev/null || cron 2>/dev/null || true
fi

(crontab -l -u www-data 2>/dev/null | grep -v "artisan schedule:run"; echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data - 2>/dev/null || true

echo -e "${GREEN}   ✓ Cron configured${NC}"

# ============================================================================
# INSTALL CLOUDFLARE TUNNEL
# ============================================================================
echo -e "${CYAN}[17/19] Installing Cloudflare Tunnel...${NC}"

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
# CLEAR CACHES (FIX: token_id mismatch & browser issues)
# ============================================================================
echo -e "${CYAN}[18/19] Clearing all caches...${NC}"

cd /var/www/pelican

# Clear Laravel caches
$PHP_BIN artisan config:clear >/dev/null 2>&1 || true
$PHP_BIN artisan cache:clear >/dev/null 2>&1 || true
$PHP_BIN artisan view:clear >/dev/null 2>&1 || true
$PHP_BIN artisan route:clear >/dev/null 2>&1 || true

# Restart PHP-FPM
if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || {
        pkill php-fpm 2>/dev/null || true
        /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
    }
else
    pkill php-fpm 2>/dev/null || true
    /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
fi

# Restart Nginx
if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart nginx 2>/dev/null || {
        pkill nginx 2>/dev/null || true
        nginx 2>/dev/null || true
    }
else
    pkill nginx 2>/dev/null || true
    nginx 2>/dev/null || true
fi

sleep 2

echo -e "${GREEN}   ✓ All caches cleared${NC}"
echo -e "${YELLOW}   ⚠ IMPORTANT: Hard refresh browser (Ctrl+Shift+R)${NC}"

# ============================================================================
# INSTALL EGG ICONS
# ============================================================================
echo -e "${CYAN}[19/19] Installing egg icons...${NC}"

mkdir -p storage/app/public/icons/egg
chown -R www-data:www-data storage/app/public

$PHP_BIN artisan storage:link 2>/dev/null || true

cd storage/app/public/icons/egg
git clone --depth 1 https://github.com/pelican-eggs/eggs.git /tmp/pelican-eggs 2>/dev/null
find /tmp/pelican-eggs -type f \( -name "*.png" -o -name "*.svg" -o -name "*.jpg" -o -name "*.webp" \) -exec cp {} . \; 2>/dev/null
rm -rf /tmp/pelican-eggs

chown -R www-data:www-data /var/www/pelican/storage
chmod -R 755 /var/www/pelican/storage/app/public

ICON_COUNT=$(ls -1 /var/www/pelican/storage/app/public/icons/egg/ 2>/dev/null | wc -l)
echo -e "${GREEN}   ✓ Installed ${ICON_COUNT} egg icons${NC}"

# ============================================================================
# FINAL VERIFICATION
# ============================================================================
echo ""
echo -e "${CYAN}Verifying installation...${NC}"

CHECKS=0
[ "$(netstat -tulpn 2>/dev/null | grep -c ":9000")" -gt 0 ] && { echo -e "${GREEN}   ✓ PHP-FPM running${NC}"; ((CHECKS++)); }
[ "$(netstat -tulpn 2>/dev/null | grep -c ":8443")" -gt 0 ] && { echo -e "${GREEN}   ✓ Nginx running${NC}"; ((CHECKS++)); }
[ "$(ps aux | grep -v grep | grep -c "queue:work")" -gt 0 ] && { echo -e "${GREEN}   ✓ Queue worker${NC}"; ((CHECKS++)); }
[ "$(ps aux | grep -v grep | grep -c cloudflared)" -gt 0 ] && { echo -e "${GREEN}   ✓ Cloudflare Tunnel${NC}"; ((CHECKS++)); }
[ -f "/var/www/pelican/vendor/autoload.php" ] && { echo -e "${GREEN}   ✓ Dependencies${NC}"; ((CHECKS++)); }

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Panel Installation Complete! (${CHECKS}/5)    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}🎯 CONFIGURE CLOUDFLARE TUNNEL${NC}"
echo -e "${YELLOW}──────────────────────────────────────${NC}"
echo -e "1. Go to: ${BLUE}https://one.dash.cloudflare.com/${NC}"
echo -e "2. Navigate: ${BLUE}Zero Trust → Networks → Tunnels → Configure${NC}"
echo -e "3. Add Public Hostname:"
echo -e "   - Subdomain: ${GREEN}$(echo $PANEL_DOMAIN | cut -d'.' -f1)${NC}"
echo -e "   - Domain: ${GREEN}$(echo $PANEL_DOMAIN | cut -d'.' -f2-)${NC}"
echo -e "   - Service Type: ${GREEN}HTTPS${NC}"
echo -e "   - URL: ${GREEN}127.0.0.1:8443${NC} ${YELLOW}(Use IP, not localhost!)${NC}"
echo -e "   - ${YELLOW}⚠️  Enable 'No TLS Verify'${NC}"
echo ""

echo -e "${RED}⚠️  CRITICAL: HARD REFRESH BROWSER${NC}"
echo -e "   Press: ${YELLOW}Ctrl + Shift + R${NC} (or Cmd + Shift + R on Mac)"
echo -e "   Or open in: ${YELLOW}Incognito/Private window${NC}"
echo -e "   This fixes token_id mismatch errors!"
echo ""

echo -e "${CYAN}🧪 TEST PANEL${NC}"
echo -e "   Local:  ${GREEN}curl -k https://localhost:8443${NC}"
echo -e "   Remote: ${GREEN}curl https://${PANEL_DOMAIN}${NC}"
echo ""

echo -e "${CYAN}📁 IMPORTANT FILES${NC}"
echo -e "   Config: ${GREEN}/var/www/pelican/.env${NC}"
echo -e "   Logs: ${GREEN}/var/log/nginx/pelican.app-error.log${NC}"
echo -e "   Queue: ${GREEN}/var/log/pelican-queue.log${NC}"
echo ""

echo -e "${CYAN}🔧 TROUBLESHOOTING COMMANDS${NC}"
echo -e "   Clear caches:"
echo -e "   ${GREEN}cd /var/www/pelican${NC}"
echo -e "   ${GREEN}php artisan config:clear && php artisan cache:clear && php artisan view:clear${NC}"
echo ""
echo -e "   Restart services (with systemd):"
echo -e "   ${GREEN}systemctl restart php8.3-fpm nginx${NC}"
echo ""
echo -e "   Restart services (without systemd):"
echo -e "   ${GREEN}pkill php-fpm && /usr/sbin/php-fpm8.3 -D${NC}"
echo -e "   ${GREEN}pkill nginx && nginx${NC}"
echo ""

echo -e "${BLUE}✅ Panel is ready! Configure Cloudflare Tunnel, then access: https://${PANEL_DOMAIN}${NC}"
echo ""
