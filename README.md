# MNC 安装脚本

一套基于 sing-box、mihomo 和 cloudflared 的一键安装脚本，旨在快速部署多种代理协议。

生成 clash和sing-box格式的配置,并创建订阅链接,可直接导入或合并订阅

## 使用说明

### 1. 一键安装 mihomo (推荐)
安装mihomo并配置 `hysteria2`， `vless-reality`， `anytls`， `vless-ws` , `tuic-v5`, `mieru`, `trusrtunnel`, `sudoku`。
```bash
curl -fsSL -o mnc-install.sh https://raw.githubusercontent.com/niylin/mnc-install/master/mnc-install.sh && chmod +x mnc-install.sh && ./mnc-install.sh
```

### 2. 一键安装 sing-box
配置 `hysteria2` `reality` `anytls`。`tuic` `vmess-argo` ,创建订阅配置,sing-box配置,仅分流cn流量.clash配置以及snlink分享配置
```bash
curl -fsSL -o sing-box-install.sh https://raw.githubusercontent.com/niylin/mnc-install/master/sing-box-install.sh && chmod +x sing-box-install.sh && ./sing-box-install.sh
```
#### sing-box脚本支持中转配置

在落地VPS上运行以下命令,运行后会输出中转VPS需要的安装的命令,可在多台中转设备上使用.
```bash
curl -fsSL https://raw.githubusercontent.com/niylin/mnc-install/master/sing-box-install.sh | bash -s -- -ouserver
```
- 临时隧道过期,运行 "-tunnel res" 即可重新获取隧道,自动更新订阅信息和配置文件

```
用法: sing-box.sh [参数]

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
```



