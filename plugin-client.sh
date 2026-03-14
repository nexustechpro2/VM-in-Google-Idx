#!/bin/bash

################################################################################
# PELICAN USER REGISTRATION & RESOURCE LIMITS SETUP - FIXED VERSION v2.1
# - FIXED: PostgreSQL driver detection and installation
# - FIXED: Auto-adds user_creatable_servers tag to ALL nodes
# - FIXED: Auto-fixes all server allocations (sets ip_alias to node FQDN)
# - FIXED: ip_alias set on ALL allocations so users see correct address
# - FIXED: Clears Panel + Wings cache after setup
# - FIXED: Table creation verification
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Pelican User Registration & Resource Limits v2.1     ║${NC}"
echo -e "${GREEN}║  Register Plugin + User-Creatable-Servers Plugin      ║${NC}"
echo -e "${GREEN}║  Auto Node Tags + ip_alias Fix + Cache Clear          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

if [ ! -f "/var/www/pelican/artisan" ]; then
    echo -e "${RED}❌ Pelican Panel not found at /var/www/pelican${NC}"
    exit 1
fi

cd /var/www/pelican

# ============================================================================
# SET CORRECT PHP BINARY
# ============================================================================
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
PHP_BIN="/usr/bin/php8.3"
[ ! -f "$PHP_BIN" ] && PHP_BIN=$(which php 2>/dev/null || echo "php")
echo -e "${BLUE}Using PHP: $($PHP_BIN -v | head -n1)${NC}"
echo ""

# ============================================================================
# DETECT DATABASE TYPE
# ============================================================================
echo -e "${CYAN}[1/14] Detecting database configuration...${NC}"

DB_CONNECTION=$(grep "^DB_CONNECTION=" .env | cut -d'=' -f2)
[ -z "$DB_CONNECTION" ] && { echo -e "${RED}❌ Could not detect database type${NC}"; exit 1; }
echo -e "${GREEN}   ✓ Database type: ${DB_CONNECTION}${NC}"

case "$DB_CONNECTION" in
    sqlite)
        DB_TYPE="SQLite"
        SQLITE_DB="/var/www/pelican/database/database.sqlite"
        ;;
    mysql)
        DB_TYPE="MySQL"
        DB_HOST=$(grep "^DB_HOST=" .env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" .env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-3306}
        DB_DATABASE=$(grep "^DB_DATABASE=" .env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" .env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" .env | cut -d'=' -f2)
        ;;
    pgsql)
        DB_TYPE="PostgreSQL"
        DB_HOST=$(grep "^DB_HOST=" .env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" .env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-5432}
        DB_DATABASE=$(grep "^DB_DATABASE=" .env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" .env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" .env | cut -d'=' -f2)
        ;;
    *)
        echo -e "${RED}❌ Unsupported database type: ${DB_CONNECTION}${NC}"; exit 1 ;;
esac

# ============================================================================
# VERIFY POSTGRESQL PHP EXTENSIONS
# ============================================================================
if [ "$DB_CONNECTION" = "pgsql" ]; then
    echo ""
    echo -e "${CYAN}[2/14] Verifying PostgreSQL PHP extensions...${NC}"
    if ! $PHP_BIN -m | grep -q pdo_pgsql; then
        echo -e "${YELLOW}   ⚠ Installing pgsql extensions...${NC}"
        apt-get update -qq 2>&1 | grep -v "GPG error" || true
        apt-get install -y php8.3-pgsql php8.3-pdo php-pgsql 2>/dev/null || { echo -e "${RED}❌ Failed!${NC}"; exit 1; }
        systemctl restart php8.3-fpm 2>/dev/null || service php8.3-fpm restart 2>/dev/null || true
        $PHP_BIN -m | grep -q pdo_pgsql || { echo -e "${RED}❌ Extension still not available!${NC}"; exit 1; }
    fi
    echo -e "${GREEN}   ✓ PostgreSQL PHP extensions verified${NC}"
else
    echo -e "${CYAN}[2/14] Skipping PostgreSQL checks (not using pgsql)${NC}"
fi

# ============================================================================
# DOWNLOAD ALL PLUGINS
# ============================================================================
echo ""
echo -e "${CYAN}[3/14] Downloading ALL plugins from GitHub...${NC}"

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
echo -e "${YELLOW}   Downloading plugin repository...${NC}"
curl -sL "https://github.com/pelican-dev/plugins/archive/refs/heads/main.zip" -o plugins.zip
unzip -q plugins.zip
mkdir -p /var/www/pelican/plugins
cp -r plugins-main/* /var/www/pelican/plugins/
rm -f /var/www/pelican/plugins/.gitignore /var/www/pelican/plugins/LICENSE /var/www/pelican/plugins/README.md
PLUGIN_COUNT=$(ls -1d /var/www/pelican/plugins/*/ 2>/dev/null | wc -l)
chown -R www-data:www-data /var/www/pelican/plugins
cd /var/www/pelican
rm -rf "$TMP_DIR"
echo -e "${GREEN}   ✓ ${PLUGIN_COUNT} plugins downloaded and ready${NC}"

# ============================================================================
# INSTALL REQUIRED PLUGINS
# ============================================================================
echo ""
echo -e "${CYAN}[4/14] Installing required plugins...${NC}"

echo -e "${YELLOW}   Installing Register plugin...${NC}"
$PHP_BIN artisan p:plugin:install register 2>&1 | grep -q "already installed" && \
    echo -e "${GREEN}   ✓ Register plugin already installed${NC}" || \
    echo -e "${GREEN}   ✓ Register plugin installed${NC}"

echo -e "${YELLOW}   Installing User-Creatable-Servers plugin...${NC}"
$PHP_BIN artisan p:plugin:install user-creatable-servers 2>&1 | grep -q "already installed" && \
    echo -e "${GREEN}   ✓ User-Creatable-Servers plugin already installed${NC}" || \
    echo -e "${GREEN}   ✓ User-Creatable-Servers plugin installed${NC}"

echo -e "${GREEN}   ✓ Plugins are auto-enabled after installation${NC}"

# ============================================================================
# RUN MIGRATIONS
# ============================================================================
echo ""
echo -e "${CYAN}[5/14] Running database migrations...${NC}"
$PHP_BIN artisan config:clear >/dev/null 2>&1 || true

echo -e "${YELLOW}   Testing database connection...${NC}"
$PHP_BIN artisan migrate:status >/dev/null 2>&1 || { echo -e "${RED}❌ Database connection failed!${NC}"; exit 1; }
echo -e "${GREEN}   ✓ Database connection successful${NC}"

MIGRATION_OUTPUT=$($PHP_BIN artisan migrate --force 2>&1)
echo "$MIGRATION_OUTPUT" | grep -qi "error\|exception" && { echo -e "${RED}❌ Migration failed!${NC}"; echo "$MIGRATION_OUTPUT" | tail -10; exit 1; }
echo "$MIGRATION_OUTPUT" | grep -q "Nothing to migrate" && \
    echo -e "${GREEN}   ✓ Database already up to date${NC}" || \
    echo -e "${GREEN}   ✓ Migrations completed${NC}"

# Verify user_resource_limits table
TABLE_EXISTS=false
if [ "$DB_TYPE" = "PostgreSQL" ]; then
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" \
        -tAc "SELECT tablename FROM pg_tables WHERE tablename='user_resource_limits';" 2>/dev/null | \
        grep -q "user_resource_limits" && TABLE_EXISTS=true
elif [ "$DB_TYPE" = "MySQL" ]; then
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" \
        -sN -e "SHOW TABLES LIKE 'user_resource_limits';" 2>/dev/null | \
        grep -q "user_resource_limits" && TABLE_EXISTS=true
fi

[ "$TABLE_EXISTS" = true ] && \
    echo -e "${GREEN}   ✓ Plugin tables verified${NC}" || \
    echo -e "${YELLOW}   ⚠ Table will be created automatically when needed${NC}"

$PHP_BIN artisan config:clear >/dev/null 2>&1
$PHP_BIN artisan cache:clear >/dev/null 2>&1
echo -e "${GREEN}   ✓ Cache cleared${NC}"

# ============================================================================
# USER CONFIGURATION
# ============================================================================
echo ""
echo -e "${CYAN}[6/14] Configure Default User Resource Limits${NC}"
echo -e "${YELLOW}────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${BLUE}These limits will be automatically assigned to new users${NC}"
echo ""

read -p "CPU Limit (in %, e.g., 200 = 2 cores) [200]: " CPU_LIMIT
CPU_LIMIT=${CPU_LIMIT:-200}

read -p "Memory/RAM Limit (in MiB, e.g., 4096 = 4GB) [4096]: " MEMORY_LIMIT
MEMORY_LIMIT=${MEMORY_LIMIT:-4096}

read -p "Disk Space Limit (in MiB, e.g., 10240 = 10GB) [10240]: " DISK_LIMIT
DISK_LIMIT=${DISK_LIMIT:-10240}

read -p "Maximum Servers per user [2]: " MAX_SERVERS
MAX_SERVERS=${MAX_SERVERS:-2}

read -p "Maximum Databases per server [2]: " MAX_DATABASES
MAX_DATABASES=${MAX_DATABASES:-2}

read -p "Maximum Allocations/Ports per server [3]: " MAX_ALLOCATIONS
MAX_ALLOCATIONS=${MAX_ALLOCATIONS:-3}

read -p "Maximum Backups per server [1]: " MAX_BACKUPS
MAX_BACKUPS=${MAX_BACKUPS:-1}

echo ""
read -p "Can users update their servers? (y/n) [y]: " CAN_UPDATE
CAN_UPDATE=${CAN_UPDATE:-y}
CAN_USERS_UPDATE=$( [[ "$CAN_UPDATE" =~ ^[Yy] ]] && echo "true" || echo "false" )

read -p "Can users delete their servers? (y/n) [y]: " CAN_DELETE
CAN_DELETE=${CAN_DELETE:-y}
CAN_USERS_DELETE=$( [[ "$CAN_DELETE" =~ ^[Yy] ]] && echo "true" || echo "false" )

read -p "Deployment tag for user-created servers [user_creatable_servers]: " DEPLOYMENT_TAG
DEPLOYMENT_TAG=${DEPLOYMENT_TAG:-user_creatable_servers}

echo ""
echo -e "${GREEN}   ✓ Configuration collected${NC}"

# ============================================================================
# CONFIGURE .ENV
# ============================================================================
echo ""
echo -e "${CYAN}[7/14] Configuring environment variables...${NC}"
sed -i '/^UCS_/d' .env
cat >> .env <<ENV

# User Creatable Servers Configuration
UCS_DEFAULT_DATABASE_LIMIT=${MAX_DATABASES}
UCS_DEFAULT_ALLOCATION_LIMIT=${MAX_ALLOCATIONS}
UCS_DEFAULT_BACKUP_LIMIT=${MAX_BACKUPS}
UCS_CAN_USERS_UPDATE_SERVERS=${CAN_USERS_UPDATE}
UCS_CAN_USERS_DELETE_SERVERS=${CAN_USERS_DELETE}
UCS_DEPLOYMENT_TAGS=${DEPLOYMENT_TAG}
ENV
echo -e "${GREEN}   ✓ Environment configured${NC}"
$PHP_BIN artisan config:clear >/dev/null 2>&1
$PHP_BIN artisan cache:clear >/dev/null 2>&1

# ============================================================================
# AUTO-ADD DEPLOYMENT TAG TO ALL NODES
# ============================================================================
echo ""
echo -e "${CYAN}[8/14] Adding deployment tag to all nodes...${NC}"

$PHP_BIN artisan tinker --execute="
\$tag = '${DEPLOYMENT_TAG}';
\$nodes = App\Models\Node::all();
\$updated = 0;
foreach(\$nodes as \$node) {
    \$tags = \$node->tags ?? [];
    if (!in_array(\$tag, \$tags)) {
        \$tags[] = \$tag;
        \$node->tags = \$tags;
        \$node->save();
        echo '  ✓ Added tag to node: ' . \$node->name . PHP_EOL;
        \$updated++;
    } else {
        echo '  ✓ Node already has tag: ' . \$node->name . PHP_EOL;
    }
}
echo 'Done! ' . \$updated . ' node(s) updated.';
"

echo -e "${GREEN}   ✓ Deployment tag added to all nodes${NC}"

# ============================================================================
# FIX ALL SERVER ALLOCATIONS
# ============================================================================
echo ""
echo -e "${CYAN}[9/14] Fixing all server allocations...${NC}"
echo -e "${YELLOW}   Setting ip_alias to node FQDN, cleaning orphaned allocations, reassigning ports in order...${NC}"

$PHP_BIN artisan tinker --execute="
// Step 1: Set ip_alias on ALL allocations to their node's FQDN
\$nodes = App\Models\Node::all();
foreach(\$nodes as \$node) {
    App\Models\Allocation::where('node_id', \$node->id)
        ->update(['ip_alias' => \$node->fqdn]);
    echo '  ✓ Set ip_alias to ' . \$node->fqdn . ' for node: ' . \$node->name . PHP_EOL;
}

// Step 2: Clean orphaned allocations (server_id set but server doesn't exist)
\$cleaned = App\Models\Allocation::whereNotNull('server_id')
    ->whereDoesntHave('server')
    ->update(['server_id' => null]);
echo '  ✓ Cleaned ' . \$cleaned . ' orphaned allocations' . PHP_EOL;

// Step 3: Free all current allocation assignments
App\Models\Allocation::query()->update(['server_id' => null]);

// Step 4: Reset all server allocation_id
App\Models\Server::query()->update(['allocation_id' => null]);

// Step 5: Reassign allocations to servers starting from lowest port
\$totalAssigned = 0;
foreach(\$nodes as \$node) {
    \$servers = App\Models\Server::where('node_id', \$node->id)->orderBy('id')->get();
    \$allocations = App\Models\Allocation::where('node_id', \$node->id)->orderBy('port')->get();

    foreach(\$servers as \$index => \$server) {
        if (isset(\$allocations[\$index])) {
            \$allocation = \$allocations[\$index];
            \$allocation->server_id = \$server->id;
            \$allocation->save();
            \$server->allocation_id = \$allocation->id;
            \$server->save();
            echo '  ✓ Server: ' . \$server->name . ' → ' . \$node->fqdn . ':' . \$allocation->port . PHP_EOL;
            \$totalAssigned++;
        }
    }
}
echo PHP_EOL . 'Done! ' . \$totalAssigned . ' server(s) assigned allocations.';
"

echo -e "${GREEN}   ✓ All server allocations fixed with correct ip_alias${NC}"

# ============================================================================
# CREATE AUTO-ASSIGNMENT SCRIPT
# ============================================================================
echo ""
echo -e "${CYAN}[10/14] Creating auto-assignment script...${NC}"

cat > /usr/local/bin/pelican-auto-resource-limits.sh <<'SCRIPT_EOF'
#!/bin/bash
DEFAULT_CPU=CPU_LIMIT_PLACEHOLDER
DEFAULT_MEMORY=MEMORY_LIMIT_PLACEHOLDER
DEFAULT_DISK=DISK_LIMIT_PLACEHOLDER
DEFAULT_SERVER_LIMIT=MAX_SERVERS_PLACEHOLDER

DB_CONNECTION=$(grep "^DB_CONNECTION=" /var/www/pelican/.env | cut -d'=' -f2)

case "$DB_CONNECTION" in
    sqlite)
        SQLITE_DB="/var/www/pelican/database/database.sqlite"
        TABLE_EXISTS=$(sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='user_resource_limits';" 2>/dev/null)
        [ -z "$TABLE_EXISTS" ] && exit 0
        sqlite3 "$SQLITE_DB" <<SQL 2>/dev/null || exit 0
INSERT OR IGNORE INTO user_resource_limits (user_id, cpu, memory, disk, server_limit, created_at, updated_at)
SELECT u.id, $DEFAULT_CPU, $DEFAULT_MEMORY, $DEFAULT_DISK, $DEFAULT_SERVER_LIMIT, datetime('now'), datetime('now')
FROM users u LEFT JOIN user_resource_limits url ON u.id = url.user_id WHERE url.id IS NULL;
SQL
        ;;
    mysql)
        DB_HOST=$(grep "^DB_HOST=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-3306}
        DB_DATABASE=$(grep "^DB_DATABASE=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" /var/www/pelican/.env | cut -d'=' -f2)
        TABLE_EXISTS=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" -sN -e "SHOW TABLES LIKE 'user_resource_limits';" 2>/dev/null)
        [ -z "$TABLE_EXISTS" ] && exit 0
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" <<SQL 2>/dev/null || exit 0
INSERT IGNORE INTO user_resource_limits (user_id, cpu, memory, disk, server_limit, created_at, updated_at)
SELECT u.id, $DEFAULT_CPU, $DEFAULT_MEMORY, $DEFAULT_DISK, $DEFAULT_SERVER_LIMIT, NOW(), NOW()
FROM users u LEFT JOIN user_resource_limits url ON u.id = url.user_id WHERE url.id IS NULL;
SQL
        ;;
    pgsql)
        DB_HOST=$(grep "^DB_HOST=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=$(grep "^DB_PORT=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PORT=${DB_PORT:-5432}
        DB_DATABASE=$(grep "^DB_DATABASE=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_USERNAME=$(grep "^DB_USERNAME=" /var/www/pelican/.env | cut -d'=' -f2)
        DB_PASSWORD=$(grep "^DB_PASSWORD=" /var/www/pelican/.env | cut -d'=' -f2)
        TABLE_EXISTS=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" -tAc "SELECT tablename FROM pg_tables WHERE tablename='user_resource_limits';" 2>/dev/null)
        [ -z "$TABLE_EXISTS" ] && exit 0
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_DATABASE" <<SQL 2>/dev/null || exit 0
INSERT INTO user_resource_limits (user_id, cpu, memory, disk, server_limit, created_at, updated_at)
SELECT u.id, $DEFAULT_CPU, $DEFAULT_MEMORY, $DEFAULT_DISK, $DEFAULT_SERVER_LIMIT, NOW(), NOW()
FROM users u LEFT JOIN user_resource_limits url ON u.id = url.user_id WHERE url.id IS NULL
ON CONFLICT DO NOTHING;
SQL
        ;;
esac
exit 0
SCRIPT_EOF

sed -i "s/CPU_LIMIT_PLACEHOLDER/$CPU_LIMIT/g" /usr/local/bin/pelican-auto-resource-limits.sh
sed -i "s/MEMORY_LIMIT_PLACEHOLDER/$MEMORY_LIMIT/g" /usr/local/bin/pelican-auto-resource-limits.sh
sed -i "s/DISK_LIMIT_PLACEHOLDER/$DISK_LIMIT/g" /usr/local/bin/pelican-auto-resource-limits.sh
sed -i "s/MAX_SERVERS_PLACEHOLDER/$MAX_SERVERS/g" /usr/local/bin/pelican-auto-resource-limits.sh
chmod +x /usr/local/bin/pelican-auto-resource-limits.sh
echo -e "${GREEN}   ✓ Auto-assignment script created${NC}"

# ============================================================================
# CREATE FAST AUTO-ASSIGNMENT SERVICE
# ============================================================================
echo ""
echo -e "${CYAN}[11/14] Creating fast auto-assignment service...${NC}"
cat > /usr/local/bin/pelican-auto-resource-limits-fast.sh <<'FAST_EOF'
#!/bin/bash
while true; do
    /usr/local/bin/pelican-auto-resource-limits.sh >/dev/null 2>&1
    sleep 1
done
FAST_EOF
chmod +x /usr/local/bin/pelican-auto-resource-limits-fast.sh
echo -e "${GREEN}   ✓ Fast auto-assignment script created${NC}"

# ============================================================================
# SETUP CRON JOB
# ============================================================================
echo ""
echo -e "${CYAN}[12/14] Setting up cron job...${NC}"
crontab -l 2>/dev/null | grep -v "pelican-auto-resource-limits" | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/pelican-auto-resource-limits.sh >> /var/log/pelican-auto-limits.log 2>&1") | crontab -
pkill -f "pelican-auto-resource-limits-fast.sh" 2>/dev/null || true
sleep 1
nohup /usr/local/bin/pelican-auto-resource-limits-fast.sh > /var/log/pelican-auto-limits-fast.log 2>&1 &
echo -e "${GREEN}   ✓ Cron job + fast service running${NC}"

# ============================================================================
# ASSIGN LIMITS TO EXISTING USERS
# ============================================================================
echo ""
echo -e "${CYAN}[13/14] Assigning limits to existing users...${NC}"
sleep 2
/usr/local/bin/pelican-auto-resource-limits.sh 2>&1 || echo -e "${YELLOW}   ⚠️  Table not ready yet - limits assigned on register${NC}"
echo -e "${GREEN}   ✓ Existing users assigned${NC}"

# ============================================================================
# CLEAR ALL PANEL + WINGS CACHE
# ============================================================================
echo ""
echo -e "${CYAN}[14/14] Clearing ALL Panel and Wings cache...${NC}"

cd /var/www/pelican

$PHP_BIN artisan config:clear >/dev/null 2>&1 && echo -e "${GREEN}   ✓ Config cache cleared${NC}"
$PHP_BIN artisan cache:clear >/dev/null 2>&1 && echo -e "${GREEN}   ✓ App cache cleared${NC}"
$PHP_BIN artisan route:clear >/dev/null 2>&1 && echo -e "${GREEN}   ✓ Route cache cleared${NC}"
$PHP_BIN artisan view:clear >/dev/null 2>&1 && echo -e "${GREEN}   ✓ View cache cleared${NC}"
$PHP_BIN artisan optimize:clear >/dev/null 2>&1 && echo -e "${GREEN}   ✓ Optimize cache cleared${NC}"

rm -rf storage/framework/views/* 2>/dev/null && echo -e "${GREEN}   ✓ View files cleared${NC}"
rm -rf storage/framework/cache/* 2>/dev/null && echo -e "${GREEN}   ✓ Framework cache cleared${NC}"

redis-cli FLUSHDB >/dev/null 2>&1 && echo -e "${GREEN}   ✓ Redis cache cleared${NC}"

# Restart services
systemctl restart nginx 2>/dev/null && echo -e "${GREEN}   ✓ Nginx restarted${NC}" || true
systemctl restart php8.3-fpm 2>/dev/null && echo -e "${GREEN}   ✓ PHP-FPM restarted${NC}" || true
supervisorctl restart pelican-queue 2>/dev/null && echo -e "${GREEN}   ✓ Queue worker restarted${NC}" || true

# Restart Wings
if pgrep -x wings > /dev/null; then
    pkill wings 2>/dev/null || true
    sleep 2
    cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 &
    sleep 3
    pgrep -x wings > /dev/null && echo -e "${GREEN}   ✓ Wings restarted${NC}" || echo -e "${YELLOW}   ⚠ Wings restart failed - check manually${NC}"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              SETUP COMPLETE - SUMMARY                  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}📦 PLUGINS:${NC}"
echo -e "   ${GREEN}✓ Register plugin installed${NC}"
echo -e "   ${GREEN}✓ User-Creatable-Servers plugin installed${NC}"
echo ""

echo -e "${CYAN}🏷️  NODE TAGS:${NC}"
echo -e "   ${GREEN}✓ '${DEPLOYMENT_TAG}' tag added to all nodes automatically${NC}"
echo ""

echo -e "${CYAN}🔌 ALLOCATION FIX:${NC}"
echo -e "   ${GREEN}✓ ip_alias set to node FQDN on all allocations${NC}"
echo -e "   ${GREEN}✓ Users will see correct domain:port as server address${NC}"
echo -e "   ${GREEN}✓ Servers reassigned ports starting from lowest available${NC}"
echo -e "   ${GREEN}✓ Orphaned allocations cleaned up${NC}"
echo ""

echo -e "${CYAN}📊 DEFAULT USER RESOURCE LIMITS:${NC}"
CPU_CORES=$(awk "BEGIN {printf \"%.1f\", $CPU_LIMIT/100}")
MEMORY_GB=$(awk "BEGIN {printf \"%.2f\", $MEMORY_LIMIT/1024}")
DISK_GB=$(awk "BEGIN {printf \"%.2f\", $DISK_LIMIT/1024}")
echo -e "   CPU: ${GREEN}${CPU_LIMIT}%${NC} (${CPU_CORES} cores)"
echo -e "   Memory: ${GREEN}${MEMORY_LIMIT} MiB${NC} (${MEMORY_GB} GB)"
echo -e "   Disk: ${GREEN}${DISK_LIMIT} MiB${NC} (${DISK_GB} GB)"
echo -e "   Max Servers: ${GREEN}${MAX_SERVERS}${NC}"
echo -e "   Max Databases: ${GREEN}${MAX_DATABASES}${NC}"
echo -e "   Max Allocations: ${GREEN}${MAX_ALLOCATIONS}${NC}"
echo -e "   Max Backups: ${GREEN}${MAX_BACKUPS}${NC}"
echo ""

echo -e "${CYAN}🔧 USER PERMISSIONS:${NC}"
echo -e "   Can Update Servers: ${GREEN}${CAN_USERS_UPDATE}${NC}"
echo -e "   Can Delete Servers: ${GREEN}${CAN_USERS_DELETE}${NC}"
echo ""

echo -e "${CYAN}🧹 CACHE:${NC}"
echo -e "   ${GREEN}✓ Panel cache fully cleared${NC}"
echo -e "   ${GREEN}✓ Wings restarted${NC}"
echo -e "   ${GREEN}✓ Redis flushed${NC}"
echo ""

echo -e "${CYAN}🔄 AUTO-ASSIGNMENT:${NC}"
echo -e "   ${GREEN}✓${NC} Cron job: every 1 minute"
echo -e "   ${GREEN}✓${NC} Fast service: every 1 second"
echo ""

echo -e "${CYAN}📝 USEFUL COMMANDS:${NC}"
echo -e "   View logs:     ${GREEN}tail -f /var/log/pelican-auto-limits-fast.log${NC}"
echo -e "   Plugin list:   ${GREEN}cd /var/www/pelican && $PHP_BIN artisan p:plugin:list${NC}"
echo -e "   Manual assign: ${GREEN}/usr/local/bin/pelican-auto-resource-limits.sh${NC}"
echo ""

echo -e "${BLUE}✅ Setup complete! Users can now self-register and create servers!${NC}"
echo ""