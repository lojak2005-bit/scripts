#!/bin/bash

# =============================================================================
# Cronicle WORKER + Node Exporter Install Script
# =============================================================================
# This script:
#   - Installs Prometheus Node Exporter (binds to primary IP:9100)
#   - Installs Node.js if missing
#   - Installs Cronicle (same install command as master)
#   - Prompts for secret_key (must match PRIMARY server!)
#   - Updates /opt/cronicle/conf/config.json with the provided secret_key
#   - Does NOT run 'control.sh setup' (critical for workers!)
#   - Sets up Cronicle as systemd service (starts on boot)
#
# Run as root/sudo on the WORKER server.
# BEFORE running: Copy config.json from your PRIMARY Cronicle server!
#
# =============================================================================

set -e

echo "============================================================="
echo "        Cronicle WORKER + Node Exporter Setup"
echo "============================================================="
echo ""

# ────────────────────────────────────────────────
# Install curl if missing
# ────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
    echo "Installing curl..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq curl
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        command -v dnf >/dev/null 2>&1 && dnf install -y curl || yum install -y curl
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl
    else
        echo "ERROR: Cannot install curl automatically. Do it manually."
        exit 1
    fi
fi

# ────────────────────────────────────────────────
# Install Node.js 20.x if missing
# ────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js 20.x..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y ca-certificates curl gnupg
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq && apt-get install -y nodejs
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        command -v dnf >/dev/null 2>&1 && dnf install -y nodejs || yum install -y nodejs
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nodejs npm
    else
        echo "ERROR: Cannot install Node.js automatically."
        exit 1
    fi
fi

# ────────────────────────────────────────────────
# Node Exporter: Detect arch + IP + latest version
# ────────────────────────────────────────────────
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64";;
  aarch64) ARCH="arm64";;
  armv7l) ARCH="armv7";;
  *) echo "Unsupported arch: $ARCH"; exit 1;;
esac

IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)
[ -z "$IP" ] && { echo "Cannot detect primary IP"; exit 1; }
echo "Server IP detected: $IP"

LATEST_VERSION=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d '"' -f4 | sed 's/v//')
[ -z "$LATEST_VERSION" ] && { echo "Cannot fetch node_exporter version"; exit 1; }

# Download + install node_exporter
wget -q --show-progress "https://github.com/prometheus/node_exporter/releases/download/v${LATEST_VERSION}/node_exporter-${LATEST_VERSION}.linux-${ARCH}.tar.gz"
tar xvf node_exporter-*.tar.gz >/dev/null
sudo mv node_exporter-*/node_exporter /usr/local/bin/
rm -rf node_exporter-*
sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# node_exporter service
cat << EOF | sudo tee /etc/systemd/system/node_exporter.service >/dev/null
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${IP}:9100
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter --quiet

# ────────────────────────────────────────────────
# Install Cronicle (same as master)
# ────────────────────────────────────────────────
echo ""
echo "Installing Cronicle..."
curl -s https://raw.githubusercontent.com/jhuckaby/Cronicle/master/bin/install.js | node

# ────────────────────────────────────────────────
# SECRET KEY PROMPT (must match primary!)
# ────────────────────────────────────────────────
echo ""
echo "!!! IMPORTANT !!!"
echo "This is a WORKER server setup."
echo "1. Copy /opt/cronicle/conf/config.json from your PRIMARY server first!"
echo "2. The secret_key below MUST match the primary server's secret_key exactly."
echo ""

while true; do
    read -sp "Enter secret_key (from primary): " SECRET_KEY
    echo ""
    read -sp "Confirm secret_key: " SECRET_KEY2
    echo ""

    if [ -z "$SECRET_KEY" ]; then
        echo "Error: secret_key cannot be empty."
    elif [ "$SECRET_KEY" != "$SECRET_KEY2" ]; then
        echo "Error: Keys do not match."
    else
        break
    fi
done

# Escape for sed
ESCAPED_SECRET=$(printf '%s' "$SECRET_KEY" | sed 's/[&/\]/\\&/g')

# Update config.json (assumes it already exists from primary copy)
if [ -f /opt/cronicle/conf/config.json ]; then
    sed -i "s/\"secret_key\": \".*\"/\"secret_key\": \"${ESCAPED_SECRET}\"/" /opt/cronicle/conf/config.json
    echo "secret_key updated in config.json."
else
    echo "ERROR: /opt/cronicle/conf/config.json not found!"
    echo "Please scp it from the primary server BEFORE continuing."
    exit 1
fi

# IMPORTANT: Do NOT run setup on workers!
echo ""
echo "Skipping 'control.sh setup' — correct for worker nodes."

# ────────────────────────────────────────────────
# Cronicle worker systemd service
# ────────────────────────────────────────────────
cat << EOF | sudo tee /etc/systemd/system/cronicle.service >/dev/null
[Unit]
Description=Cronicle Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/opt/cronicle/logs/cronicle.pid
ExecStart=/opt/cronicle/bin/control.sh start
ExecStop=/opt/cronicle/bin/control.sh stop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cronicle --quiet
sudo systemctl start cronicle

sleep 3

# ────────────────────────────────────────────────
# Status summary
# ────────────────────────────────────────────────
echo ""
echo "═════════════════════════════════════════════════════════════"
if sudo systemctl is-active --quiet node_exporter; then
    echo "Node Exporter  → ACTIVE     http://${IP}:9100/metrics"
else
    echo "Node Exporter  → FAILED     sudo systemctl status node_exporter"
fi

if sudo systemctl is-active --quiet cronicle; then
    echo "Cronicle Worker → ACTIVE"
    echo "  → Should appear in primary UI under Servers within ~30s"
    echo "  → Make sure firewall allows port 3012 (or custom http_port)"
else
    echo "Cronicle Worker → FAILED"
    echo "  sudo systemctl status cronicle"
    echo "  Check logs: /opt/cronicle/logs/"
fi
echo "═════════════════════════════════════════════════════════════"
echo ""

echo "Worker setup complete."
echo "Go to your primary Cronicle UI → Servers tab to confirm this node appears."
echo "If it doesn't show up, double-check:"
echo "  - secret_key matches exactly"
echo "  - config.json is identical (except possibly hostname/IP)"
echo "  - Firewall allows traffic on Cronicle HTTP port (default 3012)"
