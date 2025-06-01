sh
#!/bin/bash

# 设置变量
SINGBOX_VERSION="latest"  # 或者指定具体的版本号
CLOUDFLARED_VERSION="latest" # 或者指定具体的版本号
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config"
SINGBOX_CONFIG_DIR="$CONFIG_DIR/sing-box"
CLOUDFLARED_CONFIG_DIR="$CONFIG_DIR/cloudflared"
SYSTEMD_USER_DIR="$CONFIG_DIR/systemd/user"
LOG_FILE="$HOME/singbox_argo_setup.log"

# 生成随机端口 (10000-65535)
VLESS_PORT=$((RANDOM % 55536 + 10000))
VMESS_PORT=$((RANDOM % 55536 + 10000))
TROJAN_PORT=$((RANDOM % 55536 + 10000))

# 生成UUID
VLESS_UUID=$(uuidgen)
VMESS_UUID=$(uuidgen)
TROJAN_PASSWORD=$(uuidgen)

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $@" | tee -a "$LOG_FILE"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 安装依赖
install_dependencies() {
    log "正在安装依赖..."
    if command_exists apt; then
        sudo apt update
        sudo apt install -y curl uuid-runtime jq
    elif command_exists yum; then
        sudo yum install -y curl uuidgen jq
    elif command_exists dnf; then
        sudo dnf install -y curl uuidgen jq
    else
        log "错误：不支持的包管理器。请手动安装 curl, uuidgen, jq。"
        exit 1
    fi
    log "依赖安装完成。"
}

# 安装 sing-box
install_singbox() {
    log "正在安装 sing-box..."
    mkdir -p "$INSTALL_DIR" "$SINGBOX_CONFIG_DIR" "$SYSTEMD_USER_DIR"
    if [ "$SINGBOX_VERSION" = "latest" ]; then
        SINGBOX_DOWNLOAD_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.assets[] | select(.name | contains("linux-amd64")) | .browser_download_url')
    else
        SINGBOX_DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
    fi
    log "下载 sing-box: $SINGBOX_DOWNLOAD_URL"
    curl -L "$SINGBOX_DOWNLOAD_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1
    chmod +x "$INSTALL_DIR/sing-box"
    log "sing-box 安装完成。"
}

# 安装 cloudflared
install_cloudflared() {
    log "正在安装 cloudflared..."
    mkdir -p "$INSTALL_DIR" "$CLOUDFLARED_CONFIG_DIR"
    if command_exists apt; then
        curl -L https://pkg.cloudflare.com/cloudflare-argo-tunnel-release-latest.deb -o /tmp/cloudflare-argo-tunnel.deb
        sudo dpkg -i /tmp/cloudflare-argo-tunnel.deb
        rm /tmp/cloudflare-argo-tunnel.deb
    elif command_exists yum || command_exists dnf; then
        sudo rpm -ivh https://pkg.cloudflare.com/cloudflare-argo-tunnel-release-latest.rpm
    else
         if [ "$CLOUDFLARED_VERSION" = "latest" ]; then
            CLOUDFLARED_DOWNLOAD_URL=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | jq -r '.assets[] | select(.name | contains("linux-amd64")) | .browser_download_url')
        else
            CLOUDFLARED_DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64"
        fi
        log "下载 cloudflared: $CLOUDFLARED_DOWNLOAD_URL"
        curl -L "$CLOUDFLARED_DOWNLOAD_URL" -o "$INSTALL_DIR/cloudflared"
        chmod +x "$INSTALL_DIR/cloudflared"
    fi
    log "cloudflared 安装完成。"
}

# 配置 sing-box
configure_singbox() {
    log "正在配置 sing-box..."
    cat <<EOF > "$SINGBOX_CONFIG_DIR/config.json"
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $VLESS_PORT,
      "uuid": "$VLESS_UUID",
      "limit": 0,
      "clients": [],
      "decryption": "none",
      "allow_insecure": false
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": $VMESS_PORT,
      "uuid": "$VMESS_UUID",
      "limit": 0,
      "clients": [],
      "detour": ""
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "127.0.0.1",
      "listen_port": $TROJAN_PORT,
      "password": [
        "$TROJAN_PASSWORD"
      ],
      "limit": 0,
      "fallback": null,
      "fallback_port": 0,
      "fallback_detour": ""
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "vless",
        "inbound": "vless-in",
        "outbound": "direct"
      },
       {
        "protocol": "vmess",
        "inbound": "vmess-in",
        "outbound": "direct"
      },
       {
        "protocol": "trojan",
        "inbound": "trojan-in",
        "outbound": "direct"
      }
    ],
    "final": "direct"
  }
}
EOF
    log "sing-box 配置完成。"
}

# 配置 cloudflared
configure_cloudflared() {
    log "正在配置 cloudflared..."
    read -p "请输入你的 Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN
    mkdir -p "$CLOUDFLARED_CONFIG_DIR"
    cat <<EOF > "$CLOUDFLARED_CONFIG_DIR/config.yml"
tunnel: $(echo "$CF_TUNNEL_TOKEN" | cut -d'.' -f1)
credentials-file: $CLOUDFLARED_CONFIG_DIR/$(echo "$CF_TUNNEL_TOKEN" | cut -d'.' -f1).json
protocol: http2

ingress:
  - hostname: vless.YOUR_DOMAIN.COM  # 替换为你的域名
    service: http://127.0.0.1:$VLESS_PORT
  - hostname: vmess.YOUR_DOMAIN.COM  # 替换为你的域名
    service: http://127.0.0.1:$VMESS_PORT
  - hostname: trojan.YOUR_DOMAIN.COM  # 替换为你的域名
    service: http://127.0.0.1:$TROJAN_PORT
  - service: http_status:404
EOF
    log "cloudflared 配置完成。请手动替换 config.yml 中的 YOUR_DOMAIN.COM 为你的实际域名。"
}

# 配置 sing-box systemd user unit
configure_singbox_systemd_user_unit() {
    log "正在配置 sing-box systemd user unit..."
    mkdir -p "$SYSTEMD_USER_DIR"
    cat <<EOF > "$SYSTEMD_USER_DIR/sing-box.service"
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/sing-box run -c $SINGBOX_CONFIG_DIR/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable sing-box
    log "sing-box systemd user unit 配置完成。"
}

# 配置 cloudflared systemd user unit
configure_cloudflared_systemd_user_unit() {
    log "正在配置 cloudflared systemd user unit..."
    mkdir -p "$SYSTEMD_USER_DIR"
    cat <<EOF > "$SYSTEMD_USER_DIR/cloudflared.service"
[Unit]
Description=Cloudflared Tunnel
After=network.target

[Service]
ExecStart=$INSTALL_DIR/cloudflared tunnel --config $CLOUDFLARED_CONFIG_DIR/config.yml run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable cloudflared
    log "cloudflared systemd user unit 配置完成。"
}


# 生成客户端配置/链接
generate_client_configs() {
    log "正在生成客户端配置/链接..."
    echo "--- VLESS ---"
    echo "地址: YOUR_DOMAIN.COM"  # 替换为你的域名
    echo "端口: 443 (通过 Cloudflare)"
    echo "UUID: $VLESS_UUID"
    echo "传输协议: ws"
    echo "路径: /vless" # 需要在 Cloudflare Workers 或其他方式中配置路径转发
    echo "TLS: 是"
    echo "SNI: YOUR_DOMAIN.COM" # 替换为你的域名
    echo "指纹: 自动"
    echo "跳过证书验证: 否"
    echo "VLESS 链接 (需要手动添加路径和Host):"
    echo "vless://$VLESS_UUID@YOUR_DOMAIN.COM:443?encryption=none&security=tls&type=ws&host=YOUR_DOMAIN.COM&path=/vless#VLESS_Argo"

    echo ""
    echo "--- VMESS ---"
    echo "地址: YOUR_DOMAIN.COM"  # 替换为你的域名
    echo "端口: 443 (通过 Cloudflare)"
    echo "UUID: $VMESS_UUID"
    echo "传输协议: ws"
    echo "路径: /vmess" # 需要在 Cloudflare Workers 或其他方式中配置路径转发
    echo "TLS: 是"
    echo "SNI: YOUR_DOMAIN.COM" # 替换为你的域名
    echo "VMESS 链接 (需要手动添加路径和Host):"
    VMESS_CONFIG=$(cat <<EOF
{
  "v": "2",
  "ps": "VMESS_Argo",
  "add": "YOUR_DOMAIN.COM", # 替换为你的域名
  "port": "443",
  "id": "$VMESS_UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "YOUR_DOMAIN.COM", # 替换为你的域名
  "path": "/vmess",
  "tls": "tls",
  "sni": "YOUR_DOMAIN.COM" # 替换为你的域名
}
EOF
)
    echo "vmess://$(echo "$VMESS_CONFIG" | base64 -w 0)"

    echo ""
    echo "--- TROJAN ---"
    echo "地址: YOUR_DOMAIN.COM"  # 替换为你的域名
    echo "端口: 443 (通过 Cloudflare)"
    echo "密码: $TROJAN_PASSWORD"
    echo "传输协议: ws"
    echo "路径: /trojan" # 需要在 Cloudflare Workers 或其他方式中配置路径转发
    echo "TLS: 是"
    echo "SNI: YOUR_DOMAIN.COM" # 替换为你的域名
    echo "跳过证书验证: 否"
    echo "TROJAN 链接 (需要手动添加路径和Host):"
    echo "trojan://$TROJAN_PASSWORD@YOUR_DOMAIN.COM:443?security=tls&type=ws&host=YOUR_DOMAIN.COM&path=/trojan#TROJAN_Argo"

    log "客户端配置/链接生成完成。请手动替换 YOUR_DOMAIN.COM 为你的实际域名，并根据需要配置 Cloudflare Workers 或其他方式进行路径转发。"
}


# 主函数
main() {
    log "脚本开始执行..."

    install_dependencies
    install_singbox
    install_cloudflared
    configure_singbox
    configure_cloudflared
    configure_singbox_systemd_user_unit
    configure_cloudflared_systemd_user_unit

    log "启动 sing-box 和 cloudflared 服务..."
    systemctl --user start sing-box
    systemctl --user start cloudflared

    log "等待服务启动..."
    sleep 5

    systemctl --user status sing-box --no-pager
    systemctl --user status cloudflared --no-pager

    generate_client_configs

    log "脚本执行完毕。"
    echo "请检查上面的日志和客户端配置。"
    echo "日志文件位于: $LOG_FILE"
    echo "sing-box 配置文件位于: $SINGBOX_CONFIG_DIR/config.json"
    echo "cloudflared 配置文件位于: $CLOUDFLARED_CONFIG_DIR/config.yml"
    echo "sing-box systemd user unit 位于: $SYSTEMD_USER_DIR/sing-box.service"
    echo "cloudflared systemd user unit 位于: $SYSTEMD_USER_DIR/cloudflared.service"
    echo "请手动替换 config.yml 和客户端配置中的 YOUR_DOMAIN.COM 为你的实际域名，并在 Cloudflare Workers 或其他方式中配置路径转发。"
}

main
