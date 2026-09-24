
# ============================================================
# 维护：删除内核、全部卸载、脚本更新、并发锁
# ============================================================

# 修改配置时加锁，避免与定时清零同时写入
lock_acquire() {
    [ -n "${MTP_LOCKED:-}" ] && return 0
    have flock || return 0
    mkdir -p "$STATE_DIR"
    exec 9>"$STATE_DIR/.lock" || return 0
    # BusyBox 的 flock 不支持 -w，用 -n 轮询等待最多 120 秒
    local waited=0
    until flock -n 9 2>/dev/null; do
        if (( waited >= 120 )); then
            exec 9>&-
            err "另一个 mtp 操作正在进行，请稍后再试"
            return 1
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
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
