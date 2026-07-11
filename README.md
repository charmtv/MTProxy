# MTProxy 一键管理脚本 V2.5

适用于 Debian、Ubuntu、CentOS、RHEL 和 Alpine Linux，支持 Go（mtg）与 Rust（Telemt）双内核。

## 一键安装

```bash
bash <(curl -fsSL https://mtproxy.813099.xyz)
```

安装后可随时打开管理菜单：

```bash
mtp
```

## 主要功能

- 安装和管理 Go、Telemt 服务
- 支持 IPv4、IPv6 和双栈模式
- 查看连接、运行状态和日志
- 修改配置及启停、重启服务
- Telemt 多用户、流量配额和到期时间管理

## 手动安装

```bash
curl -fsSLo /usr/local/bin/mtp https://mtproxy.813099.xyz/mtp.sh
chmod +x /usr/local/bin/mtp
mtp
```

域名入口由 Cloudflare Worker 提供，源脚本同步自本仓库。Go 与 Telemt 的预编译文件继续使用上游项目 `Go-Rust` Release。

## 常用命令

```bash
mtp              # 打开管理菜单
mtp update       # 更新管理脚本
mtp force_reset  # 立即重置 Telemt 流量配额
mtp check_reset  # 执行定时配额检查
```

仅供个人学习和测试使用。
