sh
#!/bin/bash

# Define variables
SINGBOX_VERSION="1.4.0" # Replace with the desired sing-box version
CLOUDFLARED_VERSION="2023.10.0" # Replace with the desired cloudflared version
SINGBOX_CONFIG_PATH="/etc/sing-box/config.json"
CLOUDFLARED_CONFIG_PATH="/etc/cloudflared/config.yml"
CLOUDFLARED_TUNNEL_ID="YOUR_TUNNEL_ID" # Replace with your Cloudflare Tunnel ID
CLOUDFLARED_TUNNEL_SECRET="YOUR_TUNNEL_SECRET" # Replace with your Cloudflare Tunnel Secret
CLOUDFLARED_DOMAIN="YOUR_DOMAIN.COM" # Replace with your domain name
VLESS_UUID=$(uuidgen)
VMESS_UUID=$(uuidgen)
TROJAN_PASSWORD=$(openssl rand -base64 16)
LOG_FILE="/var/log/vps_setup.log"

# --- Helper Functions ---

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

error_exit() {
  log "ERROR: $1"
  exit 1
}

install_package() {
  local package_name="$1"
  if command -v "$package_name" &>/dev/null; then
    log "$package_name is already installed."
  else
    log "Installing $package_name..."
    if command -v apt-get &>/dev/null; then
      sudo apt-get update || error_exit "Failed to update apt repository."
      sudo apt-get install -y "$package_name" || error_exit "Failed to install $package_name."
    elif command -v yum &>/dev/null; then
      sudo yum update -y || error_exit "Failed to update yum repository."
      sudo yum install -y "$package_name" || error_exit "Failed to install $package_name."
    elif command -v dnf &>/dev/null; then
      sudo dnf update -y || error_exit "Failed to update dnf repository."
      sudo dnf install -y "$package_name" || error_exit "Failed to install $package_name."
    else
      error_exit "Unsupported package manager. Please install $package_name manually."
    fi
  fi
}

# --- Installation Functions ---

install_singbox() {
  if [ -f "/usr/local/bin/sing-box" ]; then
    log "sing-box is already installed."
    return
  fi

  log "Installing sing-box version $SINGBOX_VERSION..."
  SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-linux-amd64.tar.gz"
  TEMP_DIR=$(mktemp -d)
  wget -O "$TEMP_DIR/sing-box.tar.gz" "$SINGBOX_URL" || error_exit "Failed to download sing-box."
  tar -xzf "$TEMP_DIR/sing-box.tar.gz" -C "$TEMP_DIR" || error_exit "Failed to extract sing-box."
  sudo mv "$TEMP_DIR/sing-box" /usr/local/bin/ || error_exit "Failed to move sing-box binary."
  rm -rf "$TEMP_DIR"
  log "sing-box installed successfully."
}

install_cloudflared() {
  if command -v cloudflared &>/dev/null; then
    log "cloudflared is already installed."
    return
  fi

  log "Installing cloudflared version $CLOUDFLARED_VERSION..."
  CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64"
  TEMP_DIR=$(mktemp -d)
  wget -O "$TEMP_DIR/cloudflared" "$CLOUDFLARED_URL" || error_exit "Failed to download cloudflared."
  chmod +x "$TEMP_DIR/cloudflared"
  sudo mv "$TEMP_DIR/cloudflared" /usr/local/bin/ || error_exit "Failed to move cloudflared binary."
  rm -rf "$TEMP_DIR"
  log "cloudflared installed successfully."

  # Create cloudflared service
  if [ ! -f "/etc/systemd/system/cloudflared.service" ]; then
    log "Creating cloudflared systemd service..."
    cat <<EOF | sudo tee /etc/systemd/system/cloudflared.service > /dev/null
[Unit]
Description=Cloudflared Tunnel
After=network.target

[Service]
TimeoutStartSec=0
ExecStart=/usr/local/bin/cloudflared tunnel run --config ${CLOUDFLARED_CONFIG_PATH} ${CLOUDFLARED_TUNNEL_ID}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
    sudo systemctl enable cloudflared || error_exit "Failed to enable cloudflared service."
    log "cloudflared service created."
  fi
}

# --- Configuration Functions ---

configure_singbox() {
  log "Configuring sing-box..."
  sudo mkdir -p /etc/sing-box
  cat <<EOF | sudo tee "$SINGBOX_CONFIG_PATH" > /dev/null
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 10000,
      "users": [
        {
          "uuid": "$VLESS_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "transport": {
        "type": "tcp",
        "tcp_splitting": true
      },
      "tls": {
        "enabled": true,
        "server_name": "$CLOUDFLARED_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake_bytes": "ff00000000000000000000000000000000000000000000000000000000000000",
          "private_key": "$(sing-box generate reality-keypair -k)",
          "short_id": "$(sing-box generate reality-keypair -s)"
        }
      }
    },
    {
      "type": "vmess",
      "listen": "127.0.0.1",
      "listen_port": 10001,
      "users": [
        {
          "uuid": "$VMESS_UUID"
        }
      ],
      "transport": {
        "type": "tcp",
        "tcp_splitting": true
      }
    },
    {
      "type": "trojan",
      "listen": "127.0.0.1",
      "listen_port": 10002,
      "password": [
        "$TROJAN_PASSWORD"
      ],
      "transport": {
        "type": "tcp",
        "tcp_splitting": true
      },
      "tls": {
        "enabled": true,
        "server_name": "$CLOUDFLARED_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake_bytes": "ff00000000000000000000000000000000000000000000000000000000000000",
          "private_key": "$(sing-box generate reality-keypair -k)",
          "short_id": "$(sing-box generate reality-keypair -s)"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF
  log "sing-box configuration created."

  # Create sing-box service
  if [ ! -f "/etc/systemd/system/sing-box.service" ]; then
    log "Creating sing-box systemd service..."
    cat <<EOF | sudo tee /etc/systemd/system/sing-box.service > /dev/null
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c ${SINGBOX_CONFIG_PATH}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=5000
LimitNOFILE=100000
WorkingDirectory=/etc/sing-box/

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
    sudo systemctl enable sing-box || error_exit "Failed to enable sing-box service."
    log "sing-box service created."
  fi
}

configure_cloudflared() {
  log "Configuring cloudflared..."
  sudo mkdir -p /etc/cloudflared
  cat <<EOF | sudo tee "$CLOUDFLARED_CONFIG_PATH" > /dev/null
tunnel: ${CLOUDFLARED_TUNNEL_ID}
credentials-file: /etc/cloudflared/${CLOUDFLARED_TUNNEL_ID}.json

ingress:
  - hostname: vless.${CLOUDFLARED_DOMAIN}
    service: http://127.0.0.1:10000
  - hostname: vmess.${CLOUDFLARED_DOMAIN}
    service: http://127.0.0.1:10001
  - hostname: trojan.${CLOUDFLARED_DOMAIN}
    service: http://127.0.0.1:10002
  - service: http_status:404
EOF

  if [ ! -f "/etc/cloudflared/${CLOUDFLARED_TUNNEL_ID}.json" ]; then
    log "Creating cloudflared credentials file. Please paste your tunnel credentials JSON content when prompted."
    read -p "Paste your tunnel credentials JSON here and press Enter: " TUNNEL_CREDENTIALS
    echo "$TUNNEL_CREDENTIALS" | sudo tee "/etc/cloudflared/${CLOUDFLARED_TUNNEL_ID}.json" > /dev/null || error_exit "Failed to write tunnel credentials."
  fi

  log "cloudflared configuration created."
}

generate_client_configs() {
  log "Generating client configurations:"
  echo "--- VLESS Configuration ---"
  echo "Protocol: vless"
  echo "Address: vless.${CLOUDFLARED_DOMAIN}"
  echo "Port: 443"
  echo "UUID: $VLESS_UUID"
  echo "Flow: xtls-rprx-vision"
  echo "TLS: true"
  echo "Reality: true"
  # Note: You need to get the public key and short ID from the sing-box log or config after it runs.
  echo "Public Key: Find in sing-box log/config"
  echo "Short ID: Find in sing-box log/config"
  echo ""

  echo "--- VMESS Configuration ---"
  echo "Protocol: vmess"
  echo "Address: vmess.${CLOUDFLARED_DOMAIN}"
  echo "Port: 443"
  echo "UUID: $VMESS_UUID"
  echo "TLS: true"
  echo ""

  echo "--- TROJAN Configuration ---"
  echo "Protocol: trojan"
  echo "Address: trojan.${CLOUDFLARED_DOMAIN}"
  echo "Port: 443"
  echo "Password: $TROJAN_PASSWORD"
  echo "TLS: true"
  echo "Reality: true"
  # Note: You need to get the public key and short ID from the sing-box log or config after it runs.
  echo "Public Key: Find in sing-box log/config"
  echo "Short ID: Find in sing-box log/config"
  echo ""
}

start_services() {
  log "Starting sing-box service..."
  sudo systemctl start sing-box || error_exit "Failed to start sing-box service."
  log "sing-box service started."

  log "Starting cloudflared service..."
  sudo systemctl start cloudflared || error_exit "Failed to start cloudflared service."
  log "cloudflared service started."
}

# --- Main Script ---

log "Starting VPS setup script..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  error_exit "Please run this script as root."
fi

# Install necessary packages
install_package "wget"
install_package "tar"
install_package "uuidgen"
install_package "openssl"

# Install and configure sing-box and cloudflared
install_singbox
install_cloudflared
configure_singbox
configure_cloudflared

# Start the services
start_services

# Generate client configurations
generate_client_configs

log "VPS setup script finished."
