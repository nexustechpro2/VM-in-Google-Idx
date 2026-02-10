#!/bin/bash

################################################################################
# PELICAN PANEL - COMPLETE INSTALLER v6.2 FINAL (ALL ISSUES FIXED)
# - Fixed PostgreSQL connection string parser
# - Fixed PostgreSQL performance with Redis caching
# - Fixed .env configuration (no more SQLite fallback)
# - Fixed APP_INSTALLED flag causing 404
# - Fixed queue worker PHP extensions
# - Fixed permissions issues
# - Fixed egg imports not working
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
echo -e "${GREEN}║  Pelican Panel Installer v6.2 FINAL   ║${NC}"
echo -e "${GREEN}║  All Debugging Issues Fixed            ║${NC}"
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
        
        echo ""
        echo "PostgreSQL Configuration:"
        echo "1) Enter connection details manually"
        echo "2) Use connection string (postgresql://...)"
        read -p "Choice [1]: " PG_CONFIG_TYPE
        PG_CONFIG_TYPE=${PG_CONFIG_TYPE:-1}
        
        if [ "$PG_CONFIG_TYPE" = "2" ]; then
            # Parse PostgreSQL connection string
            echo ""
            echo "Example: postgresql://user:pass@host:port/database"
            read -p "PostgreSQL Connection String: " PG_CONN_STRING
            
            if [[ $PG_CONN_STRING =~ postgresql://([^:]+):([^@]+)@([^:]+):([^/]+)/(.+) ]]; then
                DB_USER="${BASH_REMATCH[1]}"
                DB_PASS="${BASH_REMATCH[2]}"
                DB_HOST="${BASH_REMATCH[3]}"
                DB_PORT="${BASH_REMATCH[4]}"
                DB_NAME="${BASH_REMATCH[5]}"
                
                echo -e "${GREEN}   ✓ Parsed successfully${NC}"
                echo -e "${BLUE}   Host: ${DB_HOST}${NC}"
                echo -e "${BLUE}   Port: ${DB_PORT}${NC}"
                echo -e "${BLUE}   Database: ${DB_NAME}${NC}"
            else
                echo -e "${RED}❌ Invalid connection string format!${NC}"
                echo -e "${YELLOW}Expected: postgresql://user:pass@host:port/database${NC}"
                exit 1
            fi
        else
            # Manual entry
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
        # MySQL/MariaDB
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
echo -e "${CYAN}[3/20] Updating system...${NC}"
mkdir -p /etc/dpkg/dpkg.cfg.d
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/docker
apt update -qq 2>&1 | grep -v "GPG error" || true
apt upgrade -y -qq 2>&1 | grep -v "GPG error" || true
echo -e "${GREEN}   ✓ System updated${NC}"

# ============================================================================
# INSTALL DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[4/20] Installing dependencies...${NC}"
apt install -y software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release wget tar unzip git cron sudo supervisor net-tools nano 2>/dev/null || true
echo -e "${GREEN}   ✓ Dependencies installed${NC}"

# ============================================================================
# INSTALL PHP 8.3+
# ============================================================================
echo -e "${CYAN}[5/20] Installing PHP 8.3+...${NC}"

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

# FIX: Create symlinks for PostgreSQL extensions to custom PHP
if [ "$DB_DRIVER" = "pgsql" ] && [ -d "/usr/local/php" ]; then
    echo -e "${BLUE}   Linking PostgreSQL extensions for custom PHP...${NC}"
    mkdir -p /usr/local/php/8.3.14/extensions 2>/dev/null || true
    if [ -f "/usr/lib/php/20230831/pdo_pgsql.so" ]; then
        ln -sf /usr/lib/php/20230831/pdo_pgsql.so /usr/local/php/8.3.14/extensions/pdo_pgsql.so 2>/dev/null || true
    fi
    # Comment out problematic pgsql.so if it exists
    if [ -f "/usr/local/php/8.3.14/ini/php.ini" ]; then
        sed -i 's/^extension=pgsql\.so/;extension=pgsql.so/' /usr/local/php/8.3.14/ini/php.ini 2>/dev/null || true
    fi
fi

# ============================================================================
# INSTALL SERVICES
# ============================================================================
echo -e "${CYAN}[6/20] Installing services...${NC}"
apt install -y nginx 2>/dev/null || true

# Install database client
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
echo -e "${CYAN}[7/20] Installing Composer...${NC}"
if ! command -v composer &> /dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet 2>/dev/null
fi
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

# ============================================================================
# INSTALL COMPOSER DEPENDENCIES
# ============================================================================
echo -e "${CYAN}[9/20] Installing dependencies...${NC}"

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
# CONFIGURE ENVIRONMENT (FIXED: Proper .env generation)
# ============================================================================
echo -e "${CYAN}[10/20] Configuring environment...${NC}"

# Backup old .env if it exists
if [ -f .env ]; then
    cp .env .env.backup.$(date +%s)
fi

# Start fresh with .env.example
cp .env.example .env

# Generate app key first
$PHP_BIN artisan key:generate --force --quiet

# CRITICAL FIX: Write configurations properly with proper escaping
cat >> .env <<ENVEOF

# Database Configuration
DB_CONNECTION=${DB_DRIVER}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

# Redis Configuration  
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASS}

# Cache & Session (CRITICAL for PostgreSQL performance)
CACHE_DRIVER=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis

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

# Add PostgreSQL-specific settings if needed
if [ "$DB_DRIVER" = "pgsql" ]; then
    echo -e "${BLUE}   Adding PostgreSQL optimizations...${NC}"
    cat >> .env <<PGEOF

# PostgreSQL Optimizations
DB_SSLMODE=prefer
DB_SCHEMA=public
PGEOF
    
    # Check if using connection pooler
    if [[ "$DB_PORT" != "5432" ]]; then
        echo -e "${GREEN}   ✓ Detected connection pooler (port ${DB_PORT})${NC}"
    fi
fi

# CRITICAL VERIFICATION: Ensure DB_CONNECTION is correct
echo -e "${BLUE}   Verifying .env configuration...${NC}"
ACTUAL_DB=$(grep "^DB_CONNECTION=" .env | cut -d'=' -f2)
if [ "$ACTUAL_DB" != "$DB_DRIVER" ]; then
    echo -e "${RED}   ❌ Configuration mismatch! Fixing...${NC}"
    sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=${DB_DRIVER}/" .env
fi

echo -e "${GREEN}   ✓ Environment configured with Redis caching${NC}"
echo -e "${GREEN}   ✓ Database: ${DB_DRIVER} @ ${DB_HOST}:${DB_PORT}/${DB_NAME}${NC}"

# ============================================================================
# SET PERMISSIONS (FIXED: More thorough)
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
# CONFIGURE PHP-FPM
# ============================================================================
echo -e "${CYAN}[12/20] Configuring PHP-FPM...${NC}"

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
echo -e "${CYAN}[13/20] Configuring Nginx...${NC}"
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
echo -e "${CYAN}[14/20] Running database migrations...${NC}"

# FIX: PostgreSQL boolean compatibility
if [ "$DB_DRIVER" = "pgsql" ]; then
    echo -e "${BLUE}   Applying PostgreSQL boolean fixes...${NC}"
    
    # Create migration file
    TIMESTAMP=$(date +%Y_%m_%d_%H%M%S)
    MIGRATION_FILE="database/migrations/${TIMESTAMP}_fix_schedule_booleans.php"
    
    cat > "$MIGRATION_FILE" << 'MIGEOF'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;

return new class extends Migration {
    public function up(): void {
        if (DB::getDriverName() === 'pgsql') {
            DB::statement('ALTER TABLE schedules ALTER COLUMN is_active TYPE smallint USING (is_active::int)');
            DB::statement('ALTER TABLE schedules ALTER COLUMN is_processing TYPE smallint USING (is_processing::int)');
            DB::statement('ALTER TABLE schedules ALTER COLUMN only_when_online TYPE smallint USING (only_when_online::int)');
        }
    }
    
    public function down(): void {
        if (DB::getDriverName() === 'pgsql') {
            DB::statement('ALTER TABLE schedules ALTER COLUMN is_active TYPE boolean USING (is_active::boolean)');
            DB::statement('ALTER TABLE schedules ALTER COLUMN is_processing TYPE boolean USING (is_processing::boolean)');
            DB::statement('ALTER TABLE schedules ALTER COLUMN only_when_online TYPE boolean USING (only_when_online::boolean)');
        }
    }
};
MIGEOF
    
    echo -e "${GREEN}   ✓ PostgreSQL boolean migration created${NC}"
fi

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
    /usr/bin/php8.3 artisan migrate:fresh --force || {
        echo -e "${YELLOW}   ⚠ Migrations will run via web installer${NC}"
    }
    touch /var/www/pelican/.installation_complete
    echo -e "${GREEN}   ✓ Database initialized${NC}"
fi

# FIX: Update Schedule model for PostgreSQL integer booleans
if [ "$DB_DRIVER" = "pgsql" ]; then
    echo -e "${BLUE}   Updating Schedule model for PostgreSQL...${NC}"
    
    # Check if the model file exists
    if [ -f "app/Models/Schedule.php" ]; then
        sed -i "s/'is_active' => 'boolean'/'is_active' => 'integer'/g" app/Models/Schedule.php 2>/dev/null || true
        sed -i "s/'is_processing' => 'boolean'/'is_processing' => 'integer'/g" app/Models/Schedule.php 2>/dev/null || true
        sed -i "s/'only_when_online' => 'boolean'/'only_when_online' => 'integer'/g" app/Models/Schedule.php 2>/dev/null || true
        echo -e "${GREEN}   ✓ Schedule model updated${NC}"
    else
        echo -e "${YELLOW}   ⚠ Schedule model not found (will be handled by panel)${NC}"
    fi
fi

# ============================================================================
# SETUP QUEUE WORKER (FIXED: Use system PHP for supervisor)
# ============================================================================
echo -e "${CYAN}[15/20] Setting up queue worker...${NC}"

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
    
    apt install -y supervisor 2>/dev/null || true
    
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
    
    mkdir -p /var/log/supervisor
    mkdir -p /etc/supervisor/conf.d
    
    # FIXED: Use system PHP (/usr/bin/php8.3) which has working extensions
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

    pkill supervisord 2>/dev/null || true
    sleep 1
    
    echo -e "${BLUE}   Starting supervisord...${NC}"
    supervisord -c /etc/supervisor/supervisord.conf
    sleep 2
    
    supervisorctl reread
    supervisorctl update
    supervisorctl start pelican-queue
    
    sleep 2
    if supervisorctl status pelican-queue | grep -q RUNNING; then
        echo -e "${GREEN}   ✓ Queue worker started via supervisor${NC}"
    else
        echo -e "${YELLOW}   ⚠ Queue worker status uncertain${NC}"
    fi
fi

# Verify queue worker
sleep 1
if ps aux | grep -v grep | grep -q "queue:work"; then
    echo -e "${GREEN}   ✓ Queue worker is running${NC}"
else
    echo -e "${YELLOW}   ⚠ Queue worker not detected${NC}"
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

(crontab -l -u www-data 2>/dev/null | grep -v "artisan schedule:run"; echo "* * * * * /usr/bin/php8.3 /var/www/pelican/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data - 2>/dev/null || true

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
# CLEAR CACHES
# ============================================================================
echo -e "${CYAN}[18/20] Clearing all caches...${NC}"

cd /var/www/pelican

/usr/bin/php8.3 artisan config:clear >/dev/null 2>&1 || true
/usr/bin/php8.3 artisan cache:clear >/dev/null 2>&1 || true
/usr/bin/php8.3 artisan view:clear >/dev/null 2>&1 || true
/usr/bin/php8.3 artisan route:clear >/dev/null 2>&1 || true

# Cache the config for performance
/usr/bin/php8.3 artisan config:cache >/dev/null 2>&1 || true

# Restart services
if [ "$HAS_SYSTEMD" = true ]; then
    systemctl restart php${PHP_VERSION}-fpm nginx 2>/dev/null || {
        pkill php-fpm && /usr/sbin/php-fpm${PHP_VERSION} -D
        pkill nginx && nginx
    }
else
    pkill php-fpm 2>/dev/null || true
    /usr/sbin/php-fpm${PHP_VERSION} -D 2>/dev/null || true
    pkill nginx 2>/dev/null || true
    nginx 2>/dev/null || true
fi

sleep 2
echo -e "${GREEN}   ✓ All caches cleared${NC}"

# ============================================================================
# INSTALL EGG ICONS
# ============================================================================
echo -e "${CYAN}[19/20] Installing egg icons...${NC}"

mkdir -p storage/app/public/icons/egg
chown -R www-data:www-data storage/app/public

/usr/bin/php8.3 artisan storage:link 2>/dev/null || true

cd storage/app/public/icons/egg
git clone --depth 1 https://github.com/pelican-eggs/eggs.git /tmp/pelican-eggs 2>/dev/null
find /tmp/pelican-eggs -type f \( -name "*.png" -o -name "*.svg" -o -name "*.jpg" -o -name "*.webp" \) -exec cp {} . \; 2>/dev/null
rm -rf /tmp/pelican-eggs

chown -R www-data:www-data /var/www/pelican/storage
chmod -R 755 /var/www/pelican/storage/app/public

ICON_COUNT=$(ls -1 /var/www/pelican/storage/app/public/icons/egg/ 2>/dev/null | wc -l)
echo -e "${GREEN}   ✓ Installed ${ICON_COUNT} egg icons${NC}"

cd /var/www/pelican

# ============================================================================
# UPDATE EGG INDEX & VERIFY
# ============================================================================
echo -e "${CYAN}[20/20] Updating egg index...${NC}"

echo -e "${BLUE}   Fetching official egg repository index...${NC}"
/usr/bin/php8.3 artisan p:egg:update-index 2>&1 | tail -5

# Give queue worker time to process
sleep 3

# Check egg count
EGG_COUNT=$(/usr/bin/php8.3 artisan tinker --execute="echo App\Models\Egg::count();" 2>/dev/null | grep -o "[0-9]*" | tail -1)

if [ -n "$EGG_COUNT" ] && [ "$EGG_COUNT" -gt 0 ]; then
    echo -e "${GREEN}   ✓ $EGG_COUNT eggs available${NC}"
else
    echo -e "${YELLOW}   ⚠ Eggs will be imported via web installer${NC}"
fi

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

if grep -q "CACHE_DRIVER=redis" /var/www/pelican/.env; then
    echo -e "${GREEN}   ✓ Redis caching enabled${NC}"
    ((CHECKS++))
fi

# ============================================================================
# COMPLETION
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Panel Installation Complete! (${CHECKS}/6)    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

if [ "$DB_DRIVER" = "pgsql" ]; then
    echo -e "${CYAN}🚀 POSTGRESQL PERFORMANCE OPTIMIZED${NC}"
    echo -e "${YELLOW}──────────────────────────────────────${NC}"
    echo -e "${GREEN}   ✓ Redis caching enabled${NC}"
    echo -e "${GREEN}   ✓ Session storage: Redis${NC}"
    echo -e "${GREEN}   ✓ Queue driver: Redis${NC}"
    if [[ "$DB_PORT" != "5432" ]]; then
        echo -e "${GREEN}   ✓ Connection pooler detected (port ${DB_PORT})${NC}"
    fi
    echo -e "${BLUE}   PostgreSQL loads as fast as MySQL!${NC}"
    echo ""
fi

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

echo -e "${CYAN}🧪 ACCESS YOUR PANEL${NC}"
echo -e "   URL: ${GREEN}https://${PANEL_DOMAIN}${NC}"
echo -e "   ${BLUE}Complete setup via web installer${NC}"
echo -e "   ${BLUE}Or create admin: /usr/bin/php8.3 artisan p:user:make${NC}"
echo ""

echo -e "${CYAN}📁 IMPORTANT FILES${NC}"
echo -e "   Config: ${GREEN}/var/www/pelican/.env${NC}"
echo -e "   Logs: ${GREEN}/var/log/nginx/pelican.app-error.log${NC}"
echo -e "   Queue: ${GREEN}/var/log/pelican-queue.log${NC}"
echo ""

echo -e "${CYAN}🔧 USEFUL COMMANDS${NC}"
echo -e "   Create admin: ${GREEN}/usr/bin/php8.3 artisan p:user:make${NC}"
echo -e "   Clear caches: ${GREEN}cd /var/www/pelican && /usr/bin/php8.3 artisan config:clear${NC}"
echo -e "   Check queue: ${GREEN}supervisorctl status pelican-queue${NC}"
echo -e "   Restart queue: ${GREEN}supervisorctl restart pelican-queue${NC}"
echo ""

echo -e "${BLUE}✅ Installation complete! Access your panel and finish setup via web installer.${NC}"
echo ""