#!/usr/bin/env bash
echo "欢迎使用 sing-box 一键安装脚本！"
echo "本脚本将安装 sing-box，并配置 hysteria,reality,tuic,anytls"
echo "生成的客户端配置中，ip地址将配置为当前服务器的出站IP，如果出站和入站IP不同，请手动修改客户端配置文件"
read -p "使用IPv6输入y,默认IPv4: " ip_type_choice < /dev/tty
while true; do
    read -p "输入主入站端口,默认443: " select_port < /dev/tty
    select_port=${select_port:-443}
    if [[ "$select_port" =~ ^[0-9]+$ ]] && [ "$select_port" -ge 1 ] && [ "$select_port" -le 65535 ]; then
        if ss -H -ltnu "( sport = :$select_port )" | grep -q .; then
            echo "错误：端口 $select_port 已被占用，请重新输入。"
            continue
        fi
        break
    fi
    echo "错误：请输入有效的端口号数字 (1-65535)。"
done
while true; do
    read -p "输入另外一个入站端口,默认2053): " select_port_1 < /dev/tty
    select_port_1=${select_port_1:-2053}
    if [[ "$select_port_1" =~ ^[0-9]+$ ]] && [ "$select_port_1" -ge 1 ] && [ "$select_port_1" -le 65535 ]; then
        if ss -H -ltnu "( sport = :$select_port_1 )" | grep -q .; then
            echo "错误：端口 $select_port_1 已被占用，请重新输入。"
            continue
        fi
        break
    fi
    echo "错误：请输入有效的端口号数字 (1-65535)。"
done
PKGS="curl wget jq cronie  python3"
APT_PKGS="curl wget jq cron python3"
APK_PKGS="curl wget jq dcron python3"
# 安装依赖
if command -v apt >/dev/null 2>&1; then
     apt update
     apt install -y $APT_PKGS
elif command -v dnf >/dev/null 2>&1; then
     dnf install -y $PKGS
elif command -v yum >/dev/null 2>&1; then
     yum install -y $PKGS
elif command -v pacman >/dev/null 2>&1; then
     pacman -Sy --noconfirm $PKGS
elif command -v zypper >/dev/null 2>&1; then
     zypper install -y $PKGS
elif command -v apk >/dev/null 2>&1; then
     apk add $APK_PKGS
else
    echo "不支持的包管理器"
    exit 1
fi

if [[ "$ip_type_choice" =~ ^[yY]$ ]]; then
    ip_type_choice=6
    ip_regex='^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$'  # 简单IPv6
else
    ip_type_choice=4
    ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
fi

while true; do
    trace_content=$(curl -${ip_type_choice} -s --max-time 5 https://cloudflare.com/cdn-cgi/trace)
    ip_address=$(echo "$trace_content" | grep '^ip=' | cut -d= -f2)
    if [[ ! "$ip_address" =~ $ip_regex ]]; then
        echo "获取到的IP不合法：$ip_address"
        read -p " y 重试, e 手动输入,其他退出: " retry < /dev/tty
        if [[ "$retry" =~ ^[yY]$ ]]; then
            continue
        elif [[ "$retry" =~ ^[eE]$ ]]; then
            read -p "输入IP地址: " ip_address < /dev/tty
        else
            exit 1
        fi
    fi
    countryCode=$(echo "$trace_content" | grep '^loc=' | cut -d= -f2)
    colo_code=$(echo "$trace_content" | grep '^colo=' | cut -d= -f2)
    echo "检测到的IP地址：$ip_address"
    flag=$(python3 -c "print(''.join(chr(127397 + ord(c)) for c in '$countryCode'))" 2>/dev/null || echo "🌐")
    echo "检测到的地理位置：$flag $countryCode ($colo_code)"
    proxy_name="${flag}${colo_code} CF"
    HY_proxy_name=${proxy_name/CF/HY}
    RE_proxy_name=${proxy_name/CF/RE}
    TU_proxy_name=${proxy_name/CF/TU}
    AN_proxy_name=${proxy_name/CF/AN}
    break
done

current_time=$(TZ=UTC-8 date +"%Y%m%d-%H%M")
Certificate_name="nnn.uw.to"

# 检查 sing-box 是否在系统路径中
if command -v sing-box >/dev/null 2>&1; then
    echo "--------------------------------"
    echo "检测到 sing-box 已安装，跳过安装步骤。"
    sing-box version
    echo "--------------------------------"
else
    echo "未检测到 sing-box，正在开始安装..."
    curl -fsSL https://link.wdqgn.eu.org/nopasswd/pkg/sing-box-pkg.sh | sh
fi

# 证书
mkdir -p /etc/sing-box/cert
wget -O /etc/sing-box/cert/$Certificate_name.crt "https://link.wdqgn.eu.org/nopasswd/cert/$Certificate_name.crt"
wget -O /etc/sing-box/cert/$Certificate_name.key "https://link.wdqgn.eu.org/nopasswd/cert/$Certificate_name.key"

# 生成密钥
shortId=$(sing-box generate rand 8 --hex)
output=$(sing-box generate reality-keypair)
private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
uuid=$(cat /proc/sys/kernel/random/uuid)

output_ech=$(sing-box generate ech-keypair cloudflare-ech.com)
config_ech=$(echo "$output_ech" | sed -n '/BEGIN ECH CONFIGS/,/END ECH CONFIGS/p' | grep -v "ECH CONFIGS")
key_ech=$(echo "$output_ech" | sed -n '/BEGIN ECH KEYS/,/END ECH KEYS/p')
echo "$key_ech" | sudo tee /etc/sing-box/cert/ech.pem > /dev/null


cat > /etc/sing-box/config.json <<EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $select_port_1,
      "users": [
        {
          "name": "$uuid",
          "uuid": "$uuid",
          "password": "$uuid"
        }
      ],
      "congestion_control": "cubic",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert/$Certificate_name.crt",
        "key_path": "/etc/sing-box/cert/$Certificate_name.key",
        "ech": {
          "enabled": true,
          "key_path": "/etc/sing-box/cert/ech.pem"
        }
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $select_port_1,
      "users": [
        {
          "name": "$uuid",
          "password": "$uuid"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "certificate_path": "/etc/sing-box/cert/$Certificate_name.crt",
        "key_path": "/etc/sing-box/cert/$Certificate_name.key",
        "ech": {
          "enabled": true,
          "key_path": "/etc/sing-box/cert/ech.pem"
        }
      }
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $select_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [
            "$shortId"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $select_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/cert/$Certificate_name.crt",
        "key_path": "/etc/sing-box/cert/$Certificate_name.key",
        "ech": {
          "enabled": true,
          "key_path": "/etc/sing-box/cert/ech.pem"
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

cat > ~/link.yaml <<EOF
- name: ${TU_proxy_name}|${current_time}
  server: $ip_address
  port: $select_port_1
  type: tuic
  uuid: $uuid
  password: $uuid
  alpn: [h3]
  reduce-rtt: true
  request-timeout: 8000
  udp-relay-mode: native
  congestion-controller: bbr
  max-udp-relay-packet-size: 1500
  fast-open: true
  max-open-streams: 20
  tls: true
  sni: ${Certificate_name}
  ech-opts: {enable: true, config: $config_ech}
- name: ${AN_proxy_name}|${current_time}
  type: anytls
  server: $ip_address
  port: $select_port_1
  password: $uuid
  tls: true
  ech-opts: {enable: true, config: $config_ech}
  idle-session-check-interval: 30
  idle-session-timeout: 30
  min-idle-session: 0
  sni: ${Certificate_name}
  alpn: [h2, http/1.1]
- name: ${HY_proxy_name}|${current_time}
  type: hysteria2
  server: $ip_address
  port: $select_port
  password: $uuid
  sni: ${Certificate_name}
  alpn: [ h3 ]
  ech-opts: {enable: true, config: $config_ech}
  tls: true
- name: ${RE_proxy_name}|${current_time}
  type: vless
  server: $ip_address
  port: $select_port
  uuid: $uuid
  network: tcp
  tls: true
  flow: xtls-rprx-vision
  servername: www.microsoft.com
  reality-opts:
    public-key: $public_key
    short-id: $shortId
EOF

if command -v crontab &>/dev/null; then
(crontab -l 2>/dev/null; \
echo "0 0 * * 0 wget -O /etc/sing-box/cert/$Certificate_name.crt https://link.wdqgn.eu.org/nopasswd/cert/$Certificate_name.crt"; \
echo "0 0 * * 0 wget -O /etc/sing-box/cert/$Certificate_name.key https://link.wdqgn.eu.org/nopasswd/cert/$Certificate_name.key") | crontab -
else
    echo "未检测到 crontab，请手动设置定时任务更新证书"
    echo "wget -O /etc/sing-box/cert/$Certificate_name.crt https://link.wdqgn.eu.org/nopasswd/cert/$Certificate_name.crt"
    echo "wget -O /etc/sing-box/cert/$Certificate_name.key https://link.wdqgn.eu.org/nopasswd/cert/$Certificate_name.key"
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now sing-box
    systemctl status sing-box --no-pager
else
    rc-update add sing-box default
    rc-service sing-box restart
fi
cat ~/link.yaml