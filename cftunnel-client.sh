#!/bin/bash

# 服务端的 API 地址
API_URL="https://mmm-uw-to-tunnel.wdqgn.eu.org/99394bc9-1f18-40bb-96b0-a7bfbc0444a9-create"

# 依赖检测
check_dependencies() {
    local deps=("curl" "jq")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "❌ 缺少必要依赖: ${missing[*]}"
        echo "请先安装依赖，例如: sudo apt update && sudo apt install -y ${missing[*]}"
        exit 1
    fi
}

check_dependencies

countdown() {
    local seconds=$1
    while [ $seconds -gt 0 ]; do
        echo -ne "⏳ 等待中... 剩余 $seconds 秒\r"
        sleep 1
        : $((seconds--))
    done
    echo -e "\n🚀 倒计时结束，正在重新尝试..."
}

echo "--- Cloudflared 隧道配置 (New API Version) ---"

while true; do
    echo "正在向服务端发送请求，申请创建隧道..."
    
    # 发送请求
    response=$(curl -s -w "\n%{http_code}" "$API_URL")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    # 1. 处理请求频繁 (429)
    if [ "$http_code" == "429" ]; then
        echo "❌ 请求过于频繁 (HTTP 429)"
        read -p "是否等待 60 秒后重试？(y/n): " choice < /dev/tty
        [[ "$choice" =~ ^[yY]$ ]] && { countdown 60; continue; } || { echo "⏭️ 已跳过"; exit 0; }
    fi

    # 2. 处理成功 (200)
    if [ "$http_code" == "200" ]; then
        domain_name=$(echo "$body" | jq -r '.domain_name')
        domain_name_api=$(echo "$body" | jq -r '.domain_name_api')
        tunnel_id=$(echo "$body" | jq -r '.TunnelID')
        
        if [ "$tunnel_id" == "null" ]; then
            echo "❌ 无法解析 TunnelID，请检查 API 返回格式"
            exit 1
        fi

        echo "✅ 隧道创建成功！"
        echo "域名: $domain_name"
        echo "API 域名: $domain_name_api"

        # 配置文件路径
        CONFIG_DIR="/etc/cloudflared"
        mkdir -p "$CONFIG_DIR"
        echo "$body" | jq '{AccountTag, TunnelID, TunnelSecret, Endpoint}' > "$CONFIG_DIR/$tunnel_id.json"
        # 生成 config.yml
        cat <<EOF > "$CONFIG_DIR/config.yml"
tunnel: $tunnel_id
credentials-file: $CONFIG_DIR/$tunnel_id.json
protocol: quic

ingress:
  - hostname: $domain_name
    service: http://127.0.0.1:54999
  - hostname: $domain_name_api
    service: http://127.0.0.1:9090
  - service: http_status:404
EOF

        echo "----------------------------------------"
        echo "🎉 配置完成！"
        echo "配置文件: $CONFIG_DIR/config.yml"
        echo "启动命令: cloudflared tunnel run"
        
        cat > /tmp/tunnel.env <<EOF
domain_name=$domain_name
domain_name_api=$domain_name_api
tunnel_id=$tunnel_id
EOF
        break
    fi

    echo "❌ 请求失败 (HTTP $http_code)"
    read -p "是否重试？(y/n): " retry_choice < /dev/tty
    [[ "$retry_choice" =~ ^[yY]$ ]] && { sleep 2; continue; } || { echo "⏭️ 已跳过"; exit 0; }
done
