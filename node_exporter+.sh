#!/bin/bash

# =============================================================================
# Cronicle WORKER + Prometheus Node Exporter Install Script (Improved 2026)
# =============================================================================
# For WORKER servers ONLY.
# - Installs/sets up Node Exporter (monitors the worker)
# - Installs Node.js if missing
# - Installs Cronicle
# - Prompts for secret_key (MUST match primary/master exactly)
# - Expects you already copied /opt/cronicle/conf/config.json from primary
# - Uses Type=simple systemd service → fixes PID file timeout/restart loop
# - Does NOT run control.sh setup (critical!)
#
# Run as root/sudo on the WORKER.
# BEFORE running: scp config.json from primary to this server:
#   scp user@primary:/opt/cronicle/conf/config.json /opt/cronicle/conf/
#
# =============================================================================

set -e

echo ""
echo "===== Cronicle WORKER + Node Exporter Setup (Improved) ====="
echo ""

# ────────────────────────────────────────────────
# Install curl if missing
# ────────────────────────────────────────────────
if ! command -v curl &> /dev/null; then
    echo "Installing curl..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq curl
    elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        { command -v dnf && dnf install -y curl; } || yum install -y curl
    elif command -v apk &> /dev/null; then
        apk add --no-cache curl
    else
        echo "ERROR: Cannot install curl. Install it manually."
        exit 1
    fi
fi

# ────────────────────────────────────────────────
# Install Node.js 20.x if missing
# ────────────────────────────────────────────────
if ! command -v node &> /dev/null; then
    echo "Installing Node.js 20.x..."
    if command -v apt-get &> /dev/null; then
        apt-get install -y ca-certificates curl gnupg
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq && apt-get install -y nodejs
    elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        { command -v dnf && dnf install -y nodejs; } || yum install -y nodejs
    elif command -v apk &> /dev/null; then
        apk add --no-cache nodejs npm
    else
        echo "ERROR: Cannot install Node.js automatically."
        exit 1
    fi
fi

# ────────────────────────────────────────────────
# Node Exporter setup
# ────────────────────────────────────────────────
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64";;
  aarch64) ARCH="arm64";;
  armv7l) ARCH="armv7";;
  *) echo "Unsupported architecture: $ARCH"; exit 1;;
esac

IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)
[ -z "$IP" ] && { echo "Cannot detect primary IPv4"; exit 1; }
echo "Detected IP: $IP"

LATEST=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d '"' -f4 | sed 's/v//')
[ -z "$LATEST" ] && { echo "Failed to get node_exporter version"; exit 1; }

wget -q --show-progress "https://github.com/prometheus/node_exporter/releases/download/v${LATEST}/node_exporter-${LATEST}.linux-${ARCH}.tar.gz"
tar xvf node_exporter-*.tar.gz >/dev/null
sudo mv node_exporter-*/node_exporter /usr/local/bin/
rm -rf node_exporter-*
sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter 2>/dev/null || true
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

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
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter >/dev/null 2>&1 || true

# ────────────────────────────────────────────────
# Install Cronicle
# ────────────────────────────────────────────────
echo ""
echo "Installing/updating Cronicle..."
curl -s https://raw.githubusercontent.com/jhuckaby/Cronicle/master/bin/install.js | node

# ────────────────────────────────────────────────
# SECRET KEY (must match primary exactly!)
# ────────────────────────────────────────────────
echo ""
echo "!!! WORKER SETUP IMPORTANT !!!"
echo "1. You MUST have copied config.json from the primary server."
echo "2. Enter the exact same secret_key used on the primary."
echo ""

while true; do
    read -sp "Secret Key: " SECRET
    echo ""
    read -sp "Confirm:     " SECRET2
    echo ""
    if [ -z "$SECRET" ]; then
        echo "Error: Cannot be empty."
    elif [ "$SECRET" != "$SECRET2" ]; then
        echo "Error: Keys do not match."
    else
        break
    fi
done

ESCAPED=$(printf '%s' "$SECRET" | sed 's/[&/\\]/\\&/g')

CONFIG="/opt/cronicle/conf/config.json"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found!"
    echo "Copy it from primary first: scp user@primary:$CONFIG $CONFIG"
    exit 1
fi

sed -i "s/\"secret_key\": \".*\"/\"secret_key\": \"${ESCAPED}\"/" "$CONFIG"
echo "Updated secret_key in config.json"

# ────────────────────────────────────────────────
# Cronicle systemd service (FIXED: Type=simple)
# ────────────────────────────────────────────────
cat << EOF | sudo tee /etc/systemd/system/cronicle.service >/dev/null
[Unit]
Description=Cronicle Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/cronicle
Environment="NODE_ENV=production"
ExecStart=/opt/cronicle/bin/control.sh start
ExecStop=/opt/cronicle/bin/control.sh stop
Restart=always
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

# Clean any stale PID files (prevents confusion)
sudo rm -f /opt/cronicle/logs/*.pid

sudo systemctl daemon-reload
sudo systemctl enable cronicle --quiet
sudo systemctl restart cronicle  # restart in case old one was stuck

sleep 5

# ────────────────────────────────────────────────
# Status & Troubleshooting
# ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
if systemctl is-active --quiet node_exporter; then
    echo "Node Exporter → ACTIVE    → http://${IP}:9100/metrics"
else
    echo "Node Exporter → FAILED"
    systemctl status node_exporter --no-pager -l | head -n 15
fi

if systemctl is-active --quiet cronicle; then
    echo "Cronicle Worker → ACTIVE"
    echo "  → Check primary UI → Servers tab (may take 30-60s to appear)"
    echo "  → Logs: tail -f /opt/cronicle/logs/cronicle.log"
else
    echo "Cronicle Worker → FAILED / not starting properly"
    echo ""
    echo "systemctl status cronicle:"
    systemctl status cronicle --no-pager -l
    echo ""
    echo "Last 30 log lines:"
    tail -n 30 /opt/cronicle/logs/cronicle.log || echo "No log file yet"
fi
echo "═══════════════════════════════════════════════════════════"
echo ""

echo "Done. If worker doesn't show in primary UI:"
echo " - Confirm secret_key matches exactly"
echo " - Ensure firewall allows inbound/outbound on Cronicle port (default 3012)"
echo " - Check network reachability between primary ↔ worker"
echo " - Review /opt/cronicle/logs/cronicle.log for errors"
