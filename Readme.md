# 🚀 NexusBot — Ubuntu VPS + Pelican Panel on Google IDX

> **Complete guide** for running a 24/7 Ubuntu server on Google IDX with Pelican Panel, Wings, Cloudflare Tunnel, Tailscale, and Remote Desktop.

**Created by NexusTechPro** | [GitHub](https://github.com/nexustechpro2/VM-in-Google-Idx)

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Quick Start](#quick-start)
5. [Part 1 — Ubuntu VPS on Google IDX](#part-1--ubuntu-vps-on-google-idx)
6. [Part 2 — Server Setup (SSH + RDP + Tailscale)](#part-2--server-setup-ssh--rdp--tailscale)
7. [Part 3 — VNC Desktop + 24/7 Keepalive Guide](#part-3--vnc-desktop--247-keepalive-guide)
8. [Part 4 — Pelican Panel Installation](#part-4--pelican-panel-installation)
9. [Part 5 — Pelican Wings Installation](#part-5--pelican-wings-installation)
10. [Part 6 — Cloudflare Tunnel Setup](#part-6--cloudflare-tunnel-setup)
11. [Part 7 — User Registration & Resource Limits](#part-7--user-registration--resource-limits)
12. [Part 8 — Restart All Services](#part-8--restart-all-services)
13. [dev.nix Configuration](#devnix-configuration)
14. [Troubleshooting](#troubleshooting)
15. [Scripts Reference](#scripts-reference)

---

## 🎯 Overview

This repository provides everything needed to run a full **Pelican Panel game server management system** on **Google IDX** — completely free using:

- 🖥️ **Google IDX** — Free cloud development environment
- 🐧 **Ubuntu VPS** — QEMU-based Ubuntu VM inside IDX
- 🐦 **Pelican Panel** — Game server management panel
- 🔗 **Cloudflare Tunnel** — Free SSL & domain routing
- 🌐 **Tailscale** — Secure VPN for remote access
- 🖥️ **VNC + noVNC** — Browser-based remote desktop for keepalive

---

## 🏗️ Architecture

```
Your PC / Phone (anywhere)
        │
        ▼
  Tailscale VPN
        │
        ▼
Google IDX (Ubuntu VM)
        │
   ┌────┴────────────────────┐
   │                         │
   ▼                         ▼
noVNC (port 6080)      Cloudflare Tunnel
Browser Desktop              │
(Keepalive method)   ┌───────┴──────────┐
                     ▼                  ▼
         panel.nexusbot.qzz.io  node-1.nexusbot.qzz.io
                     │                  │
                     ▼                  ▼
              Nginx :443           Wings :8080
                     │                  │
                     ▼                  ▼
            Pelican Panel          Docker Containers
            (PHP/Laravel)          (Game Servers)
```

**Port Reference:**

| Service | Internal Port | External Port |
|---------|:---:|:---:|
| Pelican Panel (Nginx) | 443 | 443 (via Cloudflare) |
| Wings Node | 8080 | 443 (via Cloudflare) |
| noVNC (Keepalive) | 6080 | Tailscale only |
| xRDP (Windows RDP) | 3389 | Tailscale only |
| SSH | 22 | Tailscale only |
| Wings SFTP | 2023 | Internal |

---

## 📦 Prerequisites

Before starting, you need:

- ✅ **Google Account** — for IDX access
- ✅ **Cloudflare Account** — free at [cloudflare.com](https://cloudflare.com)
- ✅ **Domain on Cloudflare** — any domain managed by Cloudflare
- ✅ **Supabase / PostgreSQL** — free database at [supabase.com](https://supabase.com)
- ✅ **Tailscale Account** — free at [tailscale.com](https://tailscale.com)

**Subdomains needed:**
```
panel.yourdomain.com     → Pelican Panel
node-1.yourdomain.com    → Wings Node
```

---

## ⚡ Quick Start

### Run the NexusBot Menu:

```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/main.sh | bash
```

Or download and run:

```bash
wget https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/main.sh
chmod +x main.sh
bash main.sh
```

This opens the **NexusBot All-In-One Menu** where you can install everything.

---

## Part 1 — Ubuntu VPS on Google IDX

### Step 1 — Set Up dev.nix

In your Google IDX project, open `.idx/dev.nix` and use this configuration:

```nix
{ pkgs, ... }: {
  channel = "stable-24.05";

  packages = with pkgs; [
    unzip
    openssh
    git
    qemu_kvm
    qemu
    sudo
    cdrkit
    cloud-utils
    curl
    wget
    nano
    screen
    tmux
    virtiofsd
    sshpass
  ];

  env = {
    EDITOR = "nano";
    QEMU_AUDIO_DRV = "none";
  };

  idx = {
    extensions = [
      "Dart-Code.flutter"
      "Dart-Code.dart-code"
    ];

    workspace = {
      onCreate = { };
      onStart = { };
    };

    previews = {
      enable = false;
    };
  };
}
```

Save the file — IDX will rebuild the environment automatically.

### Step 2 — Install Ubuntu VM

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/vps.sh)
```

This will:
- Download Ubuntu cloud image
- Set up QEMU/KVM virtual machine
- Configure cloud-init
- Boot into Ubuntu

### Step 3 — Access Your Ubuntu Server

After boot, SSH into it:

```bash
ssh root@localhost -p 2222
```

### Step 4 — Set Up VNC Desktop (Required for Keepalive)

After your VM is booted and you are SSH'd in, run this command to set up the VNC desktop environment. This is what you will use to keep Google IDX alive 24/7:

```bash
sudo apt install -y xfce4 xfce4-goodies tightvncserver novnc websockify
```

Then set up VNC:

```bash
vncpasswd
```

> ⚠️ **When asked for a password:** use your Ubuntu VM password.
> When asked **"Would you like to enter a view-only password?"** — type `n` and press Enter.

Then start the VNC server and desktop:

```bash
mkdir -p ~/.vnc && \
cat > ~/.vnc/xstartup << 'EOF'
#!/bin/bash
xrdb $HOME/.Xresources
startxfce4 &
EOF
chmod +x ~/.vnc/xstartup && \
vncserver -kill :1 2>/dev/null || true && \
vncserver :1 -geometry 1280x720 -depth 24
```

Then start noVNC (the browser-based viewer):

```bash
websockify --web=/usr/share/novnc/ 6080 localhost:5901 &
```

Your VNC desktop is now accessible at:
```
http://YOUR_TAILSCALE_IP:6080/vnc.html
```

> 💡 Get your Tailscale IP: `tailscale ip -4`

---

## Part 2 — Server Setup (SSH + RDP + Tailscale)

Run this **inside your Ubuntu VM** to set up all remote access tools:

```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/nexus-setup.sh | bash
```

### What it installs:

| Component | Purpose |
|-----------|---------|
| **OpenSSH** | Remote terminal access |
| **Tailscale** | Secure VPN (access from anywhere) |
| **xRDP + XFCE** | Full remote desktop (Windows RDP) |
| **Firefox** | Browser inside remote desktop |
| **sshx** | Terminal sharing (single instance) |

### Connect from Windows via Remote Desktop:

**SSH:**
```cmd
ssh root@YOUR_TAILSCALE_IP
```

**Remote Desktop (RDP):**
```
Win + R → mstsc → Enter YOUR_TAILSCALE_IP → Connect
```

> 💡 Get your Tailscale IP by running: `tailscale ip -4`

> ⚠️ **Having trouble connecting via RDP?** Make sure Tailscale is installed on your Windows PC and you are logged in with the **same Tailscale account** as your VM. Without this, the connection will fail.

---

## Part 3 — VNC Desktop + 24/7 Keepalive Guide

> Google IDX shuts down after ~2 hours of inactivity. Follow these steps to keep it running 24/7 using the **noVNC browser desktop** method.

This method is better than the Windows RDP method because it runs fully inside your VM — even if you close your PC, the session keeps going.

### Step 1 — Open Your VNC Desktop

Open any browser on your PC and go to:
```
http://YOUR_TAILSCALE_IP:6080/vnc.html
```

Enter your VNC password when prompted. You will see a full XFCE desktop in your browser.

### Step 2 — Open Firefox Inside the VNC Desktop

Inside the VNC desktop, open the **Firefox** browser.

### Step 3 — Install the Auto Refresh Extension

1. In Firefox, open a new tab and search for **"Auto Refresh"** in the Firefox Add-ons store:
   ```
   https://addons.mozilla.org/en-US/firefox/search/?q=auto+refresh
   ```
2. Install the **second option** in the results (Tab Auto Refresh)
3. After installing, **pin it to the toolbar** so it's always visible

### Step 4 — Open Google IDX

1. Open a new tab in Firefox
2. Go to: `https://idx.google.com`
3. Login with your Google account
4. Open your project — wait for it to fully load

### Step 5 — Open a Terminal in IDX

1. In the IDX interface, click the **three-dash menu** (☰) at the top left
2. Select **Terminal → New Terminal**
3. A terminal will open at the bottom of IDX

### Step 6 — Enable Auto Refresh

1. Click the **blue Auto Refresh extension icon** in the Firefox toolbar
2. Set the interval to **5 minutes**
3. Click **Save** / enable it for the current tab (the IDX tab)

### Step 7 — Close the noVNC Tab (Do NOT Shutdown)

Close the `http://YOUR_TAILSCALE_IP:6080/vnc.html` browser tab on your PC — just close the **tab**, like you would close any website. Do **not** shut down Firefox inside the VNC desktop.

The Firefox inside the VNC desktop will keep running, keep refreshing IDX every 5 minutes, and keep your server alive 24/7 — even after you close your PC.

### ✅ Result

Your server will now stay active **24/7**:
- The VNC desktop runs inside the VM
- Firefox inside VNC keeps the IDX project open
- Auto Refresh prevents IDX from timing out
- You can safely close your own browser or PC

---

## Part 4 — Pelican Panel Installation

### Step 1 — Get Cloudflare Tunnel Token

1. Go to: [https://one.dash.cloudflare.com](https://one.dash.cloudflare.com)
2. Navigate: **Zero Trust → Networks → Tunnels**
3. Click **Create a tunnel** → Name it (e.g., `nexusserver`)
4. Choose **Cloudflared**
5. Copy the tunnel token (`eyJ...`)

### Step 2 — Prepare Database

Use [Supabase](https://supabase.com) (free PostgreSQL):
1. Create new project
2. Go to **Settings → Database**
3. Copy connection details:
   - Host, Port, Database, Username, Password

### Step 3 — Install Panel

```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/panel.sh | bash
```

**You will be asked for:**
```
Panel domain:           panel.yourdomain.com
Cloudflare Token:       eyJ... (from step 1)
Database Type:          1 (PostgreSQL)
Database Host:          Your database host
Database Port:          5432
Database Name:          Your database name
Database Username:      Your database username
Database Password:      Your database password
Redis Host:             127.0.0.1
Redis Port:             6379
```

### Step 4 — Create Admin User

```bash
cd /var/www/pelican
php artisan p:user:make
```

### Step 5 — Configure Cloudflare Tunnel for Panel

1. Go to your tunnel → **Public Hostnames → Add**
2. Fill in:

```
Subdomain:      panel
Domain:         yourdomain.com
Service Type:   HTTPS
URL:            localhost:443
No TLS Verify:  ✅ ON  ← REQUIRED!
```

3. Save → wait 30 seconds
4. Access: `https://panel.yourdomain.com`

---

## Part 5 — Pelican Wings Installation

### Step 1 — Create Node in Panel

1. Login to Panel → **Admin → Nodes → Create New**
2. Fill in:

```
Name:                     Node 1
FQDN:                     node-1.yourdomain.com
Connection Port:          443
Communicate over SSL:     HTTPS with (reverse) proxy   ← IMPORTANT!
Listening Port:           8080
```

3. Save node

### Step 2 — Get API Token

1. **Admin → API Keys**
2. Copy the token (starts with `papp_`)

### Step 3 — Install Wings

```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/wings.sh | bash
```

**You will be asked for:**
```
Node domain:    node-1.yourdomain.com
Panel URL:      https://panel.yourdomain.com
API Token:      papp_xxxxxxxxxxxxxxxx
Node ID:        1
CF Token:       eyJ... (same or separate tunnel token)
```

### Step 4 — Configure Cloudflare Tunnel for Wings

1. Go to your tunnel → **Public Hostnames → Add**
2. Fill in:

```
Subdomain:      node-1
Domain:         yourdomain.com
Service Type:   HTTP
URL:            localhost:8080
No TLS Verify:  ✅ ON  ← REQUIRED!
```

### Step 5 — Verify Connection

In Panel → **Admin → Nodes** — your node should show a **green heart ❤️**

If red, check:
```bash
# Wings logs
tail -f /tmp/wings.log

# Cloudflare logs
tail -f /var/log/cloudflared-wings.log

# Test Wings API
curl http://localhost:8080/api/system
```

Expected response (this is correct!):
```json
{"error":"The required authorization heads were not present in the request."}
```

---

## Part 6 — Cloudflare Tunnel Setup

### Summary of all tunnel routes needed:

| Subdomain | Service Type | URL | No TLS Verify |
|-----------|:-----------:|-----|:---:|
| `panel` | HTTPS | `localhost:443` | ✅ |
| `node-1` | HTTP | `localhost:8080` | ✅ |

### Important Notes:
- ✅ Panel tunnel uses `HTTPS` — Nginx handles SSL directly on port 443
- ✅ Wings tunnel uses `HTTP` — Wings runs plain HTTP, Cloudflare adds SSL
- ✅ Always enable **No TLS Verify** on both routes
- ✅ Panel node: Connection Port `443` | SSL: `HTTPS with (reverse) proxy`

---

## Part 7 — User Registration & Resource Limits

Enable self-registration so users can sign up and create servers:

```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/plugin-client.sh | bash
```

**Default limits set per user:**

| Resource | Default |
|----------|---------|
| CPU | 200% (3 cores) |
| RAM | 4096 MB (3GB) |
| Disk | 10240 MB (3GB) |
| Max Servers | 3 |
| Max Databases | 2 |
| Max Allocations | 3 |
| Max Backups | 1 |

### After installation:

1. Go to **Admin → Nodes → Edit Node**
2. Find **Tags** field
3. Add: `user_creatable_servers`
4. Save

> ⚠️ Without this tag, users cannot create servers on the node!

---

## Part 8 — Restart All Services

If anything stops working, restart everything:

```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/restart.sh | bash
```

Or manually:

```bash
# Restart individual services
sudo systemctl restart nginx
sudo systemctl restart php8.3-fpm
sudo systemctl restart redis-server
sudo systemctl restart wings
sudo systemctl restart cloudflared

# Clear Panel cache
cd /var/www/pelican
php artisan cache:clear
php artisan config:clear
php artisan route:clear
php artisan view:clear
```

---

## dev.nix Configuration

This is the required `dev.nix` for Google IDX to support Ubuntu VMs:

```nix
{ pkgs, ... }: {
  channel = "stable-24.05";

  packages = with pkgs; [
    unzip
    openssh
    git
    qemu_kvm
    qemu
    sudo
    cdrkit
    cloud-utils
    curl
    wget
    nano
    screen
    tmux
    virtiofsd
    sshpass
  ];

  env = {
    EDITOR = "nano";
    QEMU_AUDIO_DRV = "none";
  };

  idx = {
    extensions = [
      "Dart-Code.flutter"
      "Dart-Code.dart-code"
    ];

    workspace = {
      onCreate = { };
      onStart = { };
    };

    previews = {
      enable = false;
    };
  };
}
```

**Key packages explained:**

| Package | Purpose |
|---------|---------|
| `qemu_kvm` + `qemu` | Run Ubuntu VM |
| `cdrkit` + `cloud-utils` | Create cloud-init ISO |
| `openssh` | SSH client/server |
| `sshpass` | Auto SSH password |
| `virtiofsd` | Shared filesystem for VM |
| `tmux` + `screen` | Terminal multiplexer |

---

## 🐛 Troubleshooting

### Panel shows 500 error
```bash
cd /var/www/pelican
php artisan cache:clear
php artisan config:clear
php artisan route:clear
php artisan migrate --force
sudo systemctl restart nginx php8.3-fpm
```

### Wings node shows red heart
```bash
# Check Wings is running
systemctl status wings

# Check logs
tail -30 /tmp/wings.log

# Restart Wings
sudo systemctl restart wings

# Test Wings API
curl http://localhost:8080/api/system
```

### Can't connect via RDP from Windows
```bash
sudo systemctl restart xrdp
sudo rm -f /tmp/.X*-lock
sudo rm -f /tmp/.X11-unix/X*
sudo systemctl restart xrdp
```

> ⚠️ Also make sure **Tailscale is installed and logged in on your Windows PC** with the **same account** as your VM. Without this, RDP will not connect.

### noVNC page not loading
```bash
# Check websockify is running
pgrep websockify || websockify --web=/usr/share/novnc/ 6080 localhost:5901 &

# Check VNC server is running
vncserver :1 -geometry 1280x720 -depth 24
```

### SSH connection timeout
```bash
# Check SSH is running
sudo systemctl status ssh

# Check Tailscale is connected
tailscale status

# Verify SSH config
grep -E "PermitRootLogin|PasswordAuthentication|Port" /etc/ssh/sshd_config
```

### apt lock error
```bash
sudo kill -9 $(lsof /var/lib/dpkg/lock-frontend | awk 'NR>1{print $2}')
sudo rm /var/lib/dpkg/lock-frontend
sudo rm /var/lib/dpkg/lock
sudo rm /var/cache/apt/archives/lock
sudo dpkg --configure -a
```

### IDX keeps shutting down
- Make sure **Auto Refresh extension** is active on the IDX tab inside the VNC Firefox
- Set interval to **5 minutes**
- Make sure Firefox inside VNC is **not closed** — only close the noVNC browser tab on your PC
- The VNC desktop must stay running inside the VM

---

## 📁 Scripts Reference

| Script | Command | Purpose |
|--------|---------|---------|
| `main.sh` | `bash main.sh` | NexusBot all-in-one menu |
| `vps.sh` | auto | Install Ubuntu VM on IDX |
| `nexus-setup.sh` | auto | Setup SSH, RDP, Tailscale, sshx |
| `panel.sh` | auto | Install Pelican Panel |
| `wings.sh` | auto | Install Pelican Wings |
| `plugin-client.sh` | auto | User registration + resource limits |
| `restart.sh` | auto | Restart all services |
| `uninstall.sh` | auto | Remove Pelican components |

### Run any script directly:
```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/SCRIPT_NAME.sh | bash
```

---

## 🔐 Security Notes

- ⚠️ Never share your `.pelican.env` file publicly
- ⚠️ Never commit secrets to GitHub
- ✅ Always add `.pelican.env` to `.gitignore`
- ✅ Use strong passwords for root and database
- ✅ Tailscale ensures SSH/RDP/VNC is not exposed publicly
- ✅ Cloudflare Tunnel avoids opening ports on the server

```bash
# Add to gitignore
echo ".pelican.env" >> .gitignore
echo ".backups/" >> .gitignore
```

---

## 📝 Quick Reference

### Important IPs & Ports

```bash
# Get Tailscale IP
tailscale ip -4

# Get public IP
curl ifconfig.me

# Check all listening ports
sudo ss -tlnp
```

### Useful Commands

```bash
# Panel
cd /var/www/pelican
php artisan migrate
php artisan p:user:make
php artisan cache:clear
tail -f storage/logs/laravel.log

# Wings
systemctl status wings
tail -f /tmp/wings.log
curl http://localhost:8080/api/system

# VNC
vncserver :1 -geometry 1280x720 -depth 24
websockify --web=/usr/share/novnc/ 6080 localhost:5901 &

# sshx link
journalctl -u sshx -f

# Tailscale
tailscale status
tailscale ip -4
```

---

## 🎉 Done!

If everything is set up correctly:

- ✅ Ubuntu VM running inside Google IDX
- ✅ VNC desktop accessible via browser at `http://TAILSCALE_IP:6080/vnc.html`
- ✅ IDX kept alive 24/7 via Auto Refresh in VNC Firefox
- ✅ Pelican Panel accessible at `https://panel.yourdomain.com`
- ✅ Wings node shows green heart in Panel
- ✅ Users can self-register and create servers

---

**Made with ❤️ by NexusTechPro**
[github.com/nexustechpro2/VM-in-Google-Idx](https://github.com/nexustechpro2/VM-in-Google-Idx)
