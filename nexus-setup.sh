#!/bin/bash

# ============================================================
#         NEXUS SERVER SETUP SCRIPT
#         For Existing Ubuntu Servers (Google IDX)
#         Sets up: SSH, Tailscale, xrdp, sshx, Firefox, Keepalive
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_banner() {
    echo -e "${CYAN}"
    echo "============================================================"
    echo "         NEXUS SERVER SETUP SCRIPT"
    echo "         Automated Ubuntu Server Configuration"
    echo "============================================================"
    echo -e "${NC}"
}

print_step() {
    echo -e "\n${BLUE}[*] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[✔] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

print_error() {
    echo -e "${RED}[✘] $1${NC}"
}

# ============================================================
# CHECK ROOT
# ============================================================
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root: sudo bash nexus-setup.sh"
    exit 1
fi

print_banner

# ============================================================
# STEP 1 — CHECK/SET ROOT PASSWORD
# ============================================================
print_step "Checking root password..."

if passwd -S root | grep -q "^root P"; then
    print_success "Root password is already set. Using existing password."
else
    print_warning "No root password found!"
    echo -e "${YELLOW}Please set a root password now:${NC}"
    passwd root
    if [ $? -eq 0 ]; then
        print_success "Root password set successfully!"
    else
        print_error "Failed to set root password. Exiting."
        exit 1
    fi
fi

# ============================================================
# STEP 2 — UPDATE SYSTEM
# ============================================================
print_step "Updating system packages..."
apt update -y
print_success "System updated!"

# ============================================================
# STEP 3 — INSTALL & CONFIGURE SSH
# ============================================================
print_step "Installing and configuring SSH..."

apt install openssh-server -y

sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

systemctl enable ssh
systemctl restart ssh

print_success "SSH installed and configured on port 22!"

# ============================================================
# STEP 4 — INSTALL XRDP (REMOTE DESKTOP)
# ============================================================
print_step "Installing xrdp and desktop environment..."

apt install -y xfce4 xfce4-goodies xrdp dbus-x11

tee /etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec xfce4-session
EOF

chmod +x /etc/xrdp/startwm.sh
echo "xfce4-session" > ~/.xsession

sed -i 's/max_bpp=32/max_bpp=16/' /etc/xrdp/xrdp.ini
sed -i 's/xserverbpp=24/xserverbpp=16/' /etc/xrdp/xrdp.ini

iptables -A INPUT -p tcp --dport 3389 -j ACCEPT

systemctl enable xrdp
systemctl restart xrdp

print_success "xrdp installed and configured at 1280x720!"

# ============================================================
# STEP 5 — INSTALL FIREFOX
# ============================================================
print_step "Installing Firefox..."

snap remove firefox
apt remove firefox -y
apt purge firefox -y

tee /etc/apt/preferences.d/firefox-no-snap << 'EOF'
Package: firefox*
Pin: release o=Ubuntu*
Pin-Priority: -1
EOF

add-apt-repository ppa:mozillateam/ppa -y
apt update
apt install -t 'o=LP-PPA-mozillateam' firefox -y

print_success "Firefox installed!"

# ============================================================
# STEP 6 — INSTALL TAILSCALE
# ============================================================
print_step "Installing Tailscale..."

curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable tailscaled
systemctl start tailscaled

print_success "Tailscale installed!"
print_warning "Run 'tailscale up' to login and get your Tailscale IP"

echo ""
echo -e "${CYAN}Starting Tailscale — please authenticate:${NC}"
tailscale up
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)
if [ -n "$TAILSCALE_IP" ]; then
    print_success "Tailscale IP: $TAILSCALE_IP"
fi

# NOW lock DNS — Tailscale already connected, preserve its DNS
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 100.100.100.100
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2 rotate
DNSEOF
chattr +i /etc/resolv.conf

# ============================================================
# STEP 7 — INSTALL SSHX (ONE INSTANCE ONLY)
# ============================================================
print_step "Installing sshx..."

pkill -9 sshx
sleep 1

curl -sSf https://sshx.io/get | sh

tee /etc/systemd/system/sshx.service << 'EOF'
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

print_success "sshx installed and running as a service (single instance)!"
# ============================================================
# STEP 9 — DISABLE FREEZE-CAUSING SERVICES
# ============================================================
print_step "Disabling services that can cause freezes..."

systemctl disable --now unattended-upgrades
systemctl stop packagekit
systemctl disable packagekit

print_success "Freeze-causing services disabled!"

# ============================================================
# FINAL SUMMARY
# ============================================================
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}         ✅ SETUP COMPLETE!${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${GREEN}SSH:${NC}       ssh root@${TAILSCALE_IP:-YOUR_TAILSCALE_IP}"
echo -e "${GREEN}RDP:${NC}       mstsc → ${TAILSCALE_IP:-YOUR_TAILSCALE_IP} (port 3389)"
echo -e "${GREEN}Tailscale:${NC} ${TAILSCALE_IP:-Run 'tailscale up' to get IP}"
echo ""
echo -e "${YELLOW}Services running:${NC}"
echo "  ✅ SSH (port 22)"
echo "  ✅ xrdp (port 3389) - Resolution 1280x720"
echo "  ✅ sshx (single instance, auto-restart)"
echo "  ✅ Tailscale (secure tunnel)"
echo "  ✅ Firefox (launch with: DISPLAY=:10 firefox &)"
echo ""
echo -e "${YELLOW}sshx Link:${NC}"
sleep 4
SSHX_LINK=$(journalctl -u sshx -n 20 --no-pager | grep -o 'https://sshx.io/s/[^ ]*' | head -1)
if [ -n "$SSHX_LINK" ]; then
    echo -e "${GREEN}  ➜ $SSHX_LINK${NC}"
else
    echo -e "${YELLOW}  ⏳ Link not ready yet — run: journalctl -u sshx -n 20 --no-pager${NC}"
fi
echo ""
echo -e "${CYAN}============================================================${NC}"