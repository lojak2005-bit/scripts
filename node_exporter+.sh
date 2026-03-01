#!/bin/bash

# This script:
# - Installs Prometheus Node Exporter (latest version)
# - Binds it to the server's primary non-loopback IPv4 on port 9100
# - Sets it up as a systemd service (start on boot)
# - Installs Node.js (if missing) → required for Cronicle
# - Installs Cronicle
# - Prompts the user for the secret_key
# - Configures config.json with the provided secret_key
# - Sets up Cronicle as a systemd service (start on boot)
#
# Run as root or with sudo.
# Assumes modern Linux with systemd.

set -e

# ────────────────────────────────────────────────
# Install curl if missing
# ────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found → installing..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq curl
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y curl
        else
            yum install -y curl
        fi
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl
    else
        echo "ERROR: Unknown package manager. Install curl manually."
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: Failed to install curl."
        exit 1
    fi
    echo "curl installed."
fi

# ────────────────────────────────────────────────
# Install Node.js if missing (required for Cronicle)
# ────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    echo "Node.js not found → installing Node.js 20.x..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y ca-certificates curl gnupg
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        NODE_MAJOR=20
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq
        apt-get install -y nodejs
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y nodejs
        else
            yum install -y nodejs
        fi
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nodejs npm
    else
        echo "ERROR: Unknown package manager. Install Node.js manually."
        exit 1
    fi

    if ! command -v node >/dev/null 2>&1; then
        echo "ERROR: Failed to install Node.js."
        exit 1
    fi
    echo "Node.js installed."
fi

# ────────────────────────────────────────────────
# Detect architecture
# ────────────────────────────────────────────────
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64";;
  aarch64) ARCH="arm64";;
  armv7l) ARCH="armv7";;
  *) echo "Unsupported architecture: $ARCH"; exit 1;;
esac

# ────────────────────────────────────────────────
# Detect primary non-loopback IPv4
# ────────────────────────────────────────────────
IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)
if [ -z "$IP" ]; then
  echo "Could not detect primary IP. Check 'ip addr' output."
  exit 1
fi
echo "Detected server IP: $IP"

# ────────────────────────────────────────────────
# Get latest node_exporter version
# ────────────────────────────────────────────────
LATEST_VERSION=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d '"' -f4 | sed 's/v//')
if [ -z "$LATEST_VERSION" ]; then
  echo "Failed to fetch latest node_exporter version."
  exit 1
fi
echo "Latest node_exporter version: v$LATEST_VERSION"

# ────────────────────────────────────────────────
# Download + install node_exporter
# ────────────────────────────────────────────────
wget -q --show-progress "https://github.com/prometheus/node_exporter/releases/download/v${LATEST_VERSION}/node_exporter-${LATEST_VERSION}.linux-${ARCH}.tar.gz"
tar xvf node_exporter-${LATEST_VERSION}.linux-${ARCH}.tar.gz >/dev/null
sudo mv node_exporter-${LATEST_VERSION}.linux-${ARCH}/node_exporter /usr/local/bin/
rm -rf node_exporter-${LATEST_VERSION}.linux-${ARCH}*
echo "node_exporter installed to /usr/local/bin/node_exporter"

# Create user if missing
if ! id -u node_exporter >/dev/null 2>&1; then
  sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter
fi
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# ────────────────────────────────────────────────
# node_exporter systemd service
# ────────────────────────────────────────────────
cat << EOF | sudo tee /etc/systemd/system/node_exporter.service >/dev/null
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

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
sudo systemctl enable node_exporter --quiet
sudo systemctl start node_exporter
sleep 3

# ────────────────────────────────────────────────
# Install Cronicle
# ────────────────────────────────────────────────
echo "Installing Cronicle..."
curl -s https://raw.githubusercontent.com/jhuckaby/Cronicle/master/bin/install.js | node

# ────────────────────────────────────────────────
# Prompt user for secret_key
# ────────────────────────────────────────────────
echo ""
echo "Cronicle requires a secret_key for signing sessions and API tokens."
echo "This value should be a strong, random string (at least 32 characters recommended)."
echo "It will be stored in /opt/cronicle/conf/config.json"
echo ""

while true; do
    read -sp "Enter your desired secret_key: " SECRET_KEY
    echo ""
    read -sp "Confirm secret_key: " SECRET_KEY_CONFIRM
    echo ""

    if [ -z "$SECRET_KEY" ]; then
        echo "Error: secret_key cannot be empty."
    elif [ "$SECRET_KEY" != "$SECRET_KEY_CONFIRM" ]; then
        echo "Error: secret_keys do not match. Try again."
    else
        break
    fi
done

# Escape any special characters that might break sed (mainly & / \)
ESCAPED_SECRET=$(printf '%s' "$SECRET_KEY" | sed 's/[&/\]/\\&/g')

# Update config.json
sed -i "s/\"secret_key\": \".*\"/\"secret_key\": \"${ESCAPED_SECRET}\"/" /opt/cronicle/conf/config.json
echo "secret_key has been set in config.json."

# ────────────────────────────────────────────────
# Run Cronicle setup (on primary server)
# ────────────────────────────────────────────────
/opt/cronicle/bin/control.sh setup

# ────────────────────────────────────────────────
# Cronicle systemd service
# ────────────────────────────────────────────────
cat << EOF | sudo tee /etc/systemd/system/cronicle.service >/dev/null
[Unit]
Description=Cronicle Job Scheduler
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
# Final status checks
# ────────────────────────────────────────────────
echo ""
echo "───────────────────────────────────────────────"
if sudo systemctl is-active --quiet node_exporter; then
    echo "Node Exporter → ACTIVE (listening on http://${IP}:9100/metrics)"
else
    echo "Node Exporter → FAILED"
    echo "  Check: sudo systemctl status node_exporter"
fi

if sudo systemctl is-active --quiet cronicle; then
    echo "Cronicle     → ACTIVE (default UI: http://${IP}:3012/)"
    echo "Default login: admin / admin  → change immediately!"
else
    echo "Cronicle     → FAILED"
    echo "  Check: sudo systemctl status cronicle"
fi
echo "───────────────────────────────────────────────"
echo ""
