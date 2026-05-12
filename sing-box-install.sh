#!/usr/bin/env bash

set -o pipefail

CERTIFICATE_NAME="nauk.eu.cc"
CERT_BASE_URL="https://link.wdqgn.eu.org/nopasswd/cert"
SING_BOX_CONFIG="/etc/sing-box/config.json"
LINK_CONFIG="$HOME/link.yaml"
V2RAY_LINK="$HOME/v2ray-link.txt"

echo "欢迎使用 sing-box 一键安装脚本！"
echo "本脚本将安装 sing-box，并配置 hysteria2, reality, tuic, anytls"
echo "生成的客户端配置中，IP 地址将配置为当前服务器的出站 IP，如果出站和入站 IP 不同，请手动修改客户端配置文件"

if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本。"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "错误：请先安装 curl"
    exit 1
fi

port_in_use() {
    port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltnu "( sport = :$port )" | grep -q .
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnu 2>/dev/null | grep -Eq "[.:]$port[[:space:]]"
    else
        return 1
    fi
}

read_ports() {
    while true; do
        read -p "输入主入站端口，默认443: " select_port < /dev/tty
        select_port=${select_port:-443}

        if ! [[ "$select_port" =~ ^[0-9]+$ ]] || [ "$select_port" -lt 1 ] || [ "$select_port" -gt 65534 ]; then
            echo "错误：请输入有效的端口号数字 (1-65534)。"
            continue
        fi

        if [ "$select_port" -eq 443 ]; then
            select_port_1=2053
        else
            select_port_1=$((select_port + 1))
        fi

        if port_in_use "$select_port" || port_in_use "$select_port_1"; then
            if port_in_use "$select_port"; then
                echo "错误：端口 $select_port 已被占用，请重新输入。"
            else
                echo "错误：自动选择的端口 $select_port_1 已被占用，请重新输入主端口。"
            fi
            continue
        fi

        echo "主端口: $select_port"
        echo "TUIC/AnyTLS 端口: $select_port_1"
        break
    done
}

valid_ip() {
    ip="$1"
    case "$ip" in
        *:*)
            [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
            ;;
        *)
            [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
            old_ifs="$IFS"
            IFS=.
            set -- $ip
            IFS="$old_ifs"
            [ "$((10#$1))" -le 255 ] && [ "$((10#$2))" -le 255 ] && [ "$((10#$3))" -le 255 ] && [ "$((10#$4))" -le 255 ]
            ;;
    esac
}

url_encode() {
    printf '%s' "$1" | sed \
        -e 's/%/%25/g' \
        -e 's/ /%20/g' \
        -e 's/#/%23/g' \
        -e 's/|/%7C/g' \
        -e 's/,/%2C/g' \
        -e 's/&/%26/g' \
        -e 's/?/%3F/g' \
        -e 's/+/%2B/g' \
        -e 's/\//%2F/g' \
        -e 's/:/%3A/g' \
        -e 's/=/%3D/g'
}

format_link_host() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

detect_ip() {
    read -p "使用 IPv6 输入 6，默认 IPv4: " ip_type_choice < /dev/tty
    ip_type_choice=${ip_type_choice:-4}

    while true; do
        trace_content=$(curl -"${ip_type_choice}" -fsS --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
        ip_address=$(printf '%s\n' "$trace_content" | sed -nE 's/^ip=(.*)$/\1/p')

        if ! valid_ip "$ip_address"; then
            echo "获取到的 IP 不合法：$ip_address"
            read -p "y 重试，e 手动输入，其他退出: " retry < /dev/tty
            if [[ "$retry" =~ ^[yY]$ ]]; then
                continue
            elif [[ "$retry" =~ ^[eE]$ ]]; then
                read -p "输入 IP 地址: " ip_address < /dev/tty
                valid_ip "$ip_address" || {
                    echo "错误：IP 地址格式不合法。"
                    exit 1
                }
            else
                exit 1
            fi
        fi

        country_code=$(printf '%s\n' "$trace_content" | sed -nE 's/^loc=(.*)$/\1/p')
        colo_code=$(printf '%s\n' "$trace_content" | sed -nE 's/^colo=(.*)$/\1/p')
        country_code=${country_code:-XX}
        colo_code=${colo_code:-CF}

        echo "检测到的 IP 地址：$ip_address"

        if command -v python3 >/dev/null 2>&1; then
            flag=$(python3 -c "print(''.join(chr(127397 + ord(c)) for c in '$country_code'))" 2>/dev/null || echo "$country_code")
        else
            flag="$country_code"
        fi

        echo "检测到的地理位置：$flag $country_code ($colo_code)"

        proxy_name="${flag} ${colo_code} CF"
        HY_proxy_name=${proxy_name/CF/HY}
        RE_proxy_name=${proxy_name/CF/RE}
        TU_proxy_name=${proxy_name/CF/TU}
        AN_proxy_name=${proxy_name/CF/AN}
        break
    done
}

install_sing_box() {
    if command -v sing-box >/dev/null 2>&1; then
        echo "--------------------------------"
        echo "检测到 sing-box 已安装，跳过安装步骤。"
        sing-box version
        echo "--------------------------------"
        return
    fi

    echo "未检测到 sing-box，正在开始安装..."
    curl -fsSL https://sing-box.app/install.sh | sh
}

download_certificates() {
    mkdir -p /etc/sing-box/cert
    curl -fsSL -o "/etc/sing-box/cert/${CERTIFICATE_NAME}.crt" "${CERT_BASE_URL}/${CERTIFICATE_NAME}.crt"
    curl -fsSL -o "/etc/sing-box/cert/${CERTIFICATE_NAME}.key" "${CERT_BASE_URL}/${CERTIFICATE_NAME}.key"
}

generate_keys() {
    shortId=$(sing-box generate rand 8 --hex)
    output=$(sing-box generate reality-keypair)
    private_key=$(echo "$output" | sed -nE 's/^PrivateKey:[[:space:]]*(.*)$/\1/p')
    public_key=$(echo "$output" | sed -nE 's/^PublicKey:[[:space:]]*(.*)$/\1/p')
    uuid=$(cat /proc/sys/kernel/random/uuid)

    output_ech=$(sing-box generate ech-keypair cloudflare-ech.com)
    config_ech=$(echo "$output_ech" | sed -n '/BEGIN ECH CONFIGS/,/END ECH CONFIGS/p' | sed '/ECH CONFIGS/d' | tr -d '\n\r')
    key_ech=$(echo "$output_ech" | sed -n '/BEGIN ECH KEYS/,/END ECH KEYS/p')
    echo "$key_ech" > /etc/sing-box/cert/ech.pem
}

write_sing_box_config() {
    cat > "$SING_BOX_CONFIG" <<EOF
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
        "certificate_path": "/etc/sing-box/cert/$CERTIFICATE_NAME.crt",
        "key_path": "/etc/sing-box/cert/$CERTIFICATE_NAME.key",
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
        "certificate_path": "/etc/sing-box/cert/$CERTIFICATE_NAME.crt",
        "key_path": "/etc/sing-box/cert/$CERTIFICATE_NAME.key",
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
        "server_name": "www.cloudflare.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.cloudflare.com",
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
        "certificate_path": "/etc/sing-box/cert/$CERTIFICATE_NAME.crt",
        "key_path": "/etc/sing-box/cert/$CERTIFICATE_NAME.key",
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
}

write_client_configs() {
    current_time=$(TZ=UTC-8 date +"%Y%m%d-%H%M")

    cat > "$LINK_CONFIG" <<EOF
- name: ${TU_proxy_name}|${current_time}
  server: "$ip_address"
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
  sni: "${CERTIFICATE_NAME}"
  ech-opts: {enable: true, config: $config_ech}
- name: ${AN_proxy_name}|${current_time}
  type: anytls
  server: "$ip_address"
  port: $select_port_1
  password: $uuid
  client-fingerprint: chrome
  tls: true
  ech-opts: {enable: true, config: $config_ech}
  idle-session-check-interval: 30
  idle-session-timeout: 30
  min-idle-session: 0
  sni: "${CERTIFICATE_NAME}"
  alpn: [h2, http/1.1]
- name: ${HY_proxy_name}|${current_time}
  type: hysteria2
  server: "$ip_address"
  port: $select_port
  password: $uuid
  sni: "${CERTIFICATE_NAME}"
  alpn: [h3]
  ech-opts: {enable: true, config: $config_ech}
  tls: true
- name: ${RE_proxy_name}|${current_time}
  type: vless
  server: "$ip_address"
  port: $select_port
  uuid: $uuid
  client-fingerprint: chrome
  network: tcp
  tls: true
  flow: xtls-rprx-vision
  servername: "www.cloudflare.com"
  reality-opts:
    public-key: $public_key
    short-id: $shortId
EOF

    link_host=$(format_link_host "$ip_address")
    ech_link=$(url_encode "$config_ech")
    tu_name=$(url_encode "${TU_proxy_name}|${current_time}")
    an_name=$(url_encode "${AN_proxy_name}|${current_time}")
    hy_name=$(url_encode "${HY_proxy_name}|${current_time}")
    re_name=$(url_encode "${RE_proxy_name}|${current_time}")

    cat > "$V2RAY_LINK" <<EOF
tuic://${uuid}:${uuid}@${link_host}:${select_port_1}?sni=${CERTIFICATE_NAME}&alpn=h3&congestion_control=bbr&udp_relay_mode=native&ech=${ech_link}#${tu_name}
anytls://${uuid}@${link_host}:${select_port_1}?security=tls&sni=${CERTIFICATE_NAME}&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=${ech_link}#${an_name}
hysteria2://${uuid}@${link_host}:${select_port}?security=tls&sni=${CERTIFICATE_NAME}&alpn=h3&ech=${ech_link}#${hy_name}
vless://${uuid}@${link_host}:${select_port}?encryption=none&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=${public_key}&sid=${shortId}&spx=%2F&type=tcp&flow=xtls-rprx-vision#${re_name}
EOF
}

setup_certificate_cron() {
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "${CERT_BASE_URL}/${CERTIFICATE_NAME}" || true
        echo "0 0 * * 0 curl -fsSL -o /etc/sing-box/cert/${CERTIFICATE_NAME}.crt ${CERT_BASE_URL}/${CERTIFICATE_NAME}.crt"
        echo "0 0 * * 0 curl -fsSL -o /etc/sing-box/cert/${CERTIFICATE_NAME}.key ${CERT_BASE_URL}/${CERTIFICATE_NAME}.key") | crontab -
        echo "已创建证书更新定时任务。"
    else
        echo "未检测到 crontab，跳过定时任务创建。可手动执行以下命令更新证书："
        echo "curl -fsSL -o /etc/sing-box/cert/${CERTIFICATE_NAME}.crt ${CERT_BASE_URL}/${CERTIFICATE_NAME}.crt"
        echo "curl -fsSL -o /etc/sing-box/cert/${CERTIFICATE_NAME}.key ${CERT_BASE_URL}/${CERTIFICATE_NAME}.key"
    fi
}

restart_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now sing-box
        systemctl status sing-box --no-pager
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        rc-update add sing-box default
        rc-service sing-box restart
    else
        echo "未找到 systemctl 或 OpenRC，请手动启动 sing-box。"
    fi
}

read_ports
detect_ip
install_sing_box
download_certificates
generate_keys
write_sing_box_config
write_client_configs
setup_certificate_cron
restart_service

cat "$LINK_CONFIG"
cat "$V2RAY_LINK"
echo "客户端分享链接已生成：$V2RAY_LINK"
