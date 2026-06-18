#!/usr/bin/env bash

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
CERTIFICATE_NAME="${CERTIFICATE_NAME:-nauk.eu.cc}"
CERT_BASE_URL="${CERT_BASE_URL:-https://link.wdqgn.eu.org/nopasswd/cert}"
CERT_DIR="${CERT_DIR:-/etc/sing-box/cert}"

SUB_ROOT="${SUB_ROOT:-/opt/www}"
SUB_DIR="${SUB_DIR:-$SUB_ROOT/sub}"
STATE_DIR="${STATE_DIR:-/run/sing-box-argo}"
STATE_FILE="${STATE_FILE:-$SUB_DIR/state.env}"
DOMAIN_FILE="${DOMAIN_FILE:-$SUB_DIR/.tunnel-domain}"
PID_FILE="${PID_FILE:-$STATE_DIR/cloudflared.pid}"
TUNNEL_LOG="${TUNNEL_LOG:-$STATE_DIR/cloudflared.log}"
README_FILE="${README_FILE:-$SUB_DIR/README.txt}"
NGINX_CONFIG_CUSTOM="${NGINX_CONFIG+x}"
NGINX_CONFIG="${NGINX_CONFIG:-/etc/nginx/conf.d/sing-box-argo.conf}"

NGINX_HOST="${NGINX_HOST:-127.0.0.1}"
NGINX_PORT="${NGINX_PORT:-58996}"
VMESS_HOST="${VMESS_HOST:-127.0.0.1}"
VMESS_PORT="${VMESS_PORT:-58997}"

MAIN_PORT="${MAIN_PORT:-443}"
SECOND_PORT="${SECOND_PORT:-2053}"
REALITY_DOMAIN="${REALITY_DOMAIN:-www.cloudflare.com}"
ECH_DOMAIN="${ECH_DOMAIN:-cloudflare-ech.com}"
CLIENT_TEMPLATE_URL="${CLIENT_TEMPLATE_URL:-https://raw.githubusercontent.com/niylin/mnc-install/master/config.yaml}"
SCRIPT_DOWNLOAD_URL="${SCRIPT_DOWNLOAD_URL:-https://raw.githubusercontent.com/niylin/mnc-install/master/sing-box-install.sh}"

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
public_ip=""
trace_content=""
country_code="XX"
country_flag=""
colo_code="CF"
node_prefix=""
current_time=""
private_key_reality=""
public_key_reality=""
short_id=""
config_ech=""
subscription_path_uuid=""
domain_name=""
outbound_mode="direct"
inserver_info=""

info() { printf '%s\n' "${BLUE}$*${RESET}"; }
ok() { printf '%s\n' "${GREEN}$*${RESET}"; }
warn() { printf '%s\n' "${YELLOW}$*${RESET}"; }
err() { printf '%s\n' "${RED}错误：$*${RESET}" >&2; }

show_help() {
    cat <<EOF
用法: $SCRIPT_NAME [参数]

不带参数:
  安装 cloudflared、sing-box、nginx，配置四个直连协议和一个 VMess-ws 临时隧道节点。

参数:
  -pkg cloudflared       仅安装 cloudflared
  -pkg sing-box          仅安装 sing-box
  -ouserver              安装 sing-box，创建一个 VLESS 入站，并输出关键信息,落地鸡使用
  -inserver "信息"       完整安装，并使用该 VLESS 节点作为 sing-box 服务端出站,中转鸡使用
  -tunnel res            重新获取临时隧道域名，更新订阅和 README.txt
  -uninstall             删除脚本创建的配置并停止相关服务，不删除包和二进制
  -h, -help, --help      显示帮助

Node information 格式:
  vless IP PORT UUID
EOF
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        err "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "未找到依赖 $1"
        exit 1
    fi
}

require_curl() {
    require_cmd curl
}

install_runtime_dependencies() {
    local deps=() dep pkg
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || deps+=("$dep")
    done
    [ "${#deps[@]}" -gt 0 ] || return 0

    info "正在安装缺失依赖: ${deps[*]}"
    if command -v apt >/dev/null 2>&1; then
        apt update || { err "apt update 失败。"; exit 1; }
        apt install -y "${deps[@]}" || { err "apt 安装依赖失败。"; exit 1; }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${deps[@]}" || { err "dnf 安装依赖失败。"; exit 1; }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${deps[@]}" || { err "yum 安装依赖失败。"; exit 1; }
    elif command -v pacman >/dev/null 2>&1; then
        local pacman_deps=()
        for dep in "${deps[@]}"; do
            case "$dep" in
                python3) pkg="python" ;;
                nginx) pkg="nginx" ;;
                *) pkg="$dep" ;;
            esac
            pacman_deps+=("$pkg")
        done
        pacman -Sy --noconfirm "${pacman_deps[@]}" || { err "pacman 安装依赖失败。"; exit 1; }
    elif command -v apk >/dev/null 2>&1; then
        apk add "${deps[@]}" || { err "apk 安装依赖失败。"; exit 1; }
    else
        err "缺少依赖 ${deps[*]}，且未找到支持的包管理器 apt/dnf/yum/pacman/apk。"
        exit 1
    fi
}

install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        ok "检测到 nginx 已安装。"
        nginx -v 2>&1 || true
        return
    fi
    install_runtime_dependencies nginx
}

select_nginx_config() {
    if [ -n "${NGINX_CONFIG_SET:-}" ]; then
        return
    fi
    if [ -n "$NGINX_CONFIG_CUSTOM" ]; then
        NGINX_CONFIG_SET=1
        return
    fi
    if [ -d /etc/nginx/http.d ]; then
        NGINX_CONFIG="/etc/nginx/http.d/sing-box-argo.conf"
    else
        NGINX_CONFIG="/etc/nginx/conf.d/sing-box-argo.conf"
    fi
    NGINX_CONFIG_SET=1
}

install_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then
        ok "检测到 cloudflared 已安装。"
        cloudflared --version
        return
    fi

    require_curl
    require_cmd install

    local arch binary_arch latest_tag url tmpfile ok mirror
    arch=$(uname -m)
    case "$arch" in
        x86_64) binary_arch="amd64" ;;
        aarch64|arm64) binary_arch="arm64" ;;
        armv7l) binary_arch="armhf" ;;
        *) err "暂不支持的架构: $arch"; exit 1 ;;
    esac

    info "正在获取 cloudflared 最新版本..."
    latest_tag="$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
        | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' \
        | head -n 1)" || {
        err "无法连接到 GitHub API，无法获取 cloudflared 最新版本。"
        exit 1
    }
    [ -n "$latest_tag" ] || { err "GitHub API 响应中 cloudflared 版本号为空。"; exit 1; }

    url="https://github.com/cloudflare/cloudflared/releases/download/${latest_tag}/cloudflared-linux-${binary_arch}"
    tmpfile="$(mktemp)"
    info "正在下载 cloudflared ${latest_tag}: cloudflared-linux-${binary_arch}"
    if curl --max-time 30 -fSL "$url" -o "$tmpfile"; then
        :
    else
        ok=false
        for mirror in "https://ghproxy.net/" "https://releases.wdqgn.eu.org/"; do
            warn "直链下载失败，尝试镜像: $mirror"
            if curl --max-time 30 -fSL "${mirror}${url}" -o "$tmpfile"; then
                ok=true
                break
            fi
        done
        if ! "$ok"; then
            rm -f "$tmpfile"
            err "所有 cloudflared 下载源均失败。"
            exit 1
        fi
    fi

    install -m 0755 "$tmpfile" /usr/local/bin/cloudflared
    rm -f "$tmpfile"
    cloudflared --version
}

install_sing_box() {
    if command -v sing-box >/dev/null 2>&1; then
        ok "检测到 sing-box 已安装。"
        sing-box version
        return
    fi

    require_curl
    local os_info os arch pkg_suffix pkg_install download_version pkg_name url ok mirror
    os_info="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -z "$os_info" ] && os_info="$(cat /etc/alpine-release 2>/dev/null | sed 's/^/Alpine Linux /')"
    [ -z "$os_info" ] && os_info="未知"

    if command -v pacman >/dev/null 2>&1; then
        os="linux"; arch=$(uname -m); pkg_suffix=".pkg.tar.zst"; pkg_install="pacman -U --noconfirm"
    elif command -v dpkg >/dev/null 2>&1; then
        os="linux"; arch=$(dpkg --print-architecture); pkg_suffix=".deb"; pkg_install="dpkg -i"
    elif command -v dnf >/dev/null 2>&1; then
        os="linux"; arch=$(uname -m); pkg_suffix=".rpm"; pkg_install="dnf install -y"
    elif command -v rpm >/dev/null 2>&1; then
        os="linux"; arch=$(uname -m); pkg_suffix=".rpm"; pkg_install="rpm -i"
    elif command -v apk >/dev/null 2>&1; then
        os="linux"; arch=$(apk --print-arch); pkg_suffix=".apk"; pkg_install="apk add --allow-untrusted"
    else
        err "未找到支持的包管理器（pacman/dpkg/dnf/rpm/apk）。当前系统: $os_info"
        exit 1
    fi

    info "正在获取 sing-box 最新版本..."
    download_version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | grep tag_name | head -n 1 | awk -F: '{print $2}' | sed 's/[", v]//g')" || {
        err "无法连接到 GitHub API，无法获取 sing-box 最新版本。当前系统: $os_info"
        exit 1
    }
    [ -n "$download_version" ] || { err "GitHub API 响应中 sing-box 版本号为空。"; exit 1; }

    pkg_name="sing-box_${download_version}_${os}_${arch}${pkg_suffix}"
    url="https://github.com/SagerNet/sing-box/releases/download/v${download_version}/${pkg_name}"
    info "正在下载: $pkg_name"
    if curl --max-time 30 -fSL "$url" -o "$pkg_name"; then
        :
    else
        ok=false
        for mirror in "https://ghproxy.net/" "https://releases.wdqgn.eu.org/"; do
            warn "直链下载失败，尝试镜像: $mirror"
            if curl --max-time 30 -fSL "${mirror}${url}" -o "$pkg_name"; then
                ok=true
                break
            fi
        done
        if ! "$ok"; then
            rm -f "$pkg_name"
            err "所有 sing-box 下载源均失败。当前系统: $os_info"
            exit 1
        fi
    fi

    info "安装包: $pkg_install $pkg_name"
    if sh -c "$pkg_install \"$pkg_name\""; then
        rm -f "$pkg_name"
        sing-box version
    else
        rm -f "$pkg_name"
        err "sing-box 安装失败。当前系统: $os_info"
        exit 1
    fi
}

valid_ip() {
    local ip="$1"
    case "$ip" in
        *:*)
            [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
            ;;
        *)
            [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
            local old_ifs="$IFS"
            IFS=.
            set -- $ip
            IFS="$old_ifs"
            [ "$((10#$1))" -le 255 ] && [ "$((10#$2))" -le 255 ] && [ "$((10#$3))" -le 255 ] && [ "$((10#$4))" -le 255 ]
            ;;
    esac
}

generate_flag() {
    country_flag=""
    if command -v python3 >/dev/null 2>&1 && [[ "$country_code" =~ ^[A-Z][A-Z]$ ]]; then
        country_flag=$(COUNTRY_CODE="$country_code" python3 -c 'import os; print("".join(chr(127397 + ord(c)) for c in os.environ.get("COUNTRY_CODE", "")))' 2>/dev/null || true)
    fi
}

detect_public_ip() {
    local ip_type_choice answer manual_ip
    read -r -p "${BOLD}使用 IPv6 输入 6，默认 IPv4: ${RESET}" ip_type_choice < /dev/tty
    case "${ip_type_choice:-4}" in
        6) ip_type_choice=6 ;;
        *) ip_type_choice=4 ;;
    esac

    trace_content=$(curl -"${ip_type_choice}" -fsS --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    public_ip=$(printf '%s\n' "$trace_content" | sed -nE 's/^ip=(.*)$/\1/p' | head -n 1)
    country_code=$(printf '%s\n' "$trace_content" | sed -nE 's/^loc=(.*)$/\1/p' | head -n 1)
    colo_code=$(printf '%s\n' "$trace_content" | sed -nE 's/^colo=(.*)$/\1/p' | head -n 1)
    country_code=${country_code:-XX}
    colo_code=${colo_code:-CF}

    if ! valid_ip "$public_ip"; then
        public_ip=$(curl -"${ip_type_choice}" -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi

    if valid_ip "$public_ip"; then
        generate_flag
        printf '%s\n' "${BOLD}检测到 IP: ${GREEN}${public_ip}${RESET}"
        printf '%s\n' "${BOLD}检测到位置: ${GREEN}${country_flag:-$country_code} ${country_code} (${colo_code})${RESET}"
        read -r -p "${BOLD}IP 是否正确？默认 y，输入 n 可手动覆盖: ${RESET}" answer < /dev/tty
        case "$answer" in
            n|N|no|NO)
                read -r -p "${BOLD}输入实际入站 IP: ${RESET}" manual_ip < /dev/tty
                valid_ip "$manual_ip" || { err "IP 地址格式不合法。"; exit 1; }
                public_ip="$manual_ip"
                ;;
        esac
    else
        warn "未能自动获取有效 IP。"
        read -r -p "${BOLD}输入实际入站 IP: ${RESET}" public_ip < /dev/tty
        valid_ip "$public_ip" || { err "IP 地址格式不合法。"; exit 1; }
    fi

    node_prefix="${country_flag:-$country_code} ${colo_code}"
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

prompt_main_ports() {
    local selected
    read -r -p "${BOLD}输入主入站端口，默认 443；输入任意端口后第二端口使用该端口+1: ${RESET}" selected < /dev/tty
    if [ -z "$selected" ]; then
        MAIN_PORT=443
        SECOND_PORT=2053
    else
        if ! [[ "$selected" =~ ^[0-9]+$ ]] || [ "$selected" -lt 1 ] || [ "$selected" -gt 65534 ]; then
            err "请输入有效端口号 (1-65534)。"
            exit 1
        fi
        MAIN_PORT="$selected"
        SECOND_PORT=$((selected + 1))
    fi

    if port_in_use "$MAIN_PORT"; then
        warn "端口 $MAIN_PORT 已被占用，sing-box 启动可能失败。"
    fi
    if port_in_use "$SECOND_PORT"; then
        warn "端口 $SECOND_PORT 已被占用，sing-box 启动可能失败。"
    fi

    printf '%s\n' "${BOLD}端口分配:${RESET}"
    printf '  HY2 UDP + VLESS Reality TCP: %s\n' "$MAIN_PORT"
    printf '  AnyTLS TCP + TUIC UDP: %s\n' "$SECOND_PORT"
}

prompt_ouserver_port() {
    local port
    while true; do
        read -r -p "${BOLD}输入 VLESS 出口节点监听端口: ${RESET}" port < /dev/tty
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            warn "请输入有效端口号 (1-65535)。"
            continue
        fi
        if port_in_use "$port"; then
            warn "端口 $port 已被占用，请重新输入。"
            continue
        fi
        MAIN_PORT="$port"
        break
    done
}

url_encode() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
}

format_link_host() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

download_certificates() {
    mkdir -p "$CERT_DIR"
    info "正在下载证书文件..."
    curl -fsSL --max-time 15 -o "$CERT_DIR/$CERTIFICATE_NAME.crt" "$CERT_BASE_URL/$CERTIFICATE_NAME.crt" || {
        err "证书 crt 下载失败。"
        exit 1
    }
    curl -fsSL --max-time 15 -o "$CERT_DIR/$CERTIFICATE_NAME.key" "$CERT_BASE_URL/$CERTIFICATE_NAME.key" || {
        err "证书 key 下载失败。"
        exit 1
    }
}

setup_certificate_cron() {
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "$CERT_BASE_URL/$CERTIFICATE_NAME" || true
        echo "0 0 * * 0 curl -fsSL -o $CERT_DIR/$CERTIFICATE_NAME.crt $CERT_BASE_URL/$CERTIFICATE_NAME.crt"
        echo "0 0 * * 0 curl -fsSL -o $CERT_DIR/$CERTIFICATE_NAME.key $CERT_BASE_URL/$CERTIFICATE_NAME.key") | crontab -
        ok "已创建证书更新定时任务。"
    else
        warn "未检测到 crontab，跳过证书更新定时任务。"
    fi
}

generate_materials() {
    current_time=$(TZ=UTC-8 date +"%Y%m%d-%H%M%S")
    uuid=$(cat /proc/sys/kernel/random/uuid)
    subscription_path_uuid=$(cat /proc/sys/kernel/random/uuid)
    short_id=$(sing-box generate rand 8 --hex)

    local output_reality output_ech key_ech
    output_reality=$(sing-box generate reality-keypair)
    private_key_reality=$(printf '%s' "$output_reality" | sed -nE 's/^PrivateKey:[[:space:]]*(.*)$/\1/p')
    public_key_reality=$(printf '%s' "$output_reality" | sed -nE 's/^PublicKey:[[:space:]]*(.*)$/\1/p')

    output_ech=$(sing-box generate ech-keypair "$ECH_DOMAIN")
    config_ech=$(printf '%s' "$output_ech" | sed -n '/BEGIN ECH CONFIGS/,/END ECH CONFIGS/p' | sed '/ECH CONFIGS/d' | tr -d '\n\r')
    key_ech=$(printf '%s' "$output_ech" | sed -n '/BEGIN ECH KEYS/,/END ECH KEYS/p')
    printf '%s\n' "$key_ech" > "$CERT_DIR/ech.pem"
}

parse_inserver_info() {
    [ -n "$inserver_info" ] || return 0
    set -- $inserver_info
    if [ "$#" -ne 4 ] || [ "$1" != "vless" ]; then
        err "Node information 格式应为: vless IP PORT UUID"
        exit 1
    fi
    valid_ip "$2" || { err "Node information 中的 IP 不合法。"; exit 1; }
    if ! [[ "$3" =~ ^[0-9]+$ ]] || [ "$3" -lt 1 ] || [ "$3" -gt 65535 ]; then
        err "Node information 中的端口不合法。"
        exit 1
    fi
    outbound_mode="vless"
}

write_sing_box_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    local outbound_json
    if [ "$outbound_mode" = "vless" ]; then
        set -- $inserver_info
        outbound_json=$(python3 - "$2" "$3" "$4" <<'PY'
import json
import sys
server, port, uuid = sys.argv[1:4]
print(json.dumps({
    "type": "vless",
    "tag": "proxy",
    "server": server,
    "server_port": int(port),
    "uuid": uuid,
    "tls": {"enabled": False},
}, ensure_ascii=False))
PY
)
    else
        outbound_json='{"type":"direct","tag":"direct"}'
    fi

    python3 - "$CONFIG_FILE" "$uuid" "$MAIN_PORT" "$SECOND_PORT" "$VMESS_HOST" "$VMESS_PORT" \
        "$CERT_DIR/$CERTIFICATE_NAME.crt" "$CERT_DIR/$CERTIFICATE_NAME.key" "$CERT_DIR/ech.pem" \
        "$private_key_reality" "$short_id" "$REALITY_DOMAIN" "$outbound_json" <<'PY'
import json
import sys

(
    config_path,
    uuid,
    main_port,
    second_port,
    vmess_host,
    vmess_port,
    cert_path,
    key_path,
    ech_path,
    reality_private_key,
    short_id,
    reality_domain,
    outbound_json,
) = sys.argv[1:14]

tls = {
    "enabled": True,
    "certificate_path": cert_path,
    "key_path": key_path,
    "ech": {"enabled": True, "key_path": ech_path},
}

config = {
    "log": {"level": "info"},
    "inbounds": [
        {
            "type": "hysteria2",
            "tag": "hysteria2-in",
            "listen": "::",
            "listen_port": int(main_port),
            "users": [{"password": uuid}],
            "obfs": {"type": "salamander", "password": uuid},
            "tls": {**tls, "alpn": ["h3"]},
        },
        {
            "type": "vless",
            "tag": "vless-reality-in",
            "listen": "::",
            "listen_port": int(main_port),
            "users": [{"uuid": uuid, "flow": "xtls-rprx-vision"}],
            "tls": {
                "enabled": True,
                "server_name": reality_domain,
                "reality": {
                    "enabled": True,
                    "handshake": {"server": reality_domain, "server_port": 443},
                    "private_key": reality_private_key,
                    "short_id": [short_id],
                },
            },
        },
        {
            "type": "anytls",
            "tag": "anytls-in",
            "listen": "::",
            "listen_port": int(second_port),
            "users": [{"name": uuid, "password": uuid}],
            "padding_scheme": [],
            "tls": {**tls, "alpn": ["h2"]},
        },
        {
            "type": "tuic",
            "tag": "tuic-in",
            "listen": "::",
            "listen_port": int(second_port),
            "users": [{"name": uuid, "uuid": uuid, "password": uuid}],
            "congestion_control": "bbr",
            "auth_timeout": "3s",
            "zero_rtt_handshake": False,
            "heartbeat": "10s",
            "tls": {**tls, "alpn": ["h3"]},
        },
        {
            "type": "vmess",
            "tag": "vmess-ws-in",
            "listen": vmess_host,
            "listen_port": int(vmess_port),
            "users": [{"uuid": uuid, "alterId": 0}],
            "transport": {"type": "ws", "path": f"/{uuid}-vm"},
        },
    ],
    "outbounds": [json.loads(outbound_json)],
}

with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

write_ouserver_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" "$SUB_DIR"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    python3 - "$CONFIG_FILE" "$uuid" "$MAIN_PORT" <<'PY'
import json
import sys
config_path, uuid, port = sys.argv[1:4]
config = {
    "log": {"level": "info"},
    "inbounds": [{
        "type": "vless",
        "tag": "vless-ouserver-in",
        "listen": "::",
        "listen_port": int(port),
        "users": [{"uuid": uuid}],
    }],
    "outbounds": [{"type": "direct", "tag": "direct"}],
}
with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

    python3 - "$SUB_DIR/ouserver.json" "$public_ip" "$MAIN_PORT" "$uuid" <<'PY'
import json
import sys
path, server, port, uuid = sys.argv[1:5]
outbound = {
    "type": "vless",
    "tag": "proxy",
    "server": server,
    "server_port": int(port),
    "uuid": uuid,
    "tls": {"enabled": False},
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(outbound, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

start_sing_box() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now sing-box || { err "sing-box systemd 服务启用失败。"; exit 1; }
        systemctl restart sing-box || { err "sing-box systemd 服务重启失败。"; exit 1; }
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        rc-update add sing-box default || { err "sing-box OpenRC 服务启用失败。"; exit 1; }
        rc-service sing-box restart || { err "sing-box OpenRC 服务重启失败。"; exit 1; }
    else
        warn "未找到 systemctl 或 OpenRC，请手动启动 sing-box。"
    fi
}

start_nginx() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now nginx || { err "nginx systemd 服务启用失败。"; exit 1; }
        systemctl reload nginx 2>/dev/null || systemctl restart nginx || { err "nginx systemd 服务重载/重启失败。"; exit 1; }
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        rc-update add nginx default || { err "nginx OpenRC 服务启用失败。"; exit 1; }
        rc-service nginx restart || { err "nginx OpenRC 服务重启失败。"; exit 1; }
    elif command -v service >/dev/null 2>&1; then
        service nginx restart || { err "nginx 服务重启失败。"; exit 1; }
    else
        warn "未找到服务管理器，请手动启动 nginx。"
    fi
}

write_nginx_config() {
    select_nginx_config
    mkdir -p "$SUB_ROOT" "$SUB_DIR" "$(dirname "$NGINX_CONFIG")"
    cat > "$NGINX_CONFIG" <<EOF
server {
    listen ${NGINX_HOST}:${NGINX_PORT};
    server_name _;

    location /${subscription_path_uuid}/ {
        alias ${SUB_DIR}/;
        default_type text/plain;
        add_header Cache-Control "no-store";
        try_files \$uri =404;
    }

    location /${uuid}-vm {
        proxy_pass http://${VMESS_HOST}:${VMESS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }

    location / {
        return 404;
    }
}
EOF
    nginx -t || { err "nginx 配置检查失败: $NGINX_CONFIG"; exit 1; }
}

stop_tunnel() {
    local pid drain_pid
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    if [ -f "$STATE_DIR/cloudflared-drain.pid" ]; then
        drain_pid=$(cat "$STATE_DIR/cloudflared-drain.pid" 2>/dev/null || true)
        if [ -n "$drain_pid" ] && kill -0 "$drain_pid" 2>/dev/null; then
            kill "$drain_pid" 2>/dev/null || true
        fi
    fi
    pkill -f "cloudflared tunnel --url http://${NGINX_HOST}:${NGINX_PORT}" 2>/dev/null || true
    rm -f "$PID_FILE"
    rm -f "$STATE_DIR/cloudflared-drain.pid"
    rm -f "$STATE_DIR/cloudflared.pipe"
}

start_tunnel() {
    require_cmd cloudflared
    mkdir -p "$STATE_DIR" "$SUB_DIR"
    stop_tunnel
    local fifo line drain_pid
    fifo="$STATE_DIR/cloudflared.pipe"
    rm -f "$fifo"
    mkfifo "$fifo"
    : > "$TUNNEL_LOG"
    cloudflared tunnel --url "http://${NGINX_HOST}:${NGINX_PORT}" > "$fifo" 2>&1 &
    local pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"

    info "cloudflared PID: $pid，等待分配临时域名..."
    local timeout=30
    domain_name=""
    exec 3< "$fifo"
    while [ "$timeout" -gt 0 ]; do
        if IFS= read -r -t 1 line <&3; then
            printf '%s\n' "$line" >> "$TUNNEL_LOG"
            domain_name=$(printf '%s\n' "$line" | sed -nE 's/.*https:\/\/([[:alnum:].-]+trycloudflare\.com).*/\1/p' | head -n 1)
            [ -n "$domain_name" ] && break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            exec 3<&-
            err "cloudflared 已退出，请查看 $TUNNEL_LOG"
            exit 1
        fi
        timeout=$((timeout - 1))
    done

    if [ -z "$domain_name" ]; then
        exec 3<&-
        kill "$pid" 2>/dev/null || true
        err "未能获取临时隧道域名，请查看 $TUNNEL_LOG"
        exit 1
    fi
    cat "$fifo" >/dev/null &
    drain_pid=$!
    exec 3<&-
    printf '%s\n' "$drain_pid" > "$STATE_DIR/cloudflared-drain.pid"
    printf '%s\n' "$domain_name" > "$DOMAIN_FILE"
    ok "临时隧道域名: $domain_name"
}

write_state() {
    {
        printf 'UUID=%q\n' "$uuid"
        printf 'PUBLIC_IP=%q\n' "$public_ip"
        printf 'COUNTRY_CODE=%q\n' "$country_code"
        printf 'COUNTRY_FLAG=%q\n' "$country_flag"
        printf 'COLO_CODE=%q\n' "$colo_code"
        printf 'NODE_PREFIX=%q\n' "$node_prefix"
        printf 'CURRENT_TIME=%q\n' "$current_time"
        printf 'MAIN_PORT=%q\n' "$MAIN_PORT"
        printf 'SECOND_PORT=%q\n' "$SECOND_PORT"
        printf 'VMESS_PORT=%q\n' "$VMESS_PORT"
        printf 'NGINX_PORT=%q\n' "$NGINX_PORT"
        printf 'SUBSCRIPTION_PATH_UUID=%q\n' "$subscription_path_uuid"
        printf 'PUBLIC_KEY_REALITY=%q\n' "$public_key_reality"
        printf 'SHORT_ID=%q\n' "$short_id"
        printf 'CONFIG_ECH=%q\n' "$config_ech"
        printf 'OUTBOUND_MODE=%q\n' "$outbound_mode"
    } > "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || { err "未找到状态文件 $STATE_FILE，请先运行完整安装。"; exit 1; }
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    uuid="$UUID"
    public_ip="$PUBLIC_IP"
    country_code="$COUNTRY_CODE"
    country_flag="$COUNTRY_FLAG"
    colo_code="$COLO_CODE"
    node_prefix="$NODE_PREFIX"
    current_time="$CURRENT_TIME"
    MAIN_PORT="$MAIN_PORT"
    SECOND_PORT="$SECOND_PORT"
    VMESS_PORT="$VMESS_PORT"
    NGINX_PORT="$NGINX_PORT"
    subscription_path_uuid="$SUBSCRIPTION_PATH_UUID"
    public_key_reality="$PUBLIC_KEY_REALITY"
    short_id="$SHORT_ID"
    config_ech="$CONFIG_ECH"
    outbound_mode="$OUTBOUND_MODE"
}

write_subscription_files() {
    mkdir -p "$SUB_DIR"
    local provider_name link_host ech_link hy_name re_name an_name tu_name argo_name
    provider_name="$node_prefix"
    link_host=$(format_link_host "$public_ip")
    ech_link=$(url_encode "$config_ech")
    hy_name=$(url_encode "${provider_name} HY")
    re_name=$(url_encode "${provider_name} RE")
    an_name=$(url_encode "${provider_name} AN")
    tu_name=$(url_encode "${provider_name} TU")
    argo_name=$(url_encode "${provider_name} ARGO")

    cat > "$SUB_DIR/${current_time}.yaml" <<EOF
proxies:
- name: "${provider_name} HY"
  type: hysteria2
  server: $public_ip
  port: $MAIN_PORT
  obfs: salamander
  obfs-password: $uuid
  password: $uuid
  tls: true
  ech-opts: {enable: true, config: $config_ech}
  sni: $CERTIFICATE_NAME
  alpn: [h3]
- name: "${provider_name} TU"
  type: tuic
  server: $public_ip
  port: $SECOND_PORT
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
  sni: $CERTIFICATE_NAME
  ech-opts: {enable: true, config: $config_ech}
- name: "${provider_name} RE"
  type: vless
  server: $public_ip
  port: $MAIN_PORT
  uuid: $uuid
  client-fingerprint: chrome
  network: tcp
  tls: true
  flow: xtls-rprx-vision
  servername: $REALITY_DOMAIN
  reality-opts: {public-key: $public_key_reality, short-id: $short_id}
  encryption: none
- name: "${provider_name} AN"
  type: anytls
  server: $public_ip
  port: $SECOND_PORT
  password: $uuid
  client-fingerprint: chrome
  tls: true
  ech-opts: {enable: true, config: $config_ech}
  sni: $CERTIFICATE_NAME
  alpn: [h2]
- name: "${provider_name} ARGO"
  type: vmess
  server: $domain_name
  port: 443
  uuid: $uuid
  alterId: 0
  cipher: auto
  network: ws
  tls: true
  servername: $domain_name
  ws-opts:
    path: /$uuid-vm
    headers:
      Host: $domain_name
EOF

    cat > "$SUB_DIR/${current_time}.txt" <<EOF
tuic://${uuid}:${uuid}@${link_host}:${SECOND_PORT}?sni=${CERTIFICATE_NAME}&alpn=h3&congestion_control=bbr&udp_relay_mode=native&ech=${ech_link}#${tu_name}
anytls://${uuid}@${link_host}:${SECOND_PORT}?security=tls&sni=${CERTIFICATE_NAME}&fp=chrome&alpn=h2&ech=${ech_link}#${an_name}
hysteria2://${uuid}@${link_host}:${MAIN_PORT}?security=tls&sni=${CERTIFICATE_NAME}&alpn=h3&obfs=salamander&obfs-password=${uuid}&ech=${ech_link}#${hy_name}
vless://${uuid}@${link_host}:${MAIN_PORT}?encryption=none&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${public_key_reality}&sid=${short_id}&spx=%2F&type=tcp&flow=xtls-rprx-vision#${re_name}
vmess://$(printf '{"v":"2","ps":"%s ARGO","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/%s-vm","tls":"tls","sni":"%s"}' "$provider_name" "$domain_name" "$uuid" "$domain_name" "$uuid" "$domain_name" | base64 | tr -d '\n')
EOF

    if curl -fsSL --max-time 15 "$CLIENT_TEMPLATE_URL" -o "$SUB_DIR/config.yaml"; then
        printf '\n' >> "$SUB_DIR/config.yaml"
    else
        warn "默认客户端模板下载失败，使用最小模板。"
        cat > "$SUB_DIR/config.yaml" <<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${provider_name} ARGO"
rules:
  - MATCH,PROXY
EOF
    fi
    cat "$SUB_DIR/${current_time}.yaml" >> "$SUB_DIR/config.yaml"

    write_client_sing_box_config
    write_readme
}

write_client_sing_box_config() {
    python3 - "$SUB_DIR/client-sing-box.json" "$uuid" "$public_ip" "$MAIN_PORT" "$SECOND_PORT" "$domain_name" \
        "$CERTIFICATE_NAME" "$REALITY_DOMAIN" "$public_key_reality" "$short_id" "$config_ech" "$node_prefix" <<'PY'
import json
import sys

(
    path,
    uuid,
    public_ip,
    main_port,
    second_port,
    domain,
    cert_name,
    reality_domain,
    public_key,
    short_id,
    ech_config,
    node_prefix,
) = sys.argv[1:13]

ech = {
    "enabled": True,
    "config": [
        "-----BEGIN ECH CONFIGS-----",
        ech_config,
        "-----END ECH CONFIGS-----",
    ],
}

outbounds = [
    {"type": "direct", "tag": "direct"},
    {"type": "selector", "tag": "PROXY", "outbounds": [
        f"{node_prefix} ARGO",
        f"{node_prefix} HY",
        f"{node_prefix} TU",
        f"{node_prefix} RE",
        f"{node_prefix} AN",
    ]},
    {
        "type": "vmess",
        "tag": f"{node_prefix} ARGO",
        "server": domain,
        "server_port": 443,
        "uuid": uuid,
        "security": "auto",
        "alter_id": 0,
        "tls": {"enabled": True, "server_name": domain},
        "transport": {"type": "ws", "path": f"/{uuid}-vm", "headers": {"Host": domain}},
    },
    {
        "type": "hysteria2",
        "tag": f"{node_prefix} HY",
        "server": public_ip,
        "server_port": int(main_port),
        "password": uuid,
        "obfs": {"type": "salamander", "password": uuid},
        "tls": {"enabled": True, "server_name": cert_name, "ech": ech},
    },
    {
        "type": "tuic",
        "tag": f"{node_prefix} TU",
        "server": public_ip,
        "server_port": int(second_port),
        "uuid": uuid,
        "password": uuid,
        "congestion_control": "bbr",
        "tls": {"enabled": True, "server_name": cert_name, "alpn": ["h3"], "ech": ech},
    },
    {
        "type": "vless",
        "tag": f"{node_prefix} RE",
        "server": public_ip,
        "server_port": int(main_port),
        "uuid": uuid,
        "flow": "xtls-rprx-vision",
        "tls": {
            "enabled": True,
            "server_name": reality_domain,
            "utls": {"enabled": True, "fingerprint": ""},
            "reality": {"enabled": True, "public_key": public_key, "short_id": short_id},
        },
    },
    {
        "type": "anytls",
        "tag": f"{node_prefix} AN",
        "server": public_ip,
        "server_port": int(second_port),
        "password": uuid,
        "tls": {"enabled": True, "server_name": cert_name, "alpn": ["h2"], "ech": ech},
    },
]

config = {
    "log": {"level": "info"},
    "experimental": {
        "cache_file": {
            "enabled": true
        },
        "clash_api": {
            "external_controller": "127.0.0.1:9090",
            "secret": uuid
        }
    },
    "dns": {
        "servers": [
            {
                "tag": "dns_proxy",
                "type": "https",
                "server": "1.1.1.1",
                "path": "/dns-query",
                "detour": "PROXY",
            },
            {
                "tag": "dns_direct",
                "type": "https",
                "server": "223.5.5.5",
                "path": "/dns-query",
            },
            {
                "tag": "dns_local",
                "type": "udp",
                "server": "223.5.5.5",
            },
        ],
        "rules": [{"rule_set": ["geosite-cn"], "server": "dns_direct"}],
        "final": "dns_proxy",
        "strategy": "prefer_ipv4",
    },
    "route": {
        "rule_set": [
            {
                "tag": "geoip-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",
                "update_interval": "1d",
            },
            {
                "tag": "geosite-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs",
                "update_interval": "1d",
            },
        ],
        "rules": [
            {"action": "sniff"},
            {"protocol": "dns", "action": "hijack-dns"},
            {
                "rule_set": ["geoip-cn", "geosite-cn"],
                "action": "route",
                "outbound": "direct",
            },
        ],
        "final": "PROXY",
        "auto_detect_interface": True,
        "override_android_vpn": True,
        "default_domain_resolver": "dns_local",
    },
    "inbounds": [
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "::",
            "listen_port": 7890,
            "set_system_proxy": False,
        },
        {
            "type": "tun",
            "address": [
                "172.19.0.1/30",
                "fdfe:dcba:9876::1/126",
            ],
            "auto_route": True,
            "auto_redirect": True,
            "strict_route": True,
        },
    ],
    "outbounds": outbounds,
}

with open(path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

write_readme() {
    cat > "$README_FILE" <<EOF
-----------------------------------
临时隧道域名:
$domain_name

Clash/Mihomo 订阅:
https://${domain_name}/${subscription_path_uuid}/config.yaml

原始 provider:
https://${domain_name}/${subscription_path_uuid}/${current_time}.yaml

分享链接:
https://${domain_name}/${subscription_path_uuid}/${current_time}.txt

客户端 sing-box 配置:
https://${domain_name}/${subscription_path_uuid}/client-sing-box.json

直连服务端口:
HY2/VLESS Reality=$MAIN_PORT
AnyTLS/TUIC=$SECOND_PORT

VMess WS 后端:
${VMESS_HOST}:${VMESS_PORT}
WS path=/${uuid}-vm

临时隧道进程:
PID 文件: $PID_FILE
域名文件: $DOMAIN_FILE
日志文件: $TUNNEL_LOG

如域名失效或进程退出，运行:
$SCRIPT_NAME -tunnel res
-----------------------------------
EOF
}

refresh_domain_in_files() {
    local old_domain
    old_domain=$(cat "$DOMAIN_FILE" 2>/dev/null || true)
    start_tunnel
    if [ -n "$old_domain" ] && [ "$old_domain" != "$domain_name" ]; then
        python3 - "$SUB_DIR" "$old_domain" "$domain_name" <<'PY'
import pathlib
import sys

sub_dir, old_domain, new_domain = sys.argv[1:4]
for path in pathlib.Path(sub_dir).iterdir():
    if path.suffix not in {".yaml", ".txt", ".json"} or not path.is_file():
        continue
    text = path.read_text(encoding="utf-8")
    path.write_text(text.replace(old_domain, new_domain), encoding="utf-8")
PY
    fi
    write_readme
    cat "$README_FILE"
}

disable_service() {
    local service_name="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$service_name" 2>/dev/null || true
        systemctl disable "$service_name" 2>/dev/null || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$service_name" stop 2>/dev/null || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del "$service_name" default 2>/dev/null || true
    fi
}

uninstall_all() {
    require_root
    select_nginx_config
    info "正在停止脚本创建的服务和进程..."
    stop_tunnel
    disable_service sing-box

    info "正在删除脚本创建的配置和订阅文件..."
    rm -f "$CONFIG_FILE"
    rm -rf "$CERT_DIR"
    rm -rf "$SUB_DIR"
    rmdir "$SUB_ROOT" 2>/dev/null || true
    rm -rf "$STATE_DIR"
    rm -f "$NGINX_CONFIG"

    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && {
            if command -v systemctl >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || true
            elif command -v rc-service >/dev/null 2>&1; then
                rc-service nginx reload 2>/dev/null || true
            fi
        }
    fi

    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "$CERT_BASE_URL/$CERTIFICATE_NAME" | crontab - 2>/dev/null || true
    fi

    ok "卸载清理完成。未删除 sing-box、cloudflared、nginx 包或二进制。"
}

install_all() {
    require_root
    require_curl
    parse_inserver_info
    detect_public_ip
    prompt_main_ports
    install_runtime_dependencies python3
    install_sing_box
    install_cloudflared
    install_nginx
    download_certificates
    generate_materials
    write_sing_box_config
    start_sing_box
    write_nginx_config
    start_nginx
    start_tunnel
    write_subscription_files
    write_state
    setup_certificate_cron

    show_help
    cat "$README_FILE"
}

install_ouserver() {
    require_root
    require_curl
    detect_public_ip
    prompt_ouserver_port
    install_runtime_dependencies python3
    install_sing_box
    write_ouserver_config
    start_sing_box

    local node_info install_command
    node_info="vless ${public_ip} ${MAIN_PORT} ${uuid}"
    install_command="curl -fsSL ${SCRIPT_DOWNLOAD_URL} | bash -s -- -inserver \"${node_info}\""

    printf '%s\n' "${BOLD}${GREEN}出口节点关键信息:${RESET}"
    printf '%s\n' "$node_info"
    printf '\n%s\n' "${BOLD}${GREEN}在另一台设备上复制粘贴这条命令即可安装并配置出站:${RESET}"
    printf '%s\n' "$install_command"
    printf '\n%s\n' "完整节点配置已写入: $SUB_DIR/ouserver.json"
}

main() {
    case "${1:-}" in
        -h|-help|--help|help)
            show_help
            exit 0
            ;;
        -pkg)
            require_root
            case "${2:-}" in
                cloudflared) require_curl; install_cloudflared ;;
                sing-box) require_curl; install_sing_box ;;
                *) err "-pkg 仅支持 cloudflared、sing-box"; exit 1 ;;
            esac
            exit 0
            ;;
        -ouserver)
            install_ouserver
            exit 0
            ;;
        -inserver)
            if [ -z "${2:-}" ]; then
                err "-inserver 需要 Node information，例如: -inserver \"vless 1.2.3.4 12345 uuid\""
                exit 1
            fi
            inserver_info="$2"
            install_all
            exit 0
            ;;
        -tunnel)
            case "${2:-}" in
                res)
                    require_root
                    load_state
                    refresh_domain_in_files
                    exit 0
                    ;;
                *) err "-tunnel 仅支持 res"; exit 1 ;;
            esac
            ;;
        -uninstall)
            uninstall_all
            exit 0
            ;;
        "")
            install_all
            ;;
        *)
            err "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
