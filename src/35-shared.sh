
# ============================================================
# 两个内核共用：向导输入、端口冲突、TLS 检查、链接与二维码
# ============================================================

step_label() { printf '%s%s%s  %s' "$CD" "$1" "$C0" "$(pad "$2" 8)"; }

# 伪装域名是否支持 TLS 1.3。返回 0 支持，1 不支持，2 无法检测
tls13_check() {
    have openssl || return 2
    openssl s_client -help 2>&1 | grep -q -- '-tls1_3' || return 2
    timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 </dev/null 2>/dev/null | grep -q 'TLSv1\.3'
}

# port_check 端口 用途(mtg|telemt|user) [排除的用户名]：可用返回 0，否则输出原因
port_check() {
    local port="$((10#$1))" owner="$2" skip="${3:-}" p name self=""
    if [ "$owner" != mtg ] && [ -f "$MTG_STATE" ] && [ "$(state_get "$MTG_STATE" PORT)" = "$port" ]; then
        echo "已被 Go 内核使用"; return 1
    fi
    if [ -f "$TELEMT_STATE" ]; then
        if [ "$owner" != telemt ] && [ "$(state_get "$TELEMT_STATE" PORT)" = "$port" ]; then
            if [ "$owner" = user ]; then echo "是 Telemt 的共享端口"; else echo "已被 Telemt 使用"; fi
            return 1
        fi
        if [ -f "$USERS_DB" ]; then
            while IFS=$'\t' read -r name _ p _; do
                [[ -z "$name" || "$name" == \#* ]] && continue
                if [ "$p" = "$port" ] && [ "$name" != "$skip" ]; then
                    echo "已被用户 $name 使用"; return 1
                fi
            done < "$USERS_DB"
        fi
    fi
    case $owner in mtg) self="mtg-go" ;; *) self="telemt" ;; esac
    if port_taken_by_other "$port" "$self"; then
        echo "已被其他程序占用"; return 1
    fi
    return 0
}

# port_suggest 用途：返回第一个可用的常用 HTTPS 端口
port_suggest() {
    local p
    for p in 443 8443 2053 2083 2087 2096 9443; do
        port_check "$p" "$1" >/dev/null && { echo "$p"; return 0; }
    done
    echo 443
}

# wiz_domain 变量 步骤 默认值
wiz_domain() {
    local __d rc
    note "可选：www.apple.com · www.microsoft.com · www.cloudflare.com · www.bing.com"
    ask_valid __d "$(step_label "$2" 伪装域名)" "$3" "" is_domain "域名格式不正确，例如 www.apple.com" || return 1
    __d="${__d,,}"
    spin_run "检查 $__d" tls13_check "$__d"
    rc=$?
    case $rc in
        0) ok "$__d 支持 TLS 1.3" ;;
        2) ;;
        *) warn "未能确认 $__d 支持 TLS 1.3，建议换一个域名" ;;
    esac
    printf -v "$1" '%s' "$__d"
}

# wiz_ip_mode 变量 步骤
wiz_ip_mode() {
    local __m __try
    for __try in 1 2 3; do
        ask __m "$(step_label "$2" 监听模式) 1 IPv4 · 2 IPv6 · 3 双栈" 1
        case $__m in
            1) printf -v "$1" v4; return 0 ;;
            2)
                if [ -z "$PUBLIC_IPV6" ]; then
                    err "未检测到公网 IPv6，无法使用仅 IPv6 模式"
                    continue
                fi
                printf -v "$1" v6; return 0 ;;
            3)
                [ -z "$PUBLIC_IPV6" ] && warn "未检测到公网 IPv6，双栈模式下只有 IPv4 可用"
                printf -v "$1" dual; return 0 ;;
            *) err "请输入 1、2 或 3" ;;
        esac
    done
    return 1
}

# wiz_port 变量 步骤 默认值 用途 [排除的用户名]
wiz_port() {
    local __p __why __try
    for __try in 1 2 3; do
        ask __p "$(step_label "$2" 端口)" "$3"
        if ! is_port "$__p"; then
            err "端口需为 1–65535 的整数"
            continue
        fi
        __p=$((10#$__p))
        if __why=$(port_check "$__p" "$4" "${5:-}"); then
            printf -v "$1" '%s' "$__p"
            return 0
        fi
        err "端口 $__p $__why"
    done
    return 1
}

# ------------------------------------------------------------
# 链接展示
# ------------------------------------------------------------

# show_links 监听模式 端口 FakeTLS密钥(base64)
# 每个地址输出 tg:// 与 t.me 两种链接，并记录到 LAST_LINKS 供二维码使用
show_links() {
    local mode="$1" port="$2" secret="$3" label host found=0
    LAST_LINKS=()
    while read -r label host; do
        [ -z "$host" ] && continue
        found=1
        printf '\n  %s%s%s %s\n' "$CD" "$label" "$C0" "$host"
        printf '  %s\n' "$(link_tg "$host" "$port" "$secret")"
        printf '  %s\n' "$(link_tme "$host" "$port" "$secret")"
        LAST_LINKS+=("$(link_tme "$host" "$port" "$secret")")
    done < <(link_hosts "$mode")
    if [ "$found" = 0 ]; then
        printf '\n'
        warn "未检测到可用的公网地址，可在「端口与域名」中设置链接地址"
        detail "密钥 $secret"
    fi
}

# 为 LAST_LINKS 中的链接显示二维码
show_qr() {
    local link
    if [ ${#LAST_LINKS[@]} -eq 0 ]; then
        warn "没有可显示的链接"
        return 0
    fi
    if ! have qrencode; then
        spin_run "安装二维码工具" ensure_qrencode
        have qrencode || { warn "无法安装 qrencode，请直接复制链接"; return 0; }
    fi
    for link in "${LAST_LINKS[@]}"; do
        printf '\n'
        qrencode -t ANSIUTF8 -m 2 "$link" | sed 's/^/  /'
        detail "${link%%&secret=*}"
    done
}

# links_menu：链接页底部操作
links_menu() {
    local c
    printf '\n'
    ui_rule
    ui_item v "二维码"
    ui_item 0 "返回"
    printf '\n'
    ui_prompt c
    [ "${c,,}" = v ] && { show_qr; pause; }
    return 0
}

# 服务状态文本：● 运行中 / ○ 已停止 / ○ 未安装
svc_status_text() {
    if ! svc_exists "$1"; then
        printf '%s○ 未安装%s' "$CD" "$C0"
    elif svc_active "$1"; then
        printf '%s● 运行中%s' "$CG" "$C0"
    else
        printf '%s○ 已停止%s' "$CR" "$C0"
    fi
}

# 启动失败时输出最近日志（隐藏密钥）
svc_show_failure() {
    detail "最近日志："
    svc_logs "$1" 15 | redact | sed 's/^/    /' | tail -n 15
}
