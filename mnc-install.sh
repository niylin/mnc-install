#!/usr/bin/env bash

if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本。"
    exit 1
fi

remove_nginx_block() {
    local nginx_conf="/etc/nginx/nginx.conf"
    if [ -f "$nginx_conf" ]; then
        sed -i '/# BEGIN MIHOMO_NGINX_STREAM/,/# END MIHOMO_NGINX_STREAM/d' "$nginx_conf"
    fi
}

uninstall_all() {
    echo "开始清理 mihomo-nginx.sh 及关联脚本创建的内容..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop mihomo 2>/dev/null || true
        systemctl disable mihomo 2>/dev/null || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service mihomo stop 2>/dev/null || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del mihomo default 2>/dev/null || true
    fi

    rm -f /etc/systemd/system/mihomo.service
    rm -f /etc/init.d/mihomo
    rm -f /usr/local/bin/mihomo
    rm -rf /etc/mihomo
    rm -f /etc/nginx/conf.d/subscription.conf
    rm -f /opt/www/*.yaml
    rmdir /opt/www 2>/dev/null || true

    remove_nginx_block

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service nginx restart 2>/dev/null || true
    fi

    echo "清理完成。"
    exit 0
}

if [ "${1:-}" = "-uninstall" ]; then
    uninstall_all
fi

echo "脚本将安装 mihomo，并配置 hysteria,reality，anytls,vless-ws 四种协议的入站"
echo "建议在使用apt和apk包管理器的系统中运行,其他系统未经测试,包名不同可能导致安装依赖失败"
echo "生成的客户端配置中，ip地址将配置为当前服务器的出站IP，如果出站和入站IP不同，请手动修改客户端配置文件"
echo "大多数系统内存需求至少256mb,如配置过低请使用无nginx版本的安装脚本或更改为精简的alpine系统"

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
    read -rp "是否要配置 Warp 节点出站? (y/n) " warp_choice < /dev/tty
    case "$warp_choice" in
        y|Y) break ;;
        n|N) break ;;
        *) echo "错误：无效选项 '$warp_choice'，请输入 y 或 n。" ;;
    esac
done

while true; do
    read -p "请输入入站端口(例如 443,多协议共用,建议443,不会影响建站): " select_port < /dev/tty
    if [[ "$select_port" =~ ^[0-9]+$ ]] && [ "$select_port" -ge 1 ] && [ "$select_port" -le 65535 ]; then
        if ss -H -ltnu "( sport = :$select_port )" | grep -q .; then
            echo "错误：端口 $select_port 已被占用，请重新输入。"
            continue
        fi
        break
    fi
    echo "错误：请输入有效的端口号数字 (1-65535)。"
done
current_time=$(TZ=UTC-8 date +"%Y%m%d-%H%M%S")

mkdir -p /etc/mihomo/cert

while true; do
    echo "使用默认证书还是自定义证书？"
    echo "y 默认证书"
    echo "n 自定义证书"

    read -r -p "请输入选项 [y/n]: " cert_choice < /dev/tty

    case "$cert_choice" in
        y)
            Certificate_name="${current_time}.nnn.uw.to"
            CERT_NAME="nnn.uw.to"
            break
            ;;
        n)  
            while true; do
                read -r -p "请输入自定义证书域名: " Certificate_name < /dev/tty
                if [ -n "$Certificate_name" ]; then
                    break
                else
                    echo "域名不能为空"
                fi
            done
            CERT_NAME=$Certificate_name
            echo "请将证书放入："
            echo "/etc/mihomo/cert/$Certificate_name.crt"
            echo "/etc/mihomo/cert/$Certificate_name.key"
            break
            ;;
        *)
            echo "错误：请输入 y 或 n"
            ;;
    esac
done

# 依赖安装
APT_PKGS="curl wget nano jq cron python3 openssl nginx libnginx-mod-stream"
APK_PKGS="curl wget nano jq dcron python3 openssl nginx nginx-mod-stream"
ZYPPER_PKGS="curl wget nano jq cron python3 openssl nginx nginx-module-stream"
PKGS="curl wget nano jq cronie  python3 openssl nginx nginx-mod-stream"

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
     zypper install -y $ZYPPER_PKGS
elif command -v apk >/dev/null 2>&1; then
     apk add $APK_PKGS
else
    echo "不支持的包管理器"
    exit 1
fi

# 获取本机IP
ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
ipv6_regex='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'

if [ "$ip_type_choice" == "1" ]; then
    ip_address=$(curl -6 -sL --max-time 5 https://ip-api.wdqgn.eu.org | jq -r '.ip // empty')
    if [[ -z "$ip_address" || ! "$ip_address" =~ $ipv6_regex ]]; then
        echo "提示：未能自动获取到有效的 IPv6 地址。"
        until [[ "$ip_address" =~ $ipv6_regex ]]; do
            read -p "请输入服务器的 IPv6 地址: " ip_address < /dev/tty
            if [[ ! "$ip_address" =~ $ipv6_regex ]]; then
                echo "格式错误，请检查后再输入。"
            fi
        done
    fi

elif [ "$ip_type_choice" == "2" ]; then
    ip_address=$(curl -4 -sL --max-time 5 https://ip-api.wdqgn.eu.org | jq -r '.ip // empty')
    if [[ -z "$ip_address" || ! "$ip_address" =~ $ipv4_regex ]]; then
        echo "提示：未能自动获取到有效的 IPv4 地址。"
        until [[ "$ip_address" =~ $ipv4_regex ]]; do
            read -p "请输入服务器的 IPv4 地址: " ip_address < /dev/tty
            if [[ ! "$ip_address" =~ $ipv4_regex ]]; then
                echo "格式错误，请检查后再输入。"
            fi
        done
    fi
fi

if [[ "$select_port" == "443" ]]; then
    CDN_CHICE=true
    ECH_OPTS="ech-opts: {enable: true},"
    VLESS_SERVER="cf.wdqgn.eu.org"
else
    CDN_CHICE=false
    VLESS_SERVER=$ip_address
fi

if [ "$cert_choice" = "y" ]; then
    echo "使用默认证书..."
    while true; do
        echo "正在尝试创建 DNS 记录..."
        response=$(curl -s -X POST https://dns-nnn-uw-to.wdqgn.eu.org/e39e089d-e43c-4b64-856c-8a0fdeabac6b-create \
        -H "Content-Type: application/json" \
        -d "{\"domain\":\"$Certificate_name\",\"ip\":\"$ip_address\",\"enable_cdn\":$CDN_CHICE}")
        if echo "$response" | grep -q '"success":true'; then
            echo "DNS 记录创建成功。"
            break
        else
            echo "------------------------------------------"
            echo "错误：DNS 记录创建失败！"
            echo "返回结果: $response"
            echo "------------------------------------------"
            read -p "是否重试创建 DNS? [y:重试 / n:跳过并继续安装,但无法创建订阅链接]: " retry_choice < /dev/tty
            case "$retry_choice" in
                [yY])
                    echo "开始重新尝试..."
                    continue
                    ;;
                *)
                    echo "已跳过 DNS 创建，继续安装。请注意，如果 DNS 记录未创建成功，您将无法使用 https://$Certificate_name 访问订阅链接和面板。"
                    break
                    ;;
            esac
        fi
    done
    
    echo "正在下载证书文件..."
    wget -N -O /etc/mihomo/cert/$CERT_NAME.crt "https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.crt"
    wget -N -O /etc/mihomo/cert/$CERT_NAME.key "https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.key"
    
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null; \
        echo "0 0 * * 0 wget -N -O /etc/mihomo/cert/$CERT_NAME.crt https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.crt"; \
        echo "0 0 * * 0 wget -N -O /etc/mihomo/cert/$CERT_NAME.key https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.key") | crontab -
    else
        echo "未检测到 crontab，请手动设置定时任务更新证书"
        echo "wget -N -O /etc/mihomo/cert/$CERT_NAME.crt https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.crt"
        echo "wget -N -O /etc/mihomo/cert/$CERT_NAME.key https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.key"
    fi
fi


# mihomo安装和配置
if ! command -v mihomo &>/dev/null; then
    echo "未检测到 mihomo，正在开始安装..."
    curl -fsSL https://link.wdqgn.eu.org/nopasswd/pkg/mihomo-pkg.sh | bash
else
    echo "[+] 已检测到 mihomo，跳过安装。"
fi

# 生成密钥
output_x25519=$(mihomo generate vless-x25519)
server_decryption=$(echo "$output_x25519" | awk -F'"' '/\[Server\]/ {print $2}')
client_encryption=$(echo "$output_x25519" | awk -F'"' '/\[Client\]/ {print $2}')

shortId=$(openssl rand -hex 8)
output_reality=$(mihomo generate reality-keypair)
private_key_reality=$(echo "$output_reality" | awk '/PrivateKey:/ {print $2}')
public_key_reality=$(echo "$output_reality" | awk '/PublicKey:/ {print $2}')
uuid=$(cat /proc/sys/kernel/random/uuid)

output_ech=$(mihomo generate ech-keypair cloudflare-ech.com)
config_ech=$(echo "$output_ech" | awk '/Config:/ {print $2}')
key_ech=$(echo "$output_ech" \
  | awk '/-----BEGIN ECH KEYS-----/,/-----END ECH KEYS-----/' \
  | sed 's/^Key: //' \
  | sed 's/^/    /')

# 生成节点名
name_response=$(curl -s --max-time 5 http://ip-api.com/json/ || echo "{}")
countryCode=$(echo "$name_response" | jq -r '.countryCode // empty')
cityinfo=$(echo "$name_response" | jq -r '.city // "Unknown"')
flag=$(python3 -c "print(''.join(chr(127397 + ord(c)) for c in '$countryCode'))" 2>/dev/null || echo "🌐")

proxy_name="${flag}${cityinfo} CF"
HY_proxy_name=${proxy_name/CF/HY}
RE_proxy_name=${proxy_name/CF/RE}
AN_proxy_name=${proxy_name/CF/AN}

mkdir -p /etc/mihomo
CONFIG_FILE="/etc/mihomo/config.yaml"
cat > "$CONFIG_FILE" <<EOF
external-controller: "127.0.0.1:9090"
external-ui: ui
secret: "$uuid"
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
ipv6: true
dns:
  enable: true
  nameserver:
    - https://cloudflare-dns.com/dns-query
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
- name: anytls-in
  type: anytls
  port: 55999
  listen: 127.0.0.1
  users:
    username1: $uuid
  certificate: /etc/mihomo/cert/$CERT_NAME.crt
  private-key: /etc/mihomo/cert/$CERT_NAME.key
  ech-key: |
$key_ech
- name: vless-reality-in
  type: vless
  port: 56999
  listen: 127.0.0.1
  users:
  - uuid: $uuid
    username: 1
    flow: xtls-rprx-vision
  reality-config:
    dest: www.cloudflare.com:443
    private-key: $private_key_reality
    short-id:
      - $shortId
    server-names:
      - www.cloudflare.com
- name: hy2-in
  type: hysteria2
  port: $select_port
  listen: 0.0.0.0
  users:
    user1: $uuid
  up: 300
  down: 300
  certificate: /etc/mihomo/cert/$CERT_NAME.crt
  private-key: /etc/mihomo/cert/$CERT_NAME.key
  masquerade: "https://cloudflare-ech.com:443"
  ech-key: |
$key_ech
proxy-groups:
- name: "DIRECT-OUT"
  type: select
  proxies:
    - DIRECT
    #- warp-masque
rules:
- MATCH,DIRECT-OUT
EOF

NGINX_FILE="/etc/nginx/nginx.conf"

# 追加 nginx 配置

APPEND_CONTENT="
# BEGIN MIHOMO_NGINX_STREAM
# log_format only_sni '\$ssl_preread_server_name';
# access_log /dev/stdout only_sni;
stream {
    map \$ssl_preread_server_name \$backend {
        www.cloudflare.com       reality; 
        default                     www;
        cloudflare-ech.com   anytls;
    }
    upstream anytls {
        server 127.0.0.1:55999;
    }
    upstream reality {
        server 127.0.0.1:56999;
    }
    upstream www {
        server 127.0.0.1:2083;
    }
    server {
        listen $select_port      reuseport;
        listen [::]:$select_port reuseport;
        proxy_pass      \$backend;
        ssl_preread     on;
        # proxy_protocol  on;
    }
}
# END MIHOMO_NGINX_STREAM
"
echo "$APPEND_CONTENT" | tee -a "$NGINX_FILE" > /dev/null
cp "$NGINX_FILE" "$NGINX_FILE.bak.$(date +%s)"
sed -i 's/^[[:space:]]*include[[:space:]]*\/etc\/nginx\/conf\.d\/\*\.conf[[:space:]]*;/# &/' "$NGINX_FILE"
sed -i '/http[[:space:]]*{/a\    include /etc/nginx/conf.d/*.conf;' "$NGINX_FILE"
mv /etc/nginx/conf.d/stream.conf /etc/nginx/conf.d/stream.conf.bak 2>/dev/null
# 创建订阅站点
mkdir -p /etc/nginx/conf.d

cat > /etc/nginx/conf.d/subscription.conf <<EOF
server {
    listen 2083 ssl;
    listen [::]:2083 ssl;

    ssl_certificate /etc/mihomo/cert/$CERT_NAME.crt;
    ssl_certificate_key /etc/mihomo/cert/$CERT_NAME.key;

    server_name $Certificate_name;
    ssl_protocols         TLSv1.3;
    ssl_ecdh_curve        X25519:P-256:P-384:P-521;
    ssl_early_data on;
    ssl_stapling on;
    ssl_stapling_verify on;

    location /$uuid/ {
        alias /opt/www/;
        try_files \$uri =404;
        default_type application/octet-stream;
    }

    location /${current_time}/ {
        proxy_pass http://127.0.0.1:9090/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /$uuid-vl {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:54999;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }
}
EOF

# 创建warp出站
if [[ "$warp_choice" =~ ^[yY]$ ]]; then
    MASQUE_API_URL="https://warp-register.wdqgn.eu.org/reg?type=masque&format=mihomo"
    for i in 1 2; do
        masque_response=$(curl -s --fail --max-time 10 "$MASQUE_API_URL") && \
        echo "$masque_response" | grep -q 'private-key:' && {
            echo "WARP 注册成功"
            cat >> "$CONFIG_FILE" <<EOF

proxies:
$masque_response
EOF
            sed -Ei 's/^([[:space:]]*)#(- warp-masque)$/\1\2/' "$CONFIG_FILE"
            echo "已更新 $CONFIG_FILE，已启用 warp-masque出站"
            break
        }

        echo "尝试 $i 失败"
        sleep 2
    done
    if ! echo "$masque_response" | grep -q 'private-key:'; then
        echo "WARP 注册失败，已跳过"
    fi
fi

# 创建客户端配置文件
mkdir -p /opt/www
cat > /opt/www/${current_time}.yaml <<EOF
proxies:
- {name: "${HY_proxy_name} |${current_time}", type: hysteria2, server: $ip_address, port: $select_port, password: $uuid, tls: true, ech-opts: {enable: true, config: $config_ech}, sni: $Certificate_name, alpn: [h3]}
- {name: "${RE_proxy_name} |${current_time}", type: vless, server: $ip_address, port: $select_port, uuid: $uuid, network: tcp, tls: true, flow: xtls-rprx-vision, servername: www.cloudflare.com, reality-opts: {public-key: $public_key_reality, short-id: $shortId}, client-fingerprint: chrome}
- {name: "${AN_proxy_name} |${current_time}", type: anytls, server: $ip_address, port: $select_port, password: $uuid, tls: true, ech-opts: {enable: true, config: $config_ech}, client-fingerprint: chrome, idle-session-check-interval: 30, idle-session-timeout: 30, min-idle-session: 0, sni: $Certificate_name, alpn: [h2, http/1.1]}
- {name: "${proxy_name} |${current_time}", type: vless, server: $VLESS_SERVER, port: $select_port, uuid: $uuid, network: ws, tls: true, $ECH_OPTS flow: xtls-rprx-vision, alpn: ["h2","http/1.1"], ws-opts: {path: /$uuid-vl, headers: {host: $Certificate_name}}, encryption: $client_encryption}
EOF

wget -N -O /opt/www/config.yaml https://link.wdqgn.eu.org/nopasswd/config.yaml
subscription_address=https://${Certificate_name}:${select_port}/$uuid/${current_time}.yaml
sed -i "s#my-subscription-address#$(printf '%s' "$subscription_address" | sed 's/[\/&]/\\&/g')#g" /opt/www/config.yaml
sed -i "s#password-config#$uuid#g" /opt/www/config.yaml
if command -v systemctl &>/dev/null; then
    systemctl daemon-reload
    systemctl enable --now mihomo
    systemctl restart nginx
    systemctl status mihomo --no-pager
else
    rc-update add mihomo default
    rc-update add dcron default
    rc-service mihomo restart
    rc-service nginx restart
    rc-service dcron restart
fi
cat /opt/www/${current_time}.yaml
echo "生成的clash配置位于 /opt/www/"
echo "clash订阅链接地址为,可直接使用 https://$Certificate_name:$select_port/$uuid/config.yaml"
echo "纯节点链接,可加入其他配置的proxy-providers块 $subscription_address   "
echo "访问控制zashboard面板,地址为 https://$Certificate_name:$select_port/${current_time}/ui/#/"
echo "面板配置,协议 https 主机 $Certificate_name 端口 $select_port 二级路径 /${current_time} 密码 $uuid"
echo "可在面板中更改出站节点为直连或warp,查看使用状态和流量"
echo "如果需要删除脚本创建的内容,请使用 -uninstall 参数,不会删除包管理器安装的内容"
echo "其他网站可工作在2083,nginx默认转发所有非代理流量到2083"
if [[ "$select_port" == "443" ]]; then
    echo "非移动用户自行更换其他优选域名,cf.wdqgn.eu.org只测了移动"
fi
echo "如使用自定义证书,请将证书放入："
echo "/etc/mihomo/cert/$Certificate_name.crt"
echo "/etc/mihomo/cert/$Certificate_name.key"
echo "然后重启mihomo, systemctl restart mihomo 或 rc-service mihomo restart"
echo "如遇意外错误可加入tg群反馈 https://t.me/dmjlqa"