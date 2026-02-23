# Auto-Install Prometheus Node Exporter

A simple, one-click bash script that installs the latest **Prometheus Node Exporter** on modern Linux systems, configures it securely, binds it to the server's primary IPv4 address on port 9100, sets up a systemd service, enables auto-start on boot, and verifies everything works.

Perfect for homelabs, VPS fleets, bare-metal clusters, or quickly adding monitoring to new servers.

## Features

- Downloads and installs the **latest stable** Node Exporter release automatically (via GitHub API)
- Supports common architectures: amd64 (x86_64), arm64 (aarch64), armv7
- Automatically detects the server's main non-loopback IPv4 address
- Installs `curl` if missing (Debian/Ubuntu, RHEL/CentOS/Fedora, Alpine)
- Creates a dedicated unprivileged user `node_exporter`
- Binds Node Exporter explicitly to the detected IP:9100 (safer than 0.0.0.0)
- Installs a clean systemd service with auto-restart
- Enables and starts the service in the background
- Includes success/failure verification + quick metrics test
- Minimal dependencies, mostly idempotent

## Requirements

- Linux with **systemd** (Ubuntu 16.04+, Debian 9+, CentOS 7+, Fedora, Rocky, AlmaLinux, etc.)
- Root or sudo access
- Internet access (for download + curl if needed)
- Common tools: `ip`, `wget`, `tar`, `grep`, `sed` (usually pre-installed)

## Supported Distributions

- Ubuntu / Debian
- CentOS / RHEL / Rocky / AlmaLinux / Fedora
- Alpine Linux
- Most other systemd-based distros with apt, yum/dnf, or apk

## Installation

1. Download the script:

   ```bash
   wget https://raw.githubusercontent.com/YOUR-USERNAME/YOUR-REPO/main/install-node-exporter.sh
