# MNC 安装脚本

一套基于 sing-box、mihomo 和 cloudflared 的一键安装脚本，旨在快速部署多种代理协议。

## 主要脚本说明

- **`mnc-install.sh`**：一键安装 mihomo，并配置 `hysteria2`， `vless-reality`， `anytls`， `vless-ws` , `tuic-v5`, `mieru`, `trusrtunnel` `sudoku`。-h 参数查看额外用法
- 支持使用自定义证书或内置默认证书，创建订阅链接，开启ech。
- **`sing-box-install.sh`**：一键安装 sing-box，并自动配置 `reality` 和 `hysteria2` 服务，配置要求低。可在64mb内存的设备上使用。
- **`argo.sh`**：适用于没有入站端口（如被防火墙拦截或无公网 IP）的vps，通过 Cloudflare Tunnel 建立隧道。

- 入站端口默认使用443,2053.如手动输入,则使用 输入内容及其 +1
## 使用说明

### 1. 一键安装 mihomo (推荐)
安装mihomo并配置 `hysteria2`， `vless-reality`， `anytls`， `vless-ws` , `tuic-v5`, `mieru`, `trusrtunnel`。
```bash
curl -fsSL -o mnc-install.sh https://raw.githubusercontent.com/niylin/mnc-install/master/mnc-install.sh && chmod +x mnc-install.sh && ./mnc-install.sh
```

### 2. 一键安装 sing-box
配置 `hysteria2` 和 `reality`。
```bash
curl -fsSL https://raw.githubusercontent.com/niylin/mnc-install/master/sing-box-install.sh | bash
```

### 3. cloudflared 临时隧道
适用于无入站环境。
```bash
curl -fsSL -o argo.sh https://raw.githubusercontent.com/niylin/mnc-install/master/argo.sh && chmod +x argo.sh && ./argo.sh
```


