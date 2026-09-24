
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
