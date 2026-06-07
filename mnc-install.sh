#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

CERTIFICATE_NAME="${CERTIFICATE_NAME:-nauk.eu.cc}"
CERT_BASE_URL="${CERT_BASE_URL:-https://link.wdqgn.eu.org/nopasswd/cert}"
CERT_DIR="${CERT_DIR:-/etc/mihomo/cert}"
CONFIG_FILE="${CONFIG_FILE:-/etc/mihomo/config.yaml}"
SUB_ROOT="${SUB_ROOT:-/opt/www}"
SUB_DIR="${SUB_DIR:-$SUB_ROOT/sub}"
CLIENT_TEMPLATE_URL="${CLIENT_TEMPLATE_URL:-https://raw.githubusercontent.com/niylin/mnc-install/master/config.yaml}"
NGINX_HTTP_CONF="${NGINX_HTTP_CONF:-}"
NGINX_STREAM_CONF="${NGINX_STREAM_CONF:-}"
GITHUB_DOWNLOAD_TIMEOUT="${GITHUB_DOWNLOAD_TIMEOUT:-15}"
DNS_CREATE_API_URL="${DNS_CREATE_API_URL:-https://dns-nnn-uw-to.wdqgn.eu.org/e39e089d-e43c-4b64-856c-8a0fdeabac6b-create}"
GITHUB_MIRRORS=(
    "https://mirror.ghproxy.com/"
    "https://ghproxy.net/"
    "https://github.moeyy.xyz/"
)

RED=""
GREEN=""
YELLOW=""
BLUE=""
BOLD=""
RESET=""
if [ -t 1 ]; then
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    BLUE="$(printf '\033[34m')"
    BOLD="$(printf '\033[1m')"
    RESET="$(printf '\033[0m')"
fi

uuid=""
short_id=""
current_time=""
public_ip=""
node_prefix=""
subscription_address=""
final_config_address=""
links_file=""
main_port="443"
secondary_port="2053"
cert_name="$CERTIFICATE_NAME"
server_decryption=""
client_encryption=""
private_key_reality=""
public_key_reality=""
ech_config_primary=""
ech_key_primary=""
ech_config_secondary=""
ech_key_secondary=""
include_vless_ws="0"

info() { printf '%s\n' "${BLUE}$*${RESET}"; }
ok() { printf '%s\n' "${GREEN}$*${RESET}"; }
warn() { printf '%s\n' "${YELLOW}$*${RESET}"; }
err() { printf '错误：%s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        die "请使用 root 权限运行此脚本。"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "未找到依赖：$1"
}

package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' apt
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
    elif command -v pacman >/dev/null 2>&1; then
        printf '%s\n' pacman
    elif command -v apk >/dev/null 2>&1; then
        printf '%s\n' apk
    else
        printf '%s\n' none
    fi
}

install_packages() {
    local pm pkg_list=("$@")
    [ "${#pkg_list[@]}" -gt 0 ] || return 0
    pm="$(package_manager)"

    case "$pm" in
        apt)
            apt-get update
            apt-get install -y "${pkg_list[@]}"
            ;;
        dnf)
            dnf install -y "${pkg_list[@]}"
            ;;
        yum)
            yum install -y "${pkg_list[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${pkg_list[@]}"
            ;;
        apk)
            apk add --no-cache "${pkg_list[@]}"
            ;;
        *)
            die "未找到支持的包管理器，无法安装：${pkg_list[*]}"
            ;;
    esac
}

ensure_runtime_tools() {
    local need=()
    for tool in curl python3 gzip; do
        command -v "$tool" >/dev/null 2>&1 || need+=("$tool")
    done
    [ "${#need[@]}" -gt 0 ] || return 0
    info "正在安装运行依赖：${need[*]}"
    install_packages "${need[@]}"
}

download_with_mirrors() {
    local url="$1"
    local output="$2"
    local mirror

    if curl --max-time "$GITHUB_DOWNLOAD_TIMEOUT" -fsSL "$url" -o "$output"; then
        return 0
    fi

    for mirror in "${GITHUB_MIRRORS[@]}"; do
        warn "直链失败，尝试镜像：$mirror"
        if curl --max-time "$GITHUB_DOWNLOAD_TIMEOUT" -fsSL "${mirror}${url}" -o "$output"; then
            return 0
        fi
    done

    return 1
}

valid_ip() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    ipaddress.ip_address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltnu "( sport = :$port )" | grep -q .
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnu 2>/dev/null | grep -Eq "[.:]$port[[:space:]]"
    else
        return 1
    fi
}

stop_conflicting_services() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop apache2 httpd caddy 2>/dev/null || true
        systemctl stop apache2.socket httpd.socket caddy.socket 2>/dev/null || true
        systemctl disable apache2 httpd caddy 2>/dev/null || true
        systemctl disable apache2.socket httpd.socket caddy.socket 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service apache2 stop 2>/dev/null || true
        rc-service httpd stop 2>/dev/null || true
        rc-service caddy stop 2>/dev/null || true
    fi
}

detect_nginx_paths() {
    if [ -n "$NGINX_HTTP_CONF" ] && [ -n "$NGINX_STREAM_CONF" ]; then
        return 0
    fi

    local http_dir stream_dir
    if [ -d /etc/nginx/http.d ] || [ -f /etc/alpine-release ]; then
        http_dir="/etc/nginx/http.d"
    else
        http_dir="/etc/nginx/conf.d"
    fi
    stream_dir="/etc/nginx/stream.d"

    mkdir -p "$http_dir" "$stream_dir"

    NGINX_HTTP_CONF="$http_dir/mnc-install-subscription.conf"
    NGINX_STREAM_CONF="$stream_dir/mnc-install-stream.conf"
}

select_nginx_config() {
    detect_nginx_paths
}

remove_nginx_stream_block() {
    local nginx_conf="/etc/nginx/nginx.conf"
    if [ -f "$nginx_conf" ]; then
        sed -i '/# BEGIN MNC_INSTALL_STREAM/,/# END MNC_INSTALL_STREAM/d' "$nginx_conf"
    fi
}

backup_alpine_default_confs() {
    if [ ! -f /etc/alpine-release ]; then
        return 0
    fi

    local conf_dir="/etc/nginx/conf.d"
    local default_conf="$conf_dir/default.conf"
    local stream_conf="$conf_dir/stream.conf"

    if [ -f "$default_conf" ]; then
        info "备份 Alpine 默认 nginx 配置：$default_conf"
        mv -f "$default_conf" "$default_conf.bak"
    fi

    if [ -f "$stream_conf" ]; then
        info "备份 Alpine 默认 nginx 配置：$stream_conf"
        mv -f "$stream_conf" "$stream_conf.bak"
    fi
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        ok "检测到 nginx 已安装。"
        return
    fi

    local pm extra=()
    pm="$(package_manager)"
    case "$pm" in
        apt) extra=(libnginx-mod-stream) ;;
        dnf|yum|pacman|apk) extra=(nginx-mod-stream) ;;
        *) extra=() ;;
    esac

    info "正在安装 nginx"
    install_packages nginx "${extra[@]}"
}

install_mihomo_binary() {
    local arch bin_arch level latest_version release_url asset_url asset_name work_dir latest_json
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) bin_arch="amd64" ;;
        aarch64|arm64) bin_arch="arm64" ;;
        armv7l|armv7*) bin_arch="armv7" ;;
        armv6l|armv6*) bin_arch="armv6" ;;
        *) die "不支持的架构：$arch" ;;
    esac

    if [[ "$bin_arch" = "amd64" ]]; then
        if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
            level="v3"
        elif grep -q avx /proc/cpuinfo 2>/dev/null; then
            level="v2"
        else
            level="v1"
        fi
    fi

    if command -v mihomo >/dev/null 2>&1; then
        ok "检测到 mihomo 已安装。"
        return
    fi

    ensure_runtime_tools
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mihomo-install.XXXXXX")"

    latest_json="$work_dir/latest.json"
    release_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    info "正在获取 mihomo 最新版本..."
    if ! download_with_mirrors "$release_url" "$latest_json"; then
        rm -rf "$work_dir"
        die "无法获取 mihomo 最新版本信息。"
    fi

    read -r asset_url asset_name < <(
        python3 - "$latest_json" "$bin_arch" "$level" <<'PY'
import json
import sys

path, bin_arch, level = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

version = data.get("tag_name", "").lstrip("v")
if not version:
    raise SystemExit("无法获取 mihomo 版本号")

if bin_arch == "amd64":
    name = f"mihomo-linux-{bin_arch}-{level}-v{version}.gz"
else:
    name = f"mihomo-linux-{bin_arch}-v{version}.gz"

for asset in data.get("assets", []):
    if asset.get("name") == name:
        print(asset.get("browser_download_url", ""), asset.get("name", ""))
        break
else:
    candidates = [asset for asset in data.get("assets", []) if "linux" in asset.get("name", "").lower() and bin_arch in asset.get("name", "").lower()]
    if not candidates:
        raise SystemExit(f"未找到适合 {bin_arch} 的 mihomo 资产")
    candidates.sort(key=lambda a: a.get("name", ""))
    asset = candidates[0]
    print(asset.get("browser_download_url", ""), asset.get("name", ""))
PY
    )

    if [ -z "$asset_url" ]; then
        rm -rf "$work_dir"
        die "未能解析 mihomo 下载地址。"
    fi
    info "正在下载 mihomo：$asset_name"
    if ! download_with_mirrors "$asset_url" "$work_dir/mihomo.gz"; then
        rm -rf "$work_dir"
        die "mihomo 下载失败。"
    fi

    gzip -df "$work_dir/mihomo.gz"
    install -m 0755 "$work_dir/mihomo" /usr/local/bin/mihomo
    rm -rf "$work_dir"
    ok "mihomo 安装完成。"
}

install_mihomo_service() {
    mkdir -p /etc/mihomo

    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon
After=network.target

[Service]
Type=simple
Restart=always
LimitNPROC=500
LimitNOFILE=1000000
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    elif command -v rc-service >/dev/null 2>&1; then
        cat > /etc/init.d/mihomo <<EOF
#!/sbin/openrc-run

name="mihomo"
description="mihomo Daemon"

command="/usr/local/bin/mihomo"
command_args="-d /etc/mihomo"
command_background="yes"
pidfile="/run/\${name}.pid"

depend() {
    after network
}
EOF
        chmod +x /etc/init.d/mihomo
        rc-update add mihomo default 2>/dev/null || true
    fi
}

install_mihomo() {
    install_mihomo_binary
    install_mihomo_service
}

download_certificates() {
    mkdir -p "$CERT_DIR"
    info "正在下载证书：$cert_name"
    curl -fsSL --max-time "$GITHUB_DOWNLOAD_TIMEOUT" -o "$CERT_DIR/$cert_name.crt" "$CERT_BASE_URL/$cert_name.crt"
    curl -fsSL --max-time "$GITHUB_DOWNLOAD_TIMEOUT" -o "$CERT_DIR/$cert_name.key" "$CERT_BASE_URL/$cert_name.key"
}

setup_certificate_renewal() {
    if ! command -v crontab >/dev/null 2>&1; then
        warn "未检测到 crontab，跳过证书更新定时任务。"
        return 0
    fi

    local tmp_cron
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$CERT_BASE_URL/$cert_name" > "$tmp_cron" || true
    {
        printf '0 0 * * 0 curl -fsSL -o %s/%s.crt %s/%s.crt\n' "$CERT_DIR" "$cert_name" "$CERT_BASE_URL" "$cert_name"
        printf '0 0 * * 0 curl -fsSL -o %s/%s.key %s/%s.key\n' "$CERT_DIR" "$cert_name" "$CERT_BASE_URL" "$cert_name"
    } >> "$tmp_cron"
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
}

create_dns_record() {
    local enable_cdn="false"
    local response retry_choice

    [ "$main_port" = "443" ] && enable_cdn="true"

    while true; do
        info "正在尝试创建 DNS 记录..."
        response=$(
            curl -fsS -X POST "$DNS_CREATE_API_URL" \
                -H "Content-Type: application/json" \
                -d "{\"domain\":\"$cert_name\",\"ip\":\"$public_ip\",\"enable_cdn\":$enable_cdn}" 2>/dev/null || true
        )

        if printf '%s' "$response" | grep -q '"success":true'; then
            ok "DNS 记录创建成功。"
            return 0
        fi

        warn "DNS 记录创建失败。"
        [ -n "$response" ] && warn "返回结果: $response"
        read -r -p "是否重试创建 DNS? [y:重试 / n:跳过并继续安装]: " retry_choice < /dev/tty
        case "$retry_choice" in
            y|Y)
                continue
                ;;
            *)
                warn "已跳过 DNS 创建，继续安装。"
                return 0
                ;;
        esac
    done
}

detect_public_ip() {
    local ip_type_choice trace_content answer manual_ip

    read -r -p "${BOLD}使用 IPv6 输入 6，默认 IPv4: ${RESET}" ip_type_choice < /dev/tty
    ip_type_choice="${ip_type_choice:-4}"

    trace_content=$(curl -"${ip_type_choice}" -fsS --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    public_ip=$(printf '%s\n' "$trace_content" | sed -nE 's/^ip=(.*)$/\1/p' | head -n 1)

    if ! valid_ip "$public_ip" 2>/dev/null; then
        public_ip=$(curl -"${ip_type_choice}" -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi

    if valid_ip "$public_ip" 2>/dev/null; then
        printf '%s\n' "${BOLD}检测到 IP: ${GREEN}${public_ip}${RESET}"
        read -r -p "${BOLD}IP 是否正确？默认 y，输入 n 可手动覆盖: ${RESET}" answer < /dev/tty
        case "$answer" in
            n|N|no|NO)
                read -r -p "${BOLD}输入实际入站 IP: ${RESET}" manual_ip < /dev/tty
                valid_ip "$manual_ip" || die "IP 地址格式不合法。"
                public_ip="$manual_ip"
                ;;
        esac
    else
        warn "未能自动获取有效 IP。"
        while true; do
            read -r -p "${BOLD}输入实际入站 IP: ${RESET}" public_ip < /dev/tty
            valid_ip "$public_ip" || {
                warn "IP 地址格式不合法。"
                continue
            }
            break
        done
    fi

    node_prefix="mihomo"
}

prompt_main_port() {
    local selected
    read -r -p "${BOLD}输入主入站端口，默认 443；输入任意端口后第二端口使用该端口+1: ${RESET}" selected < /dev/tty
    selected="${selected:-443}"

    if ! [[ "$selected" =~ ^[0-9]+$ ]] || [ "$selected" -lt 1 ] || [ "$selected" -gt 65534 ]; then
        die "请输入有效端口号 (1-65534)。"
    fi

    main_port="$selected"
    if [ "$main_port" = "443" ]; then
        secondary_port="2053"
        include_vless_ws="1"
    else
        secondary_port="$((main_port + 1))"
        include_vless_ws="0"
    fi

    if port_in_use "$main_port"; then
        warn "端口 $main_port 已被占用，nginx/mihomo 启动可能失败。"
    fi
    if port_in_use "$secondary_port"; then
        warn "端口 $secondary_port 已被占用，nginx/mihomo 启动可能失败。"
    fi
}

generate_materials() {
    current_time=$(date +"%Y%m%d-%H%M%S")
    uuid=$(cat /proc/sys/kernel/random/uuid)
    short_id=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

    local output_x25519 output_reality output_ech_1
    output_x25519=$(mihomo generate vless-x25519)
    server_decryption=$(printf '%s\n' "$output_x25519" | awk -F'"' '/\[Server\]/ {print $2; exit}')
    client_encryption=$(printf '%s\n' "$output_x25519" | awk -F'"' '/\[Client\]/ {print $2; exit}')

    output_reality=$(mihomo generate reality-keypair)
    private_key_reality=$(printf '%s\n' "$output_reality" | awk -F': ' '/PrivateKey:/ {print $2; exit}')
    public_key_reality=$(printf '%s\n' "$output_reality" | awk -F': ' '/PublicKey:/ {print $2; exit}')

    output_ech=$(mihomo generate ech-keypair cloudflare-ech.com)
    ech_config_primary=$(printf '%s\n' "$output_ech" | awk -F': ' '/^Config:/ {print $2; exit}')
    ech_key_primary=$(printf '%s\n' "$output_ech" | sed -n '/-----BEGIN ECH KEYS-----/,/-----END ECH KEYS-----/p' | sed '/ECH KEYS/d' | sed 's/^Key: //' | tr -d '\r')

    output_ech_1=$(mihomo generate ech-keypair cloudflare.com)
    ech_config_secondary=$(printf '%s\n' "$output_ech_1" | awk -F': ' '/^Config:/ {print $2; exit}')
    ech_key_secondary=$(printf '%s\n' "$output_ech_1" | sed -n '/-----BEGIN ECH KEYS-----/,/-----END ECH KEYS-----/p' | sed '/ECH KEYS/d' | sed 's/^Key: //' | tr -d '\r')
}

write_mihomo_config() {
    mkdir -p /etc/mihomo "$CERT_DIR"

    local vless_ws_block=""
    if [ "$include_vless_ws" = "1" ]; then
        vless_ws_block=$(cat <<EOF
- name: vless-ws-in
  type: vless
  listen: 127.0.0.1
  port: 58991
  users:
    - username: 1
      uuid: $uuid
      flow: xtls-rprx-vision
  decryption: $server_decryption
  ws-path: /$uuid-vl
EOF
)
    fi

    cat > "$CONFIG_FILE" <<EOF
log:
  level: info
listeners:
- name: sudoku-in
  type: sudoku
  port: 58995
  listen: 127.0.0.1
  key: $uuid
  aead-method: chacha20-poly1305
  padding-min: 1
  padding-max: 7
  table-type: prefer_ascii
  handshake-timeout: 5
  enable-pure-downlink: false
  httpmask:
    disable: false
    mode: legacy
    path_root: "/$uuid"
  fallback: "127.0.0.1:9998"
- name: mieru-in
  type: mieru
  port: $secondary_port
  listen: 0.0.0.0
  transport: TCP
  users:
    $uuid: $uuid
  user-hint-is-mandatory: true
- name: tuicv5-in
  type: tuic
  port: $secondary_port
  listen: 0.0.0.0
  users:
    $uuid: $uuid
  certificate: $CERT_DIR/$cert_name.crt
  private-key: $CERT_DIR/$cert_name.key
  ech-key: |
$ech_key_primary
  congestion-controller: bbr
  max-idle-time: 15000
  authentication-timeout: 1000
  alpn:
    - h3
  max-udp-relay-packet-size: 1500
- name: anytls-in
  type: anytls
  port: 58997
  listen: 127.0.0.1
  users:
    username1: $uuid
  certificate: $CERT_DIR/$cert_name.crt
  private-key: $CERT_DIR/$cert_name.key
  ech-key: |
$ech_key_primary
- name: vless-reality-in
  type: vless
  port: 58998
  listen: 127.0.0.1
  users:
  - uuid: $uuid
    username: 1
    flow: xtls-rprx-vision
  reality-config:
    dest: speed.cloudflare.com:443
    private-key: $private_key_reality
    short-id:
      - $short_id
    server-names:
      - speed.cloudflare.com
- name: trusttunnel-in
  type: trusttunnel
  port: 58999
  listen: 127.0.0.1
  users:
    - username: $uuid
      password: $uuid
  certificate: $CERT_DIR/$cert_name.crt
  private-key: $CERT_DIR/$cert_name.key
  ech-key: |
$ech_key_secondary
  network: [tcp]
  congestion-controller: bbr
- name: hy2-in
  type: hysteria2
  port: $main_port
  listen: 0.0.0.0
  users:
    user1: $uuid
  up: 300
  down: 300
  certificate: $CERT_DIR/$cert_name.crt
  private-key: $CERT_DIR/$cert_name.key
  ech-key: |
$ech_key_primary
$vless_ws_block
proxy-groups:
- name: "DIRECT-OUT"
  type: select
  include-all: true
  proxies:
    - DIRECT
rules:
- MATCH,DIRECT-OUT
EOF
}

write_nginx_http_conf() {
    mkdir -p "$(dirname "$NGINX_HTTP_CONF")"
    cat > "$NGINX_HTTP_CONF" <<EOF
server {
    listen 127.0.0.1:9999 ssl;

    ssl_certificate $CERT_DIR/$cert_name.crt;
    ssl_certificate_key $CERT_DIR/$cert_name.key;

    server_name $cert_name;
    ssl_protocols TLSv1.3;
    ssl_ecdh_curve X25519:P-256:P-384:P-521;
    ssl_early_data on;
    ssl_stapling on;
    ssl_stapling_verify on;

    port_in_redirect off;
    absolute_redirect off;

    location /$uuid/ {
        alias $SUB_DIR/;
        try_files \$uri =404;
        default_type application/octet-stream;
    }

    location /$current_time/ {
        proxy_pass http://127.0.0.1:9090/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /$uuid-vl {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:58991;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location / {
        return 403;
    }
}
EOF
}

write_nginx_config() {
    select_nginx_config
    mkdir -p "$SUB_DIR" "$(dirname "$NGINX_HTTP_CONF")"

    local nginx_conf="/etc/nginx/nginx.conf"
    cp "$nginx_conf" "$nginx_conf.bak.$(date +%s)" 2>/dev/null || true
    remove_nginx_stream_block

    write_nginx_http_conf

    cat >> "$nginx_conf" <<EOF
# BEGIN MNC_INSTALL_STREAM
stream {
    map \$ssl_preread_server_name \$backend {
        cloudflare-ech.com     anytls;
        speed.cloudflare.com   reality;
        cloudflare.com         trusttunnel;
        $cert_name             website;
        default                sudoku;
    }

    upstream sudoku {
        server 127.0.0.1:58995;
    }

    upstream anytls {
        server 127.0.0.1:58997;
    }

    upstream reality {
        server 127.0.0.1:58998;
    }

    upstream trusttunnel {
        server 127.0.0.1:58999;
    }

    upstream website {
        server 127.0.0.1:9999;
    }

    server {
        listen $main_port reuseport;
        listen [::]:$main_port reuseport;
        proxy_pass \$backend;
        ssl_preread on;
    }
}
# END MNC_INSTALL_STREAM
EOF
}

ensure_subscription_base() {
    mkdir -p "$SUB_DIR"
    subscription_address="https://${cert_name}:${main_port}/${uuid}/${current_time}.yaml"
    final_config_address="https://${cert_name}:${main_port}/${uuid}/config.yaml"
    links_file="$SUB_DIR/links.txt"

    if ! download_with_mirrors "$CLIENT_TEMPLATE_URL" "$SUB_DIR/config.yaml"; then
        die "config.yaml 下载失败。"
    fi
}

write_client_outputs() {
    local client_yaml="$SUB_DIR/${current_time}.yaml"

    cat > "$client_yaml" <<EOF
proxies:
- name: "${node_prefix}-HY|${current_time}"
  type: hysteria2
  server: $public_ip
  port: $main_port
  password: $uuid
  up: "30 Mbps"
  down: "300 Mbps"
  tls: true
  ech-opts: {enable: true, config: $ech_config_primary}
  sni: $cert_name
  alpn: [h3]
- name: "${node_prefix}-RE|${current_time}"
  type: vless
  server: $public_ip
  port: $main_port
  uuid: $uuid
  client-fingerprint: chrome
  network: tcp
  tls: true
  flow: xtls-rprx-vision
  servername: speed.cloudflare.com
  reality-opts: {public-key: $public_key_reality, short-id: $short_id}
- name: "${node_prefix}-AN|${current_time}"
  type: anytls
  server: $public_ip
  port: $main_port
  password: $uuid
  client-fingerprint: chrome
  tls: true
  ech-opts: {enable: true, config: $ech_config_primary}
  idle-session-check-interval: 30
  idle-session-timeout: 30
  min-idle-session: 0
  sni: $cert_name
  alpn: [h2, http/1.1]
- name: "${node_prefix}-SU|${current_time}"
  type: sudoku
  server: $public_ip
  port: $main_port
  key: "$uuid"
  aead-method: chacha20-poly1305
  padding-min: 1
  padding-max: 7
  table-type: prefer_ascii
  httpmask:
    disable: false
    mode: legacy
    path-root: "/$uuid"
    multiplex: auto
  enable-pure-downlink: false
- name: "${node_prefix}-MR|${current_time}"
  type: mieru
  server: $public_ip
  port: $secondary_port
  transport: TCP
  username: $uuid
  password: $uuid
  multiplexing: MULTIPLEXING_LOW
- name: "${node_prefix}-TU|${current_time}"
  server: $public_ip
  port: $secondary_port
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
  sni: $cert_name
  ech-opts: {enable: true, config: $ech_config_primary}
- name: "${node_prefix}-TT|${current_time}"
  type: trusttunnel
  server: $public_ip
  port: $main_port
  username: $uuid
  password: $uuid
  client-fingerprint: chrome
  health-check: true
  ech-opts: {enable: true, config: $ech_config_secondary}
  sni: $cert_name
  alpn: [h2]
  congestion-controller: bbr
EOF

    if [ "$include_vless_ws" = "1" ]; then
        cat >> "$client_yaml" <<EOF
- name: "${node_prefix}-WS|${current_time}"
  type: vless
  server: cf.wdqgn.eu.org
  port: 443
  uuid: $uuid
  client-fingerprint: chrome
  network: ws
  tls: true
  ech-opts: {enable: true}
  flow: xtls-rprx-vision
  alpn: [h2]
  ws-opts: {path: /$uuid-vl, headers: {host: $cert_name}}
  encryption: $client_encryption
EOF
    fi

    ensure_subscription_base
    printf '\n' >> "$SUB_DIR/config.yaml"
    cat "$client_yaml" >> "$SUB_DIR/config.yaml"
}

start_services() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now mihomo
        systemctl enable --now nginx
        systemctl restart nginx
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add mihomo default 2>/dev/null || true
        rc-update add nginx default 2>/dev/null || true
        rc-service mihomo restart
        rc-service nginx restart
    else
        warn "未找到系统服务管理器，请手动启动 mihomo 和 nginx。"
    fi
}

uninstall_all() {
    info "开始清理 mnc-install.sh 创建的内容..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop mihomo 2>/dev/null || true
        systemctl stop nginx 2>/dev/null || true
        systemctl disable mihomo 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi

    if command -v rc-service >/dev/null 2>&1; then
        rc-service mihomo stop 2>/dev/null || true
        rc-service nginx stop 2>/dev/null || true
    fi

    rm -f /etc/systemd/system/mihomo.service
    rm -f /etc/init.d/mihomo
    rm -f /usr/local/bin/mihomo
    rm -f "$CONFIG_FILE"
    rm -f "$CONFIG_FILE".bak.*
    rm -f "$CERT_DIR/$cert_name.crt"
    rm -f "$CERT_DIR/$cert_name.key"
    rm -f /etc/nginx/http.d/mnc-install-subscription.conf
    rm -f /etc/nginx/conf.d/mnc-install-subscription.conf
    rm -f /etc/nginx/stream.d/mnc-install-stream.conf
    remove_nginx_stream_block
    rm -f "$SUB_DIR/config.yaml"
    rm -f "$SUB_DIR/links.txt"
    rm -f "$SUB_DIR/"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].yaml
    rm -f /opt/www/sub/config.yaml
    rm -f /opt/www/sub/links.txt

    info "清理完成。"
}

show_help() {
    cat <<EOF
用法: $SCRIPT_NAME [参数]

  不带参数:
  安装 mihomo、nginx，生成 mihomo 配置、订阅文件，并写入 nginx 配置。

参数:
  -h, --help, help   显示帮助
  -uninstall         删除脚本创建的服务、配置、订阅文件，并移除 mihomo/nginx 相关文件
  -mihomo            仅安装 mihomo 二进制和服务文件

可通过环境变量覆盖:
  CERTIFICATE_NAME   默认 nauk.eu.cc
  CERT_BASE_URL      默认 https://link.wdqgn.eu.org/nopasswd/cert
  CERT_DIR           默认 /etc/mihomo/cert
  CONFIG_FILE        默认 /etc/mihomo/config.yaml
  SUB_DIR            默认 /opt/www/sub
EOF
}

main() {
    case "${1:-}" in
        -h|--help|help)
            show_help
            exit 0
            ;;
        -uninstall)
            require_root
            uninstall_all
            exit 0
            ;;
        -mihomo)
            require_root
            ensure_runtime_tools
            install_mihomo
            exit 0
            ;;
        "")
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac

    require_root
    ensure_runtime_tools
    select_nginx_config
    backup_alpine_default_confs
    stop_conflicting_services
    install_nginx
    install_mihomo
    detect_public_ip
    prompt_main_port
    generate_materials
    create_dns_record
    download_certificates
    setup_certificate_renewal
    write_mihomo_config
    write_nginx_config

    nginx -t
    start_services
    write_client_outputs

    ok "安装完成。"
    cat > "$links_file" <<EOF
$subscription_address
$final_config_address
EOF
    cat "$links_file"
}

main "$@"
