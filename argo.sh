#!/bin/bash

set -o pipefail

LISTEN_HOST="127.0.0.1"
LISTEN_PORT="54999"
PROXY_NAME="argo-vless"
CONFIG_FILE="/etc/mihomo/config.yaml"
ARGO_CONFIG="$HOME/argo.yaml"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：请使用 root 权限运行此脚本。"
        exit 1
    fi
}

require_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "错误：请先安装 curl"
        exit 1
    fi
}

get_current_uuid() {
    sed -nE 's/^[[:space:]]*uuid:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' "$CONFIG_FILE" | head -n 1
}

get_current_client_encryption() {
    sed -nE 's/^#[[:space:]]*client-encryption:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' "$CONFIG_FILE" | head -n 1
}

url_encode_encryption() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' \
        -e 's/:/%3A/g' \
        -e 's/+/%2B/g' \
        -e 's/\//%2F/g' \
        -e 's/=/%3D/g'
}

generate_vless_encryption() {
    vless_x25519=$(mihomo generate vless-x25519)
    server_decryption=$(echo "$vless_x25519" | sed -nE '/\[Server\]/s/.*"([^"]+)".*/\1/p' | head -n 1)
    client_encryption=$(echo "$vless_x25519" | sed -nE '/\[Client\]/s/.*"([^"]+)".*/\1/p' | head -n 1)

    if [ -z "$server_decryption" ] || [ -z "$client_encryption" ]; then
        echo "错误：mihomo generate vless-x25519 未能生成有效的 VLESS 加密参数。"
        exit 1
    fi
}

start_tunnel() {
    pkill -f "cloudflared tunnel --url http://${LISTEN_HOST}:${LISTEN_PORT}" 2>/dev/null
    sleep 1

    tmp_log=$(mktemp)
    cloudflared tunnel --url "http://${LISTEN_HOST}:${LISTEN_PORT}" >> "$tmp_log" 2>&1 &
    cloudflared_pid=$!

    echo "cloudflared PID: $cloudflared_pid，等待分配域名..."

    domain_name=""
    timeout=20
    while [ "$timeout" -gt 0 ]; do
        domain_name=$(sed -nE 's/.*https:\/\/([[:alnum:].-]+trycloudflare\.com).*/\1/p' "$tmp_log" | head -n 1)
        if [ -n "$domain_name" ]; then
            break
        fi
        sleep 1
        timeout=$((timeout - 1))
    done

    rm -f "$tmp_log"

    if [ -z "$domain_name" ]; then
        echo "错误：未能获取域名，请运行 argo.sh -res 重新创建隧道"
        exit 1
    fi
}

write_client_config() {
    ws_path="/${uuid}-vl"
    uri_path="%2F${uuid}-vl"
    uri_client_encryption=$(url_encode_encryption "$client_encryption")
    vless_link="vless://${uuid}@${domain_name}:443?encryption=${uri_client_encryption}&security=tls&sni=${domain_name}&type=ws&host=${domain_name}&path=${uri_path}#${PROXY_NAME}"

    cat > "$ARGO_CONFIG" <<EOF
# Clash/Mihomo 配置
proxies:
  - name: "${PROXY_NAME}"
    type: vless
    server: "${domain_name}"
    port: 443
    uuid: "${uuid}"
    network: ws
    tls: true
    servername: "${domain_name}"
    client-fingerprint: chrome
    ws-opts:
      path: "${ws_path}"
      headers:
        Host: "${domain_name}"
    encryption: "${client_encryption}"

# V2Ray/v2rayN/v2rayNG 链接
# ${vless_link}
EOF
}

restart_tunnel() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误：未找到 $CONFIG_FILE，请先运行 argo.sh 初始化。"
        exit 1
    fi

    uuid=$(get_current_uuid)
    if [ -z "$uuid" ]; then
        echo "错误：未能从 $CONFIG_FILE 读取 uuid，请先运行 argo.sh 重新生成配置。"
        exit 1
    fi

    client_encryption=$(get_current_client_encryption)
    if [ -z "$client_encryption" ]; then
        echo "错误：未能从 $CONFIG_FILE 读取客户端加密参数，请先运行 argo.sh 重新生成配置。"
        exit 1
    fi

    start_tunnel
    write_client_config

    cat "$ARGO_CONFIG"
    echo "生成的配置位于 $ARGO_CONFIG"
    echo "脚本执行完成，cloudflared 隧道已在后台运行，域名为 $domain_name"
    echo "临时隧道仅供测试使用，如需稳定连接，请使用个人账户创建隧道至 http://${LISTEN_HOST}:${LISTEN_PORT}"
    echo "隧道过期，运行 ./argo.sh -res 重新创建隧道"
}

install_cloudflared() {
    echo "正在安装 cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) BINARY_ARCH="amd64" ;;
        aarch64|arm64) BINARY_ARCH="arm64" ;;
        armv7l) BINARY_ARCH="armhf" ;;
        *) echo "暂不支持的架构: $ARCH"; exit 1 ;;
    esac

    echo "检测到系统架构: $ARCH -> 匹配二进制: $BINARY_ARCH"
    echo "正在获取最新版本信息..."
    LATEST_TAG=$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)

    if [ -z "$LATEST_TAG" ]; then
        echo "无法获取最新版本，请检查网络连接。"
        exit 1
    fi

    URL="https://github.com/cloudflare/cloudflared/releases/download/${LATEST_TAG}/cloudflared-linux-${BINARY_ARCH}"
    echo "最新版本: $LATEST_TAG"
    echo "正在下载: $URL"
    curl -fL --progress-bar -o /usr/local/bin/cloudflared "$URL"
    chmod +x /usr/local/bin/cloudflared
    cloudflared --version
    echo "cloudflared 安装完成！"
}

ensure_cloudflared() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "未检测到 cloudflared，正在开始安装..."
        install_cloudflared
    fi
}

ensure_mihomo() {
    if ! command -v mihomo >/dev/null 2>&1; then
        echo "未检测到 mihomo，正在安装..."
        curl -fsSL https://raw.githubusercontent.com/niylin/mnc-install/master/pkg/mihomo-pkg.sh | bash
    fi
}

restart_mihomo() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mihomo
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service mihomo restart
    else
        echo "错误：未找到 systemctl 或 rc-service，无法重启 mihomo。"
        exit 1
    fi
}

write_mihomo_config() {
    mkdir -p /etc/mihomo
    cat > "$CONFIG_FILE" <<EOF
# client-encryption: "${client_encryption}"
ipv6: true
log-level: info
mode: rule
listeners:
  - name: vless-ws-in
    type: vless
    listen: ${LISTEN_HOST}
    port: ${LISTEN_PORT}
    users:
      - username: 1
        uuid: ${uuid}
    decryption: "${server_decryption}"
    ws-path: /${uuid}-vl
rules:
  - MATCH,DIRECT
EOF
}

main() {
    echo "适用没有入站的小鸡"
    require_root
    require_curl

    case "${1:-}" in
        -ins)
            install_cloudflared
            exit 0
            ;;
        -res)
            ensure_cloudflared
            restart_tunnel
            exit 0
            ;;
    esac

    uuid=$(cat /proc/sys/kernel/random/uuid)

    ensure_mihomo
    generate_vless_encryption
    write_mihomo_config
    restart_mihomo
    ensure_cloudflared
    start_tunnel
    write_client_config

    echo "分配域名: $domain_name"
    echo "cloudflared 隧道已在后台运行，PID: $cloudflared_pid"
    cat "$ARGO_CONFIG"
    echo "生成的配置位于 $ARGO_CONFIG"
    echo "临时隧道仅供测试使用，如需稳定连接，请使用个人账户创建隧道至 http://${LISTEN_HOST}:${LISTEN_PORT}"
    echo "隧道过期，运行 argo.sh -res 重新创建隧道"
}

main "$@"
