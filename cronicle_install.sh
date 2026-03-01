#!/bin/bash

# This script installs Cronicle on a Linux server (Ubuntu/Debian recommended) as a WORKER node.
# It:
#   - Installs Node.js LTS
#   - Installs Cronicle
#   - Prompts for secret_key (must match primary server!)
#   - Edits config.json to set the secret_key using jq
#   - Sets up systemd service
#   - Starts the service and enables on boot
#
# Prerequisites:
# - Run as root (or with sudo)
# - For workers: Do NOT run bin/control.sh setup
# - secret_key must be identical to the primary server's config.json secret_key
#   (copy it from the primary server or generate once and reuse everywhere)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Cronicle worker installation...${NC}"

# Update and install prerequisites
apt update -y
apt install -y curl tar jq  # jq is needed for safe JSON editing

# Install Node.js LTS via nodesource
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install -y nodejs

# Verify
node -v || { echo -e "${RED}Node.js install failed${NC}"; exit 1; }
npm -v  || { echo -e "${RED}npm install failed${NC}"; exit 1; }

# Install Cronicle
mkdir -p /opt/cronicle
cd /opt/cronicle
curl -s https://raw.githubusercontent.com/jhuckaby/Cronicle/master/bin/install.js | node

echo -e "${GREEN}Cronicle installed.${NC}"

# ────────────────────────────────────────────────
# Prompt for secret_key (critical for worker to join cluster)
# ────────────────────────────────────────────────
echo ""
echo "For a worker node, all servers MUST share the exact same 'secret_key'."
echo "Copy the value from your primary/master server's /opt/cronicle/conf/config.json"
echo "(it's a random string set during primary setup)."
echo ""
read -p "Enter the secret_key value: " SECRET_KEY
echo ""

if [[ -z "$SECRET_KEY" ]]; then
  echo -e "${RED}Error: secret_key cannot be empty. Exiting.${NC}"
  exit 1
fi

CONFIG_FILE="/opt/cronicle/conf/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}Error: $CONFIG_FILE not found. Installation may have failed.${NC}"
  exit 1
fi

# Backup original config
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
echo "Created backup: ${CONFIG_FILE}.bak"

# Use jq to set secret_key (creates field if missing, overwrites if present)
jq --arg sk "$SECRET_KEY" '.secret_key = $sk' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
  && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo -e "${GREEN}Updated secret_key in $CONFIG_FILE${NC}"

# Optional: You can also set other common worker-friendly settings here, e.g.:
# jq '. + { "server_comm_use_hostnames": 1, "web_direct_connect": 0 }' "$CONFIG_FILE" > tmp && mv tmp "$CONFIG_FILE"

# ────────────────────────────────────────────────
# Set up systemd service
# ────────────────────────────────────────────────
cat <<EOF > /etc/systemd/system/cronicle.service
[Unit]
Description=Cronicle Worker Service
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/opt/cronicle/logs/cronicled.pid
ExecStart=/opt/cronicle/bin/control.sh start
ExecStop=/opt/cronicle/bin/control.sh stop
Restart=always
User=root
Group=root
WorkingDirectory=/opt/cronicle

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cronicle.service

# Start the service
systemctl start cronicle.service

echo ""
echo -e "${GREEN}Done!${NC}"
echo "Cronicle worker installed, configured with your secret_key, and started."
echo ""
echo "Next steps:"
echo " 1. Check status:   systemctl status cronicle"
echo " 2. View logs:      journalctl -u cronicle -f"
echo " 3. Go to your primary Cronicle web UI → Admin → Servers"
echo "    → Confirm this worker appears and shows as online."
echo ""
echo "If the worker doesn't connect:"
echo " - Double-check secret_key matches exactly (case-sensitive)"
echo " - Ensure clocks are synced between servers"
echo " - Check firewall allows UDP 3014 (discovery) and TCP 3012 (API)"
echo ""
