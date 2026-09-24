# MTProxy 管理脚本

Go（mtg）与 Rust（Telemt）双内核的 MTProxy 一键部署与管理工具，适用于 Debian、Ubuntu、CentOS / RHEL / Rocky / Alma 与 Alpine Linux，支持 amd64 与 arm64。

[English](README.en-US.md)

## 安装

```bash
bash <(curl -fsSL https://mtproxy.813099.xyz)
```

安装完成后输入 `mtp` 打开管理菜单。

<details>
<summary>手动安装 / 开发版</summary>

```bash
curl -fsSLo /usr/local/bin/mtp https://mtproxy.813099.xyz/mtp.sh
chmod +x /usr/local/bin/mtp
mtp

# 安装开发版（main 分支）
MTP_CHANNEL=dev bash <(curl -fsSL https://mtproxy.813099.xyz)
```

</details>

## 界面

```
  MTProxy                                           v3.0.0
  Debian GNU/Linux 12 (bookworm) · systemd · amd64
  ────────────────────────────────────────────────────────
  Go       ● 运行中   :443    12.4 MB    3天4时
  Telemt   ● 运行中   :8443   18.1 MB    3天4时
  ────────────────────────────────────────────────────────

  部署
    1  Go 内核                       已安装 · 更新或重装
    2  Telemt 内核                   已安装 · 更新或重装
    3  更新内核                      保留配置与链接

  管理
    4  连接信息                      链接 · 二维码
    5  用户管理                      Telemt · 4 人
    6  端口与域名
    7  服务控制                      启动 · 停止 · 重启
    8  日志

  系统
    9  诊断                          端口 · 时间 · 域名
    b  备份与恢复
    u  更新脚本
    d  删除内核
    x  卸载全部
    0  退出
```

```
  用户管理                                   Telemt · 4 人
  ────────────────────────────────────────────────────────
  #   用户         端口   流量                      到期
  1   admin        8443   不限 · 3.2G               永久
  2   alice        9443   ▰▰▰▰▰▰▱▱▱▱  62% 31G/50G   12-31
  3   bob          8443   ▰▰▰▰▰▰▰▰▰▰  已用尽        2027-03-31  ✗
  4   carol        8443   ▰▰▰▰▰▰▰▰▰▱  90% 9G/10G    09-27  !
```

## 功能

**内核**

- Go 版（mtg）：内存占用低，适合个人或小团队。
- Telemt 版（Rust）：多用户，每个用户可设置专属端口、流量配额、到期时间与上下行限速。
- 两个内核可以同时运行；支持 IPv4、IPv6 与双栈。
- 内核从 Release 下载并校验 SHA-256；「更新内核」只替换程序，配置与链接保持不变，新内核启动失败时自动回滚。

**用户管理（Telemt）**

- 表格总览：流量进度、到期日，用量达到 80% 或 7 天内到期会提示。
- 流量配额支持单位：`50G`、`500M`、`1.5T`。
- 到期时间支持 `2026-12-31`、`2026-12-31 18:00`，或 `+30d`（在当前到期日基础上顺延）。
- 每月或指定日期自动清零流量，已到期用户不参与；日期大于当月天数时在月末执行。
- 每个用户可单独查看链接与二维码，也可单独重置密钥。

**可靠性与安全**

- 用户数据集中保存在 `users.db`，每次修改都重新生成完整的 Telemt 配置。服务启动失败会自动回滚到修改前。
- 修改流量记录前先停止 Telemt，避免退出时写回的旧数据覆盖清零结果。
- mtg 的密钥写在配置文件中，不再出现在进程参数里；配置文件权限为 600。
- systemd 服务默认启用沙箱加固（mtg 使用独立的低权限账号）；环境不支持时自动改用兼容模式。
- 日志中的连接密钥默认隐藏，OpenRC 日志按周轮转。

**运维**

- 诊断：服务与端口、公网连通、防火墙放行、时间同步、伪装域名的 TLS 1.3 支持、BBR、版本更新。可以一键放行端口与开启 BBR。
- 备份与恢复：把配置、用户与流量记录打包成一个文件，可以迁移到新服务器。
- 可以设置「链接地址」，用域名或指定 IP 生成链接（适合 NAT 机器）。
- Telemt 支持推广频道（ad_tag）。

## 命令行

所有菜单功能都可以通过命令完成，便于自动化：

```bash
mtp status                         # 运行状态
mtp info                           # 连接信息
mtp restart telemt                 # 启动 / 停止 / 重启
mtp logs telemt -f                 # 日志

mtp user list [--json]
mtp user add alice --quota 50G --expire +30d --port 8443 --up 2 --down 10
mtp user edit alice --expire +30d --no-limit
mtp user link alice --qr
mtp user reset alice               # 清零已用流量
mtp user del alice -y
mtp reset-now                      # 立即清零全部配额用户

mtp doctor [--fix]                 # 诊断
mtp upgrade-core                   # 更新内核
mtp update [--dev|--stable]        # 更新脚本
mtp backup / mtp restore 文件
mtp uninstall
```

完整说明见 `mtp help`。

## 文件位置

| 路径 | 内容 |
|---|---|
| `/etc/mtproxy/` | 配置与用户数据（`mtg.toml`、`telemt.toml`、`users.db` 等） |
| `/etc/mtproxy/telemt.extra.toml` | 可选，自定义 Telemt 配置，会追加到生成的配置末尾 |
| `/etc/telemt_quota.json` | Telemt 流量用量（路径由内核固定） |
| `/var/lib/mtproxy/` | 运行状态与备份 |
| `/var/log/mtproxy/` | 日志 |
| `/opt/mtproxy/bin/` | 内核程序 |

## 从 2.x 升级

运行 `mtp update`（旧版为菜单中的「更新管理脚本」）即可。新版首次运行时自动迁移旧配置：

- 用户、配额、到期时间、限速、专属端口、流量用量和自动清零计划全部保留，现有链接不变。
- 迁移前的旧文件打包在 `/var/lib/mtproxy/backups/legacy-*.tar.gz`。
- 迁移过程中服务会重启一次。
- 迁移失败时服务继续按旧配置运行。处理后可运行 `mtp migrate` 重试。

## 开发

脚本源码按模块放在 `src/`，发布用的单文件 `mtp.sh` 由构建脚本生成：

```bash
bash scripts/build.sh        # 生成 mtp.sh 与 mtp.sh.sha256
npm test                     # Worker 测试 + 脚本单元测试
bash tests/shell/cores.sh    # 用真实内核验证生成的配置（需要网络）
```

发布：推送 `v3.x.y` 标签后，工作流会把 `stable` 分支指向该标签。安装入口默认读取 `stable`，`stable` 不存在时读取 `main`。

域名入口由 `worker/` 中的 Cloudflare Worker 提供（`npm run deploy`）。

## 更新日志

### 3.0.0

- 重写管理界面：分组菜单、统一的简约视觉，危险操作需要输入确认。
- 新增：命令行、二维码、诊断、备份与恢复、单独更新内核、链接地址、推广频道。
- 修复：重装内核会清空用户；卸载没有确认；日期格式错误会导致 Telemt 无法启动；到期时间时区固定为 +08:00；每月 29–31 日的清零在小月不会执行；只改 Go 端口也会更换密钥；流量清零可能被覆盖。
- 安全：密钥不再出现在进程参数和权限为 644 的文件中；systemd 服务加固；脚本下载校验 SHA-256。
- 分发：Worker 的缓存生效，支持稳定版与开发版通道。

### 2026.04.07

- ARM 支持：Go 与 Telemt 版加入 ARM 架构二进制文件。

### 2026.03.19

- Telemt 带宽限制：支持按用户设置上下行带宽限制。

### 2026.03.10

- Telemt 用户流量配额与到期时间控制，支持每月自动清零。

### 2026.03.03

- 加入 Telemt（Rust 版），支持单用户单端口。

### 2026.03.01

- Go 版重构，修复僵尸连接与多用户连接时的内存溢出。

---

仅供个人学习和测试使用。
