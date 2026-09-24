
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
