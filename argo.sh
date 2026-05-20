#!/bin/bash

set -o pipefail

LISTEN_HOST="127.0.0.1"
LISTEN_PORT="58991"
PROXY_NAME="argo-vless"
CONFIG_FILE="/etc/sing-box/config.json"
ARGO_CONFIG="$HOME/argo.yaml"
uuid=""
domain_name=""
cloudflared_pid=""
tmp_log=""

show_help() {
cat <<EOF
用法: $0 [参数]

不带参数:
  安装 sing-box,cloudflared 并配置临时隧道。

参数:
  -h, --help       显示此帮助信息
  -res             重新创建隧道,适用于隧道过期
  -sing-box        安装 sing-box 
  -cloudflared     安装 cloudflared
EOF
}
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
    sed -nE 's/^[[:space:]]*"uuid":[[:space:]]*"([^"]+)".*/\1/p' "$CONFIG_FILE" | head -n 1
}

start_tunnel() {
    pkill -f "cloudflared tunnel --url http://${LISTEN_HOST}:${LISTEN_PORT}" 2>/dev/null
    sleep 1

    local tmp_log
    tmp_log="$(mktemp)"
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
    echo "分配的域名: $domain_name"
    if [ -z "$domain_name" ]; then
        echo "错误：未能获取域名，请运行 ./argo.sh -res 重新创建隧道"
        exit 1
    fi
}

write_client_config() {
    ws_path="/${uuid}-vl"
    uri_path="%2F${uuid}-vl"
    vless_link="vless://${uuid}@${domain_name}:443?encryption=none&security=tls&sni=${domain_name}&type=ws&host=${domain_name}&path=${uri_path}#${PROXY_NAME}"

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
    if ! command -v install >/dev/null 2>&1; then
        echo "错误：未找到依赖 'install'(coreutils)，请先安装。"
        exit 1
    fi
    local arch binary_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) binary_arch="amd64" ;;
        aarch64|arm64) binary_arch="arm64" ;;
        armv7l) binary_arch="armhf" ;;
        *) echo "暂不支持的架构: $arch"; exit 1 ;;
    esac

    echo "检测到系统架构: $arch -> 匹配二进制: $binary_arch"
    echo "正在获取最新版本信息..."
    local latest_tag
    latest_tag="$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
        | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' \
        | head -n 1)" || {
        echo "错误：无法连接到 GitHub API，无法获取最新版本。"
        exit 1
    }

    if [ -z "$latest_tag" ]; then
        echo "错误：GitHub API 响应中版本号为空。"
        exit 1
    fi

    local url="https://github.com/cloudflare/cloudflared/releases/download/${latest_tag}/cloudflared-linux-${binary_arch}"
    local mirrors=(
        "https://mirror.ghproxy.com/"
        "https://ghproxy.net/"
        "https://github.moeyy.xyz/"
    )
    local tmpfile
    tmpfile="$(mktemp)"

    echo "最新版本: $latest_tag"
    echo "正在下载: cloudflared-linux-${binary_arch}"

    if curl --max-time 15 -fSL "$url" -o "$tmpfile"; then
        :
    else
        echo "直链下载失败，尝试镜像代理 ..."
        local ok=false
        for mirror in "${mirrors[@]}"; do
            echo "尝试镜像: ${mirror}"
            if curl --max-time 15 -fSL "${mirror}${url}" -o "$tmpfile"; then
                ok=true
                break
            fi
        done
        if ! "$ok"; then
            echo "错误：所有下载源均失败。"
            rm -f "$tmpfile"
            exit 1
        fi
    fi

    install -m 0755 "$tmpfile" /usr/local/bin/cloudflared
    rm -f "$tmpfile"
    cloudflared --version
    echo "cloudflared 安装完成！"
}

ensure_cloudflared() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "未检测到 cloudflared，正在开始安装..."
        install_cloudflared
    fi
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

    local os_info
    os_info="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -z "$os_info" ] && os_info="$(cat /etc/alpine-release 2>/dev/null | sed 's/^/Alpine Linux /')"
    [ -z "$os_info" ] && os_info="未知"

    local os="" arch="" pkg_suffix="" pkg_install=""
    if command -v pacman >/dev/null 2>&1; then
        os="linux"
        arch=$(uname -m)
        pkg_suffix=".pkg.tar.zst"
        pkg_install="pacman -U --noconfirm"
    elif command -v dpkg >/dev/null 2>&1; then
        os="linux"
        arch=$(dpkg --print-architecture)
        pkg_suffix=".deb"
        pkg_install="dpkg -i"
    elif command -v dnf >/dev/null 2>&1; then
        os="linux"
        arch=$(uname -m)
        pkg_suffix=".rpm"
        pkg_install="dnf install -y"
    elif command -v rpm >/dev/null 2>&1; then
        os="linux"
        arch=$(uname -m)
        pkg_suffix=".rpm"
        pkg_install="rpm -i"
    elif command -v apk >/dev/null 2>&1; then
        os="linux"
        arch=$(apk --print-arch)
        pkg_suffix=".apk"
        pkg_install="apk add --allow-untrusted"
    elif command -v opkg >/dev/null 2>&1; then
        os="openwrt"
        . /etc/os-release 2>/dev/null || true
        arch="$OPENWRT_ARCH"
        pkg_suffix=".ipk"
        pkg_install="opkg update && opkg install"
    else
        echo "错误：未找到支持的包管理器（pacman/dpkg/dnf/rpm/apk/opkg）"
        echo "当前系统: $os_info"
        exit 1
    fi
    echo "检测到包管理器: ${pkg_install%% *}，架构: $arch"

    echo "正在获取最新版本信息..."
    local download_version
    download_version="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | grep tag_name \
        | head -n 1 \
        | awk -F: '{print $2}' \
        | sed 's/[", v]//g')" || {
        echo "错误：无法连接到 GitHub API，无法获取最新版本。"
        echo "当前系统: $os_info"
        exit 1
    }

    if [ -z "$download_version" ]; then
        echo "错误：GitHub API 响应中版本号为空。"
        echo "当前系统: $os_info"
        exit 1
    fi
    echo "最新版本: $download_version"

    local pkg_name="sing-box_${download_version}_${os}_${arch}${pkg_suffix}"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${download_version}/${pkg_name}"
    local mirrors=(
        "https://mirror.ghproxy.com/"
        "https://ghproxy.net/"
        "https://github.moeyy.xyz/"
    )

    echo "正在下载: $pkg_name"
    if curl --max-time 15 -fSL "$url" -o "$pkg_name"; then
        :
    else
        echo "直链下载失败，尝试镜像代理 ..."
        local ok=false
        for mirror in "${mirrors[@]}"; do
            echo "尝试镜像: ${mirror}"
            if curl --max-time 15 -fSL "${mirror}${url}" -o "$pkg_name"; then
                ok=true
                break
            fi
        done
        if ! "$ok"; then
            echo "错误：所有下载源均失败。"
            echo "当前系统: $os_info"
            rm -f "$pkg_name"
            exit 1
        fi
    fi

    echo "安装包: $pkg_install $pkg_name"
    if sh -c "$pkg_install \"$pkg_name\""; then
        rm -f "$pkg_name"
        echo "sing-box 安装完成！"
        sing-box version
    else
        echo ""
        echo "========================================================"
        echo "  sing-box 安装失败"
        echo "  当前系统: $os_info"
        echo "  可能原因: 系统过旧，有未满足的依赖"
        echo "  建议: 升级系统后重试"
        echo "========================================================"
        rm -f "$pkg_name"
        exit 1
    fi
}
start_sing_box() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now sing-box
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        rc-update add sing-box default
        rc-service sing-box start
    else
        echo "错误：未找到 systemctl 或 OpenRC，无法启用 sing-box。"
        exit 1
    fi
}

write_sing_box_config() {
    mkdir -p /etc/sing-box
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "${LISTEN_HOST}",
      "listen_port": ${LISTEN_PORT},
      "users": [
        {
          "uuid": "${uuid}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/${uuid}-vl"
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

main() {
    echo "适用没有入站的小鸡"
    require_root
    require_curl

    case "${1:-}" in
        -h|--help|help)
            show_help
            exit 0
            ;;
        -cloudflared)
            install_cloudflared
            exit 0
            ;;
        -res)
            ensure_cloudflared
            restart_tunnel
            exit 0
            ;;
        -sing-box)
            install_sing_box
            exit 0
            ;;
    esac

    uuid=$(cat /proc/sys/kernel/random/uuid)

    install_sing_box
    write_sing_box_config
    start_sing_box
    ensure_cloudflared
    start_tunnel
    write_client_config
    show_help
    echo "分配域名: $domain_name"
    echo "cloudflared 隧道已在后台运行，PID: $cloudflared_pid"
    cat "$ARGO_CONFIG"
    echo "生成的配置位于 $ARGO_CONFIG"
    echo "临时隧道仅供测试使用，如需稳定连接，请使用个人账户创建隧道至 http://${LISTEN_HOST}:${LISTEN_PORT}"
    echo "隧道过期，运行 ./argo.sh -res 重新创建隧道"
    echo "如遇意外错误可加入tg群反馈 https://t.me/dmjlqa"

}

main "$@"
