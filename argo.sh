#!/bin/bash
echo "适用没有入站的小鸡"

if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本。"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "错误：请先安装 curl"
    exit 1
fi

uuid=$(cat /proc/sys/kernel/random/uuid)

if ! command -v cloudflared &>/dev/null; then
    echo "未检测到 cloudflared，正在安装..."
    curl -fsSL https://link.wdqgn.eu.org/nopasswd/pkg/cloudflared-pkg.sh | bash
fi

if ! command -v mihomo &>/dev/null; then
    echo "未检测到 mihomo，正在安装..."
    curl -fsSL https://link.wdqgn.eu.org/nopasswd/pkg/mihomo-pkg.sh | bash
fi

pkill -f 'cloudflared tunnel --url http://127.0.0.1:54999' 2>/dev/null
sleep 1

vless_x25519=$(mihomo generate vless-x25519)
server_decryption=$(echo "$vless_x25519" | awk -F'"' '/\[Server\]/ {print $2}')
client_encryption=$(echo "$vless_x25519" | awk -F'"' '/\[Client\]/ {print $2}')

mkdir -p /etc/mihomo
cat > /etc/mihomo/config.yaml <<EOF
ipv6: true
log-level: info
mode: rule
listeners:
  - name: vless-ws-in
    type: vless
    listen: 127.0.0.1
    port: 54999
    users:
      - username: 1
        uuid: $uuid
        flow: xtls-rprx-vision
    decryption: $server_decryption
    ws-path: /$uuid-vl
rules:
  - MATCH,DIRECT
EOF


pkill -f 'cloudflared tunnel --url http://127.0.0.1:54999' 2>/dev/null
sleep 1

tmp_log=$(mktemp)
rm -f "$tmp_log"

/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:54999 >> "$tmp_log" 2>&1 &
cloudflared_pid=$!

echo "cloudflared PID: $cloudflared_pid, 等待分配域名..."

domain_name=""
timeout=15  
while [ $timeout -gt 0 ]; do
    if grep -q 'https://.*trycloudflare\.com' "$tmp_log"; then
        domain_name=$(grep -oP 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$tmp_log" | head -1)
        domain_name="${domain_name#https://}"
        break
    fi
    sleep 1
    timeout=$((timeout-1))
done

rm -f "$tmp_log"

if [ -z "$domain_name" ]; then
    echo "错误：未能获取域名，请重新创建隧道"
    exit 1
fi
if command -v systemctl &>/dev/null; then
    systemctl restart mihomo
else
    rc-service mihomo restart
fi
echo "分配域名: $domain_name"
echo "cloudflared 隧道已在后台运行，PID: $cloudflared_pid"
cat > $HOME/argo.yaml <<EOF
# clash 配置
proxies:
- {name: "argo-vless", type: vless, server: $domain_name, port: 443, uuid: $uuid, client-fingerprint: chrome, network: ws, tls: true, flow: xtls-rprx-vision, alpn: ["h2","http/1.1"], ws-opts: {path: /$uuid-vl, headers: {host: $domain_name}}, encryption: $client_encryption}

----------------------------------------------------------------------------
# snlink
vless://${uuid}@${domain_name}:443?encryption=${client_encryption}&security=tls&type=ws&host=${domain_name}&path=${ws_path}#argo-vless

EOF
cat $HOME/argo.yaml
echo "生成的配置位于 $HOME/argo.yaml"
echo "脚本执行完成，cloudflared 隧道已在后台运行，域名为 $domain_name"
echo "临时隧道仅供测试使用,如需稳定连接,请使用个人账户创建隧道至http://127.0.0.1:54999"