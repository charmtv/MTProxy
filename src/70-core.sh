
# ============================================================
# 内核二进制：下载、SHA-256 校验、版本、更新与回滚
# ============================================================

core_bin() { case $1 in mtg) echo "$BIN_DIR/mtg-go" ;; telemt) echo "$BIN_DIR/telemt" ;; esac; }
core_asset() { case $1 in mtg) echo "mtg-go-$ARCH" ;; telemt) echo "telemt-linux-$ARCH" ;; esac; }
core_label() { case $1 in mtg) echo "Go" ;; telemt) echo "Telemt" ;; esac; }
core_proc() { case $1 in mtg) echo "mtg-go" ;; telemt) echo "telemt" ;; esac; }
core_key() { case $1 in mtg) echo "MTG" ;; telemt) echo "TELEMT" ;; esac; }
core_release_url() { echo "https://github.com/${RELEASE_REPO}/releases/latest/download/$1"; }

core_state_clear() {
    local key
    key=$(core_key "$1")
    [ -f "$CORE_STATE" ] || return 0
    grep -v "^${key}_" "$CORE_STATE" | atomic_write "$CORE_STATE" 0600
}

# 内核版本说明，例如 "V1.0.1 · telemt 3.1.5"
core_version() {
    local key ver bin extra=""
    key=$(core_key "$1")
    ver=$(state_get "$CORE_STATE" "${key}_VER")
    bin=$(core_bin "$1")
    if [ "$1" = telemt ] && [ -x "$bin" ]; then
        extra=$("$bin" --version 2>/dev/null | head -n 1)
    fi
    # 2.x 安装的内核没有记录版本，显示文件摘要以便核对
    [ -z "$ver" ] && [ -f "$bin" ] && ver="sha256 $(sha256_of "$bin" | cut -c1-8)"
    if [ -n "$ver" ] && [ -n "$extra" ]; then printf '%s · %s' "$ver" "$extra"
    else printf '%s' "${ver:-${extra:-未安装}}"
    fi
}

# 在脚本所在目录等位置查找预先放置的内核文件
core_find_local() {
    local asset dir f names
    asset=$(core_asset "$1")
    names=("$asset")
    [ "$1" = telemt ] && names+=("telemt")
    for dir in "$PWD" "${SCRIPT_DIR:-}" "$PWD/bin" "${SCRIPT_DIR:+$SCRIPT_DIR/bin}"; do
        [ -n "$dir" ] || continue
        for f in "${names[@]}"; do
            f="$dir/$f"
            if [ -f "$f" ] && [ "$f" != "$(core_bin "$1")" ]; then
                printf '%s' "$f"
                return 0
            fi
        done
    done
    return 1
}

# core_download 类型 目录：下载内核、SHA256SUMS 与版本信息（在后台执行，只写文件）
core_download() {
    local asset
    asset=$(core_asset "$1")
    http_get "$(core_release_url SHA256SUMS)" "$2/SHA256SUMS" || return 1
    http_get "$(core_release_url BUILD-METADATA.json)" "$2/meta.json" 2>/dev/null || : > "$2/meta.json"
    [ "${3:-}" = sums-only ] && return 0
    http_get "$(core_release_url "$asset")" "$2/$asset"
}

core_expected_sha() { awk -v n="$(core_asset "$1")" '$2 == n { print $1; exit }' "$2/SHA256SUMS"; }
core_meta_version() { grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$1/meta.json" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/'; }

# core_put 类型 源文件 版本：备份旧文件后原子替换
core_put() {
    local bin tmp key
    bin=$(core_bin "$1")
    key=$(core_key "$1")
    mkdir -p "$BIN_DIR"
    [ -f "$bin" ] && cp -p "$bin" "$bin.bak"
    tmp="$bin.new.$$"
    cp "$2" "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$bin" || { rm -f "$tmp"; return 1; }
    state_set "$CORE_STATE" "${key}_SHA=$(sha256_of "$bin")" "${key}_VER=${3:-}" "${key}_TIME=$(date +%Y-%m-%d)"
}

# core_install 类型：安装内核（优先使用本地文件）
core_install() {
    local kind="$1" label asset local_file dir expected actual ver
    label=$(core_label "$kind")
    asset=$(core_asset "$kind")
    if local_file=$(core_find_local "$kind"); then
        core_put "$kind" "$local_file" "本地文件" || { err "安装本地内核失败"; return 1; }
        ok "已使用本地文件 $(basename "$local_file")"
        return 0
    fi
    dir=$(mktemp -d)
    if ! run_step "下载 $label 内核 $asset" core_download "$kind" "$dir"; then
        rm -rf "$dir"
        err "下载失败，请检查网络或 GitHub 访问"
        return 1
    fi
    expected=$(core_expected_sha "$kind" "$dir")
    actual=$(sha256_of "$dir/$asset")
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        rm -rf "$dir"
        err "SHA-256 校验失败，已拒绝安装"
        return 1
    fi
    ver=$(core_meta_version "$dir")
    core_put "$kind" "$dir/$asset" "$ver" || { rm -rf "$dir"; err "写入内核文件失败"; return 1; }
    rm -rf "$dir"
    ok "SHA-256 校验通过${ver:+ · $ver}"
}

# core_upgrade 类型：检查并更新内核，保留配置；失败时回滚到旧版本
core_upgrade() {
    local kind="$1" label bin dir expected current ver asset
    label=$(core_label "$kind")
    bin=$(core_bin "$kind")
    asset=$(core_asset "$kind")
    [ -x "$bin" ] || { warn "$label 内核未安装"; return 1; }
    [ -n "$ARCH" ] || { err "不支持的架构"; return 1; }
    dir=$(mktemp -d)
    if ! run_step "检查 $label 内核版本" core_download "$kind" "$dir" sums-only; then
        rm -rf "$dir"
        detail "无法访问 GitHub Release，请检查网络后重试"
        return 1
    fi
    expected=$(core_expected_sha "$kind" "$dir")
    current=$(sha256_of "$bin")
    ver=$(core_meta_version "$dir")
    if [ -n "$expected" ] && [ "$expected" = "$current" ]; then
        rm -rf "$dir"
        [ -n "$ver" ] && state_set "$CORE_STATE" "$(core_key "$kind")_VER=$ver"
        ok "$label 内核已是最新${ver:+ · $ver}"
        return 0
    fi
    if ! run_step "下载 $label 内核 $asset" http_get "$(core_release_url "$asset")" "$dir/$asset"; then
        rm -rf "$dir"
        return 1
    fi
    if [ -z "$expected" ] || [ "$(sha256_of "$dir/$asset")" != "$expected" ]; then
        rm -rf "$dir"
        err "SHA-256 校验失败，已拒绝更新"
        return 1
    fi
    core_put "$kind" "$dir/$asset" "$ver" || { rm -rf "$dir"; err "写入内核文件失败"; return 1; }
    rm -rf "$dir"
    if core_restart_check "$kind"; then
        ok "$label 内核已更新${ver:+到 $ver}，配置与链接不变"
        return 0
    fi
    err "新内核启动失败，正在回滚"
    mv -f "$bin.bak" "$bin"
    core_restart_check "$kind" && warn "已回滚到旧版本"
    return 1
}

core_restart_check() {
    case $1 in
        mtg)
            mtg_installed || return 0
            mtg_load
            svc_ctl restart mtg
            wait_for "重启 Go 服务" 15 mtg_ready ;;
        telemt)
            telemt_installed || return 0
            telemt_load
            svc_ctl restart telemt
            wait_for "重启 Telemt 服务" 45 telemt_ready ;;
    esac
}

core_upgrade_page() {
    local any=0
    ui_page "更新内核" "保留配置与链接"
    if mtg_installed; then any=1; core_upgrade mtg; fi
    if telemt_installed; then any=1; core_upgrade telemt; fi
    [ "$any" = 0 ] && warn "尚未安装任何内核"
    return 0
}
