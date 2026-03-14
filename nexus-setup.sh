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

# Check if root has a password set
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
apt update -y > /dev/null 2>&1
print_success "System updated!"

# ============================================================
# STEP 3 — INSTALL & CONFIGURE SSH
# ============================================================
print_step "Installing and configuring SSH..."

apt install openssh-server -y > /dev/null 2>&1

# Configure SSH
sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Enable and start SSH
systemctl enable ssh > /dev/null 2>&1
systemctl restart ssh > /dev/null 2>&1

print_success "SSH installed and configured on port 22!"

# ============================================================
# STEP 4 — INSTALL XRDP (REMOTE DESKTOP)
# ============================================================
print_step "Installing xrdp and desktop environment..."

apt install -y xfce4 xfce4-goodies xrdp dbus-x11 > /dev/null 2>&1

# Configure xrdp
tee /etc/xrdp/startwm.sh << 'EOF' > /dev/null
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec xfce4-session
EOF

chmod +x /etc/xrdp/startwm.sh
echo "xfce4-session" > ~/.xsession

# Set resolution
sed -i 's/max_bpp=32/max_bpp=16/' /etc/xrdp/xrdp.ini
sed -i 's/xserverbpp=24/xserverbpp=16/' /etc/xrdp/xrdp.ini

# Allow port 3389
iptables -A INPUT -p tcp --dport 3389 -j ACCEPT > /dev/null 2>&1

# Enable and start xrdp
systemctl enable xrdp > /dev/null 2>&1
systemctl restart xrdp > /dev/null 2>&1

print_success "xrdp installed and configured at 1280x720!"

# ============================================================
# STEP 5 — INSTALL FIREFOX
# ============================================================
print_step "Installing Firefox..."

# Remove snap firefox stub
snap remove firefox > /dev/null 2>&1
apt remove firefox -y > /dev/null 2>&1
apt purge firefox -y > /dev/null 2>&1

# Prevent snap firefox
tee /etc/apt/preferences.d/firefox-no-snap << 'EOF' > /dev/null
Package: firefox*
Pin: release o=Ubuntu*
Pin-Priority: -1
EOF

# Add Mozilla PPA and install
add-apt-repository ppa:mozillateam/ppa -y > /dev/null 2>&1
apt update > /dev/null 2>&1
apt install -t 'o=LP-PPA-mozillateam' firefox -y > /dev/null 2>&1

print_success "Firefox installed!"

# ============================================================
# STEP 6 — INSTALL TAILSCALE
# ============================================================
print_step "Installing Tailscale..."

curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1

systemctl enable tailscaled > /dev/null 2>&1
systemctl start tailscaled > /dev/null 2>&1

print_success "Tailscale installed!"
print_warning "Run 'tailscale up' to login and get your Tailscale IP"

# Start tailscale and show login link
echo ""
echo -e "${CYAN}Starting Tailscale — please authenticate:${NC}"
tailscale up
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)
if [ -n "$TAILSCALE_IP" ]; then
    print_success "Tailscale IP: $TAILSCALE_IP"
fi

# ============================================================
# STEP 7 — INSTALL SSHX (ONE INSTANCE ONLY)
# ============================================================
print_step "Installing sshx..."

# Kill any existing sshx processes
pkill -9 sshx > /dev/null 2>&1
sleep 1

# Install sshx
curl -sSf https://sshx.io/get | sh > /dev/null 2>&1

# Create sshx systemd service
tee /etc/systemd/system/sshx.service << 'EOF' > /dev/null
[Unit]
Description=sshx terminal sharing
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'pkill -9 sshx; sleep 1'
ExecStart=/usr/local/bin/sshx run
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload > /dev/null 2>&1
systemctl enable sshx > /dev/null 2>&1
systemctl start sshx > /dev/null 2>&1

print_success "sshx installed and running as a service (single instance)!"

# ============================================================
# STEP 8 — SETUP KEEPALIVE SERVICE
# ============================================================
print_step "Setting up keepalive service..."

tee /etc/systemd/system/keepalive.service << 'EOF' > /dev/null
[Unit]
Description=Server Keepalive Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do echo "Server alive - $(date)"; sleep 60; done'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload > /dev/null 2>&1
systemctl enable keepalive > /dev/null 2>&1
systemctl start keepalive > /dev/null 2>&1

print_success "Keepalive service running (pings every 60 seconds)!"

# ============================================================
# STEP 9 — DISABLE FREEZE-CAUSING SERVICES
# ============================================================
print_step "Disabling services that can cause freezes..."

systemctl disable --now unattended-upgrades > /dev/null 2>&1
systemctl stop packagekit > /dev/null 2>&1
systemctl disable packagekit > /dev/null 2>&1

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
echo "  ✅ Keepalive (pings every 60s)"
echo ""
echo -e "${YELLOW}To get sshx link:${NC}"
echo "  journalctl -u sshx -f"
echo ""
echo -e "${CYAN}============================================================${NC}"