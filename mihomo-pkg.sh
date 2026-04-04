#!/usr/bin/env bash
set -e

# 检查依赖
install_dependencies() {
    echo "🔧 检查并安装依赖..."
    # 基本依赖
    local base_pkgs=(curl wget gzip)

    if command -v apt &>/dev/null; then
        # apt 安装前刷新索引
        apt update -y
        apt install -y "${base_pkgs[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${base_pkgs[@]}" || true
    elif command -v dnf &>/dev/null; then
        dnf install -y "${base_pkgs[@]}"
    elif command -v pacman &>/dev/null; then
        # pacman 需要同步更新数据库
        pacman -Sy --noconfirm "${base_pkgs[@]}"
    elif command -v apk &>/dev/null; then
        apk add --no-cache "${base_pkgs[@]}"
    else
        echo "❌ 无法识别包管理器，请手动安装: curl wget gzip"
        exit 1
    fi

    echo "✅ 依赖安装完成。"
}

for cmd in curl wget gzip; do
    if ! command -v "$cmd" &>/dev/null; then
        install_dependencies
        break
    fi
done

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) BIN_ARCH="amd64" ;;
    aarch64) BIN_ARCH="arm64" ;;
    armv7l) BIN_ARCH="armv7" ;;
    armv6l) BIN_ARCH="armv6" ;;
    *)
        echo "[-] 不支持的架构: $ARCH"
        exit 1
        ;;
esac

CPU_FLAGS=$(grep flags /proc/cpuinfo | head -n1)
if [[ $CPU_FLAGS =~ avx2 ]]; then
    LEVEL="v3"
elif [[ $CPU_FLAGS =~ avx ]]; then
    LEVEL="v2"
else
    LEVEL="v1"
fi

echo "[+] 检测到 架构=$ARCH 可执行=$BIN_ARCH 指令集等级=$LEVEL"

if ! command -v mihomo &>/dev/null; then
    echo "[+] 正在安装 mihomo..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo "[-] 无法获取最新版本号。"
        exit 1
    fi

    if [ "$BIN_ARCH" = "amd64" ]; then
        FILE_NAME="mihomo-linux-${BIN_ARCH}-${LEVEL}-${LATEST_VERSION}.gz"
    else
        FILE_NAME="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    fi
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"

    echo "[+] 正在下载 ${FILE_NAME}..."
    if ! wget -O /tmp/mihomo.gz "$DOWNLOAD_URL"; then
        echo "[!] 对应等级的构建下载失败，尝试兼容版本..."
        FILE_NAME="mihomo-linux-${BIN_ARCH}-compatible-${LATEST_VERSION}.gz"
        DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"
        wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" || {
            echo "[-] 所有下载方式均失败。"
            exit 1
        }
    fi

    gzip -d /tmp/mihomo.gz
    chmod +x /tmp/mihomo
    mv /tmp/mihomo /usr/local/bin/mihomo
    echo "[+] mihomo 安装完成。"
else
    echo "[+] 已检测到 mihomo，跳过安装。"
fi

if command -v systemctl &>/dev/null; then
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
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF
elif [ -d /etc/init.d ] && command -v rc-status &>/dev/null; then
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
    echo "未检测到 systemd 或 OpenRC，请手动创建服务"
fi
