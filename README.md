
# sing-box 安装脚本

- `sing-box-install.sh`：一键安装 sing-box，并自动配置 `reality` 和 `hysteria2` 服务。
- `sing-box-pkg.sh`：下载并安装 sing-box 官方发行包，支持多种 Linux 包管理器和 。
- `mihomo-install.sh`：一键安装 mihomo，并自动配置 `reality` `hysteria2` `anytls` 服务。
- `mihomo-pkg.sh`：下载并安装 mihomo 官方发行包，支持多种 Linux 包管理器和 。

## 主要功能

### `sing-box-install.sh`

- 自动检查并安装依赖：`curl`, `wget`, `nano`, `jq`, `python3`, `cron`
- 支持 Linux 发行版的主流包管理器：`apt`, `dnf`, `yum`, `pacman`, `zypper`, `apk`
- 生成 `hysteria2` 和 `reality` 节点配置
- 自动下载配置证书到 `/opt/cert`
- 生成 Sing-box 配置文件 `/etc/sing-box/config.json`
- 生成客户端配置文件 `~/link.yml`
- 自动启用并启动 `sing-box` 服务（`systemd` 或 `OpenRC`）

### `sing-box-pkg.sh`

- 与sing-box官方安装脚本功能一致，仅修改请求方式，为了绕过GitHub速率限制创建

## 使用说明

###  仅安装sing-box

```bash
wget -qO- https://raw.githubusercontent.com/niylin/sing-box-install/master/sing-box-pkg.sh | bash
```
```bash
wget -qO- https://link.wdqgn.eu.org/nopasswd/sing-box-pkg.sh | bash
```
###  仅安装mihomo

```bash
wget -qO- https://raw.githubusercontent.com/niylin/sing-box-install/master/mihomo-pkg.sh | bash
```
```bash
wget -qO- https://link.wdqgn.eu.org/nopasswd/mihomo-pkg.sh | bash
```
脚本运行时会提示：

- 选择 IPv6 或 IPv4
- 输入 `hysteria` 端口（`reality` 端口将自动设为该值 + 1）

###  一键安装sing-box和生成节点
```bash
wget -qO- https://raw.githubusercontent.com/niylin/sing-box-install/master/sing-box-install.sh | bash
```
```bash
wget -qO- https://link.wdqgn.eu.org/nopasswd/sing-box-install.sh | bash
```
###  一键安装mihomo和生成节点
```bash
wget -qO- https://raw.githubusercontent.com/niylin/sing-box-install/master/mihomo-install.sh | bash
```
```bash
wget -qO- https://link.wdqgn.eu.org/nopasswd/mihomo-install.sh | bash
```

###  脚本和证书在 https://link.wdqgn.eu.org/nopasswd/ 更新


## 注意事项

- 生成的客户端配置默认使用当前出站 IP，如果出站 IP 与入站 IP 不一致，需手动修改客户端配置。
- 脚本默认使用 `www.tencentcloud.com` 作为 `reality` handshake 和 `server_name`。
- 只会在使用apt包管理器中会主动安装cron来更新证书，其他系统如未安装cron，需要定期手动更新证书。


