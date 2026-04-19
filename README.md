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

## worker,用于创建隧道和dns分发API
- tunnel.js  
- BASE_DOMAIN:用于分发的域  CF_ACCOUNT_ID:账户标识ID  CF_ZONE_ID:用于分发域的ZONE_ID
- CF_API_TOKEN:拥有管理隧道和创建特定域dns的权限的令牌,一般通过cloudflared通过 cloudflared login 创建,然后找到该令牌,点击轮转即可获得通用令牌  
- CREATE_PATH:自定义PATH,更改即可使旧链接失效
- 请求方式,访问链接即可 https://API_DOMAIN/YOUR_CREATE_PATH
  ![tunnel](png/tunnel.png)

- dns.js
- API_TOKEN:创建特定域dns的权限的令牌,控制台手动生成.勾选dns权限即可
- ZONE_ID:用于分发域的ZONE_ID 
- CREATE_PATH:自定义PATH,更改即可使旧链接失效
- 请求方式  domain_name;ip_address需要解析的域名和IP地址
- curl -s -X POST https://API_DOMAIN/YOUR_CREATE_PATH -H "Content-Type: application/json" -d "{\"domain\":\"$domain_name\",\"ip\":\"$ip_address\"}"


  ![dns](png/dns.png)