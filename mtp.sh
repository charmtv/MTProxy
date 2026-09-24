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

# ============================================================
# 界面组件：一个强调色、灰色辅助信息，只用单宽符号
# ============================================================

UI_W=56
UI_TTY=0
_DW=0

ui_init() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        C0=$'\e[0m' CB=$'\e[1m' CD=$'\e[2m' CA=$'\e[36m' CG=$'\e[32m' CY=$'\e[33m' CR=$'\e[31m'
    else
        C0='' CB='' CD='' CA='' CG='' CY='' CR=''
    fi
    [ -t 0 ] && [ -t 1 ] && UI_TTY=1
    UI_RULE=$(printf '─%.0s' $(seq 1 "$UI_W"))
    [ "$UI_TTY" = 1 ] && trap ui_restore EXIT
}

# 等待动画期间隐藏光标并关闭输入回显，避免按键打乱动画；退出时一定恢复
ui_busy() {
    [ "$UI_TTY" = 1 ] || return 0
    stty -echo 2>/dev/null
    printf '\033[?25l'
}

ui_restore() {
    [ "$UI_TTY" = 1 ] || return 0
    stty echo 2>/dev/null
    printf '\033[?25h'
}

# 终端显示宽度（与语言环境无关）：中日韩字符占 2 列，其余占 1 列。
dwidth() {
    local LC_ALL=C s="${1//$'\e'\[*([0-9;])m/}"
    local cont="${s//[^$'\x80'-$'\xbf']/}"
    local wide="${s//[^$'\xe3'-$'\xef'$'\xf0'-$'\xf4']/}"
    _DW=$(( ${#s} - ${#cont} + ${#wide} ))
}

# pad 文本 宽度：右侧补空格到指定显示宽度
pad() {
    dwidth "$1"
    local gap=$(( $2 - _DW ))
    (( gap < 0 )) && gap=0
    printf '%s%*s' "$1" "$gap" ''
}

# 截断到指定显示宽度（仅用于 ASCII 字段，如用户名）
clip() {
    local s="$1" w="$2"
    if (( ${#s} > w )); then printf '%s…' "${s:0:$((w - 1))}"; else printf '%s' "$s"; fi
}

ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }
err()  { printf '  %s✗%s %s\n' "$CR" "$C0" "$*" >&2; }
info() { printf '  %s›%s %s\n' "$CA" "$C0" "$*"; }
note() { printf '  %s%s%s\n' "$CD" "$*" "$C0"; }
detail() { printf '    %s%s%s\n' "$CD" "$*" "$C0"; }
die()  { err "$*"; exit 1; }

ui_rule() { printf '  %s%s%s\n' "$CD" "$UI_RULE" "$C0"; }
ui_blank() { printf '\n'; }

ui_clear() {
    [ "$UI_TTY" = 1 ] && printf '\033[H\033[2J'
    printf '\n'
}

# ui_header 标题 [右侧说明]
ui_header() {
    local left="$1" right="${2:-}" lw gap
    dwidth "$left"; lw=$_DW
    dwidth "$right"
    gap=$(( UI_W - lw - _DW ))
    (( gap < 2 )) && gap=2
    printf '  %s%s%s%*s%s%s%s\n' "$CB" "$left" "$C0" "$gap" '' "$CD" "$right" "$C0"
}

# ui_page 标题 [右侧说明]：清屏并输出页头
ui_page() {
    ui_clear
    ui_header "$1" "${2:-}"
    ui_rule
}

ui_section() { printf '\n  %s%s%s\n' "$CD" "$1" "$C0"; }

# ui_item 按键 名称 [说明] [按键颜色]
ui_item() {
    local key="$1" label="$2" hint="${3:-}" kc="${4:-$CA}"
    if [ -n "$hint" ]; then
        printf '    %s%s%s  %s%s%s%s\n' "$kc" "$key" "$C0" "$(pad "$label" 30)" "$CD" "$hint" "$C0"
    else
        printf '    %s%s%s  %s\n' "$kc" "$key" "$C0" "$label"
    fi
}

# ui_kv 名称 值
ui_kv() { printf '  %s%s%s%s\n' "$CD" "$(pad "$1" 10)" "$C0" "$2"; }

# ui_bar 百分比 [格数]：输出 ▰▰▰▱▱ 进度条
ui_bar() {
    local pct="$1" cells="${2:-10}" filled i out=''
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    filled=$(( (pct * cells + 50) / 100 ))
    (( pct > 0 && filled == 0 )) && filled=1
    for (( i = 0; i < cells; i++ )); do
        if (( i < filled )); then out+='▰'; else out+='▱'; fi
    done
    printf '%s' "$out"
}

# 读取一行输入；遇到 EOF（Ctrl-D 或输入流结束）直接退出。
_ui_read() {
    local __v
    if ! IFS= read -r -p "$2" __v; then
        printf '\n'
        exit 0
    fi
    __v="${__v//$'\r'/}"
    __v="${__v#"${__v%%[![:space:]]*}"}"
    __v="${__v%"${__v##*[![:space:]]}"}"
    printf -v "$1" '%s' "$__v"
}

# ask 变量名 提示 [默认值] [默认值的显示文字]
ask() {
    local __var="$1" __prompt="$2" __def="${3-}" __show="${4-}" __in
    [ -z "$__show" ] && __show="$__def"
    if [ -n "$__show" ]; then
        _ui_read __in "  $__prompt ${CD}[$__show]${C0} › "
    else
        _ui_read __in "  $__prompt › "
    fi
    printf -v "$__var" '%s' "${__in:-$__def}"
}

# ask_valid 变量名 提示 默认值 显示文字 校验函数 错误提示
# 输入无效时重新询问，最多 3 次；空值（且无默认值）直接接受。
ask_valid() {
    local __var="$1" __prompt="$2" __def="$3" __show="$4" __check="$5" __msg="$6" __val __try
    for __try in 1 2 3; do
        ask __val "$__prompt" "$__def" "$__show"
        if [ -z "$__val" ] || "$__check" "$__val"; then
            printf -v "$__var" '%s' "$__val"
            return 0
        fi
        err "$__msg"
    done
    return 1
}

# confirm 问题 [y|n]
confirm() {
    local q="$1" def="${2:-n}" a hint
    if [ "$def" = y ]; then hint="Y/n"; else hint="y/N"; fi
    _ui_read a "  $q ${CD}[$hint]${C0} › "
    a="${a,,}"
    [ -z "$a" ] && a="$def"
    [[ "$a" == y || "$a" == yes ]]
}

# confirm_word 关键词：危险操作要求手动输入关键词
confirm_word() {
    local a
    _ui_read a "  输入 ${CR}$1${C0} 以确认 › "
    [ "$a" = "$1" ]
}

ui_prompt() { _ui_read "$1" "  ${CA}›${C0} "; }

pause() {
    [ "$UI_TTY" = 1 ] || return 0
    printf '\n  %s按任意键返回%s' "$CD" "$C0"
    IFS= read -r -s -n 1 _ || true
    printf '\n'
}

UI_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# wait_for 描述 超时秒数 命令...：反复执行命令直到成功，期间显示进度
wait_for() {
    local msg="$1" limit="$2" start now n=0
    shift 2
    start=$(date +%s)
    ui_busy
    while :; do
        if "$@"; then
            [ "$UI_TTY" = 1 ] && printf '\r\033[K'
            ui_restore
            return 0
        fi
        now=$(date +%s)
        (( now - start >= limit )) && break
        if [ "$UI_TTY" = 1 ]; then
            printf '\r  %s%s%s %s %s%ss%s' "$CA" "${UI_SPIN[n % 10]}" "$C0" "$msg" "$CD" "$(( now - start ))" "$C0"
        fi
        n=$(( n + 1 ))
        sleep 0.5
    done
    [ "$UI_TTY" = 1 ] && printf '\r\033[K'
    ui_restore
    return 1
}

# spin_run 描述 命令...：后台执行并显示动画，不输出结果（只适合仅产生文件副作用的命令）
spin_run() {
    local msg="$1" rc pid n=0
    shift
    if [ "$UI_TTY" != 1 ]; then
        "$@"
        return
    fi
    ui_busy
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$CA" "${UI_SPIN[n % 10]}" "$C0" "$msg"
        n=$(( n + 1 ))
        sleep 0.1
    done
    wait "$pid"
    rc=$?
    printf '\r\033[K'
    ui_restore
    return "$rc"
}

_to_log() {
    local log="$1"
    shift
    "$@" >"$log" 2>&1
}

# run_step 描述 命令...：同上，完成后显示 ✓ 或 ✗ 与错误输出
run_step() {
    local msg="$1" log rc
    shift
    log=$(mktemp)
    spin_run "$msg" _to_log "$log" "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$msg"
    else
        err "$msg"
        tail -n 8 "$log" | sed "s/^/    /" >&2
    fi
    rm -f "$log"
    return "$rc"
}

# 简单菜单：先 menu_reset，再 menu_add / menu_sep，最后 menu_show 与 menu_read
menu_reset() { MENU_KEYS=(); MENU_LABELS=(); MENU_HINTS=(); MENU_ACTS=(); MENU_COLORS=(); }
menu_add() {
    MENU_KEYS+=("$1"); MENU_LABELS+=("$2"); MENU_HINTS+=("${3:-}"); MENU_ACTS+=("${4:-}"); MENU_COLORS+=("${5:-$CA}")
}
menu_sep() { menu_add "" "$1"; }
menu_show() {
    local i
    for i in "${!MENU_KEYS[@]}"; do
        if [ -z "${MENU_KEYS[$i]}" ]; then
            ui_section "${MENU_LABELS[$i]}"
        else
            ui_item "${MENU_KEYS[$i]}" "${MENU_LABELS[$i]}" "${MENU_HINTS[$i]}" "${MENU_COLORS[$i]}"
        fi
    done
}
# menu_read：读取选择，结果放入 MENU_CHOICE（按键）与 MENU_ACTION（动作）
menu_read() {
    local i
    MENU_ACTION=""
    ui_prompt MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE,,}"
    for i in "${!MENU_KEYS[@]}"; do
        if [ -n "${MENU_KEYS[$i]}" ] && [ "${MENU_KEYS[$i]}" = "$MENU_CHOICE" ]; then
            MENU_ACTION="${MENU_ACTS[$i]}"
            return 0
        fi
    done
    return 1
}

# ============================================================
# 通用工具：校验、解析、状态文件、下载、公网 IP
# ============================================================

is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_username() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,31}$ ]]; }
is_hex32() { [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]; }
is_ip_mode() { [[ "$1" == v4 || "$1" == v6 || "$1" == dual ]]; }
is_domain() {
    (( ${#1} <= 253 )) && [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
is_ipv4() {
    local IFS=. o
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for o in $1; do (( 10#$o <= 255 )) || return 1; done
}
is_ipv6() { [[ "$1" == *:*:* && "$1" =~ ^[0-9A-Fa-f:]+$ && ${#1} -le 39 ]]; }
is_host() { is_ipv4 "$1" || is_ipv6 "$1" || is_domain "$1"; }
is_speed() { [[ "$1" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]] && awk -v v="$1" 'BEGIN { exit !(v > 0) }'; }
is_quota() { parse_quota "$1"; }
is_expire() { parse_expire "$1"; }

ip_mode_label() {
    case $1 in v6) echo "IPv6" ;; dual) echo "双栈" ;; *) echo "IPv4" ;; esac
}

# parse_quota "50G" -> _QUOTA（字节）。支持 K/M/G/T 单位，省略单位按 GB 计算。
parse_quota() {
    local s="${1// /}" num unit mult
    s="${s^^}"
    s="${s%B}"
    [[ "$s" =~ ^([0-9]+(\.[0-9]+)?|\.[0-9]+)([KMGT]?)$ ]] || return 1
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]:-G}"
    case $unit in
        K) mult=1024 ;;
        M) mult=1048576 ;;
        G) mult=1073741824 ;;
        T) mult=1099511627776 ;;
    esac
    _QUOTA=$(awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f", n * m }')
    (( _QUOTA > 0 ))
}

# fmt_bytes 字节数 -> 1.5G / 512M
fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B K M G T", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        s = (i <= 2) ? sprintf("%d", b + 0.5) : sprintf("%.1f", b)
        sub(/\.0$/, "", s)
        printf "%s%s", s, u[i]
    }'
}

# 当前时区偏移，形如 +08:00；可指定本地时间 "YYYY-MM-DD HH:MM:SS"
tz_offset() {
    local z
    if [ -n "${1:-}" ]; then z=$(date -d "$1" +%z 2>/dev/null); else z=$(date +%z); fi
    [[ "$z" =~ ^[+-][0-9]{4}$ ]] || z="+0000"
    printf '%s:%s' "${z:0:3}" "${z:3:2}"
}

# iso_to_epoch "2026-12-31T23:59:59+08:00" -> _EPOCH
iso_to_epoch() {
    local d t sign oh om base
    [[ "$1" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[T\ ]([0-9]{2}:[0-9]{2}(:[0-9]{2})?)(Z|([+-])([0-9]{2}):?([0-9]{2}))?$ ]] || return 1
    d="${BASH_REMATCH[1]}"; t="${BASH_REMATCH[2]}"
    sign="${BASH_REMATCH[5]}"; oh="${BASH_REMATCH[6]}"; om="${BASH_REMATCH[7]}"
    [ ${#t} -eq 5 ] && t="$t:00"
    if [ -z "${BASH_REMATCH[4]}" ]; then
        base=$(date -d "$d $t" +%s 2>/dev/null) || return 1
    else
        base=$(date -u -d "$d $t" +%s 2>/dev/null) || return 1
        if [ -n "$sign" ]; then
            if [ "$sign" = "+" ]; then
                base=$(( base - 10#$oh * 3600 - 10#$om * 60 ))
            else
                base=$(( base + 10#$oh * 3600 + 10#$om * 60 ))
            fi
        fi
    fi
    _EPOCH="$base"
}

# epoch_fmt 时间戳 [格式]：按本地时区显示
epoch_fmt() { date -d "@$1" "+${2:-%Y-%m-%d %H:%M}" 2>/dev/null; }

# parse_expire 输入 [当前到期时间] -> _EXPIRE（ISO 8601，带时区）
# 支持：2026-12-31 / 2026-12-31 18:00 / 2026-12-31 18:00:00 / +30d（在当前到期时间或现在的基础上顺延）
parse_expire() {
    local s="$1" cur="${2:-}" now base days d t local_ts
    now=$(date +%s)
    if [[ "$s" =~ ^\+([0-9]{1,4})[dD]?$ ]]; then
        days=$(( 10#${BASH_REMATCH[1]} ))
        (( days > 0 )) || return 1
        base=$now
        if [ -n "$cur" ] && iso_to_epoch "$cur" && (( _EPOCH > now )); then base=$_EPOCH; fi
        base=$(( base + days * 86400 ))
        local_ts=$(epoch_fmt "$base" "%Y-%m-%d %H:%M:%S")
    elif [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})([\ T]([0-9]{2}:[0-9]{2})(:[0-9]{2})?)?$ ]]; then
        d="${BASH_REMATCH[1]}"
        if [ -n "${BASH_REMATCH[3]}" ]; then
            t="${BASH_REMATCH[3]}${BASH_REMATCH[4]:-:00}"
        else
            t="23:59:59"
        fi
        # 往返格式化校验，拦截 2026-02-30 这类会被自动顺延的日期
        [ "$(date -d "$d $t" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)" = "$d $t" ] || return 1
        local_ts="$d $t"
        base=$(date -d "$local_ts" +%s)
    else
        return 1
    fi
    (( base > now )) || return 1
    _EXPIRE="${local_ts/ /T}$(tz_offset "$local_ts")"
}

# ------------------------------------------------------------
# 状态文件：KEY=VALUE 纯文本，只做解析，不执行
# ------------------------------------------------------------

# state_load 文件 前缀：读取为 前缀_KEY 变量
state_load() {
    local file="$1" prefix="$2" key val
    [ -f "$file" ] || return 1
    while IFS= read -r key || [ -n "$key" ]; do
        key="${key%$'\r'}"
        [[ "$key" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
        val="${BASH_REMATCH[2]}"
        val="${val#\"}"; val="${val%\"}"
        printf -v "${prefix}_${BASH_REMATCH[1]}" '%s' "$val"
    done < "$file"
}

# state_get 文件 KEY [默认值]
state_get() {
    local v
    v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1)
    v="${v#\"}"; v="${v%\"}"
    printf '%s' "${v:-${3:-}}"
}

# state_set 文件 KEY=VALUE...：合并写入
state_set() {
    local file="$1" kv key tmp
    shift
    tmp=$(mktemp)
    [ -f "$file" ] && cp "$file" "$tmp"
    for kv in "$@"; do
        key="${kv%%=*}"
        grep -v "^$key=" "$tmp" > "$tmp.n" || true
        printf '%s\n' "$kv" >> "$tmp.n"
        mv "$tmp.n" "$tmp"
    done
    atomic_write "$file" 0600 < "$tmp"
    rm -f "$tmp"
}

setting_get() { state_get "$SETTINGS_FILE" "$1" "${2:-}"; }
setting_set() { state_set "$SETTINGS_FILE" "$@"; }

# atomic_write 文件 权限 [属主]：从标准输入写入临时文件后原子替换
atomic_write() {
    local file="$1" mode="$2" owner="${3:-}" tmp
    mkdir -p "$(dirname "$file")"
    tmp="$(dirname "$file")/.$(basename "$file").tmp.$$"
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp"
    [ -n "$owner" ] && [ -z "$R" ] && chown "$owner" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file"
}

# ------------------------------------------------------------
# 密钥与链接
# ------------------------------------------------------------

generate_secret() {
    local s=""
    [ -r /dev/urandom ] && s=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')
    if ! is_hex32 "$s" && command -v openssl >/dev/null 2>&1; then
        s=$(openssl rand -hex 16 2>/dev/null | tr -d '[:space:]')
    fi
    if ! is_hex32 "$s"; then
        err "无法生成安全密钥，请检查 /dev/urandom 或 openssl"
        return 1
    fi
    printf '%s' "${s,,}"
}

hex_of() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

# FakeTLS 密钥：ee + 32 位十六进制 + 域名
secret_hex() { printf 'ee%s%s' "${1,,}" "$(hex_of "$2")"; }

# 新版客户端推荐的 base64url 形式（更短）
secret_b64() {
    local esc
    esc=$(secret_hex "$1" "$2" | sed 's/../\\x&/g')
    printf '%b' "$esc" | base64 | tr -d '\n=' | tr '+/' '-_'
}

link_tg() { printf 'tg://proxy?server=%s&port=%s&secret=%s' "$1" "$2" "$3"; }
link_tme() { printf 'https://t.me/proxy?server=%s&port=%s&secret=%s' "$1" "$2" "$3"; }

mask_secret() { printf '%s…%s' "${1:0:4}" "${1: -4}"; }

# ------------------------------------------------------------
# 网络
# ------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# http_get 地址 目标文件
http_get() {
    if have curl; then
        curl -fsSL --connect-timeout 10 --max-time 600 --retry 2 --retry-delay 1 -o "$2" "$1"
    elif have wget; then
        wget -q -T 15 -t 3 -O "$2" "$1"
    else
        err "系统缺少 curl 或 wget"
        return 127
    fi
}

# http_text 地址：短超时读取文本
http_text() {
    if have curl; then
        curl -fsSL --connect-timeout 5 --max-time 10 "$1" 2>/dev/null
    elif have wget; then
        wget -qO- -T 10 "$1" 2>/dev/null
    fi
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{ print $1 }'; }

has_global_ipv6() {
    [ -r /proc/net/if_inet6 ] && awk '$4 == "00" && $1 !~ /^f[cd]/ { found = 1 } END { exit !found }' /proc/net/if_inet6
}

PUBLIC_IPV4="" PUBLIC_IPV6=""
LAST_LINKS=()

# ip_detect 4|6：从多个服务查询公网地址
ip_detect() {
    local fam="$1" url out urls
    if [ "$fam" = 6 ]; then
        has_global_ipv6 || return 1
        urls="https://api.ip.sb/ip https://api6.ipify.org https://ifconfig.co/ip"
    else
        urls="https://api.ip.sb/ip https://api.ipify.org https://ipinfo.io/ip"
    fi
    have curl || return 1
    for url in $urls; do
        out=$(curl -"$fam" -fsS --connect-timeout 3 --max-time 5 -A "Mozilla/5.0" "$url" 2>/dev/null | tr -d '[:space:]')
        if { [ "$fam" = 4 ] && is_ipv4 "$out"; } || { [ "$fam" = 6 ] && is_ipv6 "$out"; }; then
            printf '%s' "$out"
            return 0
        fi
    done
    return 1
}

# ip_load [refresh]：读取缓存的公网地址（6 小时有效），得到 PUBLIC_IPV4 / PUBLIC_IPV6
ip_load() {
    local now ts
    now=$(date +%s)
    PUBLIC_IPV4="" PUBLIC_IPV6=""
    if [ "${1:-}" != refresh ] && [ -f "$IP_CACHE" ]; then
        ts=$(state_get "$IP_CACHE" TS 0)
        if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < 21600 )); then
            PUBLIC_IPV4=$(state_get "$IP_CACHE" V4)
            PUBLIC_IPV6=$(state_get "$IP_CACHE" V6)
            return 0
        fi
    fi
    PUBLIC_IPV4=$(ip_detect 4)
    PUBLIC_IPV6=$(ip_detect 6)
    # 全部失败时不写缓存，下次重新检测
    [ -z "${PUBLIC_IPV4}${PUBLIC_IPV6}" ] && return 1
    printf 'TS=%s\nV4=%s\nV6=%s\n' "$now" "$PUBLIC_IPV4" "$PUBLIC_IPV6" | atomic_write "$IP_CACHE" 0600
}

ip_refresh_ui() {
    [ "$UI_TTY" = 1 ] && printf '  %s%s%s 检测公网地址' "$CA" "${UI_SPIN[0]}" "$C0"
    ip_load refresh
    [ "$UI_TTY" = 1 ] && printf '\r\033[K'
    if [ -n "$PUBLIC_IPV4" ]; then ok "公网 IPv4 $PUBLIC_IPV4"; else warn "未检测到公网 IPv4"; fi
    if [ -n "$PUBLIC_IPV6" ]; then ok "公网 IPv6 $PUBLIC_IPV6"; else detail "未检测到公网 IPv6"; fi
}

# link_hosts 监听模式：输出生成链接用的地址（每行：标签 地址）
link_hosts() {
    local mode="$1" custom
    custom=$(setting_get LINK_HOST)
    if [ -n "$custom" ]; then
        printf '%s %s\n' "自定义" "$custom"
        return 0
    fi
    [ -z "${PUBLIC_IPV4}${PUBLIC_IPV6}" ] && ip_load
    if [[ "$mode" != v6 && -n "$PUBLIC_IPV4" ]]; then printf 'IPv4 %s\n' "$PUBLIC_IPV4"; fi
    if [[ "$mode" != v4 && -n "$PUBLIC_IPV6" ]]; then printf 'IPv6 %s\n' "$PUBLIC_IPV6"; fi
}

# 版本号比较：ver_gt 3.1.0 3.0.9
ver_gt() {
    local i a b
    IFS=. read -ra a <<< "$1"
    IFS=. read -ra b <<< "$2"
    for i in 0 1 2; do
        (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
        (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
    done
    return 1
}

# ------------------------------------------------------------
# 文件快照：修改前保存，失败时恢复
# ------------------------------------------------------------

snap_take() {
    local f
    SNAP_DIR=$(mktemp -d)
    for f in "$@"; do
        if [ -e "$f" ]; then
            cp -p "$f" "$SNAP_DIR/$(printf '%s' "$f" | tr '/' '%')"
        else
            : > "$SNAP_DIR/$(printf '%s' "$f" | tr '/' '%').absent"
        fi
    done
}

snap_restore() {
    local s f
    [ -d "${SNAP_DIR:-}" ] || return 0
    for s in "$SNAP_DIR"/*; do
        [ -e "$s" ] || continue
        f=$(basename "$s")
        if [[ "$f" == *.absent ]]; then
            rm -f "$(printf '%s' "${f%.absent}" | tr '%' '/')"
        else
            cp -p "$s" "$(printf '%s' "$f" | tr '%' '/')"
        fi
    done
}

snap_drop() {
    [ -d "${SNAP_DIR:-}" ] && rm -rf "$SNAP_DIR"
    SNAP_DIR=""
}

# ============================================================
# 系统层：发行版识别、依赖、服务管理、端口、防火墙、定时任务
# ============================================================

OS_ID="" OS_LIKE="" OS_NAME="Linux" PKG="" INIT_SYSTEM="" ARCH=""

os_release_get() {
    sed -n "s/^$1=//p" "$R/etc/os-release" 2>/dev/null | head -n 1 | tr -d '"'
}

detect_os() {
    OS_ID=$(os_release_get ID)
    OS_LIKE=$(os_release_get ID_LIKE)
    OS_NAME=$(os_release_get PRETTY_NAME)
    [ -z "$OS_NAME" ] && OS_NAME="Linux"
    [ -f "$R/etc/alpine-release" ] && OS_ID="alpine"

    case " $OS_ID $OS_LIKE " in
        *" alpine "*) PKG="apk" ;;
        *" debian "*|*" ubuntu "*) PKG="apt" ;;
        *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*|*" amzn "*)
            if have dnf; then PKG="dnf"; else PKG="yum"; fi ;;
        *)
            if have apt-get; then PKG="apt"
            elif have apk; then PKG="apk"
            elif have dnf; then PKG="dnf"
            elif have yum; then PKG="yum"
            fi ;;
    esac

    if [ -n "${MTP_INIT:-}" ]; then
        INIT_SYSTEM="$MTP_INIT"
    elif [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif have openrc-run || [ -x /sbin/openrc-run ]; then
        INIT_SYSTEM="openrc"
    elif have systemctl; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="none"
    fi

    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) ARCH="" ;;
    esac
}

require_platform() {
    if [ "$INIT_SYSTEM" != systemd ] && [ "$INIT_SYSTEM" != openrc ]; then
        err "未检测到 systemd 或 OpenRC，无法管理服务"
        return 1
    fi
    if [ -z "$ARCH" ]; then
        err "暂不支持 $(uname -m) 架构，仅支持 amd64 与 arm64"
        return 1
    fi
    if [ -z "$PKG" ]; then
        err "无法识别的发行版：$OS_NAME"
        return 1
    fi
}

require_root() {
    [ -n "$R" ] && return 0
    [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行"
}

# ------------------------------------------------------------
# 依赖
# ------------------------------------------------------------

pkg_install() {
    case $PKG in
        apk) apk add --no-cache "$@" ;;
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
        *) return 1 ;;
    esac
}

pkg_update() {
    case $PKG in
        apk) apk update ;;
        apt) apt-get update -q ;;
        *) return 0 ;;
    esac
}

# 仅在缺少命令时安装依赖，已齐全时不访问软件源
ensure_deps() {
    local need=() cron_pkg
    have curl || need+=(curl)
    have openssl || need+=(openssl)
    have tar || need+=(tar)
    have sha256sum || need+=(coreutils)
    have crontab || {
        case $PKG in
            apk) cron_pkg="dcron" ;;
            apt) cron_pkg="cron" ;;
            *) cron_pkg="cronie" ;;
        esac
        need+=("$cron_pkg")
    }
    [ -d /etc/ssl/certs ] || need+=(ca-certificates)
    [ "$PKG" = apk ] && ! have logrotate && need+=(logrotate)
    [ ${#need[@]} -eq 0 ] && return 0

    run_step "更新软件源" pkg_update || return 1
    run_step "安装依赖 ${need[*]}" pkg_install "${need[@]}" || return 1
    if [ "$PKG" = apk ] && [ -n "${cron_pkg:-}" ]; then
        pkg_install dcron-openrc >/dev/null 2>&1 || true
    fi
}

# 二维码工具为可选依赖，安装失败不影响使用
ensure_qrencode() {
    local pkg=qrencode
    have qrencode && return 0
    [ "$PKG" = apk ] && pkg=libqrencode-tools
    pkg_install "$pkg" >/dev/null 2>&1 || { pkg_update >/dev/null 2>&1 && pkg_install "$pkg" >/dev/null 2>&1; }
    have qrencode
}

# ------------------------------------------------------------
# 目录与服务账号
# ------------------------------------------------------------

svc_group() { if [ -z "$R" ] && id -u "$SVC_USER" >/dev/null 2>&1; then echo "$SVC_USER"; else echo root; fi; }

ensure_dirs() {
    local g
    g=$(svc_group)
    mkdir -p "$ETC_DIR" "$STATE_DIR" "$LOG_DIR" "$BIN_DIR" "$BACKUP_DIR" "$TELEMT_WORKDIR"
    chmod 0750 "$ETC_DIR" "$LOG_DIR"
    chmod 0700 "$STATE_DIR" "$BACKUP_DIR" "$TELEMT_WORKDIR"
    chmod 0755 "$OPT_DIR" "$BIN_DIR"
    if [ -z "$R" ]; then
        chown "root:$g" "$ETC_DIR" "$LOG_DIR" 2>/dev/null
    fi
}

ensure_service_user() {
    [ -n "$R" ] && return 0
    id -u "$SVC_USER" >/dev/null 2>&1 && return 0
    local shell=/sbin/nologin
    [ -x /usr/sbin/nologin ] && shell=/usr/sbin/nologin
    if have useradd; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell "$shell" "$SVC_USER" >/dev/null 2>&1
    elif have adduser; then
        addgroup -S "$SVC_USER" >/dev/null 2>&1
        adduser -S -D -H -h /nonexistent -s "$shell" -G "$SVC_USER" "$SVC_USER" >/dev/null 2>&1
    fi
    id -u "$SVC_USER" >/dev/null 2>&1
}

remove_service_user() {
    [ -n "$R" ] && return 0
    id -u "$SVC_USER" >/dev/null 2>&1 || return 0
    if have userdel; then userdel "$SVC_USER" >/dev/null 2>&1
    elif have deluser; then deluser "$SVC_USER" >/dev/null 2>&1
    fi
    if have groupdel; then groupdel "$SVC_USER" >/dev/null 2>&1
    elif have delgroup; then delgroup "$SVC_USER" >/dev/null 2>&1
    fi
    return 0
}

# ------------------------------------------------------------
# 服务管理（systemd / OpenRC）
# ------------------------------------------------------------

svc_file() {
    if [ "$INIT_SYSTEM" = openrc ]; then echo "$OPENRC_DIR/$1"; else echo "$SYSTEMD_DIR/$1.service"; fi
}

svc_exists() { [ -f "$(svc_file "$1")" ]; }

svc_active() {
    case $INIT_SYSTEM in
        systemd) systemctl is-active --quiet "$1" 2>/dev/null ;;
        openrc) rc-service "$1" status 2>/dev/null | grep -q started ;;
        *) return 1 ;;
    esac
}

# svc_ctl start|stop|restart 服务
svc_ctl() {
    case $INIT_SYSTEM in
        systemd) systemctl "$1" "$2" >/dev/null 2>&1 ;;
        openrc) rc-service "$2" "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

svc_reload_units() { [ "$INIT_SYSTEM" = systemd ] && systemctl daemon-reload >/dev/null 2>&1; return 0; }

svc_enable() {
    case $INIT_SYSTEM in
        systemd) systemctl daemon-reload >/dev/null 2>&1; systemctl enable "$1" >/dev/null 2>&1 ;;
        openrc) rc-update add "$1" default >/dev/null 2>&1 ;;
    esac
    return 0
}

svc_remove() {
    svc_exists "$1" || return 0
    svc_ctl stop "$1"
    case $INIT_SYSTEM in
        systemd) systemctl disable "$1" >/dev/null 2>&1 ;;
        openrc) rc-update del "$1" default >/dev/null 2>&1 ;;
    esac
    rm -f "$(svc_file "$1")"
    svc_reload_units
}

proc_pid() {
    local f comm
    for f in /proc/[0-9]*/comm; do
        [ -r "$f" ] || continue
        IFS= read -r comm < "$f" 2>/dev/null || continue
        if [ "$comm" = "$1" ]; then
            f="${f#/proc/}"
            printf '%s' "${f%%/*}"
            return 0
        fi
    done
    return 1
}

# svc_pid 服务 进程名
svc_pid() {
    local pid=""
    [ "$INIT_SYSTEM" = systemd ] && pid=$(systemctl show -p MainPID --value "$1" 2>/dev/null)
    if [ -z "$pid" ] || [ "$pid" = 0 ]; then pid=$(proc_pid "$2"); fi
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && printf '%s' "$pid"
}

# 进程内存与运行时长，输出 "12.4 MB|3天4时"
proc_stats() {
    local pid="$1" rss stat start boot hz diff d h m up=""
    rss=$(awk '/^VmRSS/ { printf "%.1f MB", $2 / 1024 }' "/proc/$pid/status" 2>/dev/null)
    # /proc/PID/stat 第 22 列是进程启动时刻（开机后的时钟节拍数）
    stat=$(cat "/proc/$pid/stat" 2>/dev/null)
    stat="${stat##*) }"
    start=$(awk '{ print $20 }' <<< "$stat")
    boot=$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    if [[ "$start" =~ ^[0-9]+$ && "$boot" =~ ^[0-9]+$ && "$hz" =~ ^[0-9]+$ ]] && (( hz > 0 )); then
        diff=$(( boot - start / hz ))
        (( diff < 0 )) && diff=0
        d=$(( diff / 86400 )); h=$(( diff % 86400 / 3600 )); m=$(( diff % 3600 / 60 ))
        if (( d > 0 )); then up="${d}天${h}时"; elif (( h > 0 )); then up="${h}时${m}分"; else up="${m}分"; fi
    fi
    printf '%s|%s' "$rss" "$up"
}

svc_logs() {
    local name="$1" lines="${2:-50}"
    if [ "$INIT_SYSTEM" = systemd ]; then
        journalctl -u "$name" -n "$lines" --no-pager 2>/dev/null
    else
        tail -n "$lines" "$LOG_DIR/$name.log" 2>/dev/null
    fi
}

# 显示日志时隐藏连接密钥
redact() { sed -E 's/(secret=)[A-Za-z0-9_=-]+/\1***/g; s/(EE-TLS:[[:space:]]*).*/\1***/'; }

# ------------------------------------------------------------
# 端口（直接读取 /proc，无需 ss）
# ------------------------------------------------------------

port_inodes() {
    local hex
    printf -v hex '%04X' "$((10#$1))"
    awk -v p=":$hex" '$4 == "0A" && substr($2, length($2) - 4) == p { print $10 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

port_is_listening() { [ -n "$(port_inodes "$1")" ]; }

# 找出监听端口的进程名；没有权限读取时输出为空
port_owner_names() {
    local port="$1" out inodes
    if have ss; then
        out=$(ss -H -ltnp "sport = :$port" 2>/dev/null | grep -oE '\("[^"]+"' | tr -d '("' | sort -u)
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
    inodes=$(port_inodes "$port" | tr '\n' ' ')
    [ -n "${inodes// /}" ] || return 0
    # shellcheck disable=SC2012
    ls -l /proc/[0-9]*/fd/ 2>/dev/null | awk -v inodes=" $inodes " '
        /^\/proc\// { split($0, p, "/"); pid = p[3]; next }
        /socket:\[/ {
            s = $NF; gsub(/^socket:\[|\]$/, "", s)
            if (index(inodes, " " s " ")) print pid
        }' | sort -u | while read -r pid; do
            cat "/proc/$pid/comm" 2>/dev/null
        done | sort -u
}

# port_owned_by 端口 进程名 [配置中的端口]
port_owned_by() {
    local port="$1" name="$2" owners
    port_is_listening "$port" || return 1
    owners=$(port_owner_names "$port")
    if [ -n "$owners" ]; then
        printf '%s\n' "$owners" | grep -qx "$name"
        return
    fi
    # 受限容器中读不到进程信息：以进程存在作为依据
    proc_pid "$name" >/dev/null
}

# 端口被其他程序占用（允许被指定进程自身占用）
port_taken_by_other() {
    local port="$1" self="${2:-}"
    port_is_listening "$port" || return 1
    [ -n "$self" ] && port_owned_by "$port" "$self" && return 1
    return 0
}

# ------------------------------------------------------------
# 防火墙
# ------------------------------------------------------------

fw_backend() {
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then echo firewalld
    # 默认拒绝，或末尾有兜底 REJECT/DROP 规则（如 Oracle Cloud 的 Ubuntu 镜像）
    elif have iptables && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|^-A INPUT -j (REJECT|DROP)'; then echo iptables
    elif have nft && nft list chain inet filter input 2>/dev/null | grep -q 'policy drop'; then echo nftables
    else echo none
    fi
}

fw_label() {
    case $1 in ufw) echo "ufw" ;; firewalld) echo "firewalld" ;; iptables) echo "iptables" ;; nftables) echo "nftables" ;; *) echo "无" ;; esac
}

# fw_port_open 后端 端口
fw_port_open() {
    case $1 in
        ufw)
            ufw status verbose 2>/dev/null | grep -q 'Default: allow (incoming)' && return 0
            ufw status 2>/dev/null | grep -qE "^$2(/tcp)?[[:space:]]+ALLOW" ;;
        firewalld) firewall-cmd --query-port="$2/tcp" >/dev/null 2>&1 ;;
        iptables) iptables -C INPUT -p tcp --dport "$2" -j ACCEPT >/dev/null 2>&1 ;;
        nftables) nft list chain inet filter input 2>/dev/null | grep -qE "tcp dport (\{[^}]*[ ,]$2[ ,}]|$2 )" ;;
        *) return 0 ;;
    esac
}

fw_allow() {
    local backend="$1" port="$2"
    case $backend in
        ufw) ufw allow "$port/tcp" >/dev/null 2>&1 ;;
        firewalld) firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 ;;
        iptables)
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || return 1
            have ip6tables && ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
            if have netfilter-persistent; then netfilter-persistent save >/dev/null 2>&1
            elif [ -d /etc/iptables ]; then iptables-save > /etc/iptables/rules.v4 2>/dev/null
            else warn "iptables 规则未持久化，重启后需重新放行"
            fi ;;
        *) return 1 ;;
    esac
}

# fw_offer 端口：防火墙未放行时询问是否放行
fw_offer() {
    local backend
    backend=$(fw_backend)
    [ "$backend" = none ] && return 0
    fw_port_open "$backend" "$1" && return 0
    if [ "$backend" = nftables ]; then
        warn "nftables 未放行 $1/tcp，请手动添加规则"
        return 0
    fi
    warn "防火墙 $(fw_label "$backend") 未放行 $1/tcp"
    if confirm "现在放行？" y; then
        if fw_allow "$backend" "$1"; then ok "已放行 $1/tcp"; else err "放行失败，请手动处理"; fi
    fi
}

# ------------------------------------------------------------
# 定时任务与日志轮转
# ------------------------------------------------------------

cron_has() { crontab -l 2>/dev/null | grep -q "$CRON_TAG"; }

cron_install() {
    local svc
    have crontab || { err "缺少 crontab，无法启用定时清零"; return 1; }
    if ! { crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_LINE"; } | crontab - 2>/dev/null; then
        err "写入定时任务失败"
        return 1
    fi
    if [ "$INIT_SYSTEM" = systemd ]; then
        for svc in cron crond cronie; do
            if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "^$svc.service"; then
                systemctl enable --now "$svc" >/dev/null 2>&1 && return 0
            fi
        done
    else
        for svc in crond dcron cronie; do
            if [ -x "/etc/init.d/$svc" ]; then
                rc-update add "$svc" default >/dev/null 2>&1
                rc-service "$svc" start >/dev/null 2>&1
                return 0
            fi
        done
    fi
    warn "未找到 cron 服务，定时任务可能不会执行"
    return 0
}

cron_remove() {
    have crontab || return 0
    cron_has || return 0
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null
    return 0
}

logrotate_install() {
    [ -d "$(dirname "$LOGROTATE_FILE")" ] || return 0
    atomic_write "$LOGROTATE_FILE" 0644 <<EOF
$LOG_DIR/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

# ============================================================
# 两个内核共用：向导输入、端口冲突、TLS 检查、链接与二维码
# ============================================================

step_label() { printf '%s%s%s  %s' "$CD" "$1" "$C0" "$(pad "$2" 8)"; }

# 伪装域名是否支持 TLS 1.3。返回 0 支持，1 不支持，2 无法检测
tls13_check() {
    have openssl || return 2
    openssl s_client -help 2>&1 | grep -q -- '-tls1_3' || return 2
    timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 </dev/null 2>/dev/null | grep -q 'TLSv1\.3'
}

# port_check 端口 用途(mtg|telemt|user) [排除的用户名]：可用返回 0，否则输出原因
port_check() {
    local port="$((10#$1))" owner="$2" skip="${3:-}" p name self=""
    if [ "$owner" != mtg ] && [ -f "$MTG_STATE" ] && [ "$(state_get "$MTG_STATE" PORT)" = "$port" ]; then
        echo "已被 Go 内核使用"; return 1
    fi
    if [ -f "$TELEMT_STATE" ]; then
        if [ "$owner" != telemt ] && [ "$(state_get "$TELEMT_STATE" PORT)" = "$port" ]; then
            if [ "$owner" = user ]; then echo "是 Telemt 的共享端口"; else echo "已被 Telemt 使用"; fi
            return 1
        fi
        if [ -f "$USERS_DB" ]; then
            while IFS=$'\t' read -r name _ p _; do
                [[ -z "$name" || "$name" == \#* ]] && continue
                if [ "$p" = "$port" ] && [ "$name" != "$skip" ]; then
                    echo "已被用户 $name 使用"; return 1
                fi
            done < "$USERS_DB"
        fi
    fi
    case $owner in mtg) self="mtg-go" ;; *) self="telemt" ;; esac
    if port_taken_by_other "$port" "$self"; then
        echo "已被其他程序占用"; return 1
    fi
    return 0
}

# port_suggest 用途：返回第一个可用的常用 HTTPS 端口
port_suggest() {
    local p
    for p in 443 8443 2053 2083 2087 2096 9443; do
        port_check "$p" "$1" >/dev/null && { echo "$p"; return 0; }
    done
    echo 443
}

# wiz_domain 变量 步骤 默认值
wiz_domain() {
    local __d rc
    note "可选：www.apple.com · www.microsoft.com · www.cloudflare.com · www.bing.com"
    ask_valid __d "$(step_label "$2" 伪装域名)" "$3" "" is_domain "域名格式不正确，例如 www.apple.com" || return 1
    __d="${__d,,}"
    spin_run "检查 $__d" tls13_check "$__d"
    rc=$?
    case $rc in
        0) ok "$__d 支持 TLS 1.3" ;;
        2) ;;
        *) warn "未能确认 $__d 支持 TLS 1.3，建议换一个域名" ;;
    esac
    printf -v "$1" '%s' "$__d"
}

# wiz_ip_mode 变量 步骤
wiz_ip_mode() {
    local __m __try
    for __try in 1 2 3; do
        ask __m "$(step_label "$2" 监听模式) 1 IPv4 · 2 IPv6 · 3 双栈" 1
        case $__m in
            1) printf -v "$1" v4; return 0 ;;
            2)
                if [ -z "$PUBLIC_IPV6" ]; then
                    err "未检测到公网 IPv6，无法使用仅 IPv6 模式"
                    continue
                fi
                printf -v "$1" v6; return 0 ;;
            3)
                [ -z "$PUBLIC_IPV6" ] && warn "未检测到公网 IPv6，双栈模式下只有 IPv4 可用"
                printf -v "$1" dual; return 0 ;;
            *) err "请输入 1、2 或 3" ;;
        esac
    done
    return 1
}

# wiz_port 变量 步骤 默认值 用途 [排除的用户名]
wiz_port() {
    local __p __why __try
    for __try in 1 2 3; do
        ask __p "$(step_label "$2" 端口)" "$3"
        if ! is_port "$__p"; then
            err "端口需为 1–65535 的整数"
            continue
        fi
        __p=$((10#$__p))
        if __why=$(port_check "$__p" "$4" "${5:-}"); then
            printf -v "$1" '%s' "$__p"
            return 0
        fi
        err "端口 $__p $__why"
    done
    return 1
}

# ------------------------------------------------------------
# 链接展示
# ------------------------------------------------------------

# show_links 监听模式 端口 FakeTLS密钥(base64)
# 每个地址输出 tg:// 与 t.me 两种链接，并记录到 LAST_LINKS 供二维码使用
show_links() {
    local mode="$1" port="$2" secret="$3" label host found=0
    LAST_LINKS=()
    while read -r label host; do
        [ -z "$host" ] && continue
        found=1
        printf '\n  %s%s%s %s\n' "$CD" "$label" "$C0" "$host"
        printf '  %s\n' "$(link_tg "$host" "$port" "$secret")"
        printf '  %s\n' "$(link_tme "$host" "$port" "$secret")"
        LAST_LINKS+=("$(link_tme "$host" "$port" "$secret")")
    done < <(link_hosts "$mode")
    if [ "$found" = 0 ]; then
        printf '\n'
        warn "未检测到可用的公网地址，可在「端口与域名」中设置链接地址"
        detail "密钥 $secret"
    fi
}

# 为 LAST_LINKS 中的链接显示二维码
show_qr() {
    local link
    if [ ${#LAST_LINKS[@]} -eq 0 ]; then
        warn "没有可显示的链接"
        return 0
    fi
    if ! have qrencode; then
        spin_run "安装二维码工具" ensure_qrencode
        have qrencode || { warn "无法安装 qrencode，请直接复制链接"; return 0; }
    fi
    for link in "${LAST_LINKS[@]}"; do
        printf '\n'
        qrencode -t ANSIUTF8 -m 2 "$link" | sed 's/^/  /'
        detail "${link%%&secret=*}"
    done
}

# links_menu：链接页底部操作
links_menu() {
    local c
    printf '\n'
    ui_rule
    ui_item v "二维码"
    ui_item 0 "返回"
    printf '\n'
    ui_prompt c
    [ "${c,,}" = v ] && { show_qr; pause; }
    return 0
}

# 服务状态文本：● 运行中 / ○ 已停止 / ○ 未安装
svc_status_text() {
    if ! svc_exists "$1"; then
        printf '%s○ 未安装%s' "$CD" "$C0"
    elif svc_active "$1"; then
        printf '%s● 运行中%s' "$CG" "$C0"
    else
        printf '%s○ 已停止%s' "$CR" "$C0"
    fi
}

# 启动失败时输出最近日志（隐藏密钥）
svc_show_failure() {
    detail "最近日志："
    svc_logs "$1" 15 | redact | sed 's/^/    /' | tail -n 15
}

# ============================================================
# Go 内核（mtg）
# ============================================================

mtg_installed() { [ -f "$MTG_STATE" ]; }

mtg_load() {
    MTG_PORT="" MTG_SECRET="" MTG_DOMAIN="" MTG_IP_MODE=""
    state_load "$MTG_STATE" MTG
    is_ip_mode "$MTG_IP_MODE" || MTG_IP_MODE="v4"
}

mtg_save() {
    printf 'PORT=%s\nSECRET=%s\nDOMAIN=%s\nIP_MODE=%s\n' \
        "$MTG_PORT" "$MTG_SECRET" "$MTG_DOMAIN" "$MTG_IP_MODE" | atomic_write "$MTG_STATE" 0600
}

mtg_ready() { svc_active mtg && port_owned_by "$MTG_PORT" mtg-go; }

# mtg_render_config 加固(1|0)：密钥写入配置文件，不再出现在进程参数里
mtg_render_config() {
    local bind pref mode=0600 owner="root:root"
    case $MTG_IP_MODE in
        v6) bind="[::]:$MTG_PORT"; pref="only-ipv6" ;;
        dual) bind="[::]:$MTG_PORT"; pref="prefer-ipv6" ;;
        *) bind="0.0.0.0:$MTG_PORT"; pref="only-ipv4" ;;
    esac
    if [ "$1" = 1 ]; then mode=0640; owner="root:$SVC_USER"; fi
    atomic_write "$MTG_CONF" "$mode" "$owner" <<EOF
# 由 mtp 生成，请通过 mtp 修改
secret = "$(secret_hex "$MTG_SECRET" "$MTG_DOMAIN")"
bind-to = "$bind"
prefer-ip = "$pref"
concurrency = 65535
domain-fronting-port = 443
allow-fallback-on-unknown-dc = true

[network]
doh-ip = "1.1.1.1"

[network.timeout]
tcp = "30s"
http = "30s"
idle = "30s"

[defense.anti-replay]
enabled = true
max-size = "1mib"
EOF
}

# mtg_render_service 加固(1|0)
mtg_render_service() {
    local harden="$1" log="$LOG_DIR/mtg.log"
    if [ "$INIT_SYSTEM" = openrc ]; then
        : >> "$log"
        chmod 0600 "$log"
        [ "$harden" = 1 ] && [ -z "$R" ] && chown "$SVC_USER:$SVC_USER" "$log"
        {
            cat <<EOF
#!/sbin/openrc-run
name="mtg"
description="MTProxy (Go · mtg)"
command="$BIN_DIR/mtg-go"
command_args="run $MTG_CONF"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 65535"
pidfile="/run/mtg.pid"
output_log="$log"
error_log="$log"
EOF
            if [ "$harden" = 1 ]; then
                printf 'command_user="%s:%s"\ncapabilities="^cap_net_bind_service"\n' "$SVC_USER" "$SVC_USER"
            fi
            printf '\ndepend() {\n    need net\n    after firewall\n}\n'
        } | atomic_write "$(svc_file mtg)" 0755
        return
    fi
    {
        cat <<EOF
[Unit]
Description=MTProxy (Go · mtg)
Documentation=https://github.com/$MTP_REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/mtg-go run $MTG_CONF
Restart=always
RestartSec=3
LimitNOFILE=65535
EOF
        if [ "$harden" = 1 ]; then
            cat <<EOF
User=$SVC_USER
Group=$SVC_USER
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
EOF
        fi
        printf '\n[Install]\nWantedBy=multi-user.target\n'
    } | atomic_write "$(svc_file mtg)" 0644
}

_mtg_start() {
    mtg_render_config "$1"
    mtg_render_service "$1"
    svc_enable mtg
    svc_ctl restart mtg
    wait_for "启动 Go 服务" 15 mtg_ready
}

# mtg_apply：写入配置并重启；加固模式失败时自动改用兼容模式
mtg_apply() { with_lock _mtg_apply; }

_mtg_apply() {
    local harden
    harden=$(setting_get HARDEN_MTG 1)
    [ "$harden" = 1 ] && ! ensure_service_user && harden=0
    # 服务账号需要能进入配置目录读取 mtg.toml
    ensure_dirs
    if _mtg_start "$harden"; then
        setting_set "HARDEN_MTG=$harden"
        return 0
    fi
    if [ "$harden" = 1 ]; then
        note "当前环境不支持加固模式，改用兼容模式"
        if _mtg_start 0; then
            setting_set "HARDEN_MTG=0"
            return 0
        fi
    fi
    err "Go 服务启动失败"
    svc_show_failure mtg
    return 1
}

# mtg_commit 描述：应用当前内存中的配置，失败时回滚到修改前
mtg_commit() {
    local existed=0
    [ -f "$MTG_STATE" ] && existed=1
    snap_take "$MTG_STATE" "$MTG_CONF" "$(svc_file mtg)"
    mtg_save
    if mtg_apply; then
        snap_drop
        ok "$1"
        return 0
    fi
    [ "$existed" = 0 ] && svc_remove mtg
    snap_restore
    snap_drop
    if [ "$existed" = 1 ]; then
        svc_reload_units
        svc_ctl restart mtg
        warn "已恢复修改前的配置"
    fi
    return 1
}

mtg_show_info() {
    mtg_installed || { warn "Go 内核未安装"; return 1; }
    mtg_load
    ui_header "Go · mtg" "$(svc_status_text mtg)"
    ui_rule
    ui_kv "端口" "$MTG_PORT"
    ui_kv "伪装域名" "$MTG_DOMAIN"
    ui_kv "监听" "$(ip_mode_label "$MTG_IP_MODE")"
    show_links "$MTG_IP_MODE" "$MTG_PORT" "$(secret_b64 "$MTG_SECRET" "$MTG_DOMAIN")"
}

mtg_install() {
    local domain mode port
    ui_page "安装 Go 内核" "mtg"
    if mtg_installed; then
        mtg_load
        note "已安装 · :$MTG_PORT · $MTG_DOMAIN · $(ip_mode_label "$MTG_IP_MODE")"
        printf '\n'
        menu_reset
        menu_add 1 "更新内核" "保留配置与链接" upgrade
        menu_add 2 "重新安装" "生成新密钥，旧链接失效" fresh
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || return 0
        case $MENU_ACTION in
            upgrade) printf '\n'; core_upgrade mtg; return ;;
            fresh) printf '\n' ;;
            *) return 0 ;;
        esac
    fi
    require_platform || return 1
    ensure_deps || return 1
    ip_refresh_ui
    printf '\n'
    wiz_domain domain "1/3" "www.apple.com" || return 1
    wiz_ip_mode mode "2/3" || return 1
    wiz_port port "3/3" "$(port_suggest mtg)" mtg || return 1
    printf '\n'
    ui_rule
    ui_kv "即将安装" "Go · $(ip_mode_label "$mode") · :$port · $domain"
    confirm "确认安装？" y || { note "已取消"; return 0; }
    printf '\n'

    core_install mtg || return 1
    MTG_SECRET=$(generate_secret) || return 1
    MTG_PORT="$port" MTG_DOMAIN="$domain" MTG_IP_MODE="$mode"
    ensure_dirs
    mtg_commit "Go 内核已启动，监听 $port" || return 1
    logrotate_install
    fw_offer "$port"
    printf '\n'
    mtg_show_info
}

# mtg_modify 项目(port|domain|mode|secret)
mtg_modify() {
    local v
    mtg_installed || { warn "Go 内核未安装"; return 1; }
    mtg_load
    case $1 in
        port)
            wiz_port v "" "$MTG_PORT" mtg || return 1
            [ "$v" = "$MTG_PORT" ] && { note "端口未变化"; return 0; }
            MTG_PORT="$v"
            mtg_commit "端口已改为 $v，密钥保持不变" || return 1 ;;
        domain)
            wiz_domain v "" "$MTG_DOMAIN" || return 1
            [ "$v" = "$MTG_DOMAIN" ] && { note "域名未变化"; return 0; }
            MTG_DOMAIN="$v"
            mtg_commit "伪装域名已改为 $v，链接已更新" || return 1 ;;
        mode)
            ip_load
            wiz_ip_mode v "" || return 1
            [ "$v" = "$MTG_IP_MODE" ] && { note "监听模式未变化"; return 0; }
            MTG_IP_MODE="$v"
            mtg_commit "监听模式已改为 $(ip_mode_label "$v")" || return 1 ;;
        secret)
            confirm "重置密钥后旧链接立即失效，继续？" n || return 0
            MTG_SECRET=$(generate_secret) || return 1
            mtg_commit "密钥已重置" || return 1 ;;
    esac
    printf '\n'
    mtg_show_info
}

mtg_uninstall() {
    svc_remove mtg
    rm -f "$MTG_STATE" "$MTG_CONF" "$BIN_DIR/mtg-go" "$BIN_DIR/mtg-go.bak" "$LOG_DIR/mtg.log"
    core_state_clear mtg
    ok "Go 内核已删除"
}

# ============================================================
# Rust 内核（Telemt）
# 用户数据以 users.db 为准，每次变更都重新生成完整的 telemt.toml
# ============================================================

declare -A Q_USED=()

telemt_installed() { [ -f "$TELEMT_STATE" ]; }

telemt_load() {
    TELEMT_PORT="" TELEMT_DOMAIN="" TELEMT_IP_MODE="" TELEMT_MAIN_USER="" TELEMT_AD_TAG=""
    state_load "$TELEMT_STATE" TELEMT
    is_ip_mode "$TELEMT_IP_MODE" || TELEMT_IP_MODE="v4"
}

telemt_save() {
    printf 'PORT=%s\nDOMAIN=%s\nIP_MODE=%s\nMAIN_USER=%s\nAD_TAG=%s\n' \
        "$TELEMT_PORT" "$TELEMT_DOMAIN" "$TELEMT_IP_MODE" "$TELEMT_MAIN_USER" "$TELEMT_AD_TAG" \
        | atomic_write "$TELEMT_STATE" 0600
}

# ------------------------------------------------------------
# 用户数据：制表符分隔，空值写作 "-"
# 名称 密钥 专属端口 配额(字节) 到期(ISO) 上行(MB/s) 下行(MB/s) 创建日期
# ------------------------------------------------------------

users_load() {
    U_NAME=() U_SECRET=() U_PORT=() U_QUOTA=() U_EXPIRE=() U_UP=() U_DOWN=() U_CREATED=()
    [ -f "$USERS_DB" ] || return 0
    local n s p q e u d c
    while IFS=$'\t' read -r n s p q e u d c || [ -n "$n" ]; do
        [[ -z "$n" || "$n" == \#* ]] && continue
        is_username "$n" && is_hex32 "$s" || continue
        U_NAME+=("$n") U_SECRET+=("${s,,}") U_PORT+=("${p:--}") U_QUOTA+=("${q:--}")
        U_EXPIRE+=("${e:--}") U_UP+=("${u:--}") U_DOWN+=("${d:--}") U_CREATED+=("${c:--}")
    done < "$USERS_DB"
}

users_save() {
    local i
    {
        printf '# name\tsecret\tport\tquota\texpire\tup\tdown\tcreated\n'
        for i in "${!U_NAME[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${U_NAME[i]}" "${U_SECRET[i]}" "${U_PORT[i]}" \
                "${U_QUOTA[i]}" "${U_EXPIRE[i]}" "${U_UP[i]}" "${U_DOWN[i]}" "${U_CREATED[i]}"
        done
    } | atomic_write "$USERS_DB" 0600
}

# user_find 名称 -> _UIDX
user_find() {
    local i
    for i in "${!U_NAME[@]}"; do
        [ "${U_NAME[i]}" = "$1" ] && { _UIDX=$i; return 0; }
    done
    return 1
}

user_drop_index() {
    local i="$1"
    unset "U_NAME[i]" "U_SECRET[i]" "U_PORT[i]" "U_QUOTA[i]" "U_EXPIRE[i]" "U_UP[i]" "U_DOWN[i]" "U_CREATED[i]"
    U_NAME=("${U_NAME[@]}") U_SECRET=("${U_SECRET[@]}") U_PORT=("${U_PORT[@]}") U_QUOTA=("${U_QUOTA[@]}")
    U_EXPIRE=("${U_EXPIRE[@]}") U_UP=("${U_UP[@]}") U_DOWN=("${U_DOWN[@]}") U_CREATED=("${U_CREATED[@]}")
}

user_port() { if [ "${U_PORT[$1]}" != - ]; then echo "${U_PORT[$1]}"; else echo "$TELEMT_PORT"; fi; }

# ------------------------------------------------------------
# 流量用量：/etc/telemt_quota.json，由 Telemt 在运行中写入
# 修改前必须先停止服务，否则会被 Telemt 退出时写回的旧数据覆盖
# ------------------------------------------------------------

quota_load() {
    Q_USED=()
    [ -s "$TELEMT_QUOTA_JSON" ] || return 0
    local k v
    while IFS=: read -r k v; do
        [ -n "$k" ] && Q_USED["$k"]="$v"
    done < <(grep -oE '"[A-Za-z0-9_-]+"[[:space:]]*:[[:space:]]*[0-9]+' "$TELEMT_QUOTA_JSON" | tr -d '" \t')
}

# 只处理 {"用户":数字,...} 这种扁平格式，其他格式一律不改动
quota_flat_ok() {
    [ -s "$TELEMT_QUOTA_JSON" ] || return 0
    tr -d ' \t\r\n' < "$TELEMT_QUOTA_JSON" | grep -qE '^\{("[A-Za-z0-9_-]+":[0-9]+(,"[A-Za-z0-9_-]+":[0-9]+)*)?\}$'
}

# quota_edit zero=名称 drop=名称 ...
quota_edit() {
    [ $# -eq 0 ] && return 0
    [ -s "$TELEMT_QUOTA_JSON" ] || return 0
    if ! quota_flat_ok; then
        warn "流量记录格式无法识别，未做修改"
        return 1
    fi
    quota_load
    local op out="{" sep="" k
    for op in "$@"; do
        case $op in
            zero=*) [ -n "${Q_USED[${op#zero=}]+x}" ] && Q_USED["${op#zero=}"]=0 ;;
            drop=*) unset "Q_USED[${op#drop=}]" ;;
        esac
    done
    for k in "${!Q_USED[@]}"; do
        out+="$sep\"$k\":${Q_USED[$k]}"
        sep=","
    done
    printf '%s}' "$out" | atomic_write "$TELEMT_QUOTA_JSON" 0600
}

# ------------------------------------------------------------
# 生成配置与服务
# ------------------------------------------------------------

telemt_render_config() {
    local i has
    {
        printf '# 由 mtp 生成，请通过 mtp 修改。\n'
        printf '# 自定义配置可写入 %s（仅能新增表），会追加到本文件末尾。\n\n' "${TELEMT_EXTRA#"$R"}"
        printf '[general]\n'
        if [ -n "$TELEMT_AD_TAG" ]; then
            printf 'use_middle_proxy = true\nad_tag = "%s"\n' "$TELEMT_AD_TAG"
        else
            printf 'use_middle_proxy = false\n'
        fi
        printf '\n[general.modes]\nclassic = false\nsecure = false\ntls = true\n'
        printf '\n[network]\nipv4 = %s\nipv6 = %s\nprefer = %s\n' \
            "$([ "$TELEMT_IP_MODE" = v6 ] && echo false || echo true)" \
            "$([ "$TELEMT_IP_MODE" = v4 ] && echo false || echo true)" \
            "$([ "$TELEMT_IP_MODE" = v6 ] && echo 6 || echo 4)"
        printf '\n[server]\nport = %s\n' "$TELEMT_PORT"
        [ "$TELEMT_IP_MODE" != v6 ] && printf '\n[[server.listeners]]\nip = "0.0.0.0"\n'
        [ "$TELEMT_IP_MODE" != v4 ] && printf '\n[[server.listeners]]\nip = "::"\n'
        printf '\n[censorship]\ntls_domain = "%s"\nmask = true\ntls_emulation = false\n' "$TELEMT_DOMAIN"

        printf '\n[access.users]\n'
        for i in "${!U_NAME[@]}"; do printf '%s = "%s"\n' "${U_NAME[i]}" "${U_SECRET[i]}"; done

        has=""; for i in "${!U_NAME[@]}"; do [ "${U_PORT[i]}" != - ] && has=1; done
        if [ -n "$has" ]; then
            printf '\n[access.user_ports]\n'
            for i in "${!U_NAME[@]}"; do [ "${U_PORT[i]}" != - ] && printf '%s = %s\n' "${U_NAME[i]}" "${U_PORT[i]}"; done
        fi
        has=""; for i in "${!U_NAME[@]}"; do [ "${U_QUOTA[i]}" != - ] && has=1; done
        if [ -n "$has" ]; then
            printf '\n[access.user_data_quota]\n'
            for i in "${!U_NAME[@]}"; do [ "${U_QUOTA[i]}" != - ] && printf '%s = %s\n' "${U_NAME[i]}" "${U_QUOTA[i]}"; done
        fi
        has=""; for i in "${!U_NAME[@]}"; do [ "${U_EXPIRE[i]}" != - ] && has=1; done
        if [ -n "$has" ]; then
            printf '\n[access.user_expirations]\n'
            for i in "${!U_NAME[@]}"; do [ "${U_EXPIRE[i]}" != - ] && printf '%s = %s\n' "${U_NAME[i]}" "${U_EXPIRE[i]}"; done
        fi
        has=""; for i in "${!U_NAME[@]}"; do [ "${U_UP[i]}${U_DOWN[i]}" != -- ] && has=1; done
        if [ -n "$has" ]; then
            printf '\n[access.user_speed_limits]\n'
            for i in "${!U_NAME[@]}"; do
                [ "${U_UP[i]}${U_DOWN[i]}" = -- ] && continue
                printf '%s = "%s %s"\n' "${U_NAME[i]}" "${U_UP[i]/#-/0}" "${U_DOWN[i]/#-/0}"
            done
        fi
        if [ -s "$TELEMT_EXTRA" ]; then
            printf '\n# ---- %s ----\n' "${TELEMT_EXTRA#"$R"}"
            cat "$TELEMT_EXTRA"
        fi
    } | atomic_write "$TELEMT_CONF" 0600
}

telemt_render_service() {
    local harden="$1" log="$LOG_DIR/telemt.log"
    if [ "$INIT_SYSTEM" = openrc ]; then
        : >> "$log"
        chmod 0600 "$log"
        atomic_write "$(svc_file telemt)" 0755 <<EOF
#!/sbin/openrc-run
name="telemt"
description="MTProxy (Rust · Telemt)"
command="$BIN_DIR/telemt"
command_args="$TELEMT_CONF"
directory="$TELEMT_WORKDIR"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 65535"
pidfile="/run/telemt.pid"
output_log="$log"
error_log="$log"
export RUST_LOG=info

depend() {
    need net
    after firewall
}
EOF
        return
    fi
    {
        cat <<EOF
[Unit]
Description=MTProxy (Rust · Telemt)
Documentation=https://github.com/$MTP_REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$TELEMT_WORKDIR
Environment=RUST_LOG=info
ExecStart=$BIN_DIR/telemt $TELEMT_CONF
Restart=always
RestartSec=5
LimitNOFILE=65535
EOF
        # Telemt 需要写入 /etc/telemt_quota.json，因此只保护 /usr 与 /boot
        if [ "$harden" = 1 ]; then
            cat <<EOF
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=true
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
EOF
        fi
        printf '\n[Install]\nWantedBy=multi-user.target\n'
    } | atomic_write "$(svc_file telemt)" 0644
}

telemt_ready() { svc_active telemt && port_owned_by "$TELEMT_PORT" telemt; }

# _telemt_start 加固 [流量操作...]
_telemt_start() {
    local harden="$1"
    shift
    mkdir -p "$TELEMT_WORKDIR"
    telemt_render_config
    telemt_render_service "$harden"
    svc_enable telemt
    svc_ctl stop telemt
    quota_edit "$@"
    svc_ctl start telemt
    # Telemt 启动时会先探测网络，通常需要 10 秒左右才开始监听
    wait_for "启动 Telemt 服务" 45 telemt_ready
}

# telemt_apply [zero=用户 drop=用户 ...]
telemt_apply() { with_lock _telemt_apply "$@"; }

_telemt_apply() {
    local harden
    harden=$(setting_get HARDEN_TELEMT 1)
    if _telemt_start "$harden" "$@"; then
        setting_set "HARDEN_TELEMT=$harden"
        return 0
    fi
    if [ "$harden" = 1 ] && [ "$INIT_SYSTEM" = systemd ]; then
        note "当前环境不支持加固模式，改用兼容模式"
        if _telemt_start 0; then
            setting_set "HARDEN_TELEMT=0"
            return 0
        fi
    fi
    err "Telemt 服务启动失败"
    svc_show_failure telemt
    return 1
}

# telemt_commit 描述 [流量操作...]：保存内存中的状态与用户并应用，失败时回滚
telemt_commit() {
    local msg="$1" existed=0 files
    shift
    [ -f "$TELEMT_STATE" ] && existed=1
    files=("$TELEMT_STATE" "$USERS_DB" "$TELEMT_CONF" "$(svc_file telemt)")
    [ $# -gt 0 ] && files+=("$TELEMT_QUOTA_JSON")
    snap_take "${files[@]}"
    telemt_save
    users_save
    if telemt_apply "$@"; then
        snap_drop
        ok "$msg"
        return 0
    fi
    [ "$existed" = 0 ] && svc_remove telemt
    svc_ctl stop telemt
    snap_restore
    snap_drop
    if [ "$existed" = 1 ]; then
        svc_reload_units
        svc_ctl start telemt
        warn "已恢复修改前的配置"
    fi
    telemt_load
    users_load
    return 1
}

# ------------------------------------------------------------
# 安装与信息
# ------------------------------------------------------------

telemt_install() {
    local domain mode port name
    ui_page "安装 Telemt 内核" "Rust"
    if telemt_installed; then
        telemt_load
        users_load
        note "已安装 · :$TELEMT_PORT · $TELEMT_DOMAIN · ${#U_NAME[@]} 个用户"
        printf '\n'
        menu_reset
        menu_add 1 "更新内核" "保留配置、用户与链接" upgrade
        menu_add 2 "重新安装" "清除全部 ${#U_NAME[@]} 个用户" fresh
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || return 0
        case $MENU_ACTION in
            upgrade) printf '\n'; core_upgrade telemt; return ;;
            fresh)
                printf '\n'
                confirm "将删除全部 ${#U_NAME[@]} 个用户及其链接，继续？" n || return 0
                printf '\n' ;;
            *) return 0 ;;
        esac
    fi
    require_platform || return 1
    ensure_deps || return 1
    ip_refresh_ui
    printf '\n'
    wiz_domain domain "1/4" "www.apple.com" || return 1
    wiz_ip_mode mode "2/4" || return 1
    wiz_port port "3/4" "$(port_suggest telemt)" telemt || return 1
    ask_valid name "$(step_label 4/4 首个用户)" "admin" "" is_username "仅限字母、数字、下划线和连字符，最长 32 位" || return 1
    printf '\n'
    ui_rule
    ui_kv "即将安装" "Telemt · $(ip_mode_label "$mode") · :$port · $domain"
    confirm "确认安装？" y || { note "已取消"; return 0; }
    printf '\n'

    core_install telemt || return 1
    local secret
    secret=$(generate_secret) || return 1
    TELEMT_PORT="$port" TELEMT_DOMAIN="$domain" TELEMT_IP_MODE="$mode" TELEMT_MAIN_USER="$name" TELEMT_AD_TAG=""
    U_NAME=("$name") U_SECRET=("$secret") U_PORT=(-) U_QUOTA=(-) U_EXPIRE=(-) U_UP=(-) U_DOWN=(-)
    U_CREATED=("$(date +%Y-%m-%d)")
    ensure_dirs
    # 重新安装时清空旧的流量记录
    svc_ctl stop telemt
    rm -f "$TELEMT_QUOTA_JSON"
    telemt_commit "Telemt 内核已启动，监听 $port" || return 1
    logrotate_install
    fw_offer "$port"
    printf '\n'
    telemt_show_info
}

telemt_show_info() {
    telemt_installed || { warn "Telemt 内核未安装"; return 1; }
    telemt_load
    users_load
    local main="$TELEMT_MAIN_USER"
    user_find "$main" || { main="${U_NAME[0]:-}"; _UIDX=0; }
    ui_header "Telemt · Rust" "$(svc_status_text telemt)"
    ui_rule
    ui_kv "端口" "$TELEMT_PORT"
    ui_kv "伪装域名" "$TELEMT_DOMAIN"
    ui_kv "监听" "$(ip_mode_label "$TELEMT_IP_MODE")"
    ui_kv "用户" "${#U_NAME[@]} 人"
    [ -n "$TELEMT_AD_TAG" ] && ui_kv "推广频道" "已启用"
    [ -z "$main" ] && return 0
    printf '\n'
    note "用户 $main 的链接，其他用户请在「用户管理」中查看"
    show_links "$TELEMT_IP_MODE" "$(user_port "$_UIDX")" "$(secret_b64 "${U_SECRET[_UIDX]}" "$TELEMT_DOMAIN")"
}

# telemt_modify 项目(port|domain|mode|adtag)
telemt_modify() {
    local v
    telemt_installed || { warn "Telemt 内核未安装"; return 1; }
    telemt_load
    users_load
    case $1 in
        port)
            wiz_port v "" "$TELEMT_PORT" telemt || return 1
            [ "$v" = "$TELEMT_PORT" ] && { note "端口未变化"; return 0; }
            TELEMT_PORT="$v"
            telemt_commit "共享端口已改为 $v，密钥保持不变" || return 1 ;;
        domain)
            wiz_domain v "" "$TELEMT_DOMAIN" || return 1
            [ "$v" = "$TELEMT_DOMAIN" ] && { note "域名未变化"; return 0; }
            TELEMT_DOMAIN="$v"
            telemt_commit "伪装域名已改为 $v，全部用户的链接已更新" || return 1 ;;
        mode)
            ip_load
            wiz_ip_mode v "" || return 1
            [ "$v" = "$TELEMT_IP_MODE" ] && { note "监听模式未变化"; return 0; }
            TELEMT_IP_MODE="$v"
            telemt_commit "监听模式已改为 $(ip_mode_label "$v")" || return 1 ;;
        adtag)
            note "在 Telegram 的 @MTProxybot 注册代理后可获得推广标签（32 位十六进制）"
            note "启用后流量经官方中转节点，速度可能下降；输入 0 关闭"
            ask v "推广标签" "${TELEMT_AD_TAG:-}" "${TELEMT_AD_TAG:-未启用}"
            if [ "$v" = 0 ]; then
                [ -z "$TELEMT_AD_TAG" ] && return 0
                TELEMT_AD_TAG=""
                telemt_commit "推广频道已关闭" || return 1
            elif [ "$v" != "$TELEMT_AD_TAG" ]; then
                is_hex32 "$v" || { err "推广标签应为 32 位十六进制"; return 1; }
                TELEMT_AD_TAG="${v,,}"
                telemt_commit "推广频道已启用" || return 1
            fi
            return 0 ;;
    esac
    printf '\n'
    telemt_show_info
}

telemt_uninstall() {
    svc_remove telemt
    rm -f "$TELEMT_STATE" "$USERS_DB" "$TELEMT_CONF" "$TELEMT_QUOTA_JSON" "$RESET_STATE" \
        "$BIN_DIR/telemt" "$BIN_DIR/telemt.bak" "$LOG_DIR/telemt.log"
    rm -rf "$TELEMT_WORKDIR"
    cron_remove
    core_state_clear telemt
    ok "Telemt 内核已删除"
}

# ------------------------------------------------------------
# 用户操作（菜单与命令行共用）
# ------------------------------------------------------------

# user_create 名称 端口 配额 到期 上行 下行（空值用 "-"）
user_create() {
    local secret
    telemt_load
    users_load
    user_find "$1" && { err "用户 $1 已存在"; return 1; }
    secret=$(generate_secret) || return 1
    U_NAME+=("$1") U_SECRET+=("$secret") U_PORT+=("$2") U_QUOTA+=("$3")
    U_EXPIRE+=("$4") U_UP+=("$5") U_DOWN+=("$6") U_CREATED+=("$(date +%Y-%m-%d)")
    telemt_commit "已添加用户 $1" "zero=$1"
}

# user_update 名称 字段=值 ...；字段：port quota expire up down secret zero
user_update() {
    local name="$1" kv ops=() what=""
    shift
    telemt_load
    users_load
    user_find "$name" || { err "用户 $name 不存在"; return 1; }
    for kv in "$@"; do
        case $kv in
            port=*) U_PORT[_UIDX]="${kv#*=}"; what+="、端口" ;;
            quota=*) U_QUOTA[_UIDX]="${kv#*=}"; what+="、流量配额" ;;
            expire=*) U_EXPIRE[_UIDX]="${kv#*=}"; what+="、到期时间" ;;
            up=*) U_UP[_UIDX]="${kv#*=}"; what+="、限速" ;;
            down=*) U_DOWN[_UIDX]="${kv#*=}" ;;
            secret=*) U_SECRET[_UIDX]="${kv#*=}"; what+="、密钥" ;;
            zero) ops+=("zero=$name"); what+="、已用流量" ;;
        esac
    done
    telemt_commit "已更新 $name 的${what#、}" "${ops[@]}"
}

user_remove() {
    telemt_load
    users_load
    user_find "$1" || { err "用户 $1 不存在"; return 1; }
    if [ ${#U_NAME[@]} -le 1 ]; then
        err "至少需要保留一个用户"
        return 1
    fi
    user_drop_index "$_UIDX"
    [ "$TELEMT_MAIN_USER" = "$1" ] && TELEMT_MAIN_USER="${U_NAME[0]}"
    telemt_commit "已删除用户 $1" "drop=$1"
}

# ============================================================
# Telemt 用户管理界面
# ============================================================

NOW=0

# user_eval 序号：得到 US_STATE(ok|expired|exhausted) US_WARN US_PCT US_USED US_EXP
user_eval() {
    local i="$1" q
    US_USED="${Q_USED[${U_NAME[i]}]:-0}" US_PCT=-1 US_STATE=ok US_WARN="" US_EXP=""
    if [ "${U_QUOTA[i]}" != - ]; then
        q="${U_QUOTA[i]}"
        US_PCT=$(( US_USED * 100 / q ))
        if (( US_USED >= q )); then
            US_STATE=exhausted
        elif (( US_PCT >= 80 )); then
            US_WARN="流量已用 ${US_PCT}%"
        fi
    fi
    if [ "${U_EXPIRE[i]}" != - ] && iso_to_epoch "${U_EXPIRE[i]}"; then
        US_EXP=$_EPOCH
        if (( US_EXP <= NOW )); then
            US_STATE=expired
        elif (( US_EXP - NOW <= 604800 )); then
            US_WARN="$(( (US_EXP - NOW + 86399) / 86400 )) 天后到期"
        fi
    fi
}

user_state_text() {
    case $US_STATE in
        expired) printf '%s○ 已到期%s' "$CR" "$C0" ;;
        exhausted) printf '%s○ 流量用尽%s' "$CR" "$C0" ;;
        *) printf '%s● 正常%s' "$CG" "$C0" ;;
    esac
}

speed_text() {
    local up="${U_UP[$1]}" down="${U_DOWN[$1]}"
    [[ "$up" == - || "$up" =~ ^0+(\.0+)?$ ]] && up=""
    [[ "$down" == - || "$down" =~ ^0+(\.0+)?$ ]] && down=""
    if [ -z "$up$down" ]; then printf '不限'; return; fi
    printf '↑ %s · ↓ %s' "${up:-不限}${up:+ MB/s}" "${down:-不限}${down:+ MB/s}"
}

expire_text() {
    local left
    if [ -z "$US_EXP" ]; then printf '永久'; return; fi
    if (( US_EXP <= NOW )); then
        printf '已于 %s 到期' "$(epoch_fmt "$US_EXP")"
    else
        left=$(( (US_EXP - NOW) / 86400 ))
        printf '%s · 剩 %s 天' "$(epoch_fmt "$US_EXP")" "$left"
    fi
}

traffic_text() {
    local i="$1" color="$CA"
    if [ "$US_PCT" -lt 0 ]; then
        printf '不限'
        (( US_USED > 0 )) && printf ' · 已用 %s' "$(fmt_bytes "$US_USED")"
        return
    fi
    [ -n "$US_WARN" ] && color="$CY"
    [ "$US_STATE" = exhausted ] && color="$CR"
    printf '%s / %s  %s%s%s %s%%' "$(fmt_bytes "$US_USED")" "$(fmt_bytes "${U_QUOTA[i]}")" \
        "$color" "$(ui_bar "$US_PCT" 10)" "$C0" "$US_PCT"
}

users_table() {
    local i year cell plain color exp mark port pc bar rest
    NOW=$(date +%s)
    year=$(date +%Y)
    printf '  %s%s%s%s%s%s%s\n' "$CD" "$(pad '#' 4)" "$(pad 用户 13)" "$(pad 端口 7)" "$(pad 流量 26)" "到期" "$C0"
    for i in "${!U_NAME[@]}"; do
        user_eval "$i"
        if [ "${U_PORT[i]}" != - ]; then port="${U_PORT[i]}" pc=""; else port="$TELEMT_PORT" pc="$CD"; fi

        if [ "$US_PCT" -ge 0 ]; then
            color="$CA"
            [ -n "$US_WARN" ] && color="$CY"
            if [ "$US_STATE" = exhausted ]; then
                plain="$(ui_bar 100 10)  已用尽"
                cell="$CR$(ui_bar 100 10)$C0  已用尽"
            else
                bar=$(ui_bar "$US_PCT" 10)
                rest=" $(printf '%3s%%' "$US_PCT") $(fmt_bytes "$US_USED")/$(fmt_bytes "${U_QUOTA[i]}")"
                plain="$bar$rest"
                cell="$color$bar$C0$rest"
            fi
        else
            plain="不限"
            (( US_USED > 0 )) && plain+=" · $(fmt_bytes "$US_USED")"
            cell="$CD$plain$C0"
        fi
        dwidth "$plain"
        cell+=$(printf '%*s' "$(( 26 - _DW > 1 ? 26 - _DW : 1 ))" '')

        if [ -z "$US_EXP" ]; then
            exp="${CD}永久${C0}"
        elif [ "$(epoch_fmt "$US_EXP" %Y)" = "$year" ]; then
            exp=$(epoch_fmt "$US_EXP" %m-%d)
        else
            exp=$(epoch_fmt "$US_EXP" %Y-%m-%d)
        fi

        mark=""
        if [ "$US_STATE" != ok ]; then mark="  ${CR}✗${C0}"; elif [ -n "$US_WARN" ]; then mark="  ${CY}!${C0}"; fi

        printf '  %s%s%s%s%s%s%s%s\n' "$CA$(pad "$((i + 1))" 4)$C0" "$(pad "$(clip "${U_NAME[i]}" 12)" 13)" \
            "$pc" "$(pad "$port" 7)" "$C0" "$cell" "$exp" "$mark"
    done
}

users_page() {
    local c
    if ! telemt_installed; then
        ui_page "用户管理"
        warn "请先安装 Telemt 内核"
        pause
        return
    fi
    while :; do
        telemt_load
        users_load
        quota_load
        ui_page "用户管理" "Telemt · ${#U_NAME[@]} 人"
        users_table
        ui_rule
        printf '  %s序号%s 查看   %sa%s 添加   %sr%s 自动清零   %s0%s 返回   %s回车刷新%s\n\n' \
            "$CA" "$C0" "$CA" "$C0" "$CA" "$C0" "$CA" "$C0" "$CD" "$C0"
        ui_prompt c
        case ${c,,} in
            '') continue ;;
            0|q) return ;;
            a) user_add_wizard; pause ;;
            r) reset_page ;;
            *)
                if [[ "$c" =~ ^[0-9]+$ ]] && (( 10#$c >= 1 && 10#$c <= ${#U_NAME[@]} )); then
                    user_page "${U_NAME[10#$c - 1]}"
                fi ;;
        esac
    done
}

user_page() {
    local name="$1" i port kind
    while :; do
        telemt_load
        users_load
        quota_load
        NOW=$(date +%s)
        user_find "$name" || return 0
        i=$_UIDX
        user_eval "$i"
        port=$(user_port "$i")
        if [ "${U_PORT[i]}" != - ]; then kind="专属"; else kind="共享"; fi
        ui_page "$name" "$(user_state_text)"
        ui_kv "端口" "$port · $kind"
        ui_kv "流量" "$(traffic_text "$i")"
        ui_kv "到期" "$(expire_text)"
        ui_kv "限速" "$(speed_text "$i")"
        [ "${U_CREATED[i]}" != - ] && ui_kv "创建" "${U_CREATED[i]}"
        [ -n "$US_WARN" ] && { printf '\n'; warn "$US_WARN"; }
        show_links "$TELEMT_IP_MODE" "$port" "$(secret_b64 "${U_SECRET[i]}" "$TELEMT_DOMAIN")"
        printf '\n'
        ui_rule
        menu_reset
        menu_add 1 "二维码" "" qr
        menu_add 2 "流量配额" "" quota
        menu_add 3 "到期时间" "" expire
        menu_add 4 "限速" "" speed
        menu_add 5 "专属端口" "" port
        menu_add 6 "清零已用流量" "" zero
        menu_add 7 "重置密钥" "旧链接立即失效" secret
        menu_add 8 "删除用户" "" delete "$CR"
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || continue
        printf '\n'
        case $MENU_ACTION in
            qr) show_qr; pause ;;
            quota) user_edit_quota "$name"; pause ;;
            expire) user_edit_expire "$name"; pause ;;
            speed) user_edit_speed "$name"; pause ;;
            port) user_edit_port "$name"; pause ;;
            zero)
                confirm "清零 $name 的已用流量？" y && user_update "$name" zero
                pause ;;
            secret)
                if confirm "重置 $name 的密钥？旧链接会立即失效" n; then
                    local s
                    s=$(generate_secret) && user_update "$name" "secret=$s"
                fi
                pause ;;
            delete)
                if confirm "删除用户 $name？其连接会立即断开" n && user_remove "$name"; then
                    pause
                    return 0
                fi
                pause ;;
            back) return 0 ;;
        esac
    done
}

# ------------------------------------------------------------
# 输入校验（0 表示取消该项限制）
# ------------------------------------------------------------

EDIT_CUR_EXPIRE=""
_quota_in() { [ "$1" = 0 ] || parse_quota "$1"; }
_expire_in() { [ "$1" = 0 ] || parse_expire "$1" "$EDIT_CUR_EXPIRE"; }
_speed_in() { [ "$1" = 0 ] || is_speed "$1"; }
_quota_new() { parse_quota "$1"; }
_expire_new() { parse_expire "$1"; }

# ask_user_port 变量 提示 显示 [排除的用户]：0 或空表示共享端口
ask_user_port() {
    local __p __why __try
    for __try in 1 2 3; do
        ask __p "$2" "" "$3"
        if [ -z "$__p" ] || [ "$__p" = 0 ]; then
            printf -v "$1" '%s' "$__p"
            return 0
        fi
        if ! is_port "$__p"; then err "端口需为 1–65535 的整数"; continue; fi
        __p=$((10#$__p))
        if __why=$(port_check "$__p" user "${4:-}"); then
            printf -v "$1" '%s' "$__p"
            return 0
        fi
        err "端口 $__p $__why"
    done
    return 1
}

user_add_wizard() {
    local name port quota expire up down summary _
    telemt_load
    users_load
    ui_page "添加用户" "Telemt"
    for _ in 1 2 3; do
        ask name "$(pad 用户名 10)"
        if ! is_username "$name"; then
            err "仅限字母、数字、下划线和连字符，最长 32 位"
            name=""
        elif user_find "$name"; then
            err "用户 $name 已存在"
            name=""
        else
            break
        fi
    done
    [ -z "$name" ] && return 1
    ask_user_port port "$(pad 专属端口 10)" "共享 $TELEMT_PORT" || return 1
    ask_valid quota "$(pad 流量配额 10)" "" "不限 · 例 50G" _quota_new "格式如 50G、500M、1.5T" || return 1
    ask_valid expire "$(pad 到期时间 10)" "" "永久 · 例 +30d" _expire_new \
        "格式如 2026-12-31、2026-12-31 18:00 或 +30d，需晚于现在" || return 1
    ask_valid up "$(pad 上行限速 10)" "" "不限 · MB/s" is_speed "请输入大于 0 的数字" || return 1
    ask_valid down "$(pad 下行限速 10)" "" "不限 · MB/s" is_speed "请输入大于 0 的数字" || return 1

    [ -z "$port" ] || [ "$port" = 0 ] && port="-"
    if [ -n "$quota" ]; then parse_quota "$quota"; quota="$_QUOTA"; else quota="-"; fi
    if [ -n "$expire" ]; then parse_expire "$expire"; expire="$_EXPIRE"; else expire="-"; fi
    up="${up:--}" down="${down:--}"

    summary="$name"
    if [ "$port" != - ]; then summary+=" · 专属 $port"; else summary+=" · 共享 $TELEMT_PORT"; fi
    if [ "$quota" != - ]; then summary+=" · $(fmt_bytes "$quota")"; else summary+=" · 不限流量"; fi
    if [ "$expire" != - ]; then iso_to_epoch "$expire"; summary+=" · 至 $(epoch_fmt "$_EPOCH" %Y-%m-%d)"; else summary+=" · 永久"; fi
    [ "$up$down" != -- ] && summary+=" · 限速"
    printf '\n'
    ui_rule
    ui_kv "即将添加" "$summary"
    confirm "确认添加？" y || { note "已取消"; return 0; }
    printf '\n'
    user_create "$name" "$port" "$quota" "$expire" "$up" "$down" || return 1
    [ "$quota" != - ] && reset_offer
    users_load
    user_find "$name" || return 0
    show_links "$TELEMT_IP_MODE" "$(user_port "$_UIDX")" "$(secret_b64 "${U_SECRET[_UIDX]}" "$TELEMT_DOMAIN")"
    links_menu
}

user_edit_quota() {
    local name="$1" v q cur args
    user_find "$name" || return 1
    if [ "${U_QUOTA[_UIDX]}" = - ]; then cur="不限"; else cur="$(fmt_bytes "${U_QUOTA[_UIDX]}")"; fi
    ask_valid v "流量配额" "" "当前 $cur · 0 不限" _quota_in "格式如 50G、500M、1.5T，0 表示不限" || return 1
    [ -z "$v" ] && { note "未修改"; return 0; }
    q="-"
    if [ "$v" != 0 ]; then parse_quota "$v"; q="$_QUOTA"; fi
    args=("quota=$q")
    [ "$q" != - ] && confirm "同时清零已用流量？" y && args+=(zero)
    user_update "$name" "${args[@]}" || return 1
    [ "$q" != - ] && reset_offer
    return 0
}

user_edit_expire() {
    local name="$1" v cur
    user_find "$name" || return 1
    EDIT_CUR_EXPIRE="${U_EXPIRE[_UIDX]/#-/}"
    cur="永久"
    [ -n "$EDIT_CUR_EXPIRE" ] && iso_to_epoch "$EDIT_CUR_EXPIRE" && cur=$(epoch_fmt "$_EPOCH")
    note "+30d 表示在当前到期时间基础上顺延 30 天"
    ask_valid v "到期时间" "" "当前 $cur · 0 永久" _expire_in \
        "格式如 2026-12-31、2026-12-31 18:00 或 +30d，需晚于现在；0 表示永久" || return 1
    [ -z "$v" ] && { note "未修改"; return 0; }
    if [ "$v" = 0 ]; then
        user_update "$name" "expire=-"
    else
        parse_expire "$v" "$EDIT_CUR_EXPIRE"
        user_update "$name" "expire=$_EXPIRE"
    fi
}

user_edit_speed() {
    local name="$1" up down
    user_find "$name" || return 1
    note "单位 MB/s，0 表示不限，回车保持不变"
    ask_valid up "上行限速" "" "当前 ${U_UP[_UIDX]/#-/不限}" _speed_in "请输入大于 0 的数字，0 表示不限" || return 1
    ask_valid down "下行限速" "" "当前 ${U_DOWN[_UIDX]/#-/不限}" _speed_in "请输入大于 0 的数字，0 表示不限" || return 1
    [ -z "$up$down" ] && { note "未修改"; return 0; }
    [ -z "$up" ] && up="${U_UP[_UIDX]}"
    [ -z "$down" ] && down="${U_DOWN[_UIDX]}"
    [ "$up" = 0 ] && up="-"
    [ "$down" = 0 ] && down="-"
    user_update "$name" "up=$up" "down=$down"
}

user_edit_port() {
    local name="$1" p cur
    user_find "$name" || return 1
    if [ "${U_PORT[_UIDX]}" = - ]; then cur="共享 $TELEMT_PORT"; else cur="${U_PORT[_UIDX]}"; fi
    ask_user_port p "专属端口" "当前 $cur · 0 共享" "$name" || return 1
    [ -z "$p" ] && { note "未修改"; return 0; }
    [ "$p" = 0 ] && p="-"
    [ "$p" = "${U_PORT[_UIDX]}" ] && { note "未修改"; return 0; }
    user_update "$name" "port=$p"
}

# ============================================================
# 流量自动清零（由 cron 每天 00:00 调用 mtp check_reset）
# ============================================================

reset_load() {
    RESET_MODE="disabled" RESET_DAY="1" RESET_DATE="" RESET_LAST=""
    state_load "$RESET_STATE" RESET
    [[ "$RESET_DAY" =~ ^[0-9]+$ ]] && (( 10#$RESET_DAY >= 1 && 10#$RESET_DAY <= 31 )) || RESET_DAY=1
}

reset_save() {
    printf 'MODE=%s\nDAY=%s\nDATE=%s\nLAST=%s\n' "$RESET_MODE" "$RESET_DAY" "$RESET_DATE" "$RESET_LAST" \
        | atomic_write "$RESET_STATE" 0600
}

reset_log() {
    mkdir -p "$LOG_DIR"
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$RESET_LOG"
    chmod 0600 "$RESET_LOG" 2>/dev/null
}

days_in_month() {
    local y=$((10#$1)) m=$((10#$2))
    case $m in
        2) if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then echo 29; else echo 28; fi ;;
        4|6|9|11) echo 30 ;;
        *) echo 31 ;;
    esac
}

reset_describe() {
    case $RESET_MODE in
        monthly)
            if (( RESET_DAY > 28 )); then
                printf '每月 %s 日 00:00（小月在月末执行）' "$RESET_DAY"
            else
                printf '每月 %s 日 00:00' "$RESET_DAY"
            fi ;;
        once) printf '%s 00:00 执行一次' "$RESET_DATE" ;;
        *) printf '未开启' ;;
    esac
}

# 设置了配额且未到期的用户
reset_targets() {
    local i
    NOW=$(date +%s)
    RESET_TARGETS=() RESET_SKIPPED=0
    for i in "${!U_NAME[@]}"; do
        [ "${U_QUOTA[i]}" = - ] && continue
        if [ "${U_EXPIRE[i]}" != - ] && iso_to_epoch "${U_EXPIRE[i]}" && (( _EPOCH <= NOW )); then
            RESET_SKIPPED=$(( RESET_SKIPPED + 1 ))
            continue
        fi
        RESET_TARGETS+=("${U_NAME[i]}")
    done
}

# reset_run 来源：清零并记录日志
reset_run() {
    local src="$1" ops=() n
    telemt_installed || { reset_log "$src：Telemt 未安装，已跳过"; return 1; }
    telemt_load
    users_load
    reset_targets
    if [ ${#RESET_TARGETS[@]} -eq 0 ]; then
        reset_log "$src：没有需要清零的用户"
        return 0
    fi
    for n in "${RESET_TARGETS[@]}"; do ops+=("zero=$n"); done
    if telemt_apply "${ops[@]}" >/dev/null 2>&1; then
        reset_log "$src：已清零 ${#RESET_TARGETS[@]} 人，跳过已到期 $RESET_SKIPPED 人"
        return 0
    fi
    reset_log "$src：Telemt 重启失败，请检查服务"
    return 1
}

reset_check() {
    [ -f "$RESET_STATE" ] || return 0
    reset_load
    local today day target
    today=$(date +%Y-%m-%d)
    [ "$RESET_LAST" = "$today" ] && return 0
    case $RESET_MODE in
        monthly)
            day=$((10#$(date +%d)))
            target=$(( 10#$RESET_DAY ))
            local dim
            dim=$(days_in_month "$(date +%Y)" "$(date +%m)")
            (( target > dim )) && target=$dim
            (( day == target )) || return 0
            reset_run "每月清零"
            RESET_LAST="$today"
            reset_save ;;
        once)
            [ -n "$RESET_DATE" ] || return 0
            [[ "$today" < "$RESET_DATE" ]] && return 0
            reset_run "定时清零"
            RESET_LAST="$today" RESET_MODE="disabled"
            reset_save ;;
    esac
}

reset_enable_monthly() {
    reset_load
    RESET_MODE="monthly" RESET_DAY="$((10#$1))" RESET_DATE=""
    reset_save
    cron_install || return 1
    ok "已开启自动清零：$(reset_describe)"
}

reset_enable_once() {
    reset_load
    RESET_MODE="once" RESET_DATE="$1"
    reset_save
    cron_install || return 1
    ok "已设置：$(reset_describe)"
}

reset_disable() {
    reset_load
    RESET_MODE="disabled"
    reset_save
    cron_remove
    ok "已关闭自动清零"
}

_reset_day_ok() { [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 31 )); }
_reset_date_ok() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [ "$(date -d "$1" +%Y-%m-%d 2>/dev/null)" = "$1" ] || return 1
    ! [[ "$1" < "$(date +%Y-%m-%d)" ]]
}

# 添加配额后询问是否开启每月清零
reset_offer() {
    reset_load
    [ "$RESET_MODE" != disabled ] && return 0
    printf '\n'
    confirm "开启每月自动清零流量？" y || return 0
    local d
    ask_valid d "每月几号" "1" "" _reset_day_ok "请输入 1–31" || return 1
    reset_enable_monthly "$d"
}

reset_page() {
    local d last
    while :; do
        telemt_load
        users_load
        reset_load
        reset_targets
        ui_page "流量自动清零" "Telemt"
        ui_kv "计划" "$(reset_describe)"
        last=$(tail -n 1 "$RESET_LOG" 2>/dev/null)
        [ -n "$last" ] && ui_kv "上次" "$last"
        ui_kv "范围" "设置了配额且未到期的用户 · ${#RESET_TARGETS[@]} 人"
        if [ "$RESET_MODE" != disabled ] && have crontab && ! cron_has; then
            printf '\n'
            warn "定时任务缺失，重新选择计划即可恢复"
        fi
        printf '\n'
        ui_rule
        menu_reset
        menu_add 1 "每月清零" "" monthly
        menu_add 2 "指定日期清零一次" "" once
        menu_add 3 "关闭自动清零" "" off
        menu_add 4 "立即清零" "已到期用户除外" now
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || continue
        printf '\n'
        case $MENU_ACTION in
            monthly)
                note "日期大于当月天数时在月末执行"
                ask_valid d "每月几号" "${RESET_DAY:-1}" "" _reset_day_ok "请输入 1–31" && reset_enable_monthly "$d"
                pause ;;
            once)
                ask_valid d "日期" "" "例 $(date +%Y-%m-%d)" _reset_date_ok "格式为 YYYY-MM-DD，且不早于今天" && [ -n "$d" ] && reset_enable_once "$d"
                pause ;;
            off) reset_disable; pause ;;
            now)
                if [ ${#RESET_TARGETS[@]} -eq 0 ]; then
                    note "没有需要清零的用户"
                elif confirm "立即清零 ${#RESET_TARGETS[@]} 位用户的已用流量？" y; then
                    if spin_run "清零并重启 Telemt" reset_run "手动清零"; then
                        ok "$(tail -n 1 "$RESET_LOG" | sed 's/^[^ ]* [^ ]*  //')"
                    else
                        err "清零失败，请查看日志"
                    fi
                fi
                pause ;;
            back) return ;;
        esac
    done
}

# ============================================================
# 内核二进制：下载、SHA-256 校验、版本、更新与回滚
# ============================================================

core_bin() { case $1 in mtg) echo "$BIN_DIR/mtg-go" ;; telemt) echo "$BIN_DIR/telemt" ;; esac; }
core_asset() { case $1 in mtg) echo "mtg-go-$ARCH" ;; telemt) echo "telemt-linux-$ARCH" ;; esac; }
core_label() { case $1 in mtg) echo "Go" ;; telemt) echo "Telemt" ;; esac; }
core_proc() { case $1 in mtg) echo "mtg-go" ;; telemt) echo "telemt" ;; esac; }
core_key() { case $1 in mtg) echo "MTG" ;; telemt) echo "TELEMT" ;; esac; }
core_release_url() { echo "https://github.com/${RELEASE_REPO}/releases/latest/download/$1"; }

core_state_clear() {
    local key
    key=$(core_key "$1")
    [ -f "$CORE_STATE" ] || return 0
    grep -v "^${key}_" "$CORE_STATE" | atomic_write "$CORE_STATE" 0600
}

# 内核版本说明，例如 "V1.0.1 · telemt 3.1.5"
core_version() {
    local key ver bin extra=""
    key=$(core_key "$1")
    ver=$(state_get "$CORE_STATE" "${key}_VER")
    bin=$(core_bin "$1")
    if [ "$1" = telemt ] && [ -x "$bin" ]; then
        extra=$("$bin" --version 2>/dev/null | head -n 1)
    fi
    # 2.x 安装的内核没有记录版本，显示文件摘要以便核对
    [ -z "$ver" ] && [ -f "$bin" ] && ver="sha256 $(sha256_of "$bin" | cut -c1-8)"
    if [ -n "$ver" ] && [ -n "$extra" ]; then printf '%s · %s' "$ver" "$extra"
    else printf '%s' "${ver:-${extra:-未安装}}"
    fi
}

# 在脚本所在目录等位置查找预先放置的内核文件
core_find_local() {
    local asset dir f names
    asset=$(core_asset "$1")
    names=("$asset")
    [ "$1" = telemt ] && names+=("telemt")
    for dir in "$PWD" "${SCRIPT_DIR:-}" "$PWD/bin" "${SCRIPT_DIR:+$SCRIPT_DIR/bin}"; do
        [ -n "$dir" ] || continue
        for f in "${names[@]}"; do
            f="$dir/$f"
            if [ -f "$f" ] && [ "$f" != "$(core_bin "$1")" ]; then
                printf '%s' "$f"
                return 0
            fi
        done
    done
    return 1
}

# core_download 类型 目录：下载内核、SHA256SUMS 与版本信息（在后台执行，只写文件）
core_download() {
    local asset
    asset=$(core_asset "$1")
    http_get "$(core_release_url SHA256SUMS)" "$2/SHA256SUMS" || return 1
    http_get "$(core_release_url BUILD-METADATA.json)" "$2/meta.json" 2>/dev/null || : > "$2/meta.json"
    [ "${3:-}" = sums-only ] && return 0
    http_get "$(core_release_url "$asset")" "$2/$asset"
}

core_expected_sha() { awk -v n="$(core_asset "$1")" '$2 == n { print $1; exit }' "$2/SHA256SUMS"; }
core_meta_version() { grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$1/meta.json" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/'; }

# core_put 类型 源文件 版本：备份旧文件后原子替换
core_put() {
    local bin tmp key
    bin=$(core_bin "$1")
    key=$(core_key "$1")
    mkdir -p "$BIN_DIR"
    [ -f "$bin" ] && cp -p "$bin" "$bin.bak"
    tmp="$bin.new.$$"
    cp "$2" "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$bin" || { rm -f "$tmp"; return 1; }
    state_set "$CORE_STATE" "${key}_SHA=$(sha256_of "$bin")" "${key}_VER=${3:-}" "${key}_TIME=$(date +%Y-%m-%d)"
}

# core_install 类型：安装内核（优先使用本地文件）
core_install() {
    local kind="$1" label asset local_file dir expected actual ver
    label=$(core_label "$kind")
    asset=$(core_asset "$kind")
    if local_file=$(core_find_local "$kind"); then
        core_put "$kind" "$local_file" "本地文件" || { err "安装本地内核失败"; return 1; }
        ok "已使用本地文件 $(basename "$local_file")"
        return 0
    fi
    dir=$(mktemp -d)
    if ! run_step "下载 $label 内核 $asset" core_download "$kind" "$dir"; then
        rm -rf "$dir"
        err "下载失败，请检查网络或 GitHub 访问"
        return 1
    fi
    expected=$(core_expected_sha "$kind" "$dir")
    actual=$(sha256_of "$dir/$asset")
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        rm -rf "$dir"
        err "SHA-256 校验失败，已拒绝安装"
        return 1
    fi
    ver=$(core_meta_version "$dir")
    core_put "$kind" "$dir/$asset" "$ver" || { rm -rf "$dir"; err "写入内核文件失败"; return 1; }
    rm -rf "$dir"
    ok "SHA-256 校验通过${ver:+ · $ver}"
}

# core_upgrade 类型：检查并更新内核，保留配置；失败时回滚到旧版本
core_upgrade() {
    local kind="$1" label bin dir expected current ver asset
    label=$(core_label "$kind")
    bin=$(core_bin "$kind")
    asset=$(core_asset "$kind")
    [ -x "$bin" ] || { warn "$label 内核未安装"; return 1; }
    [ -n "$ARCH" ] || { err "不支持的架构"; return 1; }
    dir=$(mktemp -d)
    if ! run_step "检查 $label 内核版本" core_download "$kind" "$dir" sums-only; then
        rm -rf "$dir"
        detail "无法访问 GitHub Release，请检查网络后重试"
        return 1
    fi
    expected=$(core_expected_sha "$kind" "$dir")
    current=$(sha256_of "$bin")
    ver=$(core_meta_version "$dir")
    if [ -n "$expected" ] && [ "$expected" = "$current" ]; then
        rm -rf "$dir"
        [ -n "$ver" ] && state_set "$CORE_STATE" "$(core_key "$kind")_VER=$ver"
        ok "$label 内核已是最新${ver:+ · $ver}"
        return 0
    fi
    if ! run_step "下载 $label 内核 $asset" http_get "$(core_release_url "$asset")" "$dir/$asset"; then
        rm -rf "$dir"
        return 1
    fi
    if [ -z "$expected" ] || [ "$(sha256_of "$dir/$asset")" != "$expected" ]; then
        rm -rf "$dir"
        err "SHA-256 校验失败，已拒绝更新"
        return 1
    fi
    core_put "$kind" "$dir/$asset" "$ver" || { rm -rf "$dir"; err "写入内核文件失败"; return 1; }
    rm -rf "$dir"
    if core_restart_check "$kind"; then
        ok "$label 内核已更新${ver:+到 $ver}，配置与链接不变"
        return 0
    fi
    err "新内核启动失败，正在回滚"
    mv -f "$bin.bak" "$bin"
    core_restart_check "$kind" && warn "已回滚到旧版本"
    return 1
}

core_restart_check() {
    case $1 in
        mtg)
            mtg_installed || return 0
            mtg_load
            svc_ctl restart mtg
            wait_for "重启 Go 服务" 15 mtg_ready ;;
        telemt)
            telemt_installed || return 0
            telemt_load
            svc_ctl restart telemt
            wait_for "重启 Telemt 服务" 45 telemt_ready ;;
    esac
}

core_upgrade_page() {
    local any=0
    ui_page "更新内核" "保留配置与链接"
    if mtg_installed; then any=1; core_upgrade mtg; fi
    if telemt_installed; then any=1; core_upgrade telemt; fi
    [ "$any" = 0 ] && warn "尚未安装任何内核"
    return 0
}

# ============================================================
# 诊断：服务、端口、防火墙、时间、伪装域名、BBR、版本
# ============================================================

DOC_ISSUES=0
DOC_FIXES=()

doc_ok()   { ok "$1"; }
doc_warn() { warn "$1"; DOC_ISSUES=$(( DOC_ISSUES + 1 )); }
doc_fail() { err "$1" 2>&1; DOC_ISSUES=$(( DOC_ISSUES + 1 )); }

# http_date_to_epoch "Date: Wed, 24 Sep 2026 03:40:00 GMT"
http_date_to_epoch() {
    local d mon y t m
    [[ "$1" =~ ([0-9]{1,2})\ ([A-Za-z]{3})\ ([0-9]{4})\ ([0-9]{2}:[0-9]{2}:[0-9]{2}) ]] || return 1
    d="${BASH_REMATCH[1]}"; mon="${BASH_REMATCH[2]}"; y="${BASH_REMATCH[3]}"; t="${BASH_REMATCH[4]}"
    m=$(awk -v s="$mon" 'BEGIN { i = index("JanFebMarAprMayJunJulAugSepOctNovDec", s); print (i ? (i - 1) / 3 + 1 : 0) }')
    (( m >= 1 )) || return 1
    date -u -d "$(printf '%s-%02d-%02d %s' "$y" "$m" "$((10#$d))" "$t")" +%s 2>/dev/null
}

# 本机时间与 HTTPS 响应头中的标准时间之差（秒）
clock_skew() {
    local u line remote
    for u in https://www.cloudflare.com https://www.apple.com https://www.microsoft.com; do
        line=$(curl -sS -o /dev/null -D - --max-time 6 "$u" 2>/dev/null | tr -d '\r' | grep -i '^date:' | head -n 1)
        if remote=$(http_date_to_epoch "$line"); then
            echo $(( $(date +%s) - remote ))
            return 0
        fi
    done
    return 1
}

# 通过公网地址连接自身端口（NAT 机器可能无法回环，结果仅供参考）
self_connect() {
    timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

doctor_ports() {
    local p
    mtg_installed && { mtg_load; echo "$MTG_PORT"; }
    if telemt_installed; then
        telemt_load
        users_load
        echo "$TELEMT_PORT"
        for p in "${U_PORT[@]}"; do [ "$p" != - ] && echo "$p"; done
    fi
}

doctor_run() {
    local backend port ports skew cc d rc remote domains
    DOC_ISSUES=0 DOC_FIXES=()

    ui_section "服务"
    if ! mtg_installed && ! telemt_installed; then
        doc_warn "尚未安装任何内核"
    fi
    if mtg_installed; then
        mtg_load
        if mtg_ready; then doc_ok "Go 运行中，监听 $MTG_PORT"
        elif svc_active mtg; then doc_fail "Go 进程在运行，但没有监听 $MTG_PORT"
        else doc_fail "Go 已停止"
        fi
    fi
    if telemt_installed; then
        telemt_load
        if telemt_ready; then doc_ok "Telemt 运行中，监听 $TELEMT_PORT"
        elif svc_active telemt; then doc_fail "Telemt 进程在运行，但没有监听 $TELEMT_PORT"
        else doc_fail "Telemt 已停止"
        fi
    fi

    ui_section "网络"
    ip_load refresh
    if [ -n "$PUBLIC_IPV4" ]; then doc_ok "公网 IPv4 $PUBLIC_IPV4"; else doc_warn "未检测到公网 IPv4"; fi
    if [ -n "$PUBLIC_IPV6" ]; then doc_ok "公网 IPv6 $PUBLIC_IPV6"; else detail "未检测到公网 IPv6"; fi
    ports=$(doctor_ports | sort -un)
    if [ -n "$ports" ] && [ -n "$PUBLIC_IPV4" ]; then
        for port in $ports; do
            if self_connect "$PUBLIC_IPV4" "$port"; then
                doc_ok "$PUBLIC_IPV4:$port 可以连接"
            else
                doc_warn "$PUBLIC_IPV4:$port 无法从本机连接（NAT 机器可能误报，请同时检查云厂商安全组）"
            fi
        done
    fi
    backend=$(fw_backend)
    if [ "$backend" = none ]; then
        doc_ok "未启用主机防火墙"
    else
        for port in $ports; do
            if fw_port_open "$backend" "$port"; then
                doc_ok "防火墙 $(fw_label "$backend") 已放行 $port/tcp"
            else
                doc_warn "防火墙 $(fw_label "$backend") 未放行 $port/tcp"
                [ "$backend" != nftables ] && DOC_FIXES+=("fw:$backend:$port")
            fi
        done
    fi

    ui_section "时间"
    if skew=$(clock_skew); then
        if (( ${skew#-} <= 2 )); then doc_ok "与标准时间相差 ${skew#-} 秒"
        elif (( ${skew#-} <= 30 )); then doc_warn "与标准时间相差 ${skew#-} 秒，建议开启时间同步"
        else doc_fail "与标准时间相差 ${skew#-} 秒，FakeTLS 可能无法连接，请开启时间同步"
        fi
    else
        detail "无法获取标准时间，已跳过"
    fi

    domains=()
    mtg_installed && domains+=("$MTG_DOMAIN")
    telemt_installed && domains+=("$TELEMT_DOMAIN")
    if [ ${#domains[@]} -gt 0 ]; then
        ui_section "伪装域名"
        for d in $(printf '%s\n' "${domains[@]}" | sort -u); do
            tls13_check "$d"
            rc=$?
            case $rc in
                0) doc_ok "$d 支持 TLS 1.3" ;;
                2) detail "系统 openssl 不支持 TLS 1.3 检测，已跳过 $d" ;;
                *) doc_warn "$d 未通过 TLS 1.3 检测，建议更换伪装域名" ;;
            esac
        done
    fi

    ui_section "系统"
    cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    if [ "$cc" = bbr ]; then
        doc_ok "BBR 已开启"
    elif grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || [ -d /sys/module/tcp_bbr ] || modinfo tcp_bbr >/dev/null 2>&1; then
        doc_warn "BBR 未开启（当前 ${cc:-未知}）"
        DOC_FIXES+=("bbr")
    else
        detail "当前内核不支持 BBR（${cc:-未知}）"
    fi
    remote=$(remote_version)
    if [ -n "$remote" ] && ver_gt "$remote" "$MTP_VERSION"; then
        doc_warn "脚本有新版本 v$remote（当前 v$MTP_VERSION）"
    else
        doc_ok "脚本 v$MTP_VERSION"
    fi
    mtg_installed && detail "Go 内核 $(core_version mtg)"
    telemt_installed && detail "Telemt 内核 $(core_version telemt)"

    printf '\n'
    ui_rule
    if [ "$DOC_ISSUES" -eq 0 ]; then
        ok "一切正常"
    else
        warn "$DOC_ISSUES 项需要留意"
    fi
}

bbr_enable() {
    modprobe tcp_bbr >/dev/null 2>&1
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' | atomic_write "$SYSCTL_BBR_FILE" 0644
    sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1
    [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" = bbr ]
}

# doctor_fix [yes]：处理可自动修复的项目
doctor_fix() {
    local fix backend port
    for fix in "${DOC_FIXES[@]}"; do
        case $fix in
            fw:*)
                backend="${fix#fw:}"; port="${backend#*:}"; backend="${backend%%:*}"
                if [ "${1:-}" = yes ] || confirm "在 $(fw_label "$backend") 中放行 $port/tcp？" y; then
                    if fw_allow "$backend" "$port"; then ok "已放行 $port/tcp"; else err "放行 $port/tcp 失败"; fi
                fi ;;
            bbr)
                if [ "${1:-}" = yes ] || confirm "开启 BBR？" y; then
                    if bbr_enable; then ok "BBR 已开启"; else err "开启失败，容器或当前内核可能不允许修改"; fi
                fi ;;
        esac
    done
}

doctor_page() {
    ui_page "诊断"
    doctor_run
    if [ ${#DOC_FIXES[@]} -gt 0 ]; then
        printf '\n'
        doctor_fix
    fi
}

# ============================================================
# 备份与恢复：配置、用户与流量记录打包为 tar.gz
# ============================================================

# backup_create [目标文件]：输出备份文件路径
backup_create() {
    local file="${1:-$BACKUP_DIR/mtproxy-$(date +%Y%m%d-%H%M%S).tar.gz}" items=()
    [ -d "$ETC_DIR" ] || { err "没有可备份的配置"; return 1; }
    items+=("${ETC_DIR#"$R"/}")
    [ -f "$TELEMT_QUOTA_JSON" ] && items+=("${TELEMT_QUOTA_JSON#"$R"/}")
    mkdir -p "$(dirname "$file")"
    if ! tar -czf "$file" -C "${R:-/}" "${items[@]}" 2>/dev/null; then
        rm -f "$file"
        err "打包失败"
        return 1
    fi
    chmod 0600 "$file"
    BACKUP_FILE="$file"
}

# 只允许恢复 etc/mtproxy/ 下的普通文件与 etc/telemt_quota.json
backup_check() {
    local line type entry list
    list=$(tar -tvzf "$1" 2>/dev/null) || return 1
    [ -n "$list" ] || return 1
    while IFS= read -r line; do
        type="${line:0:1}"
        entry="${line##* }"
        entry="${entry#./}"
        [ "$type" = "-" ] || [ "$type" = d ] || return 1
        case $entry in
            etc/mtproxy|etc/mtproxy/|etc/telemt_quota.json) ;;
            etc/mtproxy/*) case $entry in *..*) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    done <<< "$list"
}

backup_restore() {
    local file="$1"
    [ -f "$file" ] || { err "文件不存在：$file"; return 1; }
    backup_check "$file" || { err "不是有效的 mtp 备份文件"; return 1; }
    require_platform || return 1

    # 先为当前配置留一份备份
    if [ -d "$ETC_DIR" ] && backup_create; then
        detail "当前配置已备份到 $BACKUP_FILE"
    fi
    svc_ctl stop mtg
    svc_ctl stop telemt
    rm -rf "$ETC_DIR"
    if ! tar -xzf "$file" -C "${R:-/}"; then
        err "解压失败"
        return 1
    fi
    ensure_dirs
    chmod 0600 "$ETC_DIR"/*.env "$ETC_DIR"/*.db "$ETC_DIR"/*.toml 2>/dev/null
    [ -f "$TELEMT_QUOTA_JSON" ] && chmod 0600 "$TELEMT_QUOTA_JSON"

    local rc=0
    if mtg_installed; then
        [ -x "$BIN_DIR/mtg-go" ] || core_install mtg || rc=1
        mtg_load
        if [ "$rc" = 0 ] && mtg_apply; then ok "Go 内核已恢复"; else rc=1; fi
    else
        svc_remove mtg
    fi
    if telemt_installed; then
        [ -x "$BIN_DIR/telemt" ] || core_install telemt || rc=1
        telemt_load
        users_load
        if [ "$rc" = 0 ] && telemt_apply; then ok "Telemt 内核已恢复（${#U_NAME[@]} 个用户）"; else rc=1; fi
    else
        svc_remove telemt
    fi
    reset_load
    if [ "$RESET_MODE" != disabled ]; then cron_install >/dev/null; else cron_remove; fi
    return "$rc"
}

backup_page() {
    local f files=() i c
    while :; do
        files=()
        while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n 9)
        ui_page "备份与恢复"
        if [ ${#files[@]} -eq 0 ]; then
            note "暂无备份"
        else
            for i in "${!files[@]}"; do
                ui_item "$((i + 1))" "$(basename "${files[i]}")" "$(du -h "${files[i]}" 2>/dev/null | cut -f1)"
            done
        fi
        printf '\n'
        ui_rule
        printf '  %sb%s 新建备份   %s序号%s 恢复   %s0%s 返回\n' "$CA" "$C0" "$CA" "$C0" "$CA" "$C0"
        note "备份目录 ${BACKUP_DIR}，迁移到新服务器时复制备份文件后运行 mtp restore 文件"
        printf '\n'
        ui_prompt c
        case ${c,,} in
            0|q|'') return ;;
            b)
                printf '\n'
                if backup_create; then ok "已备份到 $BACKUP_FILE"; fi
                pause ;;
            *)
                if [[ "$c" =~ ^[0-9]$ ]] && (( c >= 1 && c <= ${#files[@]} )); then
                    printf '\n'
                    if confirm "用 $(basename "${files[c - 1]}") 覆盖当前配置？" n; then
                        backup_restore "${files[c - 1]}"
                    fi
                    pause
                fi ;;
        esac
    done
}

# ============================================================
# 从 2.x 版本迁移：/opt/mtproxy/config + /etc/telemt.toml -> /etc/mtproxy
# ============================================================

legacy_mtg_present() {
    [ -f "$LEGACY_CONF_DIR/go.conf" ] && return 0
    [ ! -f "$MTG_STATE" ] && svc_exists mtg && grep -q 'simple-run' "$(svc_file mtg)" 2>/dev/null
}

legacy_telemt_present() { [ -f "$LEGACY_TELEMT_TOML" ]; }

legacy_present() {
    legacy_mtg_present || legacy_telemt_present || [ -f "$LEGACY_RESET_CONF" ] || [ -f "$LEGACY_CONF_DIR/telemt.conf" ]
}

# 旧版域名可能含大写等字符，这里只拒绝会破坏配置文件的内容
_legacy_domain_ok() { [[ "$1" =~ ^[A-Za-z0-9.-]{1,253}$ ]]; }

legacy_mtg_parse() {
    local full="" line L_PORT="" L_SECRET="" L_DOMAIN="" L_IP_MODE="" hex
    MTG_PORT="" MTG_SECRET="" MTG_DOMAIN="" MTG_IP_MODE=""
    if [ -f "$LEGACY_CONF_DIR/go.conf" ]; then
        state_load "$LEGACY_CONF_DIR/go.conf" L
        MTG_PORT="$L_PORT" full="$L_SECRET" MTG_DOMAIN="$L_DOMAIN" MTG_IP_MODE="$L_IP_MODE"
    fi
    if [ -z "$full" ] && svc_exists mtg; then
        line=$(grep -E 'ExecStart=|command_args=' "$(svc_file mtg)" | head -n 1)
        full=$(grep -oE 'ee[0-9a-fA-F]{32,}' <<< "$line" | head -n 1)
        [ -z "$MTG_PORT" ] && MTG_PORT=$(grep -oE ':[0-9]+([ "]|$)' <<< "$line" | tail -n 1 | tr -dc '0-9')
        if [ -z "$MTG_IP_MODE" ]; then
            case $line in
                *only-ipv6*) MTG_IP_MODE="v6" ;;
                *prefer-ipv6*) MTG_IP_MODE="dual" ;;
                *) MTG_IP_MODE="v4" ;;
            esac
        fi
    fi
    [[ "$full" =~ ^[eE][eE]([0-9a-fA-F]{32})([0-9a-fA-F]*)$ ]] || return 1
    MTG_SECRET="${BASH_REMATCH[1],,}"
    hex="${BASH_REMATCH[2]}"
    if [ -z "$MTG_DOMAIN" ] && [ -n "$hex" ]; then
        MTG_DOMAIN=$(printf '%b' "$(sed 's/../\\x&/g' <<< "$hex")")
    fi
    is_ip_mode "$MTG_IP_MODE" || MTG_IP_MODE="v4"
    is_port "$MTG_PORT" && _legacy_domain_ok "$MTG_DOMAIN"
}

legacy_telemt_parse() {
    local section="" line key val v4="" v6="" toml_port="" toml_domain="" n up down
    local T_PORT="" T_DOMAIN="" T_IP_MODE="" T_MAIN_USER=""
    local -A lp=() lq=() le=() lsp=()
    TELEMT_PORT="" TELEMT_DOMAIN="" TELEMT_IP_MODE="" TELEMT_MAIN_USER="" TELEMT_AD_TAG=""
    U_NAME=() U_SECRET=() U_PORT=() U_QUOTA=() U_EXPIRE=() U_UP=() U_DOWN=() U_CREATED=()
    [ -f "$LEGACY_CONF_DIR/telemt.conf" ] && state_load "$LEGACY_CONF_DIR/telemt.conf" T

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[\[?([A-Za-z0-9_.]+)\]\]? ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        [[ "$line" =~ ^\"?([A-Za-z0-9_.-]+)\"?[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
        case $section in
            server) [ "$key" = port ] && toml_port="$val" ;;
            censorship) [ "$key" = tls_domain ] && toml_domain="$val" ;;
            network)
                [ "$key" = ipv4 ] && v4="$val"
                [ "$key" = ipv6 ] && v6="$val" ;;
            general) [ "$key" = ad_tag ] && is_hex32 "$val" && TELEMT_AD_TAG="${val,,}" ;;
            access.users)
                if is_username "$key" && is_hex32 "$val"; then
                    U_NAME+=("$key") U_SECRET+=("${val,,}")
                fi ;;
            access.user_ports) is_port "$val" && lp["$key"]="$((10#$val))" ;;
            access.user_data_quota) [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 )) && lq["$key"]="$val" ;;
            access.user_expirations) iso_to_epoch "$val" && le["$key"]="$val" ;;
            access.user_speed_limits) lsp["$key"]="$val" ;;
        esac
    done < "$LEGACY_TELEMT_TOML"

    [ ${#U_NAME[@]} -gt 0 ] || return 1
    for n in "${U_NAME[@]}"; do
        U_PORT+=("${lp[$n]:--}") U_QUOTA+=("${lq[$n]:--}") U_EXPIRE+=("${le[$n]:--}") U_CREATED+=("-")
        up="-" down="-"
        if [ -n "${lsp[$n]:-}" ]; then
            read -r up down <<< "${lsp[$n]}"
            [ -z "$down" ] && down="$up"
            is_speed "$up" || up="-"
            is_speed "$down" || down="-"
        fi
        U_UP+=("$up") U_DOWN+=("$down")
    done

    TELEMT_PORT="${T_PORT:-$toml_port}"
    TELEMT_DOMAIN="${T_DOMAIN:-$toml_domain}"
    TELEMT_IP_MODE="$T_IP_MODE"
    if ! is_ip_mode "$TELEMT_IP_MODE"; then
        if [ "$v4" = false ]; then TELEMT_IP_MODE="v6"
        elif [ "$v6" = true ]; then TELEMT_IP_MODE="dual"
        else TELEMT_IP_MODE="v4"
        fi
    fi
    TELEMT_MAIN_USER="${T_MAIN_USER:-${U_NAME[0]}}"
    user_find "$TELEMT_MAIN_USER" || TELEMT_MAIN_USER="${U_NAME[0]}"
    is_port "$TELEMT_PORT" && _legacy_domain_ok "$TELEMT_DOMAIN"
}

# 迁移失败时恢复旧服务文件并重启
_legacy_restore_unit() {
    local name="$1" archive="$2" unit
    unit=$(svc_file "$name")
    svc_ctl stop "$name"
    tar -xzf "$archive" -C "${R:-/}" "${unit#"$R"/}" 2>/dev/null
    svc_reload_units
    svc_ctl start "$name"
}

# migrate_legacy [force]
migrate_legacy() {
    local ts archive f files=() failed="" done_parts="" L_MODE="" L_RESET_DAY="" L_ONCE_DATE=""
    legacy_present || return 0
    if [ -f "$MIGRATE_FAILED" ] && [ "${1:-}" != force ]; then
        return 0
    fi
    ensure_dirs
    ts=$(date +%Y%m%d-%H%M%S)
    info "检测到 2.x 版本的配置，正在迁移到 ${ETC_DIR#"$R"}"

    for f in "$LEGACY_CONF_DIR/go.conf" "$LEGACY_CONF_DIR/telemt.conf" "$LEGACY_TELEMT_TOML" \
        "$LEGACY_RESET_CONF" "$LEGACY_RESET_LOG" "$TELEMT_QUOTA_JSON" "$(svc_file mtg)" "$(svc_file telemt)"; do
        [ -f "$f" ] && files+=("${f#"$R"/}")
    done
    archive="$BACKUP_DIR/legacy-$ts.tar.gz"
    if ! tar -czf "$archive" -C "${R:-/}" "${files[@]}" 2>/dev/null; then
        err "备份旧配置失败，已取消迁移"
        return 1
    fi
    chmod 0600 "$archive"

    if legacy_mtg_present; then
        if ! legacy_mtg_parse; then
            failed+=" Go(无法解析旧配置)"
        elif [ ! -x "$BIN_DIR/mtg-go" ]; then
            failed+=" Go(内核文件缺失)"
        else
            mtg_save
            if mtg_apply; then
                rm -f "$LEGACY_CONF_DIR/go.conf"
                done_parts+=" Go"
            else
                rm -f "$MTG_STATE" "$MTG_CONF"
                _legacy_restore_unit mtg "$archive"
                failed+=" Go(启动失败)"
            fi
        fi
    fi

    if legacy_telemt_present; then
        if ! legacy_telemt_parse; then
            failed+=" Telemt(无法解析旧配置)"
        elif [ ! -x "$BIN_DIR/telemt" ]; then
            failed+=" Telemt(内核文件缺失)"
        else
            telemt_save
            users_save
            if telemt_apply; then
                rm -f "$LEGACY_TELEMT_TOML" "$LEGACY_CONF_DIR/telemt.conf"
                done_parts+=" Telemt(${#U_NAME[@]} 个用户)"
            else
                rm -f "$TELEMT_STATE" "$USERS_DB" "$TELEMT_CONF"
                _legacy_restore_unit telemt "$archive"
                failed+=" Telemt(启动失败)"
            fi
        fi
    elif [ -f "$LEGACY_CONF_DIR/telemt.conf" ]; then
        rm -f "$LEGACY_CONF_DIR/telemt.conf"
    fi

    if [ -f "$LEGACY_RESET_CONF" ]; then
        state_load "$LEGACY_RESET_CONF" L
        reset_load
        case $L_MODE in
            monthly) RESET_MODE="monthly"; [[ "$L_RESET_DAY" =~ ^[0-9]+$ ]] && RESET_DAY="$((10#$L_RESET_DAY))" ;;
            once) RESET_MODE="once"; RESET_DATE="$L_ONCE_DATE" ;;
            *) RESET_MODE="disabled" ;;
        esac
        reset_save
        rm -f "$LEGACY_RESET_CONF"
    fi
    if [ -f "$LEGACY_RESET_LOG" ]; then
        cat "$LEGACY_RESET_LOG" >> "$RESET_LOG" 2>/dev/null
        chmod 0600 "$RESET_LOG"
        rm -f "$LEGACY_RESET_LOG"
    fi
    # OpenRC 旧日志含连接密钥且权限为 644，迁移成功后移入新目录
    if [ -z "$failed" ]; then
        for f in mtg telemt; do
            if [ -f "$R/var/log/$f.log" ]; then
                cat "$R/var/log/$f.log" >> "$LOG_DIR/$f.log.old" 2>/dev/null
                chmod 0600 "$LOG_DIR/$f.log.old"
                rm -f "$R/var/log/$f.log"
            fi
        done
    fi
    rmdir "$LEGACY_CONF_DIR" 2>/dev/null

    [ -n "$done_parts" ] && ok "已迁移：${done_parts# }"
    if [ -n "$failed" ]; then
        printf '%s\n' "${failed# }" > "$MIGRATE_FAILED"
        err "未能迁移：${failed# }；服务仍按旧配置运行"
        detail "旧配置备份在 ${archive}，处理后可运行 mtp migrate 重试"
        return 1
    fi
    rm -f "$MIGRATE_FAILED"
    detail "旧配置已备份到 ${archive#"$R"}"
    return 0
}

# ============================================================
# 维护：删除内核、全部卸载、脚本更新、并发锁
# ============================================================

# 修改配置时加锁，避免与定时清零同时写入
lock_acquire() {
    [ -n "${MTP_LOCKED:-}" ] && return 0
    have flock || return 0
    mkdir -p "$STATE_DIR"
    exec 9>"$STATE_DIR/.lock" || return 0
    flock -w 120 9 || { err "另一个 mtp 操作正在进行，请稍后再试"; return 1; }
    MTP_LOCKED=1
}

lock_release() {
    [ -n "${MTP_LOCKED:-}" ] || return 0
    flock -u 9 2>/dev/null
    exec 9>&-
    MTP_LOCKED=""
}

# with_lock 命令...
with_lock() {
    local rc
    if [ -n "${MTP_LOCKED:-}" ]; then
        "$@"
        return
    fi
    lock_acquire || return 1
    "$@"
    rc=$?
    lock_release
    return "$rc"
}

remove_kernel_page() {
    ui_page "删除内核" "仅删除所选内核，保留脚本"
    menu_reset
    if mtg_installed; then mtg_load; menu_add 1 "删除 Go 内核" ":$MTG_PORT" mtg "$CR"; fi
    if telemt_installed; then
        users_load
        menu_add 2 "删除 Telemt 内核" "${#U_NAME[@]} 个用户" telemt "$CR"
    fi
    if [ ${#MENU_KEYS[@]} -eq 0 ]; then
        note "尚未安装任何内核"
        return 0
    fi
    menu_add 0 "返回" "" back
    menu_show
    printf '\n'
    menu_read || return 0
    printf '\n'
    case $MENU_ACTION in
        mtg) confirm "删除 Go 内核及其配置？现有链接将失效" n && mtg_uninstall ;;
        telemt) confirm "删除 Telemt 内核及全部 ${#U_NAME[@]} 个用户？" n && telemt_uninstall ;;
    esac
    return 0
}

# uninstall_all [yes]
uninstall_all() {
    local keep
    keep="$R/root/mtproxy-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    ui_page "卸载" "全部内核、配置与 mtp 命令"
    note "将停止并删除全部内核、配置、用户、日志和 mtp 命令"
    if [ -d "$ETC_DIR" ] && [ -n "$(ls -A "$ETC_DIR" 2>/dev/null)" ]; then
        note "卸载前会把配置备份到 ${keep#"$R"}"
    fi
    printf '\n'
    if [ "${1:-}" != yes ]; then
        confirm_word uninstall || { note "已取消"; return 1; }
        printf '\n'
    fi
    if [ -d "$ETC_DIR" ] && [ -n "$(ls -A "$ETC_DIR" 2>/dev/null)" ] && backup_create "$keep"; then
        ok "配置已备份到 ${keep#"$R"}"
    fi
    svc_remove mtg
    svc_remove telemt
    svc_remove mtp-rust
    cron_remove
    rm -rf "$ETC_DIR" "$STATE_DIR" "$LOG_DIR" "$OPT_DIR"
    rm -f "$TELEMT_QUOTA_JSON" "$LOGROTATE_FILE" "$LEGACY_TELEMT_TOML" "$LEGACY_RESET_CONF" "$LEGACY_RESET_LOG" \
        "$R/var/log/mtg.log" "$R/var/log/telemt.log"
    remove_service_user
    rm -f "$MTP_BIN"
    ok "已卸载"
}

# ------------------------------------------------------------
# 脚本更新
# ------------------------------------------------------------

update_channel() { setting_get CHANNEL stable; }

# 每行：脚本地址 校验文件地址
update_sources() {
    if [ "$(update_channel)" = dev ]; then
        echo "$MTP_SCRIPT_URL?ch=dev $MTP_SCRIPT_URL.sha256?ch=dev"
        echo "$MTP_RAW_BASE/main/mtp.sh $MTP_RAW_BASE/main/mtp.sh.sha256"
    else
        echo "$MTP_SCRIPT_URL $MTP_SCRIPT_URL.sha256"
        echo "$MTP_RAW_BASE/stable/mtp.sh $MTP_RAW_BASE/stable/mtp.sh.sha256"
        echo "$MTP_RAW_BASE/main/mtp.sh $MTP_RAW_BASE/main/mtp.sh.sha256"
    fi
}

# update_fetch 目录：下载并校验，成功时写入 目录/mtp.sh 与 目录/source
update_fetch() {
    local dir="$1" url sum expected
    while read -r url sum; do
        rm -f "$dir/mtp.sh" "$dir/sum"
        http_get "$url" "$dir/mtp.sh" 2>/dev/null || continue
        [ -s "$dir/mtp.sh" ] && bash -n "$dir/mtp.sh" 2>/dev/null || continue
        grep -q '^MTP_VERSION="[0-9.]*"$' "$dir/mtp.sh" || continue
        if http_get "$sum" "$dir/sum" 2>/dev/null; then
            expected=$(awk '{ print $1; exit }' "$dir/sum")
            if [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$expected" != "$(sha256_of "$dir/mtp.sh")" ]; then
                continue
            fi
        fi
        printf '%s' "$url" > "$dir/source"
        return 0
    done < <(update_sources)
    return 1
}

# self_update [reexec]
self_update() {
    local dir new cur
    dir=$(mktemp -d)
    if ! spin_run "检查脚本更新" update_fetch "$dir"; then
        rm -rf "$dir"
        err "无法获取新版脚本，请检查网络后重试"
        return 1
    fi
    new=$(sed -n 's/^MTP_VERSION="\([0-9.]*\)"$/\1/p' "$dir/mtp.sh" | head -n 1)
    cur=$(sha256_of "$MTP_BIN")
    if [ "$cur" = "$(sha256_of "$dir/mtp.sh")" ]; then
        rm -rf "$dir"
        ok "已是最新 v$MTP_VERSION"
        return 0
    fi
    if ver_gt "$MTP_VERSION" "$new" && [ "${MTP_ALLOW_DOWNGRADE:-0}" != 1 ]; then
        rm -rf "$dir"
        warn "远端版本 v$new 低于当前 v$MTP_VERSION，未更新"
        return 0
    fi
    mkdir -p "$(dirname "$MTP_BIN")"
    if ! install -m 0755 "$dir/mtp.sh" "$MTP_BIN"; then
        rm -rf "$dir"
        err "写入 $MTP_BIN 失败"
        return 1
    fi
    rm -rf "$dir"
    printf 'TS=%s\nVER=%s\n' "$(date +%s)" "$new" | atomic_write "$REMOTE_CACHE" 0600
    ok "已更新到 v$new"
    if [ "${1:-}" = reexec ]; then
        sleep 1
        exec "$MTP_BIN"
    fi
}

remote_version_fetch() {
    local v q=""
    [ "$(update_channel)" = dev ] && q="?ch=dev"
    v=$(http_text "${MTP_SCRIPT_URL%/*}/version$q" | head -c 32 | tr -d '[:space:]')
    if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        v=$(http_text "$MTP_RAW_BASE/main/mtp.sh" | sed -n 's/^MTP_VERSION="\([0-9.]*\)"$/\1/p' | head -n 1)
    fi
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf 'TS=%s\nVER=%s\n' "$(date +%s)" "$v" | atomic_write "$REMOTE_CACHE" 0600
}

# remote_version [refresh]：远端最新版本号（缓存 6 小时）
remote_version() {
    local ts
    ts=$(state_get "$REMOTE_CACHE" TS 0)
    if [ "${1:-}" = refresh ] || ! [[ "$ts" =~ ^[0-9]+$ ]] || (( $(date +%s) - ts > 21600 )); then
        remote_version_fetch >/dev/null 2>&1
    fi
    state_get "$REMOTE_CACHE" VER
}

# 菜单启动时在后台刷新版本缓存，不阻塞界面
remote_version_bg() {
    local ts
    ts=$(state_get "$REMOTE_CACHE" TS 0)
    [[ "$ts" =~ ^[0-9]+$ ]] && (( $(date +%s) - ts <= 21600 )) && return 0
    ( remote_version_fetch >/dev/null 2>&1 & )
}

# ============================================================
# 交互菜单
# ============================================================

# status_row 类型：Go  ● 运行中  :443  12.4 MB  3天4时
status_row() {
    local kind="$1" label port pid stats
    label=$(core_label "$kind")
    printf '  %s%s' "$(pad "$label" 9)" "$(svc_status_text "$kind")"
    if [ "$kind" = mtg ] && mtg_installed; then mtg_load; port="$MTG_PORT"; fi
    if [ "$kind" = telemt ] && telemt_installed; then telemt_load; port="$TELEMT_PORT"; fi
    if [ -n "${port:-}" ]; then
        printf '   %s' "$(pad ":$port" 8)"
        if svc_active "$kind" && pid=$(svc_pid "$kind" "$(core_proc "$kind")"); then
            stats=$(proc_stats "$pid")
            printf '%s%s%s%s' "$CD" "$(pad "${stats%%|*}" 11)" "${stats#*|}" "$C0"
        fi
    fi
    printf '\n'
}

status_block() {
    status_row mtg
    status_row telemt
}

menu_main() {
    local remote hint users
    remote_version_bg
    while :; do
        ui_clear
        ui_header "MTProxy" "v$MTP_VERSION"
        note "$OS_NAME · $INIT_SYSTEM · ${ARCH:-$(uname -m)}"
        ui_rule
        status_block
        if [ -f "$MIGRATE_FAILED" ]; then
            warn "旧版配置迁移未完成：$(cat "$MIGRATE_FAILED")，请运行 mtp migrate"
        fi
        ui_rule

        menu_reset
        menu_sep "部署"
        if mtg_installed; then menu_add 1 "Go 内核" "已安装 · 更新或重装" install_mtg
        else menu_add 1 "安装 Go 内核" "mtg · 轻量" install_mtg; fi
        if telemt_installed; then menu_add 2 "Telemt 内核" "已安装 · 更新或重装" install_telemt
        else menu_add 2 "安装 Telemt 内核" "Rust · 多用户" install_telemt; fi
        menu_add 3 "更新内核" "保留配置与链接" upgrade_core

        menu_sep "管理"
        menu_add 4 "连接信息" "链接 · 二维码" info
        users=""
        telemt_installed && { users_load; users="Telemt · ${#U_NAME[@]} 人"; }
        menu_add 5 "用户管理" "$users" users
        menu_add 6 "端口与域名" "" settings
        menu_add 7 "服务控制" "启动 · 停止 · 重启" control
        menu_add 8 "日志" "" logs

        menu_sep "系统"
        menu_add 9 "诊断" "端口 · 时间 · 域名" doctor
        menu_add b "备份与恢复" "" backup
        hint=""
        remote=$(state_get "$REMOTE_CACHE" VER)
        [ -n "$remote" ] && ver_gt "$remote" "$MTP_VERSION" && hint="v$remote 可用"
        menu_add u "更新脚本" "$hint" update
        menu_add d "删除内核" "" remove "$CR"
        menu_add x "卸载全部" "" uninstall "$CR"
        menu_add 0 "退出" "" quit
        menu_show
        printf '\n'
        ui_rule
        menu_read || continue
        case $MENU_ACTION in
            install_mtg) mtg_install; pause ;;
            install_telemt) telemt_install; pause ;;
            upgrade_core) core_upgrade_page; pause ;;
            info) info_page ;;
            users) users_page ;;
            settings) settings_page ;;
            control) control_page ;;
            logs) logs_page ;;
            doctor) doctor_page; pause ;;
            backup) backup_page ;;
            update) ui_page "更新脚本" "v$MTP_VERSION"; self_update reexec; pause ;;
            remove) remove_kernel_page; pause ;;
            uninstall) uninstall_all && exit 0; pause ;;
            quit) printf '\n'; exit 0 ;;
        esac
    done
}

info_page() {
    local all=()
    ui_page "连接信息"
    if ! mtg_installed && ! telemt_installed; then
        note "尚未安装任何内核"
        pause
        return
    fi
    if mtg_installed; then
        printf '\n'
        mtg_show_info
        all+=("${LAST_LINKS[@]}")
    fi
    if telemt_installed; then
        printf '\n'
        telemt_show_info
        all+=("${LAST_LINKS[@]}")
    fi
    LAST_LINKS=("${all[@]}")
    links_menu
}

# 选择操作对象：同时安装了两个内核时询问
pick_target() {
    local c
    if mtg_installed && telemt_installed; then
        ask c "对象 ${CD}1${C0} 全部 · ${CD}2${C0} Go · ${CD}3${C0} Telemt" 1
        case $c in
            2) echo mtg ;;
            3) echo telemt ;;
            *) echo "mtg telemt" ;;
        esac
    elif mtg_installed; then
        echo mtg
    elif telemt_installed; then
        echo telemt
    fi
}

# service_action start|stop|restart 类型...
service_action() {
    local action="$1" kind label
    shift
    for kind in "$@"; do
        label=$(core_label "$kind")
        svc_exists "$kind" || { warn "$label 未安装"; continue; }
        case $action in
            stop)
                if svc_ctl stop "$kind"; then ok "$label 已停止"; else err "$label 停止失败"; fi ;;
            *)
                svc_ctl "$action" "$kind"
                if [ "$kind" = mtg ]; then
                    mtg_load
                    if wait_for "等待 $label 就绪" 15 mtg_ready; then ok "$label 运行中，监听 $MTG_PORT"; else err "$label 启动失败"; svc_show_failure mtg; fi
                else
                    telemt_load
                    if wait_for "等待 $label 就绪" 45 telemt_ready; then ok "$label 运行中，监听 $TELEMT_PORT"; else err "$label 启动失败"; svc_show_failure telemt; fi
                fi ;;
        esac
    done
}

control_page() {
    local targets
    while :; do
        ui_page "服务控制"
        status_block
        ui_rule
        menu_reset
        menu_add 1 "启动" "" start
        menu_add 2 "停止" "" stop
        menu_add 3 "重启" "" restart
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || continue
        [ "$MENU_ACTION" = back ] && return
        printf '\n'
        targets=$(pick_target)
        if [ -z "$targets" ]; then
            warn "尚未安装任何内核"
        else
            # shellcheck disable=SC2086
            service_action "$MENU_ACTION" $targets
        fi
        pause
    done
}

# 实时跟踪日志；Ctrl+C 只结束跟踪，不退出脚本
follow_logs() {
    local args=() kind
    for kind in mtg telemt; do
        svc_exists "$kind" || continue
        if [ "$INIT_SYSTEM" = systemd ]; then args+=("--unit=$kind"); else args+=("$LOG_DIR/$kind.log"); fi
    done
    if [ ${#args[@]} -eq 0 ]; then
        warn "尚未安装任何内核"
        pause
        return
    fi
    trap ':' INT
    if [ "$INIT_SYSTEM" = systemd ]; then
        journalctl -f -n 20 "${args[@]}" 2>/dev/null | redact
    else
        tail -n 20 -f "${args[@]}" 2>/dev/null | redact
    fi
    trap - INT
}

logs_page() {
    while :; do
        ui_page "日志" "已隐藏连接密钥"
        menu_reset
        menu_add 1 "Go 最近 50 行" "" mtg
        menu_add 2 "Telemt 最近 50 行" "" telemt
        menu_add 3 "实时跟踪" "Ctrl+C 结束" follow
        menu_add 4 "流量清零记录" "" reset
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || continue
        printf '\n'
        case $MENU_ACTION in
            mtg|telemt) svc_logs "$MENU_ACTION" 50 | redact; pause ;;
            follow)
                follow_logs ;;
            reset)
                if [ -s "$RESET_LOG" ]; then tail -n 30 "$RESET_LOG"; else note "暂无记录"; fi
                pause ;;
            back) return ;;
        esac
    done
}

settings_page() {
    local host
    while :; do
        ui_page "端口与域名"
        if mtg_installed; then
            mtg_load
            printf '  %s%s  %s  %s\n' "$(pad Go 9)" "$(pad ":$MTG_PORT" 8)" "$(pad "$MTG_DOMAIN" 22)" "$(ip_mode_label "$MTG_IP_MODE")"
        fi
        if telemt_installed; then
            telemt_load
            printf '  %s%s  %s  %s\n' "$(pad Telemt 9)" "$(pad ":$TELEMT_PORT" 8)" "$(pad "$TELEMT_DOMAIN" 22)" "$(ip_mode_label "$TELEMT_IP_MODE")"
        fi
        host=$(setting_get LINK_HOST)
        ui_kv "链接地址" "${host:-自动检测公网 IP}"
        ui_rule
        menu_reset
        if mtg_installed; then
            menu_sep "Go"
            menu_add 1 "端口" "" mtg:port
            menu_add 2 "伪装域名" "" mtg:domain
            menu_add 3 "监听模式" "" mtg:mode
            menu_add 4 "重置密钥" "旧链接立即失效" mtg:secret
        fi
        if telemt_installed; then
            menu_sep "Telemt"
            menu_add 5 "共享端口" "" telemt:port
            menu_add 6 "伪装域名" "" telemt:domain
            menu_add 7 "监听模式" "" telemt:mode
            menu_add 8 "推广频道" "${TELEMT_AD_TAG:+已启用}" telemt:adtag
        fi
        menu_sep "通用"
        menu_add 9 "链接地址" "域名或 IP，用于生成链接" linkhost
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || continue
        printf '\n'
        case $MENU_ACTION in
            mtg:*) mtg_modify "${MENU_ACTION#mtg:}"; pause ;;
            telemt:*) telemt_modify "${MENU_ACTION#telemt:}"; pause ;;
            linkhost) linkhost_edit; pause ;;
            back) return ;;
        esac
    done
}

_linkhost_ok() { [ "$1" = 0 ] || is_host "$1"; }

linkhost_edit() {
    local v cur
    cur=$(setting_get LINK_HOST)
    note "默认使用自动检测的公网 IP；NAT 机器或使用域名时可在此指定。0 恢复自动"
    ask_valid v "链接地址" "" "${cur:-自动}" _linkhost_ok "请输入域名或 IP" || return 1
    [ -z "$v" ] && { note "未修改"; return 0; }
    if [ "$v" = 0 ]; then
        setting_set "LINK_HOST="
        ok "已恢复自动检测"
    else
        setting_set "LINK_HOST=$v"
        ok "链接地址已设为 $v"
    fi
}

# ============================================================
# 命令行
# ============================================================

cli_help() {
    cat <<EOF

  ${CB}mtp${C0} ${CD}v$MTP_VERSION · MTProxy 管理脚本${C0}

  不带参数运行时打开管理菜单。

  ${CD}服务${C0}
    status                          运行状态
    info [go|telemt]                连接信息
    start|stop|restart [go|telemt]  启停服务
    logs [go|telemt] [-f]           查看日志（已隐藏密钥）
    doctor [--fix]                  诊断，--fix 自动处理防火墙与 BBR

  ${CD}用户（Telemt）${C0}
    user list [--json]
    user add 名称 [选项]            添加用户
    user edit 名称 [选项]           修改用户
    user link 名称 [--qr]           查看链接
    user reset 名称                 清零已用流量
    user del 名称 [-y]              删除用户
    reset-now                       立即清零全部配额用户（已到期除外）

    选项：--quota 50G  --expire 2026-12-31|+30d  --port 8443
          --up 1.5  --down 5  （MB/s）
          --no-quota  --no-expire  --no-port  --no-limit

  ${CD}维护${C0}
    upgrade-core [go|telemt]        更新内核，保留配置与链接
    update [--dev|--stable]         更新管理脚本
    backup [文件]                   备份配置、用户与流量记录
    restore 文件                    从备份恢复
    migrate                         重新迁移 2.x 旧配置
    uninstall [-y]                  卸载全部
    version                         显示版本

EOF
}

cli_kinds() {
    case ${1:-} in
        go|mtg) echo mtg ;;
        telemt|rust) echo telemt ;;
        ''|all)
            local k=""
            mtg_installed && k="mtg"
            telemt_installed && k="$k telemt"
            echo "$k" ;;
        *) return 1 ;;
    esac
}

cli_status() {
    ui_header "MTProxy" "v$MTP_VERSION"
    note "$OS_NAME · $INIT_SYSTEM · ${ARCH:-$(uname -m)}"
    ui_rule
    status_block
    mtg_installed && note "Go 内核 $(core_version mtg)"
    telemt_installed && { users_load; note "Telemt 内核 $(core_version telemt) · ${#U_NAME[@]} 个用户"; }
    reset_load
    [ "$RESET_MODE" != disabled ] && note "流量自动清零：$(reset_describe)"
    return 0
}

json_str() { printf '"%s"' "$1"; }
json_num_or_null() { if [ "$1" = - ] || [ -z "$1" ]; then printf 'null'; else printf '%s' "$1"; fi; }
json_str_or_null() { if [ "$1" = - ] || [ -z "$1" ]; then printf 'null'; else json_str "$1"; fi; }

cli_user_list() {
    local i sep="" host label secret links lsep
    telemt_installed || { err "Telemt 内核未安装"; return 1; }
    telemt_load
    users_load
    quota_load
    NOW=$(date +%s)
    if [ "${1:-}" = --json ]; then
        printf '['
        for i in "${!U_NAME[@]}"; do
            user_eval "$i"
            secret=$(secret_b64 "${U_SECRET[i]}" "$TELEMT_DOMAIN")
            links="" lsep=""
            while read -r label host; do
                [ -z "$host" ] && continue
                links+="$lsep$(json_str "$(link_tg "$host" "$(user_port "$i")" "$secret")")"
                lsep=","
            done < <(link_hosts "$TELEMT_IP_MODE")
            printf '%s{"name":%s,"port":%s,"shared_port":%s,"quota_bytes":%s,"used_bytes":%s,"expire":%s,"speed_up":%s,"speed_down":%s,"state":%s,"secret":%s,"links":[%s]}' \
                "$sep" "$(json_str "${U_NAME[i]}")" "$(user_port "$i")" \
                "$([ "${U_PORT[i]}" = - ] && echo true || echo false)" \
                "$(json_num_or_null "${U_QUOTA[i]}")" "$US_USED" "$(json_str_or_null "${U_EXPIRE[i]}")" \
                "$(json_num_or_null "${U_UP[i]}")" "$(json_num_or_null "${U_DOWN[i]}")" \
                "$(json_str "$US_STATE")" "$(json_str "$secret")" "$links"
            sep=","
        done
        printf ']\n'
        return 0
    fi
    ui_header "用户" "Telemt · ${#U_NAME[@]} 人"
    ui_rule
    users_table
}

# 解析 user add/edit 的选项到 OPT_ARGS（字段=值）
cli_user_opts() {
    local mode="$1" key val
    shift
    OPT_ARGS=()
    while [ $# -gt 0 ]; do
        key="$1"
        val=""
        case $key in
            --*=*) val="${key#*=}"; key="${key%%=*}" ;;
            --quota|--expire|--port|--up|--down)
                [ $# -ge 2 ] || { err "$key 需要一个值"; return 1; }
                val="$2"; shift ;;
        esac
        case $key in
            --quota) parse_quota "$val" || { err "流量配额格式不正确：$val"; return 1; }; OPT_ARGS+=("quota=$_QUOTA") ;;
            --expire)
                parse_expire "$val" "${OPT_CUR_EXPIRE:-}" || { err "到期时间格式不正确或早于现在：$val"; return 1; }
                OPT_ARGS+=("expire=$_EXPIRE") ;;
            --port)
                is_port "$val" || { err "端口不正确：$val"; return 1; }
                local why
                why=$(port_check "$val" user "${OPT_USER:-}") || { err "端口 $val $why"; return 1; }
                OPT_ARGS+=("port=$((10#$val))") ;;
            --up) is_speed "$val" || { err "上行限速不正确：$val"; return 1; }; OPT_ARGS+=("up=$val") ;;
            --down) is_speed "$val" || { err "下行限速不正确：$val"; return 1; }; OPT_ARGS+=("down=$val") ;;
            --no-quota) OPT_ARGS+=("quota=-") ;;
            --no-expire) OPT_ARGS+=("expire=-") ;;
            --no-port) OPT_ARGS+=("port=-") ;;
            --no-limit) OPT_ARGS+=("up=-" "down=-") ;;
            *) err "未知选项：$1"; return 1 ;;
        esac
        shift
    done
    [ "$mode" = edit ] && [ ${#OPT_ARGS[@]} -eq 0 ] && { err "没有需要修改的内容"; return 1; }
    return 0
}

# opt_value 字段 默认值：从 OPT_ARGS 取值
opt_value() {
    local kv
    for kv in "${OPT_ARGS[@]}"; do
        [ "${kv%%=*}" = "$1" ] && { printf '%s' "${kv#*=}"; return 0; }
    done
    printf '%s' "$2"
}

cli_user() {
    local sub="${1:-list}" name="${2:-}"
    shift 2 2>/dev/null || shift $#
    telemt_installed || { err "Telemt 内核未安装"; return 1; }
    telemt_load
    users_load
    case $sub in
        list|ls) cli_user_list "$name" ;;
        add)
            is_username "$name" || { err "用户名仅限字母、数字、下划线和连字符，最长 32 位"; return 1; }
            OPT_USER="$name"
            cli_user_opts add "$@" || return 1
            user_create "$name" "$(opt_value port -)" "$(opt_value quota -)" "$(opt_value expire -)" \
                "$(opt_value up -)" "$(opt_value down -)" || return 1
            cli_user link "$name" ;;
        edit|set)
            user_find "$name" || { err "用户 $name 不存在"; return 1; }
            OPT_USER="$name" OPT_CUR_EXPIRE="${U_EXPIRE[_UIDX]/#-/}"
            cli_user_opts edit "$@" || return 1
            user_update "$name" "${OPT_ARGS[@]}" ;;
        link|show)
            user_find "$name" || { err "用户 $name 不存在"; return 1; }
            printf '  %s%s%s\n' "$CB" "$name" "$C0"
            show_links "$TELEMT_IP_MODE" "$(user_port "$_UIDX")" "$(secret_b64 "${U_SECRET[_UIDX]}" "$TELEMT_DOMAIN")"
            [ "${1:-}" = --qr ] && show_qr
            printf '\n' ;;
        reset) user_find "$name" || { err "用户 $name 不存在"; return 1; }; user_update "$name" zero ;;
        del|rm|delete)
            user_find "$name" || { err "用户 $name 不存在"; return 1; }
            if [ "${1:-}" != -y ]; then
                [ "$UI_TTY" = 1 ] || { err "非交互环境请加 -y 确认"; return 1; }
                confirm "删除用户 $name？" n || return 1
            fi
            user_remove "$name" ;;
        *) err "未知命令：user $sub"; return 1 ;;
    esac
}

cli_main() {
    local cmd="$1" k kinds
    shift
    case $cmd in
        status) cli_status ;;
        info)
            kinds=$(cli_kinds "${1:-}") || { err "未知内核：$1"; return 1; }
            [ -n "$kinds" ] || { warn "尚未安装任何内核"; return 1; }
            for k in $kinds; do
                printf '\n'
                if [ "$k" = mtg ]; then mtg_show_info; else telemt_show_info; fi
            done
            printf '\n' ;;
        start|stop|restart)
            kinds=$(cli_kinds "${1:-}") || { err "未知内核：$1"; return 1; }
            [ -n "$kinds" ] || { warn "尚未安装任何内核"; return 1; }
            # shellcheck disable=SC2086
            service_action "$cmd" $kinds ;;
        logs)
            if [ "${1:-}" = -f ] || [ "${2:-}" = -f ]; then follow_logs; return; fi
            kinds=$(cli_kinds "${1:-}") || { err "未知内核：$1"; return 1; }
            for k in $kinds; do svc_logs "$k" 50 | redact; done ;;
        doctor)
            doctor_run
            if [ "${1:-}" = --fix ] && [ ${#DOC_FIXES[@]} -gt 0 ]; then printf '\n'; doctor_fix yes; fi ;;
        user|users) cli_user "$@" ;;
        reset-now|force_reset)
            reset_run "手动清零" && tail -n 1 "$RESET_LOG" ;;
        check_reset) reset_check ;;
        upgrade-core|upgrade)
            kinds=$(cli_kinds "${1:-}") || { err "未知内核：$1"; return 1; }
            [ -n "$kinds" ] || { warn "尚未安装任何内核"; return 1; }
            for k in $kinds; do core_upgrade "$k"; done ;;
        update)
            case ${1:-} in
                --dev) setting_set CHANNEL=dev; note "已切换到开发版通道" ;;
                --stable) setting_set CHANNEL=stable; note "已切换到稳定版通道" ;;
            esac
            self_update ;;
        backup)
            backup_create "${1:-}" && ok "已备份到 $BACKUP_FILE" ;;
        restore)
            [ -n "${1:-}" ] || { err "用法：mtp restore 备份文件"; return 1; }
            backup_restore "$1" ;;
        migrate)
            legacy_present || { ok "没有需要迁移的旧配置"; return 0; }
            migrate_legacy force ;;
        uninstall)
            if [ "${1:-}" = -y ]; then uninstall_all yes; else uninstall_all; fi ;;
        *)
            err "未知命令：$cmd"
            cli_help
            return 1 ;;
    esac
}

# ============================================================
# 入口
# ============================================================

# 从本地文件运行时，把脚本安装为 mtp 命令（不会用旧版本覆盖已安装的新版本）
self_install() {
    local src dst installed
    [ -n "$R" ] && return 0
    src=$(readlink -f "$0" 2>/dev/null)
    [ -f "$src" ] || return 0
    dst=$(readlink -f "$MTP_BIN" 2>/dev/null)
    [ "$src" = "$dst" ] && return 0
    if [ -f "$MTP_BIN" ]; then
        [ "$(sha256_of "$src")" = "$(sha256_of "$MTP_BIN")" ] && return 0
        installed=$(sed -n 's/^MTP_VERSION="\([0-9.]*\)"$/\1/p' "$MTP_BIN" | head -n 1)
        [ -n "$installed" ] && ver_gt "$installed" "$MTP_VERSION" && return 0
    fi
    mkdir -p "$(dirname "$MTP_BIN")"
    rm -f "$MTP_BIN"
    install -m 0755 "$src" "$MTP_BIN" 2>/dev/null
}

main() {
    ui_init
    case ${1:-} in
        -h|--help|help) cli_help; return 0 ;;
        -v|--version|version) printf 'mtp v%s\n' "$MTP_VERSION"; return 0 ;;
    esac
    require_root
    umask 077
    detect_os
    SCRIPT_DIR=""
    local self
    self=$(readlink -f "$0" 2>/dev/null)
    [ -f "$self" ] && SCRIPT_DIR=$(dirname "$self")
    ensure_dirs
    if legacy_present; then
        if [ "${1:-}" = check_reset ]; then
            migrate_legacy >/dev/null 2>&1
        else
            migrate_legacy
        fi
    fi
    self_install
    if [ $# -eq 0 ]; then
        [ "$UI_TTY" = 1 ] || { cli_help; return 1; }
        menu_main
    else
        cli_main "$@"
    fi
}

[ "${MTP_SOURCE_ONLY:-0}" = 1 ] || main "$@"
