
# ============================================================
# 入口
# ============================================================

# 从本地文件运行时，把脚本安装为 mtp 命令（不会用旧版本覆盖已安装的新版本）
self_install() {
    local src dst installed
    [ -n "$R" ] && return 0
    src=$(readlink -f "$0" 2>/dev/null)
    [ -f "$src" ] || return 0
    dst=$(readlink -f "$MTP_BIN" 2>/dev/null)
    [ "$src" = "$dst" ] && return 0
    if [ -f "$MTP_BIN" ]; then
        [ "$(sha256_of "$src")" = "$(sha256_of "$MTP_BIN")" ] && return 0
        installed=$(sed -n 's/^MTP_VERSION="\([0-9.]*\)"$/\1/p' "$MTP_BIN" | head -n 1)
        [ -n "$installed" ] && ver_gt "$installed" "$MTP_VERSION" && return 0
    fi
    mkdir -p "$(dirname "$MTP_BIN")"
    rm -f "$MTP_BIN"
    install -m 0755 "$src" "$MTP_BIN" 2>/dev/null
}

main() {
    ui_init
    case ${1:-} in
        -h|--help|help) cli_help; return 0 ;;
        -v|--version|version) printf 'mtp v%s\n' "$MTP_VERSION"; return 0 ;;
    esac
    require_root
    umask 077
    detect_os
    SCRIPT_DIR=""
    local self
    self=$(readlink -f "$0" 2>/dev/null)
    [ -f "$self" ] && SCRIPT_DIR=$(dirname "$self")
    ensure_dirs
    if legacy_present; then
        if [ "${1:-}" = check_reset ]; then
            migrate_legacy >/dev/null 2>&1
        else
            migrate_legacy
        fi
    fi
    self_install
    if [ $# -eq 0 ]; then
        [ "$UI_TTY" = 1 ] || { cli_help; return 1; }
        menu_main
    else
        cli_main "$@"
    fi
}

[ "${MTP_SOURCE_ONLY:-0}" = 1 ] || main "$@"
