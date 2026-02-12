#!/bin/bash

################################################################################
# PELICAN COMPLETE UNINSTALLER v1.0
# Selective removal with confirmation for each component
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}╔════════════════════════════════════════╗${NC}"
echo -e "${RED}║    PELICAN COMPLETE UNINSTALLER        ║${NC}"
echo -e "${RED}║    ⚠️  THIS WILL REMOVE COMPONENTS     ║${NC}"
echo -e "${RED}╚════════════════════════════════════════╝${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}Switching to root...${NC}"
   sudo "$0" "$@"
   exit $?
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.pelican.env"

# Load config if exists
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo -e "${GREEN}Config loaded: $ENV_FILE${NC}"
    echo ""
fi

echo -e "${YELLOW}⚠️  WARNING: This will selectively remove Pelican components${NC}"
echo -e "${CYAN}You'll be asked for confirmation before each removal${NC}"
echo ""
read -p "Continue? (type 'YES' to proceed): " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo -e "${GREEN}Cancelled.${NC}"
    exit 0
fi

echo ""

# ============================================================================
# 1. STOP SERVICES
# ============================================================================
echo -e "${CYAN}[1/11] Stopping services...${NC}"

# Stop cloudflared
pkill cloudflared 2>/dev/null && echo -e "${GREEN}   ✓ Stopped Cloudflare tunnels${NC}"

# Stop Wings
pkill wings 2>/dev/null && echo -e "${GREEN}   ✓ Stopped Wings${NC}"

# Stop queue worker
pkill -f "queue:work" 2>/dev/null && echo -e "${GREEN}   ✓ Stopped queue worker${NC}"
supervisorctl stop pelican-queue 2>/dev/null

# Stop Nginx
if pgrep nginx >/dev/null; then
    systemctl stop nginx 2>/dev/null || service nginx stop 2>/dev/null || pkill nginx
    echo -e "${GREEN}   ✓ Stopped Nginx${NC}"
fi

# Stop PHP-FPM
if pgrep php-fpm >/dev/null; then
    systemctl stop php8.3-fpm 2>/dev/null || service php8.3-fpm stop 2>/dev/null || pkill php-fpm
    echo -e "${GREEN}   ✓ Stopped PHP-FPM${NC}"
fi

sleep 2
echo -e "${GREEN}   ✓ All services stopped${NC}"

# ============================================================================
# 2. REMOVE PANEL FILES
# ============================================================================
echo ""
echo -e "${CYAN}[2/11] Remove Panel files? (/var/www/pelican)${NC}"
read -p "Remove? (y/n): " REMOVE_PANEL

if [[ "$REMOVE_PANEL" =~ ^[Yy] ]]; then
    if [ -d "/var/www/pelican" ]; then
        echo -e "${YELLOW}   Creating backup before removal...${NC}"
        BACKUP_DIR="${SCRIPT_DIR}/.backups"
        mkdir -p "$BACKUP_DIR"
        tar -czf "${BACKUP_DIR}/pelican-panel-backup-$(date +%Y%m%d_%H%M%S).tar.gz" /var/www/pelican 2>/dev/null
        
        rm -rf /var/www/pelican
        echo -e "${GREEN}   ✓ Panel files removed${NC}"
        echo -e "${GREEN}   ✓ Backup saved to: ${BACKUP_DIR}${NC}"
    else
        echo -e "${YELLOW}   Panel directory not found${NC}"
    fi
else
    echo -e "${BLUE}   Panel files kept${NC}"
fi

# ============================================================================
# 3. REMOVE WINGS
# ============================================================================
echo ""
echo -e "${CYAN}[3/11] Remove Wings? (/usr/local/bin/wings)${NC}"
read -p "Remove? (y/n): " REMOVE_WINGS

if [[ "$REMOVE_WINGS" =~ ^[Yy] ]]; then
    # Backup Wings config
    if [ -f "/etc/pelican/config.yml" ]; then
        BACKUP_DIR="${SCRIPT_DIR}/.backups"
        mkdir -p "$BACKUP_DIR"
        cp /etc/pelican/config.yml "${BACKUP_DIR}/wings-config-backup-$(date +%Y%m%d_%H%M%S).yml"
        echo -e "${GREEN}   ✓ Wings config backed up${NC}"
    fi
    
    # Remove Wings binary
    rm -f /usr/local/bin/wings
    
    # Remove Wings config
    rm -rf /etc/pelican
    
    # Remove Wings data
    echo -e "${YELLOW}   Remove Wings data? (/var/lib/pelican - contains server files)${NC}"
    read -p "   Remove data? (y/n): " REMOVE_WINGS_DATA
    
    if [[ "$REMOVE_WINGS_DATA" =~ ^[Yy] ]]; then
        rm -rf /var/lib/pelican
        echo -e "${GREEN}   ✓ Wings data removed${NC}"
    else
        echo -e "${BLUE}   Wings data kept${NC}"
    fi
    
    # Remove Wings logs
    rm -rf /var/log/pelican
    rm -f /tmp/wings.log
    
    # Remove systemd service
    if [ -f "/etc/systemd/system/wings.service" ]; then
        systemctl disable wings 2>/dev/null
        rm -f /etc/systemd/system/wings.service
        systemctl daemon-reload 2>/dev/null
    fi
    
    echo -e "${GREEN}   ✓ Wings removed${NC}"
else
    echo -e "${BLUE}   Wings kept${NC}"
fi

# ============================================================================
# 4. REMOVE DATABASE DATA
# ============================================================================
echo ""
echo -e "${CYAN}[4/11] Remove Database data?${NC}"
echo -e "${RED}   ⚠️  WARNING: This will DELETE all servers, users, and settings!${NC}"
read -p "Remove database data? (y/n): " REMOVE_DB

if [[ "$REMOVE_DB" =~ ^[Yy] ]]; then
    if [ -n "$DB_DRIVER" ] && [ -n "$DB_HOST" ] && [ -n "$DB_NAME" ]; then
        echo -e "${RED}   ⚠️  FINAL CONFIRMATION${NC}"
        echo -e "   Database: ${DB_DRIVER} @ ${DB_HOST}/${DB_NAME}"
        read -p "   Type 'DELETE ALL DATA' to confirm: " DB_CONFIRM
        
        if [ "$DB_CONFIRM" = "DELETE ALL DATA" ]; then
            if [ "$DB_DRIVER" = "pgsql" ]; then
                PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" 2>/dev/null && {
                    echo -e "${GREEN}   ✓ PostgreSQL data removed${NC}"
                } || {
                    echo -e "${RED}   ✗ Failed to drop database${NC}"
                }
            else
                mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME};" 2>/dev/null && {
                    echo -e "${GREEN}   ✓ MySQL data removed${NC}"
                } || {
                    echo -e "${RED}   ✗ Failed to drop database${NC}"
                }
            fi
        else
            echo -e "${BLUE}   Database data kept (wrong confirmation)${NC}"
        fi
    else
        echo -e "${YELLOW}   Database config not found in .pelican.env${NC}"
    fi
else
    echo -e "${BLUE}   Database data kept${NC}"
fi

# ============================================================================
# 5. REMOVE REDIS DATA
# ============================================================================
echo ""
echo -e "${CYAN}[5/11] Remove Redis data? (cache, sessions)${NC}"
read -p "Remove? (y/n): " REMOVE_REDIS_DATA

if [[ "$REMOVE_REDIS_DATA" =~ ^[Yy] ]]; then
    redis-cli FLUSHALL 2>/dev/null && {
        echo -e "${GREEN}   ✓ Redis data cleared${NC}"
    } || {
        echo -e "${YELLOW}   Redis not running or already empty${NC}"
    }
else
    echo -e "${BLUE}   Redis data kept${NC}"
fi

# ============================================================================
# 6. REMOVE NGINX CONFIG
# ============================================================================
echo ""
echo -e "${CYAN}[6/11] Remove Nginx configuration?${NC}"
read -p "Remove? (y/n): " REMOVE_NGINX_CONF

if [[ "$REMOVE_NGINX_CONF" =~ ^[Yy] ]]; then
    rm -f /etc/nginx/sites-available/pelican.conf
    rm -f /etc/nginx/sites-enabled/pelican.conf
    rm -rf /etc/ssl/pelican
    echo -e "${GREEN}   ✓ Nginx config removed${NC}"
else
    echo -e "${BLUE}   Nginx config kept${NC}"
fi

# ============================================================================
# 7. REMOVE PHP-FPM CONFIG
# ============================================================================
echo ""
echo -e "${CYAN}[7/11] Reset PHP-FPM configuration?${NC}"
read -p "Reset? (y/n): " RESET_PHP

if [[ "$RESET_PHP" =~ ^[Yy] ]]; then
    # Reset to default socket mode
    for ver in 8.3 8.4 8.2; do
        if [ -f "/etc/php/${ver}/fpm/pool.d/www.conf" ]; then
            sed -i 's|listen = 127.0.0.1:9000|listen = /run/php/php'${ver}'-fpm.sock|' /etc/php/${ver}/fpm/pool.d/www.conf
            echo -e "${GREEN}   ✓ PHP ${ver} config reset${NC}"
        fi
    done
else
    echo -e "${BLUE}   PHP-FPM config kept${NC}"
fi

# ============================================================================
# 8. REMOVE SYSTEMD SERVICES
# ============================================================================
echo ""
echo -e "${CYAN}[8/11] Remove systemd services?${NC}"
read -p "Remove? (y/n): " REMOVE_SYSTEMD

if [[ "$REMOVE_SYSTEMD" =~ ^[Yy] ]]; then
    # Panel queue
    if [ -f "/etc/systemd/system/pelican-queue.service" ]; then
        systemctl disable pelican-queue 2>/dev/null
        systemctl stop pelican-queue 2>/dev/null
        rm -f /etc/systemd/system/pelican-queue.service
        echo -e "${GREEN}   ✓ Queue service removed${NC}"
    fi
    
    # Wings
    if [ -f "/etc/systemd/system/wings.service" ]; then
        systemctl disable wings 2>/dev/null
        systemctl stop wings 2>/dev/null
        rm -f /etc/systemd/system/wings.service
        echo -e "${GREEN}   ✓ Wings service removed${NC}"
    fi
    
    # Cloudflared
    cloudflared service uninstall 2>/dev/null
    
    systemctl daemon-reload 2>/dev/null
    echo -e "${GREEN}   ✓ Systemd services removed${NC}"
else
    echo -e "${BLUE}   Systemd services kept${NC}"
fi

# ============================================================================
# 9. REMOVE SUPERVISOR CONFIG
# ============================================================================
echo ""
echo -e "${CYAN}[9/11] Remove supervisor configuration?${NC}"
read -p "Remove? (y/n): " REMOVE_SUPERVISOR

if [[ "$REMOVE_SUPERVISOR" =~ ^[Yy] ]]; then
    if [ -f "/etc/supervisor/conf.d/pelican-queue.conf" ]; then
        supervisorctl stop pelican-queue 2>/dev/null
        rm -f /etc/supervisor/conf.d/pelican-queue.conf
        supervisorctl reread 2>/dev/null
        supervisorctl update 2>/dev/null
        echo -e "${GREEN}   ✓ Supervisor config removed${NC}"
    else
        echo -e "${YELLOW}   Supervisor config not found${NC}"
    fi
else
    echo -e "${BLUE}   Supervisor config kept${NC}"
fi

# ============================================================================
# 10. REMOVE DOCKER CONTAINERS
# ============================================================================
echo ""
echo -e "${CYAN}[10/11] Remove Docker containers? (game servers)${NC}"
echo -e "${RED}   ⚠️  WARNING: This will stop and remove all game servers!${NC}"
read -p "Remove? (y/n): " REMOVE_CONTAINERS

if [[ "$REMOVE_CONTAINERS" =~ ^[Yy] ]]; then
    if docker ps -a >/dev/null 2>&1; then
        # Stop all containers
        docker ps -q | xargs -r docker stop 2>/dev/null
        
        # Remove all containers
        docker ps -aq | xargs -r docker rm 2>/dev/null
        
        # Remove pelican network
        docker network rm pelican_nw 2>/dev/null || true
        
        echo -e "${GREEN}   ✓ Docker containers removed${NC}"
        
        # Optional: Remove Docker images
        echo -e "${YELLOW}   Remove Docker images too?${NC}"
        read -p "   Remove images? (y/n): " REMOVE_IMAGES
        
        if [[ "$REMOVE_IMAGES" =~ ^[Yy] ]]; then
            docker images -q | xargs -r docker rmi -f 2>/dev/null
            echo -e "${GREEN}   ✓ Docker images removed${NC}"
        fi
    else
        echo -e "${YELLOW}   Docker not running${NC}"
    fi
else
    echo -e "${BLUE}   Docker containers kept${NC}"
fi

# ============================================================================
# 11. REMOVE CONFIGURATION FILES
# ============================================================================
echo ""
echo -e "${CYAN}[11/11] Remove .pelican.env and backups?${NC}"
read -p "Remove? (y/n): " REMOVE_CONFIG

if [[ "$REMOVE_CONFIG" =~ ^[Yy] ]]; then
    echo -e "${YELLOW}   This will remove:${NC}"
    echo -e "   - .pelican.env"
    echo -e "   - .backups/ directory"
    read -p "   Confirm removal? (y/n): " CONFIRM_CONFIG
    
    if [[ "$CONFIRM_CONFIG" =~ ^[Yy] ]]; then
        rm -f "${SCRIPT_DIR}/.pelican.env"
        rm -rf "${SCRIPT_DIR}/.backups"
        echo -e "${GREEN}   ✓ Configuration files removed${NC}"
    else
        echo -e "${BLUE}   Configuration files kept${NC}"
    fi
else
    echo -e "${BLUE}   Configuration files kept${NC}"
fi

# ============================================================================
# OPTIONAL: REMOVE INSTALLED PACKAGES
# ============================================================================
echo ""
echo -e "${CYAN}[OPTIONAL] Remove installed packages?${NC}"
echo -e "${YELLOW}This includes: PHP, Nginx, Redis, Composer, Cloudflared${NC}"
read -p "Remove packages? (y/n): " REMOVE_PACKAGES

if [[ "$REMOVE_PACKAGES" =~ ^[Yy] ]]; then
    echo -e "${YELLOW}   Removing packages...${NC}"
    
    # Remove cloudflared
    apt remove -y cloudflared 2>/dev/null && echo -e "${GREEN}   ✓ Cloudflared removed${NC}"
    
    # Remove PHP
    apt remove -y php8.3* 2>/dev/null && echo -e "${GREEN}   ✓ PHP 8.3 removed${NC}"
    
    # Remove Nginx
    apt remove -y nginx 2>/dev/null && echo -e "${GREEN}   ✓ Nginx removed${NC}"
    
    # Remove Redis
    apt remove -y redis-server 2>/dev/null && echo -e "${GREEN}   ✓ Redis removed${NC}"
    
    # Remove Composer
    rm -f /usr/local/bin/composer && echo -e "${GREEN}   ✓ Composer removed${NC}"
    
    # Remove Supervisor
    apt remove -y supervisor 2>/dev/null && echo -e "${GREEN}   ✓ Supervisor removed${NC}"
    
    # Autoremove
    apt autoremove -y 2>/dev/null
    
    echo -e "${GREEN}   ✓ Packages removed${NC}"
else
    echo -e "${BLUE}   Packages kept${NC}"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Uninstallation Complete!          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo -e "${CYAN}What was removed:${NC}"
[[ "$REMOVE_PANEL" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Panel files${NC}"
[[ "$REMOVE_WINGS" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Wings${NC}"
[[ "$REMOVE_DB" =~ ^[Yy] ]] && [ "$DB_CONFIRM" = "DELETE ALL DATA" ] && echo -e "${GREEN}  ✓ Database data${NC}"
[[ "$REMOVE_REDIS_DATA" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Redis data${NC}"
[[ "$REMOVE_NGINX_CONF" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Nginx config${NC}"
[[ "$REMOVE_SYSTEMD" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Systemd services${NC}"
[[ "$REMOVE_CONTAINERS" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Docker containers${NC}"
[[ "$REMOVE_CONFIG" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Config files${NC}"
[[ "$REMOVE_PACKAGES" =~ ^[Yy] ]] && echo -e "${GREEN}  ✓ Packages${NC}"

echo ""
echo -e "${CYAN}What was kept:${NC}"
[[ ! "$REMOVE_PANEL" =~ ^[Yy] ]] && echo -e "${BLUE}  - Panel files${NC}"
[[ ! "$REMOVE_WINGS" =~ ^[Yy] ]] && echo -e "${BLUE}  - Wings${NC}"
[[ ! "$REMOVE_DB" =~ ^[Yy] ]] || [ "$DB_CONFIRM" != "DELETE ALL DATA" ] && echo -e "${BLUE}  - Database data${NC}"
[[ "$REMOVE_WINGS" =~ ^[Yy] ]] && [[ ! "$REMOVE_WINGS_DATA" =~ ^[Yy] ]] && echo -e "${BLUE}  - Wings data (/var/lib/pelican)${NC}"

if [ -d "${SCRIPT_DIR}/.backups" ]; then
    echo ""
    echo -e "${CYAN}Backups available in:${NC}"
    echo -e "  ${GREEN}${SCRIPT_DIR}/.backups/${NC}"
    ls -lh "${SCRIPT_DIR}/.backups/" 2>/dev/null | tail -n +2
fi

echo ""
echo -e "${BLUE}Uninstallation complete!${NC}"
echo ""