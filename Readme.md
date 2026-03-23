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
7. [Part 3 — 24/7 Keepalive Guide](#part-3--247-keepalive-guide)
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
- 🖥️ **xRDP** — Remote desktop connection

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
xRDP (port 3389)      Cloudflare Tunnel
Remote Desktop              │
                    ┌───────┴──────────┐
                    ▼                  ▼
          panel.nexusbot.qzz.io  node-1.nexusbot.qzz.io
                    │                  │
                    ▼                  ▼
             Nginx :8443          Wings :8080
                    │                  │
                    ▼                  ▼
           Pelican Panel          Docker Containers
           (PHP/Laravel)          (Game Servers)
```

**Port Reference:**

| Service | Internal Port | External Port |
|---------|:---:|:---:|
| Pelican Panel (Nginx) | 8443 | 443 (via Cloudflare) |
| Wings Node | 8080 | 443 (via Cloudflare) |
| xRDP | 3389 | Tailscale only |
| SSH | 22 | Tailscale only |
| Wings SFTP | 2022 | Internal |

---

## 📦 Prerequisites

Before starting, you need:

- ✅ **Google Account** — for IDX access
- ✅ **Cloudflare Account** — free at [cloudflare.com](https://cloudflare.com)
- ✅ **Domain on Cloudflare** — any domain managed by Cloudflare
- ✅ **Supabase / PostgreSQL** — free database at [supabase.com](https://supabase.com)
- ✅ **Tailscale Account** — free at [tailscale.com](https://tailscale.com)
- ✅ **Windows PC** — for Remote Desktop Connection

**Subdomains needed:**
```
panel.yourdomain.com     → Pelican Panel
node-1.yourdomain.com    → Wings Node
```

---

## ⚡ Quick Start

### Run the NexusBot Menu:

```bash
# On your Ubuntu server inside IDX:
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
# Run the VPS installer
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

Or use the VM manager menu to connect automatically.

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
| **xRDP + XFCE** | Full remote desktop at 1280x720 |
| **Firefox** | Browser inside remote desktop |
| **sshx** | Terminal sharing (single instance) |
| **Keepalive Service** | Prevents IDX from shutting down |

### After setup, connect from Windows:

**SSH:**
```cmd
ssh root@YOUR_TAILSCALE_IP
```

**Remote Desktop:**
```
Win + R → mstsc → Enter YOUR_TAILSCALE_IP → Connect
```

> 💡 Get your Tailscale IP by running: `tailscale ip -4`

---

## Part 3 — 24/7 Keepalive Guide

> Google IDX shuts down after ~2 hours of inactivity. Follow these steps to keep it running 24/7.

### Step 1 — Get your Tailscale IP
```bash
tailscale ip -4
```

### Step 2 — Connect via Remote Desktop
- Press `Win + R` → type `mstsc` → Enter
- Enter your **Tailscale IP**
- Login with your Ubuntu username and password

### Step 3 — Open Firefox inside RDP
In the RDP terminal:
```bash
DISPLAY=:10 firefox &
```

### Step 4 — Install Auto Refresh Extension
1. In Firefox, go to the **Extensions store**
2. Search for **"Auto Refresh Page"**
3. Click **Add to Firefox**

### Step 5 — Open Google IDX
1. Open a new tab
2. Go to: `https://idx.google.com`
3. Login with your Google account
4. Open your project

### Step 6 — Set Auto Refresh
1. Click the **Auto Refresh** extension icon
2. Set interval to **20 minutes**
3. Enable it on the IDX tab

### Step 7 — Open Terminal in IDX
In the IDX terminal, run the keepalive:
```bash
while true; do echo "alive $(date)"; sleep 60; done
```

### ✅ Result
Your server will now stay active **24/7** even after you close your PC — the RDP session running inside IDX keeps the browser active, and the auto-refresh prevents IDX timeout.

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
Database Host:          aws-1-eu-west-1.pooler.supabase.com
Database Port:          5432
Database Name:          postgres
Database Username:      postgres.xxxxx
Database Password:      your_password
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
Subdomain:    panel
Domain:       yourdomain.com
Service Type: HTTPS
URL:          localhost:8443
No TLS Verify: ✅ ON  ← CRITICAL!
```

3. Save → wait 30 seconds
4. Access: `https://panel.yourdomain.com`

---

## Part 5 — Pelican Wings Installation

### Step 1 — Create Node in Panel

1. Login to Panel → **Admin → Nodes → Create New**
2. Fill in:

```
Name:           Node 1
FQDN:           node-1.yourdomain.com
Port:           8443           ← NOT 8080!
Communicate over SSL:     HTTPS (SSL)
Scheme:         https
```

3. Save node

### Step 2 — Get API Token

1. **Admin → API Keys → Create**
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
Subdomain:     node-1
Domain:        yourdomain.com
Service Type:  HTTPS
URL:           localhost:8080
No TLS Verify: ✅ ON  ← CRITICAL!
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
curl -k https://localhost:8080/api/system
```

Expected response (this is correct!):
```json
{"error":"The required authorization heads were not present in the request."}
```

---

## Part 6 — Cloudflare Tunnel Setup

### Summary of all tunnel routes needed:

| Subdomain | Service | URL | No TLS Verify |
|-----------|---------|-----|:---:|
| `panel` | HTTPS | `localhost:8443` | ✅ |
| `node-1` | HTTPS | `localhost:8080` | ✅ |

### Important Notes:
- ❌ Never use `http://` — always `https://`
- ❌ Never put port 443 as the service URL
- ✅ Always enable **No TLS Verify** (self-signed certs)
- ✅ Panel: port `8443` | Wings: port `8080`

---

## Part 7 — User Registration & Resource Limits

Enable self-registration so users can sign up and create servers:

```bash
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/plugin-client.sh | bash
```

**Default limits set per user:**

| Resource | Default |
|----------|---------|
| CPU | 200% (2 cores) |
| RAM | 4096 MB (4GB) |
| Disk | 10240 MB (10GB) |
| Max Servers | 2 |
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
sudo systemctl restart redis
sudo systemctl restart xrdp
sudo systemctl restart cloudflared
sudo systemctl restart tailscaled

# Restart Wings
pkill wings && cd /etc/pelican && nohup wings > /tmp/wings.log 2>&1 &

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
ps aux | grep wings

# Check logs
tail -30 /tmp/wings.log

# Restart Wings
pkill wings
cd /etc/pelican
nohup wings > /tmp/wings.log 2>&1 &
```

### Can't connect via RDP
```bash
sudo systemctl restart xrdp
# Remove any broken locks
sudo rm -f /tmp/.X*-lock
sudo rm -f /tmp/.X11-unix/X*
sudo systemctl restart xrdp
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
- Make sure **auto-refresh extension** is active on the IDX tab
- Set interval to **20 minutes** (not less — avoid ban)
- Keep the **keepalive loop** running in IDX terminal
- Use **RDP session** to keep the browser open

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
# Replace SCRIPT_NAME with the script you want
curl -fsSL https://raw.githubusercontent.com/nexustechpro2/VM-in-Google-Idx/main/SCRIPT_NAME.sh | bash
```

---

## 🔐 Security Notes

- ⚠️ Never share your `.pelican.env` file publicly
- ⚠️ Never commit secrets to GitHub
- ✅ Always add `.pelican.env` to `.gitignore`
- ✅ Use strong passwords for root and database
- ✅ Tailscale ensures SSH/RDP is not exposed publicly
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
tail -f /tmp/wings.log
curl -k https://localhost:8080/api/system

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
- ✅ Remote Desktop accessible via Tailscale
- ✅ IDX kept alive 24/7 via auto-refresh
- ✅ Pelican Panel accessible at `https://panel.yourdomain.com`
- ✅ Wings node shows green heart in Panel
- ✅ Users can self-register and create servers

---

**Made with ❤️ by NexusTechPro**  
[github.com/nexustechpro2/VM-in-Google-Idx](https://github.com/nexustechpro2/VM-in-Google-Idx)