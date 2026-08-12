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

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash nexus-setup.sh"; exit 1; }

auto_detect_dns() {
    local CANDIDATES=("1.1.1.1" "1.0.0.1" "8.8.8.8" "9.9.9.9" "8.8.4.4")
    local TEST_HOST="google.com"
    local WORKING=()
    for dns in "${CANDIDATES[@]}"; do
        MS=$(dig +tries=1 +timeout=3 "$TEST_HOST" "@${dns}" 2>&1 | grep "Query time" | awk '{print $4}')
        if [[ -n "$MS" ]]; then
            WORKING+=("$MS $dns")
        fi
    done
    if [[ ${#WORKING[@]} -eq 0 ]]; then
        DNS_PRIMARY="1.1.1.1"; DNS_SECONDARY="8.8.4.4"; return
    fi
    mapfile -t SORTED < <(printf '%s\n' "${WORKING[@]}" | sort -n)
    DNS_PRIMARY=$(echo "${SORTED[0]}" | awk '{print $2}')
    DNS_SECONDARY=$(echo "${SORTED[1]:-${SORTED[0]}}" | awk '{print $2}')
}
auto_detect_dns

echo -e "${CYAN}"
echo "============================================================"
echo "         Nexus Server Setup"
echo "         SSH • Tailscale • xrdp • sshx • VNC • Firefox"
echo "============================================================"
echo -e "${NC}"

# ============================================================================
# 1 — SYSTEM UPDATE + APT-UTILS
# ============================================================================

log "Updating system packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y apt-utils -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "System updated"

# ============================================================================
# 2 — SSH
# ============================================================================

log "Configuring SSH..."
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server -qq

cat > /etc/ssh/sshd_config.d/60-cloudimg-settings.conf <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
EOF

cat > /etc/ssh/sshd_config.d/99-nexus.conf <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
EOF

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'               /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

systemctl enable ssh
systemctl restart ssh
ok "SSH configured (port 22, password auth enabled)"

# ============================================================================
# 3 — XFCE + XRDP
# ============================================================================

log "Installing xrdp + XFCE..."
DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4 xfce4-goodies xrdp dbus-x11 -qq

cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec xfce4-session
EOF
chmod +x /etc/xrdp/startwm.sh
echo "xfce4-session" > /root/.xsession

sed -i 's/max_bpp=32/max_bpp=16/'       /etc/xrdp/xrdp.ini
sed -i 's/xserverbpp=24/xserverbpp=16/' /etc/xrdp/xrdp.ini

systemctl enable xrdp
systemctl restart xrdp
ok "xrdp configured (port 3389)"

# ============================================================================
# 4 — FIREFOX (Mozilla official APT repo)
# ============================================================================

log "Installing Firefox (Mozilla official repo, non-snap)..."
snap remove firefox 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get remove -y firefox 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge  -y firefox 2>/dev/null || true

rm -f /etc/apt/sources.list.d/mozillateam-ppa.list
rm -f /etc/apt/trusted.gpg.d/mozillateam.gpg

install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
    | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null

echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
    | tee /etc/apt/sources.list.d/mozilla.list > /dev/null

cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y firefox
ok "Firefox installed"

# ============================================================================
# 5 — TAILSCALE
# ============================================================================

log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable tailscaled 2>/dev/null || true
systemctl start tailscaled 2>/dev/null || true
sleep 3

echo ""
echo -e "${CYAN}Authenticate Tailscale — open the link below:${NC}"
tailscale up || true

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
[[ -n "$TAILSCALE_IP" ]] && ok "Tailscale IP: $TAILSCALE_IP" || warn "Tailscale IP not ready yet"

log "Configuring DNS..."
tailscale set --accept-dns=false 2>/dev/null || true

if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/no-stub.conf <<EOF
[Resolve]
DNS=${DNS_PRIMARY} ${DNS_SECONDARY}
DNSStubListener=no
Domains=~.
EOF
    systemctl restart systemd-resolved
    ok "DNS locked → ${DNS_PRIMARY} + ${DNS_SECONDARY}"
else
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
options timeout:2 attempts:2
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    ok "DNS locked → ${DNS_PRIMARY} + ${DNS_SECONDARY}"
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
# 8 — VNC + noVNC + Firefox on VNC
# ============================================================================

log "Installing VNC + noVNC..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    tigervnc-standalone-server novnc websockify -qq

# xstartup — fixed dbus launch
mkdir -p /root/.vnc
cat > /root/.vnc/xstartup <<'EOF'
#!/bin/bash
export DISPLAY=:1
export XDG_SESSION_TYPE=x11
unset DBUS_SESSION_BUS_ADDRESS
eval $(dbus-launch --sh-syntax)
export DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x /root/.vnc/xstartup

# VNC password
warn "Set a VNC password (max 8 chars). When asked 'view-only?' → type: n"
vncpasswd

# Kill any stale instance and start fresh
pkill Xtigervnc 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
sleep 2
vncserver :1 -geometry 1280x720 -depth 16
sleep 3

# VNC systemd service — ExecStartPre kill is optional (-) so it never fails
cat > /etc/systemd/system/vncserver.service <<'EOF'
[Unit]
Description=TigerVNC Server
After=network.target

[Service]
Type=forking
User=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:1.pid
ExecStartPre=-/bin/bash -c 'pkill Xtigervnc; rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; sleep 2'
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 16
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# noVNC proxy service
cat > /etc/systemd/system/websockify.service <<'EOF'
[Unit]
Description=WebSockify noVNC proxy
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Firefox persistent profile — only initialise once
mkdir -p /root/.firefox-vnc-profile/extensions

curl -fsSL "https://addons.mozilla.org/firefox/downloads/file/4937205/auto_refresh_url-1.0.34.xpi" \
    -o "/root/.firefox-vnc-profile/extensions/{9cf28bf3-b2e3-4912-b703-ad49a17b97c8}.xpi" 2>/dev/null || true

if [ ! -f /root/.firefox-vnc-profile/places.sqlite ]; then
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
user_pref("extensions.autoDisableScopes", 0);
user_pref("extensions.enabledScopes", 15);
EOF
fi

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

# vncserver is already running from the manual start above, so just start the rest
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
for svc in ssh xrdp vncserver websockify firefox-vnc sshx tailscaled; do
    systemctl is-active --quiet "$svc" \
        && echo -e "  ${GREEN}✅${NC} $svc" \
        || echo -e "  ${RED}❌${NC} $svc"
done
echo ""

sleep 4
SSHX_LINK=$(journalctl -u sshx -n 20 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | head -1 || true)
[[ -n "$SSHX_LINK" ]] \
    && echo -e "${GREEN}sshx:${NC} $SSHX_LINK" \
    || warn "sshx link not ready — run: journalctl -u sshx -n 20 --no-pager"

echo ""
echo -e "${CYAN}============================================================${NC}"
