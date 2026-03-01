#!/bin/bash

# This script downloads the latest Prometheus Node Exporter, installs it,
# configures it to listen on the server's primary non-loopback IPv4 address on port 9100,
# creates a systemd service, enables it for boot, and starts it in the background.
# It also installs Cronicle, including its dependencies (Node.js), configures it with a specific secret_key,
# sets it up as a systemd service to start on boot, and starts it.
# Run as root or with sudo.
# Assumes a modern Linux distro with systemd, tar, ip command (and installs curl and Node.js if missing).

set -e

# ────────────────────────────────────────────────
# Install curl if not already present
# ────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found → attempting to install it..."

    if command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu
        apt-get update -qq && apt-get install -y -qq curl
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        # CentOS/RHEL/Fedora
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y curl
        else
            yum install -y curl
        fi
    elif command -v apk >/dev/null 2>&1; then
        # Alpine
        apk add --no-cache curl
    else
        echo "ERROR: Could not detect package manager (apt/yum/dnf/apk)."
        echo "Please install curl manually and re-run the script."
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: Failed to install curl."
        exit 1
    fi
    echo "curl is now installed."
else
    echo "curl is already installed."
fi

# ────────────────────────────────────────────────
# Install Node.js if not already present (required for Cronicle)
# ────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    echo "Node.js not found → attempting to install it..."

    if command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu
        apt-get install -y ca-certificates curl gnupg
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        NODE_MAJOR=20
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq
        apt-get install -y nodejs
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        # CentOS/RHEL/Fedora
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y nodejs
        else
            yum install -y nodejs
        fi
    elif command -v apk >/dev/null 2>&1; then
        # Alpine
        apk add --no-cache nodejs npm
    else
        echo "ERROR: Could not detect package manager (apt/yum/dnf/apk)."
        echo "Please install Node.js manually and re-run the script."
        exit 1
    fi

    if ! command -v node >/dev/null 2>&1; then
        echo "ERROR: Failed to install Node.js."
        exit 1
    fi
    echo "Node.js is now installed."
else
    echo "Node.js is already installed."
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
# Detect primary non-loopback IPv4 address
# ────────────────────────────────────────────────
IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1)
if [ -z "$IP" ]; then
  echo "Could not detect server IP. Please set it manually or check 'ip addr'."
  exit 1
fi
echo "Detected server IP: $IP"

# ────────────────────────────────────────────────
# Get latest version from GitHub API
# ────────────────────────────────────────────────
LATEST_VERSION=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d '"' -f4 | sed 's/v//')
if [ -z "$LATEST_VERSION" ]; then
  echo "Failed to fetch latest version from GitHub."
  exit 1
fi
echo "Latest Node Exporter version: v$LATEST_VERSION"

# ────────────────────────────────────────────────
# Download, extract, install Node Exporter
# ────────────────────────────────────────────────
wget -q --show-progress "https://github.com/prometheus/node_exporter/releases/download/v${LATEST_VERSION}/node_exporter-${LATEST_VERSION}.linux-${ARCH}.tar.gz"
tar xvf node_exporter-${LATEST_VERSION}.linux-${ARCH}.tar.gz >/dev/null
sudo mv node_exporter-${LATEST_VERSION}.linux-${ARCH}/node_exporter /usr/local/bin/
rm -rf node_exporter-${LATEST_VERSION}.linux-${ARCH}*
echo "Node Exporter installed to /usr/local/bin/node_exporter"

# ────────────────────────────────────────────────
# Create dedicated user for Node Exporter (if missing)
# ────────────────────────────────────────────────
if ! id -u node_exporter >/dev/null 2>&1; then
  sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter
fi
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# ────────────────────────────────────────────────
# Create systemd service for Node Exporter (binds to detected IP:9100)
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

# ────────────────────────────────────────────────
# Enable for boot + start Node Exporter in background now
# ────────────────────────────────────────────────
sudo systemctl daemon-reload
sudo systemctl enable node_exporter --quiet
sudo systemctl start node_exporter

# Give it a moment to start
sleep 3

# ────────────────────────────────────────────────
# Install Cronicle
# ────────────────────────────────────────────────
echo "Installing Cronicle..."
curl -s https://raw.githubusercontent.com/jhuckaby/Cronicle/master/bin/install.js | node

# ────────────────────────────────────────────────
# Configure config.json with specific secret_key
# ────────────────────────────────────────────────
SECRET_KEY='%7*YGv5&S4fwvm!fDkG3fznB8rKthT'
sed -i "s/\"secret_key\": \"[^\"]*\"/\"secret_key\": \"${SECRET_KEY//&/\\&}\"/" /opt/cronicle/conf/config.json
echo "Updated config.json with secret_key."

# ────────────────────────────────────────────────
# Run setup (on primary server)
# ────────────────────────────────────────────────
/opt/cronicle/bin/control.sh setup

# ────────────────────────────────────────────────
# Create systemd service for Cronicle
# ────────────────────────────────────────────────
cat << EOF | sudo tee /etc/systemd/system/cronicle.service >/dev/null
[Unit]
Description=Cronicle
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

# ────────────────────────────────────────────────
# Enable for boot + start Cronicle in background now
# ────────────────────────────────────────────────
sudo systemctl daemon-reload
sudo systemctl enable cronicle --quiet
sudo systemctl start cronicle

# Give it a moment to start
sleep 3

# ────────────────────────────────────────────────
# Final verification for Node Exporter
# ────────────────────────────────────────────────
if sudo systemctl is-active --quiet node_exporter; then
  echo ""
  echo "Success! Node Exporter is now:"
  echo "  • Running in the background (managed by systemd)"
  echo "  • Set to start automatically on boot"
  echo "  • Listening on: http://${IP}:9100/metrics"
  echo ""
  echo "Quick local test:"
  echo "  curl -s http://localhost:9100/metrics | head -n 10"
  echo ""
else
  echo ""
  echo "Failed to start Node Exporter."
  echo "Check status and logs:"
  echo "  sudo systemctl status node_exporter"
  echo "  journalctl -u node_exporter -n 50 --no-pager"
fi

# ────────────────────────────────────────────────
# Final verification for Cronicle
# ────────────────────────────────────────────────
if sudo systemctl is-active --quiet cronicle; then
  echo ""
  echo "Success! Cronicle is now:"
  echo "  • Running in the background (managed by systemd)"
  echo "  • Set to start automatically on boot"
  echo "  • Listening on: http://${IP}:3012/ (default port)"
  echo ""
  echo "Default admin credentials: username 'admin', password 'admin' (change immediately)"
  echo "Quick local test:"
  echo "  curl -s http://localhost:3012/"
  echo ""
else
  echo ""
  echo "Failed to start Cronicle."
  echo "Check status and logs:"
  echo "  sudo systemctl status cronicle"
  echo "  journalctl -u cronicle -n 50 --no-pager"
fi
