
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
