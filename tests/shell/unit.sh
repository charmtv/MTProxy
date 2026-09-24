#!/usr/bin/env bash
# mtp.sh 单元测试：在沙箱根目录中运行，服务管理与网络均使用桩函数。
# 用法：bash tests/shell/unit.sh

# shellcheck disable=SC2016,SC2034,SC2153,SC2209
set -u
cd "$(dirname "$0")/../.." || exit 1

PASS=0
FAIL=0
CURRENT=""

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

export MTP_ROOT="$ROOT" MTP_SOURCE_ONLY=1 MTP_INIT=test NO_COLOR=1
# shellcheck source=/dev/null
source ./mtp.sh
ui_init
ARCH=amd64 PKG=apt OS_NAME="Test Linux"

t() { CURRENT="$1"; }
ok_() { PASS=$((PASS + 1)); }
no_() { FAIL=$((FAIL + 1)); printf '  ✗ %s: %s\n' "$CURRENT" "$1" >&2; }
check() { if eval "$1"; then ok_; else no_ "$1"; fi; }
eq() { if [ "$1" = "$2" ]; then ok_; else no_ "期望 [$2]，实际 [$1]"; fi; }
has() { if grep -qF -- "$2" "$1"; then ok_; else no_ "$1 中缺少 [$2]"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then no_ "$1 中不应出现 [$2]"; else ok_; fi; }

toml_valid() {
    python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$1" 2>/dev/null && return 0
    python3 -c 'import tomllib' 2>/dev/null || return 0   # 没有 tomllib 时跳过
    return 1
}

reset_sandbox() {
    rm -rf "${ROOT:?}"/*
    mkdir -p "$ROOT/run" "$ROOT/etc" "$ROOT/root"
    : > "$ROOT/svc.log"
    unset FAIL_START FAIL_HARDEN FAKE_TODAY
    ensure_dirs
}

# ---------------- 桩函数 ----------------
# 不允许测试触碰真实的服务管理器与定时任务
systemctl() { :; }
journalctl() { :; }
rc-service() { :; }
rc-update() { :; }
crontab() { :; }
svc_ctl() {
    echo "$1 $2" >> "$ROOT/svc.log"
    case $1 in
        start|restart)
            if [[ " ${FAIL_START:-} " == *" $2 "* ]]; then rm -f "$ROOT/run/$2"; return 1; fi
            if [ -n "${FAIL_HARDEN:-}" ] && grep -q 'NoNewPrivileges\|command_user' "$(svc_file "$2")" 2>/dev/null; then
                rm -f "$ROOT/run/$2"; return 1
            fi
            touch "$ROOT/run/$2" ;;
        stop) rm -f "$ROOT/run/$2" ;;
    esac
    return 0
}
svc_active() { [ -f "$ROOT/run/$1" ]; }
svc_enable() { :; }
svc_reload_units() { :; }
svc_logs() { :; }
port_is_listening() { grep -qx "$1" "$ROOT/run/busy" 2>/dev/null; }
port_owned_by() {
    case $2 in
        mtg-go) svc_active mtg && [ "$1" = "$(state_get "$MTG_STATE" PORT)" ] ;;
        telemt) svc_active telemt && [ "$1" = "$(state_get "$TELEMT_STATE" PORT)" ] ;;
    esac
}
wait_for() { shift 2; "$@"; }
cron_install() { echo "cron install" >> "$ROOT/svc.log"; }
cron_remove() { echo "cron remove" >> "$ROOT/svc.log"; }
ip_detect() { if [ "$1" = 4 ]; then echo 203.0.113.10; else return 1; fi; }
tls13_check() { return 0; }
fw_backend() { echo none; }
core_install() { mkdir -p "$BIN_DIR"; : > "$(core_bin "$1")"; chmod +x "$(core_bin "$1")"; }
date() {
    if [ -n "${FAKE_TODAY:-}" ]; then
        case "$*" in
            +%Y-%m-%d) echo "$FAKE_TODAY"; return ;;
            +%d) echo "${FAKE_TODAY:8:2}"; return ;;
            +%m) echo "${FAKE_TODAY:5:2}"; return ;;
            +%Y) echo "${FAKE_TODAY:0:4}"; return ;;
        esac
    fi
    command date "$@"
}

# ---------------- 纯函数 ----------------
t "parse_quota"
parse_quota 50 && eq "$_QUOTA" 53687091200
parse_quota 500M && eq "$_QUOTA" 524288000
parse_quota 1.5t && eq "$_QUOTA" 1649267441664
parse_quota "50 GB" && eq "$_QUOTA" 53687091200
check '! parse_quota abc'
check '! parse_quota 0'
check '! parse_quota 1.2.3'
check '! parse_quota -5'

t "fmt_bytes"
eq "$(fmt_bytes 53687091200)" "50G"
eq "$(fmt_bytes 1610612736)" "1.5G"
eq "$(fmt_bytes 524288000)" "500M"
eq "$(fmt_bytes 0)" "0B"

t "iso_to_epoch"
iso_to_epoch "2026-12-31T23:59:59+08:00" && eq "$_EPOCH" "$(command date -u -d '2026-12-31 15:59:59' +%s)"
iso_to_epoch "2026-12-31T15:59:59Z" && eq "$_EPOCH" "$(command date -u -d '2026-12-31 15:59:59' +%s)"
iso_to_epoch "2026-12-31T10:00:00-05:30" && eq "$_EPOCH" "$(command date -u -d '2026-12-31 15:30:00' +%s)"
check '! iso_to_epoch 2026/12/31'

t "parse_expire"
next_year=$(( $(command date +%Y) + 1 ))
parse_expire "$next_year-06-30" && check '[[ "$_EXPIRE" =~ ^'"$next_year"'-06-30T23:59:59[+-][0-9]{2}:[0-9]{2}$ ]]'
parse_expire "$next_year-06-30 18:30" && check '[[ "$_EXPIRE" == '"$next_year"'-06-30T18:30:00* ]]'
check '! parse_expire "$next_year-02-30"'
check '! parse_expire 2001-01-01'
check '! parse_expire 2026/12/31'
check '! parse_expire +0d'
before=$(command date +%s)
parse_expire +30d && iso_to_epoch "$_EXPIRE" && check '(( _EPOCH - before >= 30 * 86400 - 5 && _EPOCH - before <= 30 * 86400 + 5 ))'
cur="$next_year-01-01T00:00:00+00:00"
parse_expire +10d "$cur" && check '[[ "$_EXPIRE" == '"$next_year"'-01-1[01]T* ]]'

t "校验函数"
check 'is_port 443 && is_port 65535 && ! is_port 0 && ! is_port 65536 && ! is_port abc'
check 'is_username admin && is_username a_b-1 && ! is_username -x && ! is_username "a b" && ! is_username ""'
check 'is_domain www.apple.com && ! is_domain localhost && ! is_domain "a b.com" && ! is_domain "x.com\"; rm"'
check 'is_host 1.2.3.4 && is_host 2001:db8::1 && is_host proxy.example.com && ! is_host 999.1.1.1'
check 'is_speed 1.5 && is_speed .5 && ! is_speed 0 && ! is_speed abc'

t "密钥编码"
eq "$(secret_hex 0123456789abcdef0123456789abcdef www.apple.com)" "ee0123456789abcdef0123456789abcdef7777772e6170706c652e636f6d"
eq "$(secret_b64 0123456789abcdef0123456789abcdef www.apple.com)" "7gEjRWeJq83vASNFZ4mrze93d3cuYXBwbGUuY29t"

t "显示宽度"
dwidth "用户管理"; eq "$_DW" 8
dwidth "● 运行中"; eq "$_DW" 8
dwidth "abc"; eq "$_DW" 3
eq "$(pad 端口 6)|" "端口  |"

t "HTTP 日期"
eq "$(http_date_to_epoch "date: Thu, 24 Sep 2026 03:40:00 GMT")" "$(command date -u -d '2026-09-24 03:40:00' +%s)"
eq "$(http_date_to_epoch "Date: Sun, 1 Feb 2026 00:00:05 GMT")" "$(command date -u -d '2026-02-01 00:00:05' +%s)"
check '! http_date_to_epoch "Date: nonsense"'

t "版本比较"
check 'ver_gt 3.1.0 3.0.9 && ver_gt 3.0.10 3.0.9 && ! ver_gt 3.0.0 3.0.0 && ! ver_gt 2.9.9 3.0.0'

t "月份天数"
eq "$(days_in_month 2028 2)" 29
eq "$(days_in_month 2026 2)" 28
eq "$(days_in_month 2100 2)" 28
eq "$(days_in_month 2026 4)" 30

t "状态文件"
reset_sandbox
printf 'PORT=443\nDOMAIN="www.apple.com"\nX=$(touch %s/pwned)\n' "$ROOT" > "$ROOT/test.env"
state_load "$ROOT/test.env" T
eq "$T_PORT" 443
eq "$T_DOMAIN" www.apple.com
check '[ ! -e "$ROOT/pwned" ]'
state_set "$ROOT/test.env" PORT=8443 NEW=1
eq "$(state_get "$ROOT/test.env" PORT)" 8443
eq "$(state_get "$ROOT/test.env" NEW)" 1
eq "$(stat -c %a "$ROOT/test.env")" 600

# ---------------- 流量记录 ----------------
t "quota_edit"
reset_sandbox
printf '{\n  "alice": 100,\n  "bob" : 200,\n  "carol":300\n}\n' > "$TELEMT_QUOTA_JSON"
quota_edit zero=alice drop=bob zero=nobody
quota_load
eq "${Q_USED[alice]}" 0
eq "${Q_USED[carol]}" 300
check '[ -z "${Q_USED[bob]+x}" ]'
check '[ -z "${Q_USED[nobody]+x}" ]'
printf '{"alice":{"used":5}}' > "$TELEMT_QUOTA_JSON"
quota_edit zero=alice 2>/dev/null
eq "$(cat "$TELEMT_QUOTA_JSON")" '{"alice":{"used":5}}'

# ---------------- Telemt 配置生成 ----------------
t "telemt 配置生成"
reset_sandbox
TELEMT_PORT=443 TELEMT_DOMAIN=www.apple.com TELEMT_IP_MODE=dual TELEMT_MAIN_USER=admin TELEMT_AD_TAG=""
U_NAME=(admin bob) U_SECRET=(0123456789abcdef0123456789abcdef 00112233445566778899aabbccddeeff)
U_PORT=(- 8445) U_QUOTA=(- 1073741824) U_EXPIRE=(- 2030-12-31T23:59:59+08:00) U_UP=(- 1.5) U_DOWN=(- -) U_CREATED=(- -)
telemt_render_config
f="$TELEMT_CONF"
has "$f" 'admin = "0123456789abcdef0123456789abcdef"'
has "$f" 'bob = 8445'
has "$f" 'bob = 1073741824'
has "$f" 'bob = 2030-12-31T23:59:59+08:00'
has "$f" 'bob = "1.5 0"'
has "$f" 'ip = "0.0.0.0"'
has "$f" 'ip = "::"'
has "$f" 'use_middle_proxy = false'
hasnt "$f" 'admin = 8'
check 'toml_valid "$f"'
eq "$(stat -c %a "$f")" 600
TELEMT_AD_TAG=0123456789abcdef0123456789abcdef TELEMT_IP_MODE=v4
printf '[server.api]\nenabled = false\n' > "$TELEMT_EXTRA"
telemt_render_config
has "$f" 'use_middle_proxy = true'
has "$f" 'ad_tag = "0123456789abcdef0123456789abcdef"'
hasnt "$f" 'ip = "::"'
has "$f" '[server.api]'
check 'toml_valid "$f"'
rm -f "$TELEMT_EXTRA"

t "mtg 配置生成"
MTG_PORT=443 MTG_SECRET=0123456789abcdef0123456789abcdef MTG_DOMAIN=www.apple.com MTG_IP_MODE=dual
mtg_render_config 0
has "$MTG_CONF" 'secret = "ee0123456789abcdef0123456789abcdef7777772e6170706c652e636f6d"'
has "$MTG_CONF" 'bind-to = "[::]:443"'
has "$MTG_CONF" 'prefer-ip = "prefer-ipv6"'
check 'toml_valid "$MTG_CONF"'
INIT_SYSTEM=systemd mtg_render_service 1
has "$SYSTEMD_DIR/mtg.service" "ExecStart=$BIN_DIR/mtg-go run $MTG_CONF"
has "$SYSTEMD_DIR/mtg.service" "AmbientCapabilities=CAP_NET_BIND_SERVICE"
hasnt "$SYSTEMD_DIR/mtg.service" "0123456789abcdef"
INIT_SYSTEM=openrc mtg_render_service 1
check 'sh -n "$OPENRC_DIR/mtg"'
has "$OPENRC_DIR/mtg" 'command_user="mtproxy:mtproxy"'
INIT_SYSTEM=openrc telemt_render_service 1
check 'sh -n "$OPENRC_DIR/telemt"'
INIT_SYSTEM=test

# ---------------- 用户操作（含回滚） ----------------
t "用户增删改"
reset_sandbox
INIT_SYSTEM=systemd
TELEMT_PORT=443 TELEMT_DOMAIN=www.apple.com TELEMT_IP_MODE=v4 TELEMT_MAIN_USER=admin TELEMT_AD_TAG=""
U_NAME=(admin) U_SECRET=(0123456789abcdef0123456789abcdef) U_PORT=(-) U_QUOTA=(-) U_EXPIRE=(-) U_UP=(-) U_DOWN=(-) U_CREATED=(-)
check 'telemt_commit "安装" >/dev/null'
check 'svc_active telemt'
printf '{"admin":5,"bob":999}' > "$TELEMT_QUOTA_JSON"
check 'user_create bob 8445 1073741824 - 2 - >/dev/null'
users_load
eq "${#U_NAME[@]}" 2
user_find bob && eq "${U_PORT[_UIDX]}" 8445
quota_load
eq "${Q_USED[bob]}" 0
eq "${Q_USED[admin]}" 5
check 'grep -q "^stop telemt" "$ROOT/svc.log"'
check '! user_create bob - - - - - 2>/dev/null'
check 'user_update bob quota=- up=- down=- >/dev/null'
users_load; user_find bob && eq "${U_QUOTA[_UIDX]}" -
hasnt "$TELEMT_CONF" 'user_data_quota'
FAIL_START="telemt"
check '! user_update bob port=9000 >/dev/null 2>&1'
unset FAIL_START
users_load; user_find bob && eq "${U_PORT[_UIDX]}" 8445
has "$TELEMT_CONF" 'bob = 8445'
check 'user_remove bob >/dev/null'
users_load; eq "${#U_NAME[@]}" 1
quota_load; check '[ -z "${Q_USED[bob]+x}" ]'
check '! user_remove admin 2>/dev/null'

t "加固失败自动降级"
FAIL_HARDEN=1
setting_set HARDEN_TELEMT=1
check 'telemt_apply >/dev/null 2>&1'
eq "$(setting_get HARDEN_TELEMT)" 0
hasnt "$SYSTEMD_DIR/telemt.service" 'NoNewPrivileges'
unset FAIL_HARDEN
INIT_SYSTEM=test

t "端口冲突"
reset_sandbox
printf 'PORT=443\n' > "$MTG_STATE"
printf 'PORT=8443\n' > "$TELEMT_STATE"
printf '# h\nbob\t00112233445566778899aabbccddeeff\t9000\t-\t-\t-\t-\t-\n' > "$USERS_DB"
check '! port_check 443 telemt >/dev/null'
check 'port_check 443 mtg >/dev/null'
check '! port_check 8443 user >/dev/null'
check '! port_check 9000 user >/dev/null'
check 'port_check 9000 user bob >/dev/null'
echo 7000 > "$ROOT/run/busy"
check '! port_check 7000 user >/dev/null'
eq "$(port_suggest mtg)" 443
eq "$(port_suggest telemt)" 8443
echo 443 > "$ROOT/run/busy"
eq "$(port_suggest mtg)" 2053
rm -f "$ROOT/run/busy"

# ---------------- 并发锁 ----------------
t "并发锁（兼容 BusyBox flock）"
reset_sandbox
if command -v flock >/dev/null 2>&1; then
    ( exec 8>"$STATE_DIR/.lock"; flock -n 8; sleep 2 ) &
    holder=$!
    sleep 0.5
    lock_start=$(command date +%s)
    check 'with_lock true'
    check '(( $(command date +%s) - lock_start >= 1 ))'
    check '[ -z "${MTP_LOCKED:-}" ]'
    wait "$holder"
    check 'with_lock true'
fi

# ---------------- 自动清零 ----------------
t "自动清零"
reset_sandbox
INIT_SYSTEM=systemd
TELEMT_PORT=443 TELEMT_DOMAIN=www.apple.com TELEMT_IP_MODE=v4 TELEMT_MAIN_USER=a TELEMT_AD_TAG=""
U_NAME=(a b c) U_SECRET=(0123456789abcdef0123456789abcdef 00112233445566778899aabbccddeeff ffeeddccbbaa99887766554433221100)
U_PORT=(- - -) U_QUOTA=(100 100 -) U_EXPIRE=(- 2001-01-01T00:00:00+00:00 -) U_UP=(- - -) U_DOWN=(- - -) U_CREATED=(- - -)
telemt_commit x >/dev/null
printf '{"a":50,"b":60,"c":70}' > "$TELEMT_QUOTA_JSON"
printf 'MODE=monthly\nDAY=31\nDATE=\nLAST=\n' > "$RESET_STATE"
FAKE_TODAY=2026-04-29 reset_check
eq "$(cat "$TELEMT_QUOTA_JSON" | tr -d ' ')" '{"a":50,"b":60,"c":70}'
FAKE_TODAY=2026-04-30 reset_check
quota_load
eq "${Q_USED[a]}" 0
eq "${Q_USED[b]}" 60
eq "${Q_USED[c]}" 70
eq "$(state_get "$RESET_STATE" LAST)" 2026-04-30
printf '{"a":5}' > "$TELEMT_QUOTA_JSON"
FAKE_TODAY=2026-04-30 reset_check
eq "$(cat "$TELEMT_QUOTA_JSON")" '{"a":5}'
has "$RESET_LOG" '已清零 1 人，跳过已到期 1 人'
printf 'MODE=once\nDAY=1\nDATE=2026-05-10\nLAST=\n' > "$RESET_STATE"
FAKE_TODAY=2026-05-12 reset_check
eq "$(state_get "$RESET_STATE" MODE)" disabled
quota_load; eq "${Q_USED[a]}" 0
INIT_SYSTEM=test

# ---------------- 备份与恢复 ----------------
t "备份与恢复"
reset_sandbox
printf 'PORT=443\nSECRET=0123456789abcdef0123456789abcdef\nDOMAIN=www.apple.com\nIP_MODE=v4\n' > "$MTG_STATE"
: > "$BIN_DIR/mtg-go"; chmod +x "$BIN_DIR/mtg-go"
check 'backup_create "$ROOT/b.tar.gz"'
check 'backup_check "$ROOT/b.tar.gz"'
rm -f "$MTG_STATE"
INIT_SYSTEM=systemd
check 'backup_restore "$ROOT/b.tar.gz" >/dev/null 2>&1'
eq "$(state_get "$MTG_STATE" PORT)" 443
check 'svc_active mtg'
mkdir -p "$ROOT/evil/etc/mtproxy"
ln -s /etc/passwd "$ROOT/evil/etc/mtproxy/users.db"
tar -czf "$ROOT/evil1.tar.gz" -C "$ROOT/evil" etc/mtproxy/users.db
check '! backup_check "$ROOT/evil1.tar.gz"'
mkdir -p "$ROOT/evil2/etc"; : > "$ROOT/evil2/etc/shadow"
tar -czf "$ROOT/evil2.tar.gz" -C "$ROOT/evil2" etc/shadow
check '! backup_check "$ROOT/evil2.tar.gz"'
INIT_SYSTEM=test

# ---------------- 2.x 迁移 ----------------
write_legacy() {
    mkdir -p "$LEGACY_CONF_DIR" "$SYSTEMD_DIR" "$BIN_DIR" "$ROOT/var/log"
    : > "$BIN_DIR/mtg-go"; : > "$BIN_DIR/telemt"; chmod +x "$BIN_DIR"/*
    cat > "$LEGACY_CONF_DIR/go.conf" <<EOF
PORT=8443
SECRET=ee0123456789abcdef0123456789abcdef7777772e6170706c652e636f6d
DOMAIN=www.apple.com
IP_MODE=dual
EOF
    cat > "$SYSTEMD_DIR/mtg.service" <<EOF
[Service]
ExecStart=/opt/mtproxy/bin/mtg-go simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 -i prefer-ipv6 [::]:8443 ee0123456789abcdef0123456789abcdef7777772e6170706c652e636f6d
EOF
    cat > "$LEGACY_CONF_DIR/telemt.conf" <<EOF
PORT=443
SECRET=ffeeddccbbaa99887766554433221100
DOMAIN=www.bing.com
IP_MODE=v4
MAIN_USER=admin
EOF
    cat > "$LEGACY_TELEMT_TOML" <<'EOF'
# === General Settings ===
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[network]
ipv4 = true
ipv6 = false
prefer = 4

[server]
port = 443


[[server.listeners]]
ip = "0.0.0.0"



# === Anti-Censorship & Masking ===
[censorship]
tls_domain = "www.bing.com"
mask = true
tls_emulation = false

[access.users]
carol = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
admin = "ffeeddccbbaa99887766554433221100"

[access.user_data_quota]
carol = 53687091200

[access.user_expirations]
carol = 2030-10-01T23:59:59+08:00

[access.user_speed_limits]
carol = "2"

[access.user_ports]
carol = 9443
EOF
    printf '[Service]\nExecStart=/opt/mtproxy/bin/telemt /etc/telemt.toml\n' > "$SYSTEMD_DIR/telemt.service"
    printf '# Telemt\nMODE=monthly\nRESET_DAY=15\nONCE_DATE=\n' > "$LEGACY_RESET_CONF"
    printf '[2026-03-01 00:00:00] 旧日志\n' > "$LEGACY_RESET_LOG"
    printf '{"admin":0,"carol":123}' > "$TELEMT_QUOTA_JSON"
}

t "迁移 2.x 配置"
reset_sandbox
INIT_SYSTEM=systemd
write_legacy
check 'legacy_present'
check 'migrate_legacy >/dev/null 2>&1'
mtg_load
eq "$MTG_PORT" 8443
eq "$MTG_SECRET" 0123456789abcdef0123456789abcdef
eq "$MTG_DOMAIN" www.apple.com
eq "$MTG_IP_MODE" dual
has "$SYSTEMD_DIR/mtg.service" "run $MTG_CONF"
telemt_load
users_load
eq "$TELEMT_PORT" 443
eq "$TELEMT_DOMAIN" www.bing.com
eq "$TELEMT_MAIN_USER" admin
eq "${#U_NAME[@]}" 2
user_find carol
eq "${U_PORT[_UIDX]}" 9443
eq "${U_QUOTA[_UIDX]}" 53687091200
eq "${U_EXPIRE[_UIDX]}" 2030-10-01T23:59:59+08:00
eq "${U_UP[_UIDX]} ${U_DOWN[_UIDX]}" "2 2"
has "$TELEMT_CONF" 'carol = "2 2"'
check 'toml_valid "$TELEMT_CONF"'
eq "$(state_get "$RESET_STATE" MODE)" monthly
eq "$(state_get "$RESET_STATE" DAY)" 15
has "$RESET_LOG" '旧日志'
eq "$(cat "$TELEMT_QUOTA_JSON")" '{"admin":0,"carol":123}'
check '[ ! -e "$LEGACY_TELEMT_TOML" ] && [ ! -e "$LEGACY_CONF_DIR" ] && [ ! -e "$LEGACY_RESET_CONF" ]'
check 'ls "$BACKUP_DIR"/legacy-*.tar.gz >/dev/null'
check '! legacy_present'

t "迁移失败时保留旧配置"
reset_sandbox
INIT_SYSTEM=systemd
write_legacy
FAIL_START="telemt"
check '! migrate_legacy >/dev/null 2>&1'
unset FAIL_START
check '[ -f "$LEGACY_TELEMT_TOML" ] && [ ! -f "$TELEMT_STATE" ]'
has "$SYSTEMD_DIR/telemt.service" '/etc/telemt.toml'
check '[ -f "$MIGRATE_FAILED" ] && [ -f "$MTG_STATE" ]'
check 'migrate_legacy >/dev/null 2>&1'
check 'migrate_legacy force >/dev/null 2>&1'
check '[ -f "$TELEMT_STATE" ] && [ ! -f "$MIGRATE_FAILED" ]'
INIT_SYSTEM=test

t "只有服务文件的旧版 Go"
reset_sandbox
INIT_SYSTEM=systemd
mkdir -p "$BIN_DIR" "$SYSTEMD_DIR"; : > "$BIN_DIR/mtg-go"; chmod +x "$BIN_DIR/mtg-go"
printf '[Service]\nExecStart=/opt/mtproxy/bin/mtg-go simple-run -n 1.1.1.1 -i only-ipv4 0.0.0.0:2053 ee00112233445566778899aabbccddeeff7777772e62696e672e636f6d\n' > "$SYSTEMD_DIR/mtg.service"
check 'migrate_legacy >/dev/null 2>&1'
mtg_load
eq "$MTG_PORT" 2053
eq "$MTG_DOMAIN" www.bing.com
eq "$MTG_IP_MODE" v4
INIT_SYSTEM=test

# ---------------- 命令行 ----------------
t "OpenRC 旧版 Go"
reset_sandbox
INIT_SYSTEM=openrc
mkdir -p "$BIN_DIR" "$OPENRC_DIR"; : > "$BIN_DIR/mtg-go"; chmod +x "$BIN_DIR/mtg-go"
printf '#!/sbin/openrc-run\nname="mtg"\ncommand="/opt/mtproxy/bin/mtg-go"\ncommand_args="simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 -i only-ipv6 [::]:8443 ee00112233445566778899aabbccddeeff7777772e62696e672e636f6d"\n' > "$OPENRC_DIR/mtg"
check 'migrate_legacy >/dev/null 2>&1'
mtg_load
eq "$MTG_PORT $MTG_IP_MODE $MTG_DOMAIN" "8443 v6 www.bing.com"
has "$OPENRC_DIR/mtg" "command_args=\"run $MTG_CONF\""
check 'sh -n "$OPENRC_DIR/mtg"'
INIT_SYSTEM=test

t "命令行"
reset_sandbox
INIT_SYSTEM=systemd
TELEMT_PORT=443 TELEMT_DOMAIN=www.apple.com TELEMT_IP_MODE=v4 TELEMT_MAIN_USER=admin TELEMT_AD_TAG=""
U_NAME=(admin) U_SECRET=(0123456789abcdef0123456789abcdef) U_PORT=(-) U_QUOTA=(-) U_EXPIRE=(-) U_UP=(-) U_DOWN=(-) U_CREATED=(-)
telemt_commit x >/dev/null
check 'cli_main user add dave --quota 10G --expire +7d --port 9555 --up 2 >/dev/null 2>&1'
users_load; user_find dave && eq "${U_QUOTA[_UIDX]} ${U_PORT[_UIDX]} ${U_UP[_UIDX]} ${U_DOWN[_UIDX]}" "10737418240 9555 2 -"
check '! cli_main user add eve --quota abc >/dev/null 2>&1'
check '! cli_main user add eve --port 443 >/dev/null 2>&1'
check 'cli_main user edit dave --no-quota --no-port >/dev/null 2>&1'
users_load; user_find dave && eq "${U_QUOTA[_UIDX]} ${U_PORT[_UIDX]}" "- -"
json=$(cli_main user list --json)
check 'printf "%s" "$json" | python3 -c "import sys, json; d = json.load(sys.stdin); assert [u[\"name\"] for u in d] == [\"admin\", \"dave\"]; assert d[0][\"links\"][0].startswith(\"tg://proxy?server=203.0.113.10&port=443\")"'
check '! cli_main user del dave </dev/null >/dev/null 2>&1'
check 'cli_main user del dave -y >/dev/null 2>&1'
users_load; eq "${#U_NAME[@]}" 1
INIT_SYSTEM=test

t "卸载"
reset_sandbox
INIT_SYSTEM=systemd
write_legacy
migrate_legacy >/dev/null 2>&1
check 'uninstall_all yes >/dev/null 2>&1'
check '[ ! -e "$ETC_DIR" ] && [ ! -e "$OPT_DIR" ] && [ ! -e "$TELEMT_QUOTA_JSON" ]'
check 'ls "$ROOT"/root/mtproxy-backup-*.tar.gz >/dev/null'
INIT_SYSTEM=test

printf '\n  shell 单元测试：%s 通过，%s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
