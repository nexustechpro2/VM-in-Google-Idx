#!/usr/bin/env bash

# ==========================================
#   🚀 NEXUSBOT - ALL IN ONE TOOL
#   Created by NexusTechPro
#   github.com/Adexx-11234/newrepo
# ==========================================

set -u

# --- ANSI COLORS ---
C=$'\033[36m'   # Cyan
G=$'\033[32m'   # Green
R=$'\033[31m'   # Red
B=$'\033[34m'   # Blue
Y=$'\033[33m'   # Yellow
W=$'\033[97m'   # White
M=$'\033[35m'   # Magenta
N=$'\033[0m'    # Reset

BASE_URL="https://raw.githubusercontent.com/Adexx-11234/newrepo/main"

# --- HEADER ---
header() {
    clear
    echo -e "${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${B}║                                                          ║${N}"
    echo -e "${B}║   ${C} _   _                    ${Y}  ____        _   ${B}         ║${N}"
    echo -e "${B}║   ${C}| \ | | _____  ___   _ ___${Y}| __ )  ___ | |_ ${B}         ║${N}"
    echo -e "${B}║   ${C}|  \| |/ _ \ \/ / | | / __|${Y}  _ \ / _ \| __|${B}         ║${N}"
    echo -e "${B}║   ${C}| |\  |  __/>  <| |_| \__ \${Y}| |_) | (_) | |_ ${B}        ║${N}"
    echo -e "${B}║   ${C}|_| \_|\___/_/\_\\__,_|___/${Y}|____/ \___/ \__|${B}        ║${N}"
    echo -e "${B}║                                                          ║${N}"
    echo -e "${B}║        ${Y}⚡ NexusBot All-In-One Server Manager ⚡${B}         ║${N}"
    echo -e "${B}║              ${G}github.com/Adexx-11234/newrepo${B}              ║${N}"
    echo -e "${B}╚══════════════════════════════════════════════════════════╝${N}"
    echo ""
}

# --- PAUSE ---
pause() {
    echo ""
    read -p "${W}  Press [Enter] to return to menu...${N}" dummy
}

# --- SECTION HEADER ---
section() {
    echo ""
    echo -e "${B}══════════════════════════════════════════════════════════${N}"
    echo -e "${Y}  $1${N}"
    echo -e "${B}══════════════════════════════════════════════════════════${N}"
    echo ""
}

# --- MAIN LOOP ---
while true; do
    header

    echo -e "${B}  ┌─────────────────────────────────────────────────────┐${N}"
    echo -e "${B}  │              ${Y}🖥️  UBUNTU / VM SETUP${B}                   │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │  ${C}1)${W}  Install Ubuntu VPS          ${G}(Google IDX)${B}        │${N}"
    echo -e "${B}  │  ${C}2)${W}  Server Setup Script         ${G}(SSH+RDP+Tailscale)${B} │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │              ${Y}🐦 PELICAN PANEL${B}                         │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │  ${C}3)${W}  Install Pelican Panel        ${G}(Full Setup)${B}       │${N}"
    echo -e "${B}  │  ${C}4)${W}  Install Pelican Wings        ${G}(Node Daemon)${B}      │${N}"
    echo -e "${B}  │  ${C}5)${W}  User Registration + Limits   ${G}(Plugins)${B}          │${N}"
    echo -e "${B}  │  ${C}6)${W}  Restart All Services         ${G}(Panel+Wings)${B}      │${N}"
    echo -e "${B}  │  ${C}7)${W}  Uninstall Pelican            ${G}(Clean Remove)${B}     │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │              ${Y}🔧 SYSTEM TOOLS${B}                          │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │  ${C}8)${W}  Install Tailscale            ${G}(VPN Tunnel)${B}       │${N}"
    echo -e "${B}  │  ${C}9)${W}  Install xRDP                 ${G}(Remote Desktop)${B}   │${N}"
    echo -e "${B}  │  ${C}10)${W} Install sshx                 ${G}(Terminal Share)${B}   │${N}"
    echo -e "${B}  │  ${C}11)${W} System Status                ${G}(Health Check)${B}     │${N}"
    echo -e "${B}  │  ${C}12)${W} Clear All Cache              ${G}(Panel Cache)${B}      │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │              ${Y}📖 INFO${B}                                  │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │  ${C}13)${W} How to stay 24/7             ${G}(IDX Guide)${B}        │${N}"
    echo -e "${B}  │  ${C}14)${W} View README                  ${G}(Full Guide)${B}       │${N}"
    echo -e "${B}  ├─────────────────────────────────────────────────────┤${N}"
    echo -e "${B}  │  ${R}0)  Exit${B}                                            │${N}"
    echo -e "${B}  └─────────────────────────────────────────────────────┘${N}"
    echo ""
    read -p "${Y}  👉 Select an option [0-14]: ${N}" choice

    case $choice in

        # ─── UBUNTU / VM ───────────────────────────────────────────────
        1)
            section "🖥️  Installing Ubuntu VPS (Google IDX)"
            echo -e "${Y}  This will install an Ubuntu VM using QEMU on Google IDX...${N}"
            echo ""
            bash <(curl -fsSL "${BASE_URL}/vps.sh")
            pause
            ;;

        2)
            section "🔧 Running Server Setup Script"
            echo -e "${Y}  This will set up SSH, Tailscale, xRDP, sshx, Firefox & Keepalive...${N}"
            echo ""
            bash <(curl -fsSL "${BASE_URL}/nexus-setup.sh")
            pause
            ;;

        # ─── PELICAN ──────────────────────────────────────────────────
        3)
            section "🐦 Installing Pelican Panel"
            echo -e "${Y}  Full Pelican Panel installation with Cloudflare Tunnel...${N}"
            echo ""
            bash <(curl -fsSL "${BASE_URL}/panel.sh")
            pause
            ;;

        4)
            section "🐦 Installing Pelican Wings"
            echo -e "${Y}  Wings node daemon installation and configuration...${N}"
            echo ""
            bash <(curl -fsSL "${BASE_URL}/wings.sh") 
            pause
            ;;

        5)
            section "👥 User Registration & Resource Limits"
            echo -e "${Y}  Installing Register + User-Creatable-Servers plugins...${N}"
            echo ""
            bash <(curl -fsSL "${BASE_URL}/plugin-client.sh")
            pause
            ;;

        6)
            section "🔄 Restarting All Services"
            echo -e "${Y}  Restarting Panel, Wings, Docker, Cloudflare & all services...${N}"
            echo ""
            bash <(curl -fsSL "${BASE_URL}/restart.sh")
            pause
            ;;

        7)
            section "🗑️  Uninstalling Pelican"
            echo -e "${R}  ⚠️  WARNING: This will remove Pelican components!${N}"
            echo ""
            read -p "${W}  Are you sure? (type YES to continue): ${N}" confirm
            if [ "$confirm" = "YES" ]; then
                bash <(curl -fsSL "${BASE_URL}/uninstall.sh")
            else
                echo -e "${G}  Cancelled.${N}"
            fi
            pause
            ;;

        # ─── SYSTEM TOOLS ─────────────────────────────────────────────
        8)
            section "🌐 Installing Tailscale"
            echo -e "${Y}  Installing Tailscale VPN for secure access...${N}"
            echo ""
            curl -fsSL https://tailscale.com/install.sh | sh
            echo ""
            echo -e "${Y}  Run this to connect:${N}"
            echo -e "${G}  tailscale up${N}"
            pause
            ;;

        9)
            section "🖥️  Installing xRDP (Remote Desktop)"
            echo -e "${Y}  Installing xRDP + XFCE desktop environment...${N}"
            echo ""
            apt install -y xfce4 xfce4-goodies xrdp dbus-x11 > /dev/null 2>&1

            sudo tee /etc/xrdp/startwm.sh << 'EOF' > /dev/null
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec xfce4-session
EOF
            chmod +x /etc/xrdp/startwm.sh
            echo "xfce4-session" > ~/.xsession
            sed -i 's/max_bpp=32/max_bpp=16/' /etc/xrdp/xrdp.ini 2>/dev/null || true
            systemctl enable xrdp > /dev/null 2>&1
            systemctl restart xrdp > /dev/null 2>&1
            iptables -A INPUT -p tcp --dport 3389 -j ACCEPT > /dev/null 2>&1

            TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "YOUR_TAILSCALE_IP")
            echo ""
            echo -e "${G}  ✅ xRDP installed!${N}"
            echo -e "${C}  Connect via Windows RDP:${N}"
            echo -e "${W}  mstsc → ${G}${TAILSCALE_IP}${N}"
            pause
            ;;

        10)
            section "📡 Installing sshx"
            echo -e "${Y}  Installing sshx terminal sharing...${N}"
            echo ""
            pkill -9 sshx > /dev/null 2>&1
            curl -sSf https://sshx.io/get | sh

            sudo tee /etc/systemd/system/sshx.service << 'EOF' > /dev/null
[Unit]
Description=sshx terminal sharing
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'pkill -9 sshx; sleep 1'
ExecStart=/usr/local/bin/sshx
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
            systemctl stop sshx > /dev/null 2>&1
            systemctl disable sshx > /dev/null 2>&1
            systemctl daemon-reload > /dev/null 2>&1
            pkill -9 sshx > /dev/null 2>&1
            sleep 1
            setsid /usr/local/bin/sshx > /tmp/sshx.log 2>&1 &
            disown
            echo ""
            echo -e "${G}  ✅ sshx installed and running as service!${N}"
            sleep 4
            SSHX_LINK=$(grep -o 'https://sshx.io/s/[^ ]*' /tmp/sshx.log 2>/dev/null | head -1)
            if [ -n "$SSHX_LINK" ]; then
                echo -e "${G}  ➜ sshx Link: $SSHX_LINK${N}"
            else
                echo -e "${Y}  ⏳ Link not ready — run: journalctl -u sshx -n 20 --no-pager${N}"
            fi
            pause
            ;;

        11)
            section "📊 System Status"
            echo -e "${C}  Checking all services...${N}"
            echo ""

            # SSH
            systemctl is-active ssh > /dev/null 2>&1 && \
                echo -e "  ${G}✅ SSH:            Running${N}" || \
                echo -e "  ${R}❌ SSH:            Not Running${N}"

            # xRDP
            systemctl is-active xrdp > /dev/null 2>&1 && \
                echo -e "  ${G}✅ xRDP:           Running (port 3389)${N}" || \
                echo -e "  ${R}❌ xRDP:           Not Running${N}"

            # Tailscale
            tailscale status > /dev/null 2>&1 && \
                echo -e "  ${G}✅ Tailscale:      Connected ($(tailscale ip -4 2>/dev/null))${N}" || \
                echo -e "  ${R}❌ Tailscale:      Not Connected${N}"

            # sshx
            systemctl is-active sshx > /dev/null 2>&1 && \
                echo -e "  ${G}✅ sshx:           Running${N}" || \
                echo -e "  ${Y}⚠️  sshx:           Not Running${N}"

            # Keepalive
            systemctl is-active keepalive > /dev/null 2>&1 && \
                echo -e "  ${G}✅ Keepalive:      Running${N}" || \
                echo -e "  ${Y}⚠️  Keepalive:      Not Running${N}"

            # Nginx
            systemctl is-active nginx > /dev/null 2>&1 && \
                echo -e "  ${G}✅ Nginx:          Running (port 8443)${N}" || \
                echo -e "  ${Y}⚠️  Nginx:          Not Running${N}"

            # PHP-FPM
            netstat -tlnp 2>/dev/null | grep -q ":9000" && \
                echo -e "  ${G}✅ PHP-FPM:        Running (port 9000)${N}" || \
                echo -e "  ${Y}⚠️  PHP-FPM:        Not Running${N}"

            # Redis
            redis-cli ping > /dev/null 2>&1 && \
                echo -e "  ${G}✅ Redis:          Running${N}" || \
                echo -e "  ${Y}⚠️  Redis:          Not Running${N}"

            # Wings
            pgrep -x wings > /dev/null && \
                echo -e "  ${G}✅ Wings:          Running (port 8080)${N}" || \
                echo -e "  ${Y}⚠️  Wings:          Not Running${N}"

            # Cloudflare
            pgrep cloudflared > /dev/null && \
                echo -e "  ${G}✅ Cloudflare:     Running${N}" || \
                echo -e "  ${Y}⚠️  Cloudflare:     Not Running${N}"

            # Queue Worker
            pgrep -f "queue:work" > /dev/null && \
                echo -e "  ${G}✅ Queue Worker:   Running${N}" || \
                echo -e "  ${Y}⚠️  Queue Worker:   Not Running${N}"

            echo ""
            echo -e "${C}  Memory Usage:${N}"
            free -h | grep Mem | awk '{printf "  Total: %s | Used: %s | Free: %s\n", $2, $3, $4}'

            echo ""
            echo -e "${C}  Disk Usage:${N}"
            df -h / | tail -1 | awk '{printf "  Total: %s | Used: %s | Free: %s\n", $2, $3, $4}'

            pause
            ;;

        12)
            section "🧹 Clearing All Cache"
            echo -e "${Y}  Clearing Pelican Panel cache...${N}"
            echo ""
            if [ -d "/var/www/pelican" ]; then
                cd /var/www/pelican
                PHP_BIN=$(which php8.3 2>/dev/null || which php)
                $PHP_BIN artisan cache:clear 2>/dev/null && echo -e "${G}  ✅ App cache cleared${N}"
                $PHP_BIN artisan config:clear 2>/dev/null && echo -e "${G}  ✅ Config cache cleared${N}"
                $PHP_BIN artisan route:clear 2>/dev/null && echo -e "${G}  ✅ Route cache cleared${N}"
                $PHP_BIN artisan view:clear 2>/dev/null && echo -e "${G}  ✅ View cache cleared${N}"
                $PHP_BIN artisan optimize:clear 2>/dev/null && echo -e "${G}  ✅ All optimizations cleared${N}"
                redis-cli FLUSHDB > /dev/null 2>&1 && echo -e "${G}  ✅ Redis cache cleared${N}"
                sudo systemctl restart nginx php8.3-fpm 2>/dev/null && echo -e "${G}  ✅ Services restarted${N}"
            else
                echo -e "${Y}  ⚠️  Pelican Panel not found at /var/www/pelican${N}"
            fi
            pause
            ;;

        # ─── INFO ─────────────────────────────────────────────────────
        13)
            section "📖 How to Stay 24/7 on Google IDX"
            echo -e "${W}  Follow these steps to keep your server running 24/7:${N}"
            echo ""
            echo -e "${Y}  STEP 1 — Get your Tailscale SSH IP${N}"
            echo -e "${W}  Run: ${G}tailscale ip -4${N}"
            echo ""
            echo -e "${Y}  STEP 2 — Connect via Windows Remote Desktop${N}"
            echo -e "${W}  Press Win+R → type mstsc → enter your Tailscale IP${N}"
            echo ""
            echo -e "${Y}  STEP 3 — Open Firefox inside RDP${N}"
            echo -e "${W}  In the RDP terminal run: ${G}DISPLAY=:10 firefox &${N}"
            echo ""
            echo -e "${Y}  STEP 4 — Install Auto Refresh Extension${N}"
            echo -e "${W}  In Firefox, search: ${G}Auto Refresh Page${N}"
            echo -e "${W}  Add the extension to Firefox${N}"
            echo ""
            echo -e "${Y}  STEP 5 — Open Google IDX${N}"
            echo -e "${W}  Go to: ${G}https://idx.google.com${N}"
            echo -e "${W}  Login and open your project${N}"
            echo ""
            echo -e "${Y}  STEP 6 — Set Auto Refresh${N}"
            echo -e "${W}  Click the auto refresh extension icon${N}"
            echo -e "${W}  Set interval to: ${G}20 minutes${N}"
            echo -e "${W}  Enable it on the IDX tab${N}"
            echo ""
            echo -e "${Y}  STEP 7 — Open Terminal in IDX${N}"
            echo -e "${W}  Open terminal and run your keepalive:${N}"
            echo -e "${G}  while true; do echo 'alive'; sleep 60; done${N}"
            echo ""
            echo -e "${G}  ✅ Your server will now stay active 24/7!${N}"
            echo -e "${C}  Even if you close your PC, the RDP session keeps IDX alive.${N}"
            pause
            ;;

        14)
            section "📚 Viewing README"
            echo -e "${Y}  Fetching README from GitHub...${N}"
            echo ""
            curl -fsSL "${BASE_URL}/README.md" 2>/dev/null | head -200 || \
                echo -e "${R}  Could not fetch README. Visit: ${G}https://github.com/Adexx-11234/newrepo${N}"
            pause
            ;;

        # ─── EXIT ─────────────────────────────────────────────────────
        0)
            echo ""
            echo -e "${G}  👋 Thank you for using NexusBot! Goodbye!${N}"
            echo ""
            exit 0
            ;;

        *)
            echo ""
            echo -e "${R}  ❌ Invalid option! Please select between 0-14.${N}"
            sleep 2
            ;;
    esac
done