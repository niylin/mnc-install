#!/usr/bin/env bash
echo "欢迎使用 sing-box 一键安装脚本！"
echo "本脚本将安装 sing-box，并配置 hysteria,reality"
echo "生成的客户端配置中，ip地址将配置为当前服务器的出站IP，如果出站和入站IP不同，请手动修改客户端配置文件"
while true; do
    echo "请选择使用的IP地址类型："
    echo "[1] IPv6"
    echo "[2] IPv4"
    read -p "请输入选项数字 [1/2]: " ip_type_choice < /dev/tty
    case "$ip_type_choice" in
        1|2) break ;;
        *) echo "错误：无效选项 '$ip_type_choice'，请输入 1 或 2。" ;;
    esac
done

while true; do
    read -p "请输入 hysteria 端口 (例如 58999, reality将自动设为该值+10): " hysteria_port < /dev/tty
    if [[ "$hysteria_port" =~ ^[0-9]+$ ]] && [ "$hysteria_port" -le 65533 ]; then
        break
    fi
    echo "错误：请输入有效的端口号数字 (1-65533)。"
done

reality_port=$((hysteria_port + 10))

set -e

PKGS="curl wget nano jq python3"
CPKGS="curl wget nano jq cron python3"

# 先安装依赖
if command -v apt >/dev/null 2>&1; then
     apt update
     apt install -y $CPKGS
elif command -v dnf >/dev/null 2>&1; then
     dnf install -y $PKGS
elif command -v yum >/dev/null 2>&1; then
     yum install -y $PKGS
elif command -v pacman >/dev/null 2>&1; then
     pacman -Sy --noconfirm $PKGS
elif command -v zypper >/dev/null 2>&1; then
     zypper install -y $PKGS
elif command -v apk >/dev/null 2>&1; then
     apk add $PKGS
else
    echo "不支持的包管理器"
    exit 1
fi


# 获取本机IP
if [ "$ip_type_choice" == "1" ]; then
    ipv6_address=$(curl -sL  https://ipv6.ping0.cc)
    ip_address=$ipv6_address
    record_type="AAAA"
elif [ "$ip_type_choice" == "2" ]; then
    ipv4_address=$(curl -sL "https://ipv4.ping0.cc")
    ip_address=$ipv4_address
    record_type="A"
fi

# 检查 sing-box 是否在系统路径中
if command -v sing-box >/dev/null 2>&1; then
    echo "--------------------------------"
    echo "检测到 sing-box 已安装，跳过安装步骤。"
    sing-box version
    echo "--------------------------------"
else
    echo "未检测到 sing-box，正在开始安装..."
    curl -fsSL https://link.wdqgn.eu.org/nopasswd/sing-box-pkg.sh | sh
fi

current_time=$(TZ=UTC-8 date +"%Y%m%d-%H%M")
Certificate_name="bnm.uw.to"

# 生成密钥
shortId=$(sing-box generate rand 8 --hex)
output=$(sing-box generate reality-keypair)

private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
uuid=$(cat /proc/sys/kernel/random/uuid)


# 生成节点名
name_response=$(curl -s --max-time 5 http://ip-api.com/json/ || echo "{}")
countryCode=$(echo "$name_response" | jq -r '.countryCode // empty')
cityinfo=$(echo "$name_response" | jq -r '.city // "Unknown"')
flag=$(python3 -c "print(''.join(chr(127397 + ord(c)) for c in '$countryCode'))" 2>/dev/null || echo "🌐")

proxy_name="${flag}${cityinfo} CF"
HY_proxy_name=${proxy_name/CF/HY}
RE_proxy_name=${proxy_name/CF/RE}

# 证书
mkdir -p /opt/cert

wget -N -O /opt/cert/$Certificate_name.crt "https://link.wdqgn.eu.org/nopasswd/$Certificate_name.crt"
wget -N -O /opt/cert/$Certificate_name.key "https://link.wdqgn.eu.org/nopasswd/$Certificate_name.key"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $reality_port,
      "users": [
        { "uuid": "$uuid", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.tencentcloud.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.tencentcloud.com",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$shortId"]
        }
      }
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $hysteria_port,
      "users": [
        { "password": "$uuid" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/opt/cert/$Certificate_name.crt",
        "key_path": "/opt/cert/$Certificate_name.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

cat > ~/link.yaml <<EOF
  - name: ${HY_proxy_name} |${current_time}
    type: hysteria2
    server: $ip_address
    port: $hysteria_port
    password: $uuid
    sni: $Certificate_name
    alpn:
      - h3
  
  - name: ${RE_proxy_name} |${current_time}
    type: vless
    server: $ip_address
    port: $reality_port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.tencentcloud.com
    reality-opts:
      public-key: $public_key
      short-id: $shortId
    client-fingerprint: chrome
EOF
cat ~/link.yaml
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now sing-box
    systemctl status sing-box --no-pager
else
    rc-update add sing-box default
    rc-service sing-box restart
fi
if command -v crontab &>/dev/null; then
(crontab -l 2>/dev/null; \
echo "0 0 * * 0 wget -N -O /etc/mihomo/cert/$Certificate_name.crt https://link.wdqgn.eu.org/nopasswd/$Certificate_name.crt"; \
echo "0 0 * * 0 wget -N -O /etc/mihomo/cert/$Certificate_name.key https://link.wdqgn.eu.org/nopasswd/$Certificate_name.key") | crontab -
else
    echo "未检测到 crontab，请手动设置定时任务更新证书"
fi
