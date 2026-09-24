
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
