#!/bin/bash

# 检查权限
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 sudo 或 root 权限运行此脚本"
  exit 1
fi

#!/usr/bin/env bash
set -e

# 检查依赖
install_dependencies() {
    echo "🔧 检查并安装依赖..."
    # 基本依赖
    local base_pkgs=(curl wget)

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
        echo "❌ 无法识别包管理器，请手动安装: curl wget"
        exit 1
    fi

    echo "✅ 依赖安装完成。"
}

for cmd in curl wget; do
    if ! command -v "$cmd" &>/dev/null; then
        install_dependencies
        break
    fi
done

# 1. 检测系统架构
ARCH=$(uname -m)
case ${ARCH} in
    x86_64)  BINARY_ARCH="amd64" ;;
    aarch64|arm64) BINARY_ARCH="arm64" ;;
    armv7l)  BINARY_ARCH="armhf" ;;
    *) echo "暂不支持的架构: ${ARCH}"; exit 1 ;;
esac

echo "检测到系统架构: ${ARCH} -> 匹配二进制: ${BINARY_ARCH}"

# 2. 获取最新版本号
echo "正在获取最新版本信息..."
LATEST_TAG=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "无法获取最新版本，请检查网络连接。"
    exit 1
fi
echo "最新版本: ${LATEST_TAG}"

# 3. 下载并安装二进制文件
URL="https://github.com/cloudflare/cloudflared/releases/download/${LATEST_TAG}/cloudflared-linux-${BINARY_ARCH}"
echo "正在下载: ${URL}"
curl -L --progress-bar -o /usr/local/bin/cloudflared ${URL}
chmod +x /usr/local/bin/cloudflared

# 验证安装
cloudflared --version

echo "------------------------------------------------"
echo "cloudflared 安装完成！"