
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
