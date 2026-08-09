#!/bin/bash

# ============================================================================
# Nexus Server Setup
# Configures SSH, Tailscale, xrdp, sshx, VNC + noVNC + Firefox
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "\n${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✘]${NC} $*"; }

# ============================================================================
# ROOT CHECK
# ============================================================================

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash nexus-setup.sh"; exit 1; }

echo -e "${CYAN}"
echo "============================================================"
echo "         Nexus Server Setup"
echo "         SSH • Tailscale • xrdp • sshx • VNC • Firefox"
echo "============================================================"
echo -e "${NC}"

# ============================================================================
# 1 — SYSTEM UPDATE
# ============================================================================

log "Updating system packages..."
apt-get update -qq
ok "System updated"

# ============================================================================
# 2 — SSH
# ============================================================================

log "Configuring SSH..."
apt-get install -y openssh-server -qq

# Overwrite the cloudimg override that blocks password auth
cat > /etc/ssh/sshd_config.d/60-cloudimg-settings.conf <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
EOF

cat > /etc/ssh/sshd_config.d/99-nexus.conf <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
EOF

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'       /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

systemctl enable ssh
systemctl restart ssh
ok "SSH configured (port 22, password auth enabled)"

# ============================================================================
# 3 — XRDP
# ============================================================================

log "Installing xrdp + XFCE..."
apt-get install -y xfce4 xfce4-goodies xrdp dbus-x11 -qq

cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec xfce4-session
EOF
chmod +x /etc/xrdp/startwm.sh
echo "xfce4-session" > ~/.xsession

sed -i 's/max_bpp=32/max_bpp=16/'   /etc/xrdp/xrdp.ini
sed -i 's/xserverbpp=24/xserverbpp=16/' /etc/xrdp/xrdp.ini

iptables -A INPUT -p tcp --dport 3389 -j ACCEPT 2>/dev/null || true
systemctl enable xrdp
systemctl restart xrdp
ok "xrdp configured (port 3389)"

# ============================================================================
# 4 — FIREFOX
# ============================================================================

log "Installing Firefox (PPA, non-snap)..."
snap remove firefox 2>/dev/null || true
apt-get remove -y firefox 2>/dev/null || true
apt-get purge  -y firefox 2>/dev/null || true

cat > /etc/apt/preferences.d/firefox-no-snap <<'EOF'
Package: firefox*
Pin: release o=Ubuntu*
Pin-Priority: -1
EOF

add-apt-repository ppa:mozillateam/ppa -y -q
apt-get update -qq
apt-get install -y -t 'o=LP-PPA-mozillateam' firefox
ok "Firefox installed"

# ============================================================================
# 5 — TAILSCALE
# ============================================================================

log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable tailscaled
systemctl start tailscaled

echo ""
echo -e "${CYAN}Authenticate Tailscale:${NC}"
tailscale up
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
[[ -n "$TAILSCALE_IP" ]] && ok "Tailscale IP: $TAILSCALE_IP" || warn "Tailscale IP not ready yet"

# Prevent Tailscale DNS from polluting container DNS
tailscale set --accept-dns=false 2>/dev/null || true

# Lock DNS
if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/no-stub.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.4.4
DNSStubListener=no
Domains=~.
EOF
    systemctl restart systemd-resolved
    ok "DNS: systemd-resolved → 1.1.1.1 + 8.8.4.4 (no stub)"
else
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.4.4
options timeout:2 attempts:2
EOF
    ok "DNS: /etc/resolv.conf → 1.1.1.1 + 8.8.4.4"
fi

# ============================================================================
# 6 — SSHX
# ============================================================================

log "Installing sshx..."
pkill -9 sshx 2>/dev/null || true
sleep 1
curl -sSf https://sshx.io/get | sh

cat > /etc/systemd/system/sshx.service <<'EOF'
[Unit]
Description=sshx terminal sharing
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'pkill -9 sshx; sleep 1'
ExecStart=/usr/local/bin/sshx
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sshx
systemctl start sshx
ok "sshx installed and running"

# ============================================================================
# 7 — DISABLE FREEZE-CAUSING SERVICES
# ============================================================================

log "Disabling freeze-causing services..."
systemctl disable --now unattended-upgrades 2>/dev/null || true
systemctl stop    packagekit                2>/dev/null || true
systemctl disable packagekit                2>/dev/null || true
ok "unattended-upgrades and packagekit disabled"

# ============================================================================
# 8 — VNC + noVNC + Firefox
# ============================================================================

log "Installing VNC + noVNC + Firefox on VNC..."
apt-get install -y tigervnc-standalone-server novnc websockify -qq

# VNC xstartup — disable compositing to reduce I/O
mkdir -p /root/.vnc
cat > /root/.vnc/xstartup <<'EOF'
#!/bin/bash
xrdb $HOME/.Xresources 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null || true
startxfce4 &
EOF
chmod +x /root/.vnc/xstartup

# VNC password — prompt interactively
warn "Set a VNC password (max 8 chars). When asked 'view-only password?' → type: n"
vncpasswd

# Start VNC to initialise
vncserver -kill :1 2>/dev/null || true
vncserver :1 -geometry 1280x720 -depth 16

# VNC service
cat > /etc/systemd/system/vncserver.service <<'EOF'
[Unit]
Description=TightVNC Server
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1 2>/dev/null
ExecStartPre=/bin/sleep 1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 16
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# noVNC proxy
cat > /etc/systemd/system/websockify.service <<'EOF'
[Unit]
Description=WebSockify noVNC proxy
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ --compress-level=1 6080 localhost:5901
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Firefox on VNC — persistent profile on tmpfs, low I/O
mkdir -p /root/.firefox-vnc-profile
cat > /root/.firefox-vnc-profile/user.js <<'EOF'
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.memory.capacity", 524288);
user_pref("browser.cache.offline.enable", false);
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.interval", 3600000);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.sessionstore.max_resumed_crashes", -1);
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("browser.sessionstore.max_windows_undo", 0);
user_pref("browser.sessionstore.upgradeBackup.maxUpgradeBackups", 0);
user_pref("dom.ipc.processCount", 1);
user_pref("browser.tabs.remote.autostart", false);
user_pref("toolkit.storage.synchronous", 0);
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("ui.prefersReducedMotion", 1);
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_override_url", "");
user_pref("startup.homepage_welcome_url", "");
EOF

cat > /etc/systemd/system/firefox-vnc.service <<'EOF'
[Unit]
Description=Firefox on VNC display
After=websockify.service vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=root
Environment=DISPLAY=:1
Environment=HOME=/root
Environment=MOZ_DISABLE_CRASHREPORTER=1
Environment=MOZ_CRASHREPORTER_DISABLE=1
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/firefox --display=:1 --no-remote --profile /root/.firefox-vnc-profile
ExecStop=/bin/bash -c 'pkill -SIGTERM -f "firefox.*firefox-vnc-profile"; sleep 4'
Restart=on-failure
RestartSec=10
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vncserver websockify firefox-vnc
systemctl start vncserver
sleep 3
systemctl start websockify
sleep 5
systemctl start firefox-vnc
ok "VNC + noVNC + Firefox running"

# ============================================================================
# SUMMARY
# ============================================================================

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "YOUR_TAILSCALE_IP")

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}         ✅ SETUP COMPLETE${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${GREEN}SSH:${NC}       ssh root@${TAILSCALE_IP}"
echo -e "${GREEN}RDP:${NC}       ${TAILSCALE_IP}:3389"
echo -e "${GREEN}VNC:${NC}       http://${TAILSCALE_IP}:6080/vnc.html"
echo -e "${GREEN}Tailscale:${NC} ${TAILSCALE_IP}"
echo ""
echo -e "${YELLOW}Services:${NC}"
for svc in ssh xrdp vncserver websockify firefox-vnc sshx; do
    systemctl is-active --quiet "$svc" \
        && echo -e "  ${GREEN}✅${NC} $svc" \
        || echo -e "  ${RED}❌${NC} $svc"
done
echo ""
echo -e "${CYAN}IDX Keepalive:${NC}"
echo "  1. Open: http://${TAILSCALE_IP}:6080/vnc.html"
echo "  2. In VNC Firefox → open idx.google.com"
echo "  3. Install Auto Refresh → set 5 min interval"
echo "  4. Close your local noVNC tab (leave VNC Firefox open)"
echo ""

sleep 4
SSHX_LINK=$(journalctl -u sshx -n 20 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | head -1 || true)
if [[ -n "$SSHX_LINK" ]]; then
    echo -e "${GREEN}sshx:${NC} $SSHX_LINK"
else
    warn "sshx link not ready — run: journalctl -u sshx -n 20 --no-pager"
fi
echo ""
echo -e "${CYAN}============================================================${NC}"
