
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
