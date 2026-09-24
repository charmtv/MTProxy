#!/usr/bin/env bash
#
# MTProxy 管理脚本 · Go (mtg) / Rust (Telemt) 双内核
# https://github.com/charmtv/MTProxy
#
# 本文件由 scripts/build.sh 从 src/ 生成，请修改 src/ 后重新构建。

if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "需要 Bash 4.0 或更高版本运行。" >&2
    exit 1
fi

shopt -s extglob

MTP_VERSION="3.0.0"
MTP_REPO="charmtv/MTProxy"
RELEASE_REPO="${MTP_RELEASE_REPO:-0xdabiaoge/MTProxy}"
MTP_SCRIPT_URL="${MTP_SCRIPT_URL:-https://mtproxy.813099.xyz/mtp.sh}"
MTP_RAW_BASE="https://raw.githubusercontent.com/${MTP_REPO}"

# MTP_ROOT 仅供测试使用：把所有文件操作限制在一个沙箱目录内。
R="${MTP_ROOT:-}"

ETC_DIR="$R/etc/mtproxy"
STATE_DIR="$R/var/lib/mtproxy"
LOG_DIR="$R/var/log/mtproxy"
OPT_DIR="$R/opt/mtproxy"
BIN_DIR="$OPT_DIR/bin"
MTP_BIN="$R/usr/local/bin/mtp"
SYSTEMD_DIR="$R/etc/systemd/system"
OPENRC_DIR="$R/etc/init.d"
LOGROTATE_FILE="$R/etc/logrotate.d/mtproxy"
SYSCTL_BBR_FILE="$R/etc/sysctl.d/99-mtproxy-bbr.conf"

SETTINGS_FILE="$ETC_DIR/mtproxy.env"
MTG_STATE="$ETC_DIR/mtg.env"
MTG_CONF="$ETC_DIR/mtg.toml"
TELEMT_STATE="$ETC_DIR/telemt.env"
TELEMT_CONF="$ETC_DIR/telemt.toml"
TELEMT_EXTRA="$ETC_DIR/telemt.extra.toml"
USERS_DB="$ETC_DIR/users.db"
RESET_STATE="$ETC_DIR/reset.env"
# Telemt 内核固定从该路径读写流量用量，不能迁移。
TELEMT_QUOTA_JSON="$R/etc/telemt_quota.json"
TELEMT_WORKDIR="$STATE_DIR/telemt"

CORE_STATE="$STATE_DIR/core.env"
IP_CACHE="$STATE_DIR/ip.cache"
REMOTE_CACHE="$STATE_DIR/remote.cache"
MIGRATE_FAILED="$STATE_DIR/migrate.failed"
BACKUP_DIR="$STATE_DIR/backups"
RESET_LOG="$LOG_DIR/reset.log"

# 2.x 版本使用的旧路径，仅用于迁移。
LEGACY_CONF_DIR="$OPT_DIR/config"
LEGACY_TELEMT_TOML="$R/etc/telemt.toml"
LEGACY_RESET_CONF="$R/etc/telemt_reset.conf"
LEGACY_RESET_LOG="$R/var/log/telemt_reset.log"

SVC_USER="mtproxy"
CRON_TAG="mtp check_reset"
CRON_LINE="0 0 * * * /usr/local/bin/mtp check_reset >/dev/null 2>&1"
