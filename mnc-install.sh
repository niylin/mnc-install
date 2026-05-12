#!/usr/bin/env bash

PROXY_NAME="${PROXY_NAME:-warp-masque}"
DEVICE_NAME="${DEVICE_NAME:-mihomo-masque}"
USQUE_CONFIG="${USQUE_CONFIG:-/etc/mihomo/usque-config.json}"
MASQUE_SERVER="${MASQUE_SERVER:-masque.wdqgn.eu.org}"
USQUE_REPO="${USQUE_REPO:-Diniboy1123/usque}"
USQUE_INSTALL_DIR="${USQUE_INSTALL_DIR:-/usr/local/bin}"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：请使用 root 权限运行此脚本。"
        exit 1
    fi
}

uninstall_all() {
    echo "开始清理 mnc-install.sh 及关联脚本创建的内容..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop mihomo 2>/dev/null || true
        systemctl disable mihomo 2>/dev/null || true
        systemctl stop nginx 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service mihomo stop 2>/dev/null || true
        rc-service nginx stop 2>/dev/null || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del mihomo default 2>/dev/null || true
    fi

    rm -f /etc/systemd/system/mihomo.service
    rm -f /etc/init.d/mihomo
    rm -f /usr/local/bin/mihomo
    rm -f "$USQUE_INSTALL_DIR/usque"
    rm -f "$USQUE_CONFIG"
    rm -f /etc/mihomo/config.yaml
    rm -f /etc/mihomo/config.yaml.bak.*
    rm -f /etc/nginx/conf.d/subscription.conf
    rm -rf /opt/www/convertio
    rm -f /opt/www/convertio.tar.xz
    rm -f /opt/www/sub/config.yaml
    rm -f /opt/www/sub/README.txt
    rm -f /opt/www/sub/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].yaml
    rm -f /opt/www/sub/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].txt

    mkdir -p /etc/mihomo/cert /etc/nginx/conf.d /opt/www/sub

    echo "清理完成。"
    exit 0
}
stop_services() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop apache2 httpd caddy 2>/dev/null || true
        systemctl stop apache2.socket httpd.socket caddy.socket 2>/dev/null || true

        systemctl disable apache2 httpd caddy 2>/dev/null || true
        systemctl disable apache2.socket httpd.socket caddy.socket 2>/dev/null || true
    else
        rc-service apache2 stop 2>/dev/null || true
        rc-service httpd stop 2>/dev/null || true
        rc-service caddy stop 2>/dev/null || true
    fi
}

generate_vless_config() {
cat <<EOF
- name: "${proxy_name}|${current_time}"
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
  ws-opts: {path: /$uuid-vl, headers: {host: $Certificate_name}}
  encryption: $client_encryption
EOF
}
generate_vless_server_config() {
cat <<EOF
- name: vless-ws-in
  type: vless
  listen: 127.0.0.1
  port: 58996
  users:
    - username: 1
      uuid: $uuid
      flow: xtls-rprx-vision
  decryption: $server_decryption
  ws-path: /$uuid-vl
EOF
}
port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltnu "( sport = :$port )" | grep -q .
    else
        echo "警告：未检测到 ss，跳过端口 $port 占用检查。"
        return 1
    fi
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
warp_log() {
    printf '[+] %s\n' "$*" >&2
}
warp_die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}
warp_need_cmd() {
    command -v "$1" >/dev/null 2>&1 || warp_die "缺少命令：$1"
}
warp_detect_platform() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    case "$os" in
        linux|darwin) ;;
        *) warp_die "当前系统不支持：$os" ;;
    esac

    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7*) arch="armv7" ;;
        armv6l|armv6*) arch="armv6" ;;
        armv5l|armv5*) arch="armv5" ;;
        *) warp_die "当前架构不支持：$arch" ;;
    esac

    printf '%s %s\n' "$os" "$arch"
}
warp_install_usque_from_github() {
    warp_need_cmd find
    warp_need_cmd install

    local os arch work_dir meta_file archive asset_url asset_name bin target
    read -r os arch < <(warp_detect_platform)
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/usque-install.XXXXXX")
    trap 'rm -rf "$work_dir"' RETURN

    meta_file="$work_dir/release.json"
    archive="$work_dir/usque-release"
    target="$USQUE_INSTALL_DIR/usque"

    warp_log "未检测到 usque，正在从 GitHub 安装"
    curl -fsSL "https://api.github.com/repos/${USQUE_REPO}/releases/latest" -o "$meta_file"

    read -r asset_url asset_name < <(python3 - "$meta_file" "$os" "$arch" <<'PY'
import json
import sys

release_path, os_name, arch_name = sys.argv[1:4]
os_aliases = {
    "linux": ("linux",),
    "darwin": ("darwin", "macos", "osx"),
}.get(os_name, (os_name,))
arch_aliases = {
    "amd64": ("amd64", "x86_64", "x64"),
    "arm64": ("arm64", "aarch64"),
    "armv7": ("armv7", "armv7l", "armhf"),
    "armv6": ("armv6", "armv6l"),
    "armv5": ("armv5", "armv5l"),
}.get(arch_name, (arch_name,))

with open(release_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

matches = []
for asset in data.get("assets", []):
    name = asset.get("name", "")
    lower = name.lower()
    url = asset.get("browser_download_url", "")
    if not url:
        continue
    if not any(alias in lower for alias in os_aliases):
        continue
    if not any(alias in lower for alias in arch_aliases):
        continue
    if any(x in lower for x in ("sha256", "checksums", ".sig", ".pem")):
        continue
    matches.append((url, name))

if not matches:
    names = ", ".join(asset.get("name", "") for asset in data.get("assets", []))
    raise SystemExit(f"未找到匹配 {os_name}/{arch_name} 的 usque release asset。可用 assets: {names}")

matches.sort(key=lambda item: (0 if item[1].lower().endswith((".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".zip")) else 1, item[1]))
print(matches[0][0], matches[0][1])
PY
)
    [ -n "$asset_url" ] || warp_die "未能解析 usque 下载地址"

    warp_log "下载 $asset_name"
    curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$archive" "$asset_url"

    mkdir -p "$work_dir/extract"
    case "$asset_name" in
        *.tar.gz|*.tgz)
            warp_need_cmd tar
            tar -xzf "$archive" -C "$work_dir/extract"
            ;;
        *.tar.xz|*.txz)
            warp_need_cmd tar
            tar -xJf "$archive" -C "$work_dir/extract"
            ;;
        *.tar.bz2|*.tbz2)
            warp_need_cmd tar
            tar -xjf "$archive" -C "$work_dir/extract"
            ;;
        *.zip)
            warp_need_cmd unzip
            unzip -q "$archive" -d "$work_dir/extract"
            ;;
        *)
            cp "$archive" "$work_dir/extract/usque"
            ;;
    esac

    bin=$(find "$work_dir/extract" -type f \( -name usque -o -name usque.exe \) -print -quit)
    [ -n "$bin" ] || warp_die "压缩包中没有找到 usque 二进制文件"

    mkdir -p "$USQUE_INSTALL_DIR"
    [ -w "$USQUE_INSTALL_DIR" ] || warp_die "$USQUE_INSTALL_DIR 不可写，请用 root 运行或设置 USQUE_INSTALL_DIR 指向可写目录"
    install -m 0755 "$bin" "$target"
    warp_log "已安装 usque 到 $target"
    printf '%s\n' "$target"
}
warp_register_masque_account() {
    local usque_bin="$1"
    local usque_config="$2"
    local help_text
    local args=("--config" "$usque_config" "register" "-n" "$DEVICE_NAME")

    mkdir -p "$(dirname "$usque_config")"
    rm -f "$usque_config"
    help_text=$("$usque_bin" register --help 2>&1 || true)
    if grep -q -- '--accept-tos' <<<"$help_text"; then
        args+=("--accept-tos")
    elif grep -Eq -- '--accept.*tos' <<<"$help_text"; then
        args+=("--accept-tos")
    fi

    warp_log "使用 usque 注册 MASQUE 账户"
    "$usque_bin" "${args[@]}" </dev/null

    [ -s "$usque_config" ] || warp_die "usque 未生成配置文件：$usque_config"
}
warp_build_mihomo_proxy() {
    local usque_config="$1"

    python3 - "$usque_config" "$PROXY_NAME" "$MASQUE_SERVER" <<'PY'
import json
import re
import sys

config_path, proxy_name, masque_server = sys.argv[1:4]
with open(config_path, "r", encoding="utf-8") as fh:
    cfg = json.load(fh)

def require(key):
    value = cfg.get(key)
    if not value:
        raise SystemExit(f"usque config 缺少字段：{key}")
    return value

def public_key_from_pem(value):
    value = re.sub(r"-----BEGIN PUBLIC KEY-----", "", value)
    value = re.sub(r"-----END PUBLIC KEY-----", "", value)
    return "".join(value.split())

private_key = require("private_key")
public_key = public_key_from_pem(require("endpoint_pub_key"))
ipv4 = require("ipv4")
ipv6 = cfg.get("ipv6", "")

if "/" not in ipv4:
    ipv4 = f"{ipv4}/32"
if ipv6 and "/" not in ipv6:
    ipv6 = f"{ipv6}/128"

lines = [
    f"- name: {proxy_name}",
    "  type: masque",
    f"  server: {masque_server}",
    "  port: 443",
    f"  private-key: {private_key}",
    f"  public-key: {public_key}",
    f"  ip: {ipv4}",
]
if ipv6:
    lines.append(f"  ipv6: {ipv6}")
lines.extend([
    "  mtu: 1280",
    "  udp: true",
    "  congestion-controller: bbr",
])

print("\n".join(lines))
PY
}
warp_update_mihomo_config() {
    local proxy_yaml="$1"

    [ -f "$CONFIG_FILE" ] || warp_die "配置文件不存在：$CONFIG_FILE"
    [ -w "$CONFIG_FILE" ] || warp_die "配置文件不可写：$CONFIG_FILE"

    local backup="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup"
    warp_log "已备份配置到 $backup"

    PROXY_YAML="$proxy_yaml" python3 - "$CONFIG_FILE" "$PROXY_NAME" <<'PY'
import os
import re
import sys

config_path, proxy_name = sys.argv[1:3]
with open(config_path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()
proxy_lines = os.environ["PROXY_YAML"].splitlines(True)
if proxy_lines and not proxy_lines[-1].endswith("\n"):
    proxy_lines[-1] += "\n"

item_re = re.compile(r'^\s*-\s+name:\s*["\']?' + re.escape(proxy_name) + r'["\']?\s*$')

def remove_existing_proxy(src):
    out = []
    in_proxies = False
    skipping = False
    for line in src:
        top_level = bool(re.match(r'^[A-Za-z0-9_.-]+:\s*', line))
        if re.match(r'^proxies:\s*$', line):
            in_proxies = True
            skipping = False
            out.append(line)
            continue
        if in_proxies and top_level:
            in_proxies = False
            skipping = False
        if in_proxies and item_re.match(line):
            skipping = True
            continue
        if skipping:
            starts_next_item = bool(re.match(r'^\s*-\s+name:\s*', line))
            if top_level or starts_next_item:
                skipping = False
            else:
                continue
        out.append(line)
    return out

lines = remove_existing_proxy(lines)

proxies_idx = None
for idx, line in enumerate(lines):
    if re.match(r'^proxies:\s*$', line):
        proxies_idx = idx
        break

if proxies_idx is None:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    if lines and lines[-1].strip():
        lines.append("\n")
    lines.append("proxies:\n")
    lines.extend(proxy_lines)
else:
    insert_at = len(lines)
    for idx in range(proxies_idx + 1, len(lines)):
        if re.match(r'^[A-Za-z0-9_.-]+:\s*', lines[idx]):
            insert_at = idx
            break
    if insert_at > 0 and lines[insert_at - 1].strip():
        proxy_lines = ["\n"] + proxy_lines
    lines[insert_at:insert_at] = proxy_lines

with open(config_path, "w", encoding="utf-8") as fh:
    fh.writelines(lines)
PY

    warp_log "已更新 $CONFIG_FILE，已写入 $PROXY_NAME 出站节点"
}
warp_register_mihomo() {
    install_runtime_dependencies
    warp_need_cmd python3

    local usque_bin proxy_yaml
    usque_bin=$(command -v usque || true)
    if [ -z "$usque_bin" ]; then
        usque_bin=$(warp_install_usque_from_github)
    fi

    warp_register_masque_account "$usque_bin" "$USQUE_CONFIG"
    proxy_yaml=$(warp_build_mihomo_proxy "$USQUE_CONFIG")
    warp_update_mihomo_config "$proxy_yaml"
}
install_mihomo_dependencies() {
    local base_pkgs="curl gzip"

    if command -v curl >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
        echo "[+] mihomo 安装依赖已存在，跳过依赖安装。"
        return
    fi

    echo "[+] 正在安装 mihomo 下载依赖..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y $base_pkgs
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $base_pkgs
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $base_pkgs || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm $base_pkgs
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache $base_pkgs
    else
        echo "错误：无法识别包管理器，请手动安装 curl gzip。"
        exit 1
    fi
}
install_runtime_dependencies() {
    local pkgs="curl gzip python3 unzip"

    if command -v curl >/dev/null 2>&1 \
        && command -v gzip >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1 \
        && command -v unzip >/dev/null 2>&1; then
        return
    fi

    echo "[+] 正在安装运行依赖..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y $pkgs
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm $pkgs
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache $pkgs
    else
        echo "错误：无法识别包管理器，请手动安装 curl gzip python3 unzip。"
        exit 1
    fi
}
install_mihomo_service() {
    mkdir -p /etc/mihomo

    if command -v systemctl >/dev/null 2>&1; then
cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    elif [ -d /etc/init.d ] && command -v rc-status >/dev/null 2>&1; then
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

start_pre() {
    sleep 1
}
EOF
        chmod +x /etc/init.d/mihomo
        rc-update add mihomo default
    else
        echo "未检测到 systemd 或 OpenRC，请手动创建 mihomo 服务。"
    fi
}
install_mihomo() {
    install_mihomo_dependencies

    local arch bin_arch cpu_flags level latest_version file_name download_url
    arch=$(uname -m)
    case "$arch" in
        x86_64) bin_arch="amd64" ;;
        aarch64|arm64) bin_arch="arm64" ;;
        armv7l) bin_arch="armv7" ;;
        armv6l) bin_arch="armv6" ;;
        *)
            echo "错误：不支持的架构：$arch"
            exit 1
            ;;
    esac

    cpu_flags=$(grep flags /proc/cpuinfo 2>/dev/null | head -n1)
    if [[ "$cpu_flags" =~ avx2 ]]; then
        level="v3"
    elif [[ "$cpu_flags" =~ avx ]]; then
        level="v2"
    else
        level="v1"
    fi

    echo "[+] 检测到 架构=$arch 可执行=$bin_arch 指令集等级=$level"

    if ! command -v mihomo >/dev/null 2>&1; then
        echo "[+] 正在安装 mihomo..."
        latest_version=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$latest_version" ]; then
            echo "错误：无法获取 mihomo 最新版本号。"
            exit 1
        fi

        if [ "$bin_arch" = "amd64" ]; then
            file_name="mihomo-linux-${bin_arch}-${level}-${latest_version}.gz"
        else
            file_name="mihomo-linux-${bin_arch}-${latest_version}.gz"
        fi
        download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${file_name}"

        echo "[+] 正在下载 ${file_name}..."
        if ! curl -fsSL -o /tmp/mihomo.gz "$download_url"; then
            echo "[!] 对应构建下载失败，尝试 compatible 版本..."
            file_name="mihomo-linux-${bin_arch}-compatible-${latest_version}.gz"
            download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${file_name}"
            curl -fsSL -o /tmp/mihomo.gz "$download_url" || {
                echo "错误：mihomo 下载失败。"
                exit 1
            }
        fi

        gzip -df /tmp/mihomo.gz
        chmod +x /tmp/mihomo
        mv /tmp/mihomo /usr/local/bin/mihomo
        echo "[+] mihomo 安装完成。"
    else
        echo "[+] 已检测到 mihomo，跳过二进制安装。"
    fi

    install_mihomo_service
}
show_help() {
cat <<EOF
用法: $0 [参数]

不带参数:
  交互式安装 mihomo、nginx、入站配置、订阅文件，可选择配置 WARP MASQUE 出站。

参数:
  -h, --help       显示此帮助信息
  -uninstall       清理脚本创建的服务、配置、订阅文件，并删除 mihomo/usque 二进制
  -warpreg         只注册 WARP MASQUE 账户，并把 warp-masque 出站写入 /etc/mihomo/config.yaml
  -mihomo          只安装 mihomo 二进制和 mihomo 服务文件
  -migomo          同 -mihomo，兼容拼写

可通过环境变量覆盖:
  CONFIG_FILE            默认 /etc/mihomo/config.yaml
  USQUE_INSTALL_DIR      默认 /usr/local/bin
  USQUE_CONFIG           默认 /etc/mihomo/usque-config.json
  MASQUE_SERVER          默认 masque.wdqgn.eu.org
EOF
}

case "${1:-}" in
    -h|--help|help)
        show_help
        exit 0
        ;;
    -uninstall)
        require_root
        uninstall_all
        ;;
    -warpreg)
        require_root
        CONFIG_FILE="${CONFIG_FILE:-/etc/mihomo/config.yaml}"
        (set -e; warp_register_mihomo)
        exit $?
        ;;
    -mihomo|-migomo)
        require_root
        install_mihomo
        exit 0
        ;;
    "")
        ;;
    *)
        echo "错误：未知参数 $1"
        show_help
        exit 1
        ;;
esac

require_root

echo "脚本将安装 mihomo，并配置 hysteria,tuic，anytls,vless,trusttunnel,mieru 等协议的入站"
echo "建议在使用apt和apk包管理器的系统中运行,其他系统未经测试,包名不同可能导致安装依赖失败"
echo "生成的客户端配置中，ip地址将配置为当前服务器的出站IP，如果出站和入站IP不同，请手动修改客户端配置文件"
echo "部分128MB RAM的系统,安装nginx可能会失败,可手动安装nginx以及stream模块后重新运行脚本"

read -p "使用IPv6输入6,默认IPv4: " ip_type_choice < /dev/tty
    ip_type_choice=${ip_type_choice:-4}
read -rp "是否要配置 Warp 节点出站? y 配置,其他跳过 " warp_choice < /dev/tty

read -p "输入主入站端口,默认443: " select_port < /dev/tty
select_port=${select_port:-443}

# 验证主端口数字有效性
while ! [[ "$select_port" =~ ^[0-9]+$ ]] || [ "$select_port" -lt 1 ] || [ "$select_port" -gt 65533 ]; do
    echo "错误：请输入有效的端口号数字 (1-65533)。"
    read -p "重新输入主入站端口: " select_port < /dev/tty
done

# 2. 根据主端口生成后续端口
if [ "$select_port" -eq 443 ]; then
    TU_SELECT_PORT=2053
else
    TU_SELECT_PORT=$((select_port + 1))
fi

# 3. 统一检查所有端口是否被占用
for port in "$select_port" "$TU_SELECT_PORT"; do
    if port_in_use "$port"; then
        echo "错误：端口 $port 已被占用，请重新运行脚本并选择其他端口。"
        exit 1
    fi
done
read -r -p "输入y使用自定义证书,其他使用默认: " cert_choice < /dev/tty

current_time=$(TZ=UTC-8 date +"%Y%m%d-%H%M%S")
mkdir -p /etc/mihomo/cert

if [[ "$cert_choice" =~ ^[yY]$ ]]; then
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
else
    Certificate_name="${current_time}.nauk.eu.cc"
    CERT_NAME="nauk.eu.cc"
fi
stop_services
# 依赖安装
PKGS="curl gzip nginx python3 unzip"

if command -v apt >/dev/null 2>&1; then
     apt update
     apt install -y $PKGS libnginx-mod-stream
elif command -v dnf >/dev/null 2>&1; then
     dnf install -y $PKGS nginx-mod-stream
elif command -v yum >/dev/null 2>&1; then
     yum install -y $PKGS nginx-mod-stream
elif command -v pacman >/dev/null 2>&1; then
     pacman -Sy --noconfirm $PKGS nginx-mod-stream
elif command -v apk >/dev/null 2>&1; then
     apk add $PKGS nginx-mod-stream
else
    echo "不支持的包管理器"
    exit 1
fi

# 获取IP地址和地理位置
while true; do
    trace_content=$(curl -${ip_type_choice} -s --max-time 5 https://cloudflare.com/cdn-cgi/trace)
    ip_address=$(echo "$trace_content" | grep '^ip=' | cut -d= -f2)
    ip_valid=$(python3 - <<EOF
import ipaddress
try:
    ipaddress.ip_address("$ip_address")
    print(1)
except:
    print(0)
EOF
)

    if [[ "$ip_valid" != "1" ]]; then
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

    proxy_name="${flag} ${colo_code} CF"
    HY_proxy_name=${proxy_name/CF/HY}
    RE_proxy_name=${proxy_name/CF/RE}
    TU_proxy_name=${proxy_name/CF/TU}
    AN_proxy_name=${proxy_name/CF/AN}
    MR_proxy_name=${proxy_name/CF/MR}
    TT_proxy_name=${proxy_name/CF/TT}
    SU_proxy_name=${proxy_name/CF/SU}
    break
done

# mihomo安装和配置
install_mihomo

# 生成密钥
output_x25519=$(mihomo generate vless-x25519)
server_decryption=$(echo "$output_x25519" | awk -F'"' '/\[Server\]/ {print $2}')
client_encryption=$(echo "$output_x25519" | awk -F'"' '/\[Client\]/ {print $2}')

shortId=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
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

output_ech_1=$(mihomo generate ech-keypair cloudflare.com)
config_ech_1=$(echo "$output_ech_1" | awk '/Config:/ {print $2}')
key_ech_1=$(echo "$output_ech_1" \
  | awk '/-----BEGIN ECH KEYS-----/,/-----END ECH KEYS-----/' \
  | sed 's/^Key: //' \
  | sed 's/^/    /')

if [[ "$select_port" == "443" ]]; then
CDN_CHICE=true
VLESS_WS_CONFIG=$(generate_vless_config)
VLESS_WS_SERVER_CONFIG=$(generate_vless_server_config)
ECHO_TIPS="非移动用户自行更换其他优选域名,cf.wdqgn.eu.org只测了移动"
else
CDN_CHICE=false
fi

if [[ "$cert_choice" != "y" && "$cert_choice" != "Y" ]]; then
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
    curl -fsSL -o /etc/mihomo/cert/$CERT_NAME.crt "https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.crt"
    curl -fsSL -o /etc/mihomo/cert/$CERT_NAME.key "https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.key"
    
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null; \
        echo "0 0 * * 0 curl -fsSL -o /etc/mihomo/cert/$CERT_NAME.crt https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.crt"; \
        echo "0 0 * * 0 curl -fsSL -o /etc/mihomo/cert/$CERT_NAME.key https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.key") | crontab -
    else
        echo "未检测到 crontab，请手动设置定时任务更新证书"
        echo "curl -fsSL -o /etc/mihomo/cert/$CERT_NAME.crt https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.crt"
        echo "curl -fsSL -o /etc/mihomo/cert/$CERT_NAME.key https://link.wdqgn.eu.org/nopasswd/cert/$CERT_NAME.key"
    fi
fi



mkdir -p /etc/mihomo
CONFIG_FILE="/etc/mihomo/config.yaml"
cat > "$CONFIG_FILE" <<EOF
external-controller: "127.0.0.1:9090"
secret: "$uuid"
ipv6: true
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
  port: $TU_SELECT_PORT
  listen: 0.0.0.0
  transport: TCP
  users:
    $uuid: $uuid
  user-hint-is-mandatory: true
- name: tuicv5-in
  type: tuic
  port: $TU_SELECT_PORT
  listen: 0.0.0.0
  users:
    $uuid: $uuid
  certificate: /etc/mihomo/cert/$CERT_NAME.crt
  private-key: /etc/mihomo/cert/$CERT_NAME.key
  ech-key: |
$key_ech
  congestion-controller: bbr
  max-idle-time: 15000
  authentication-timeout: 1000
  alpn:
    - h3
  max-udp-relay-packet-size: 1500
$VLESS_WS_SERVER_CONFIG
- name: anytls-in
  type: anytls
  port: 58997
  listen: 127.0.0.1
  users:
    username1: $uuid
  certificate: /etc/mihomo/cert/$CERT_NAME.crt
  private-key: /etc/mihomo/cert/$CERT_NAME.key
  ech-key: |
$key_ech
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
      - $shortId
    server-names:
      - speed.cloudflare.com
- name: trusttunnel-in
  type: trusttunnel
  port: 58999
  listen: 127.0.0.1
  users:
    - username: $uuid
      password: $uuid
  certificate: /etc/mihomo/cert/$CERT_NAME.crt 
  private-key: /etc/mihomo/cert/$CERT_NAME.key 
  ech-key: |
$key_ech_1
  network: [tcp]
  congestion-controller: bbr
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
  masquerade: "file:///opt/www/convertio"
  ech-key: |
$key_ech
proxy-groups:
- name: "DIRECT-OUT"
  type: select
  include-all: true
  proxies:
    - DIRECT
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
        cloudflare-ech.com             anytls;
        speed.cloudflare.com       reality; 
        cloudflare.com          trusttunnel;
        $Certificate_name            website;
        default                 sudoku;
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
        listen $select_port      reuseport;
        listen [::]:$select_port reuseport;
        proxy_pass      \$backend;
        ssl_preread     on;
        # proxy_protocol  on;
    }
}
# END MIHOMO_NGINX_STREAM
"
cp "$NGINX_FILE" "$NGINX_FILE.bak.$(date +%s)"
echo "$APPEND_CONTENT" | tee -a "$NGINX_FILE" > /dev/null
sed -i 's/^[[:space:]]*include[[:space:]]*\/etc\/nginx\/conf\.d\/\*\.conf[[:space:]]*;/# &/' "$NGINX_FILE"
sed -i '/http[[:space:]]*{/a\    include /etc/nginx/conf.d/*.conf;' "$NGINX_FILE"
mv /etc/nginx/conf.d/stream.conf /etc/nginx/conf.d/stream.conf.bak 2>/dev/null
# 创建订阅站点
mkdir -p /etc/nginx/conf.d

cat > /etc/nginx/conf.d/subscription.conf <<EOF
server {
    listen 9999 ssl;
    listen [::]:9999 ssl;

    ssl_certificate /etc/mihomo/cert/$CERT_NAME.crt;
    ssl_certificate_key /etc/mihomo/cert/$CERT_NAME.key;

    server_name $Certificate_name;
    ssl_protocols         TLSv1.3;
    ssl_ecdh_curve        X25519:P-256:P-384:P-521;
    ssl_early_data on;
    ssl_stapling on;
    ssl_stapling_verify on;

    location /$uuid/ {
        alias /opt/www/sub/;
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
        proxy_pass http://127.0.0.1:58996;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }
    location / {
        proxy_pass http://127.0.0.1:9998;
    }
}
EOF
cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 127.0.0.1:9998;
    index index.html index.htm;
    root  /opt/www/convertio;
    error_page 400 = /400.html;
    }
EOF
# 创建warp出站
if [[ "$warp_choice" =~ ^[yY]$ ]]; then
    if (set -e; warp_register_mihomo); then
        echo "WARP 创建成功"
    else
        echo "WARP 创建失败，已跳过"
    fi
fi

# 创建客户端配置文件
mkdir -p /opt/www/sub
cat > /opt/www/sub/${current_time}.yaml <<EOF
proxies:
- name: "${HY_proxy_name}|${current_time}"
  type: hysteria2
  server: $ip_address
  port: $select_port
  password: $uuid
  up: "30 Mbps"
  down: "300 Mbps"
  tls: true
  ech-opts: {enable: true, config: $config_ech}
  sni: $Certificate_name
  alpn: [h3]
- name: "${RE_proxy_name}|${current_time}"
  type: vless
  server: $ip_address
  port: $select_port
  uuid: $uuid
  client-fingerprint: chrome
  network: tcp
  tls: true
  flow: xtls-rprx-vision
  servername: speed.cloudflare.com
  reality-opts: {public-key: $public_key_reality, short-id: $shortId}
- name: "${AN_proxy_name}|${current_time}"
  type: anytls
  server: $ip_address
  port: $select_port
  password: $uuid
  client-fingerprint: chrome
  tls: true
  ech-opts: {enable: true, config: $config_ech}
  idle-session-check-interval: 30
  idle-session-timeout: 30
  min-idle-session: 0
  sni: $Certificate_name
  alpn: [h2, http/1.1]
$VLESS_WS_CONFIG
- name: ${SU_proxy_name}|${current_time}
  type: sudoku
  server: $ip_address
  port: $select_port
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
- name: ${MR_proxy_name}|${current_time}
  type: mieru
  server: $ip_address
  port: $TU_SELECT_PORT
  transport: TCP
  username: $uuid
  password: $uuid
  multiplexing: MULTIPLEXING_LOW
- name: ${TU_proxy_name}|${current_time}
  server: $ip_address
  port: $TU_SELECT_PORT
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
  sni: $Certificate_name
  ech-opts: {enable: true, config: $config_ech}
- name: ${TT_proxy_name}|${current_time}
  type: trusttunnel
  server: $ip_address
  port: $select_port
  username: $uuid
  password: $uuid
  client-fingerprint: chrome
  health-check: true
  ech-opts: {enable: true, config: $config_ech_1}
  sni: $Certificate_name
  alpn: [h2]
  congestion-controller: bbr
EOF

link_host=$(format_link_host "$ip_address")
ech_link=$(url_encode "$config_ech")
ech_link_1=$(url_encode "$config_ech_1")
hy_name=$(url_encode "${HY_proxy_name}|${current_time}")
re_name=$(url_encode "${RE_proxy_name}|${current_time}")
an_name=$(url_encode "${AN_proxy_name}|${current_time}")
su_name=$(url_encode "${SU_proxy_name}|${current_time}")
mr_name=$(url_encode "${MR_proxy_name}|${current_time}")
tu_name=$(url_encode "${TU_proxy_name}|${current_time}")
tt_name=$(url_encode "${TT_proxy_name}|${current_time}")
ws_name=$(url_encode "${proxy_name}|${current_time}")

cat > /opt/www/sub/${current_time}.txt <<EOF
hysteria2://${uuid}@${link_host}:${select_port}?security=tls&sni=${Certificate_name}&alpn=h3&ech=${ech_link}#${hy_name}
vless://${uuid}@${link_host}:${select_port}?encryption=none&security=reality&sni=speed.cloudflare.com&fp=chrome&pbk=${public_key_reality}&sid=${shortId}&spx=%2F&type=tcp&flow=xtls-rprx-vision#${re_name}
anytls://${uuid}@${link_host}:${select_port}?security=tls&sni=${Certificate_name}&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=${ech_link}#${an_name}
sudoku://${uuid}@${link_host}:${select_port}?aead_method=chacha20-poly1305&padding_min=1&padding_max=7&table_type=prefer_ascii&mode=legacy&path=%2F${uuid}&multiplex=auto#${su_name}
mieru://${uuid}:${uuid}@${link_host}:${TU_SELECT_PORT}?transport=tcp&multiplexing=MULTIPLEXING_LOW#${mr_name}
tuic://${uuid}:${uuid}@${link_host}:${TU_SELECT_PORT}?sni=${Certificate_name}&alpn=h3&congestion_control=bbr&udp_relay_mode=native&ech=${ech_link}#${tu_name}
trusttunnel://${uuid}:${uuid}@${link_host}:${select_port}?security=tls&sni=${Certificate_name}&fp=chrome&alpn=h2&ech=${ech_link_1}&congestion_control=bbr#${tt_name}
#分享链接在大多数客户端无法使用,除非其支持相应的协议,并可以配置ech参数
EOF

if [[ "$select_port" == "443" ]]; then
    cat >> /opt/www/sub/${current_time}.txt <<EOF
vless://${uuid}@cf.wdqgn.eu.org:443?encryption=$(url_encode "$client_encryption")&security=tls&type=ws&host=${Certificate_name}&path=%2F${uuid}-vl&fp=chrome&alpn=h2#${ws_name}
EOF
fi

curl -fL --max-time 10 -o /opt/www/convertio.tar.xz https://github.com/niylin/mnc-install/releases/download/nhg/convertio.tar.xz
tar -xf /opt/www/convertio.tar.xz -C /opt/www
curl -fsSL -o /opt/www/sub/config.yaml https://raw.githubusercontent.com/niylin/mnc-install/master/config.yaml
subscription_address=https://${Certificate_name}:${select_port}/$uuid/${current_time}.yaml
snlink_address=https://${Certificate_name}:${select_port}/$uuid/${current_time}.txt
sed -i "s#my-subscription-address#$(printf '%s' "$subscription_address" | sed 's/[\/&]/\\&/g')#g" /opt/www/sub/config.yaml
sed -i "s#password-config#$uuid#g" /opt/www/sub/config.yaml

cat > /opt/www/sub/README.txt <<EOF
------------------------------
生成的clash配置位于 /opt/www/sub/
订阅链接仅支持使用最新mihomo内核的客户端,比如ClashX.Meta和Clash.Meta for Android,其他客户端报错,需根据报错信息删除不支持的节点
定期清理解析记录,清理后订阅链接和CF节点${proxy_name}|${current_time}失效,其他节点不受影响
clash订阅链接地址为,可直接使用 https://$Certificate_name:$select_port/$uuid/config.yaml
snlink分享链接文件为 ${snlink_address}
proxy-providers: 配置
${current_time}: {type: http, url: ${subscription_address}, health-check: {enable: true, url: https://cp.cloudflare.com}}
检测到的IP地址, $ip_address ,如果出站IP和入站IP不同,无法使用订阅链接.
手动修改/opt/www/sub/中客户端配置文件的IP地址为真实入站IP地址
服务端zashboard面板,地址为 
https://board.zash.run.place/#/setup?hostname=$Certificate_name&port=$select_port&secondaryPath=/${current_time}&secret=$uuid
可在面板中更改出站节点为直连或warp,查看使用状态和流量
如果需要删除脚本创建的内容,使用 -uninstall 参数,不会删除包管理器安装的内容
添加其他站点, default  9999
如使用自定义证书,请将证书放入：
/etc/mihomo/cert/$Certificate_name.crt
/etc/mihomo/cert/$Certificate_name.key
然后重启mihomo和nginx
如遇意外错误可加入tg群反馈 https://t.me/dmjlqa
${ECHO_TIPS}
------------------------------
EOF

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

cat /opt/www/sub/${current_time}.yaml
cat /opt/www/sub/${current_time}.txt
cat /opt/www/sub/README.txt
