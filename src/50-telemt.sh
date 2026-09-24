
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
