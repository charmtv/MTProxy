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

域名入口由 Cloudflare Worker 提供，源脚本同步自本仓库。Go 与 Telemt 的预编译文件从 `0xdabiaoge/MTProxy` 的最新 Release 下载。

## 常用命令

```bash
mtp              # 打开管理菜单
mtp update       # 更新管理脚本
mtp force_reset  # 立即重置 Telemt 流量配额
mtp check_reset  # 执行定时配额检查
```

## 上游更新日志

### 2026.03.01

- **Go 版重构优化**：修复僵尸连接及多用户连接时的内存溢出问题。

### 2026.03.03

- **加入 Telemt（Rust 版）**：支持单用户单端口，便于独立管理临时分享用户。

### 2026.03.10

- **Telemt 深度优化**：新增用户流量配额与到期时间控制。
- **流量重置**：支持按用户配置每月自动重置日期。

### 2026.03.19

- **Telemt 带宽限制**：支持按用户设置上下行带宽限制。

### 2026.04.07

- **ARM 支持**：Go 与 Telemt 版加入 ARM 架构二进制文件。

仅供个人学习和测试使用。
