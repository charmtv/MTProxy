
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
