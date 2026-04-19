# MNC 安装脚本

一套基于 sing-box、mihomo (Clash) 和 cloudflared 的一键安装脚本，旨在快速部署多种代理协议。

## 主要脚本说明

- **`mnc-install.sh`**：一键安装 mihomo，并配置 `hysteria2`, `reality`, `anytls`, `vless-ws` 四种入站协议。
- 支持使用自定义证书或内置默认证书，创建订阅链接。
- **`sing-box-install.sh`**：一键安装 sing-box，并自动配置 `reality` 和 `hysteria2` 服务。
- **`cloudflared-install.sh`**：适用于没有入站端口（如被防火墙拦截或无公网 IP）的小鸡，通过 Cloudflare Tunnel 建立隧道。

## 使用说明

### 1. 一键安装 mihomo (推荐)
支持 `hysteria2`, `reality`, `anytls`, `vless-ws` 四协议共用端口。
```bash
curl -fsSL https://raw.githubusercontent.com/niylin/mnc-install/master/mnc-install.sh | bash
```
备用链接：
```bash
curl -fsSL https://link.wdqgn.eu.org/nopasswd/mnc-install.sh | bash
```

### 2. 一键安装 sing-box
配置 `hysteria2` 和 `reality`。
```bash
curl -fsSL https://raw.githubusercontent.com/niylin/mnc-install/master/sing-box-install.sh | bash
```
备用链接：
```bash
curl -fsSL https://link.wdqgn.eu.org/nopasswd/sing-box-install.sh | bash
```

### 3. 一键安装 cloudflared (隧道模式)
适用于无入站环境。
```bash
curl -fsSL https://raw.githubusercontent.com/niylin/mnc-install/master/cloudflared-install.sh | bash
```
备用链接：
```bash
curl -fsSL https://link.wdqgn.eu.org/nopasswd/cloudflared-install.sh | bash
```

## 功能特性

- **自动依赖安装**：自动检测并安装 `curl`, `wget`, `jq`, `python3`, `openssl`, `nginx` 等依赖。
- **多平台支持**：支持 `apt`, `dnf`, `yum`, `pacman`, `zypper`, `apk` 等主流包管理器。
- **证书管理**：自动配置证书并设置定时任务更新（仅限支持定时任务的系统）。

