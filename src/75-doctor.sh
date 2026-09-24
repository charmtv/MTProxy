
# ============================================================
# 诊断：服务、端口、防火墙、时间、伪装域名、BBR、版本
# ============================================================

DOC_ISSUES=0
DOC_FIXES=()

doc_ok()   { ok "$1"; }
doc_warn() { warn "$1"; DOC_ISSUES=$(( DOC_ISSUES + 1 )); }
doc_fail() { err "$1" 2>&1; DOC_ISSUES=$(( DOC_ISSUES + 1 )); }

# http_date_to_epoch "Date: Wed, 24 Sep 2026 03:40:00 GMT"
http_date_to_epoch() {
    local d mon y t m
    [[ "$1" =~ ([0-9]{1,2})\ ([A-Za-z]{3})\ ([0-9]{4})\ ([0-9]{2}:[0-9]{2}:[0-9]{2}) ]] || return 1
    d="${BASH_REMATCH[1]}"; mon="${BASH_REMATCH[2]}"; y="${BASH_REMATCH[3]}"; t="${BASH_REMATCH[4]}"
    m=$(awk -v s="$mon" 'BEGIN { i = index("JanFebMarAprMayJunJulAugSepOctNovDec", s); print (i ? (i - 1) / 3 + 1 : 0) }')
    (( m >= 1 )) || return 1
    date -u -d "$(printf '%s-%02d-%02d %s' "$y" "$m" "$((10#$d))" "$t")" +%s 2>/dev/null
}

# 本机时间与 HTTPS 响应头中的标准时间之差（秒）
clock_skew() {
    local u line remote
    for u in https://www.cloudflare.com https://www.apple.com https://www.microsoft.com; do
        line=$(curl -sS -o /dev/null -D - --max-time 6 "$u" 2>/dev/null | tr -d '\r' | grep -i '^date:' | head -n 1)
        if remote=$(http_date_to_epoch "$line"); then
            echo $(( $(date +%s) - remote ))
            return 0
        fi
    done
    return 1
}

# 通过公网地址连接自身端口（NAT 机器可能无法回环，结果仅供参考）
self_connect() {
    timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

doctor_ports() {
    local p
    mtg_installed && { mtg_load; echo "$MTG_PORT"; }
    if telemt_installed; then
        telemt_load
        users_load
        echo "$TELEMT_PORT"
        for p in "${U_PORT[@]}"; do [ "$p" != - ] && echo "$p"; done
    fi
}

doctor_run() {
    local backend port ports skew cc d rc remote domains
    DOC_ISSUES=0 DOC_FIXES=()

    ui_section "服务"
    if ! mtg_installed && ! telemt_installed; then
        doc_warn "尚未安装任何内核"
    fi
    if mtg_installed; then
        mtg_load
        if mtg_ready; then doc_ok "Go 运行中，监听 $MTG_PORT"
        elif svc_active mtg; then doc_fail "Go 进程在运行，但没有监听 $MTG_PORT"
        else doc_fail "Go 已停止"
        fi
    fi
    if telemt_installed; then
        telemt_load
        if telemt_ready; then doc_ok "Telemt 运行中，监听 $TELEMT_PORT"
        elif svc_active telemt; then doc_fail "Telemt 进程在运行，但没有监听 $TELEMT_PORT"
        else doc_fail "Telemt 已停止"
        fi
    fi

    ui_section "网络"
    ip_load refresh
    if [ -n "$PUBLIC_IPV4" ]; then doc_ok "公网 IPv4 $PUBLIC_IPV4"; else doc_warn "未检测到公网 IPv4"; fi
    if [ -n "$PUBLIC_IPV6" ]; then doc_ok "公网 IPv6 $PUBLIC_IPV6"; else detail "未检测到公网 IPv6"; fi
    ports=$(doctor_ports | sort -un)
    if [ -n "$ports" ] && [ -n "$PUBLIC_IPV4" ]; then
        for port in $ports; do
            if self_connect "$PUBLIC_IPV4" "$port"; then
                doc_ok "$PUBLIC_IPV4:$port 可以连接"
            else
                doc_warn "$PUBLIC_IPV4:$port 无法从本机连接（NAT 机器可能误报，请同时检查云厂商安全组）"
            fi
        done
    fi
    backend=$(fw_backend)
    if [ "$backend" = none ]; then
        doc_ok "未启用主机防火墙"
    else
        for port in $ports; do
            if fw_port_open "$backend" "$port"; then
                doc_ok "防火墙 $(fw_label "$backend") 已放行 $port/tcp"
            else
                doc_warn "防火墙 $(fw_label "$backend") 未放行 $port/tcp"
                [ "$backend" != nftables ] && DOC_FIXES+=("fw:$backend:$port")
            fi
        done
    fi

    ui_section "时间"
    if skew=$(clock_skew); then
        if (( ${skew#-} <= 2 )); then doc_ok "与标准时间相差 ${skew#-} 秒"
        elif (( ${skew#-} <= 30 )); then doc_warn "与标准时间相差 ${skew#-} 秒，建议开启时间同步"
        else doc_fail "与标准时间相差 ${skew#-} 秒，FakeTLS 可能无法连接，请开启时间同步"
        fi
    else
        detail "无法获取标准时间，已跳过"
    fi

    domains=()
    mtg_installed && domains+=("$MTG_DOMAIN")
    telemt_installed && domains+=("$TELEMT_DOMAIN")
    if [ ${#domains[@]} -gt 0 ]; then
        ui_section "伪装域名"
        for d in $(printf '%s\n' "${domains[@]}" | sort -u); do
            tls13_check "$d"
            rc=$?
            case $rc in
                0) doc_ok "$d 支持 TLS 1.3" ;;
                2) detail "系统 openssl 不支持 TLS 1.3 检测，已跳过 $d" ;;
                *) doc_warn "$d 未通过 TLS 1.3 检测，建议更换伪装域名" ;;
            esac
        done
    fi

    ui_section "系统"
    cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    if [ "$cc" = bbr ]; then
        doc_ok "BBR 已开启"
    elif grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || [ -d /sys/module/tcp_bbr ] || modinfo tcp_bbr >/dev/null 2>&1; then
        doc_warn "BBR 未开启（当前 ${cc:-未知}）"
        DOC_FIXES+=("bbr")
    else
        detail "当前内核不支持 BBR（${cc:-未知}）"
    fi
    remote=$(remote_version)
    if [ -n "$remote" ] && ver_gt "$remote" "$MTP_VERSION"; then
        doc_warn "脚本有新版本 v$remote（当前 v$MTP_VERSION）"
    else
        doc_ok "脚本 v$MTP_VERSION"
    fi
    mtg_installed && detail "Go 内核 $(core_version mtg)"
    telemt_installed && detail "Telemt 内核 $(core_version telemt)"

    printf '\n'
    ui_rule
    if [ "$DOC_ISSUES" -eq 0 ]; then
        ok "一切正常"
    else
        warn "$DOC_ISSUES 项需要留意"
    fi
}

bbr_enable() {
    modprobe tcp_bbr >/dev/null 2>&1
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' | atomic_write "$SYSCTL_BBR_FILE" 0644
    sysctl -p "$SYSCTL_BBR_FILE" >/dev/null 2>&1
    [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" = bbr ]
}

# doctor_fix [yes]：处理可自动修复的项目
doctor_fix() {
    local fix backend port
    for fix in "${DOC_FIXES[@]}"; do
        case $fix in
            fw:*)
                backend="${fix#fw:}"; port="${backend#*:}"; backend="${backend%%:*}"
                if [ "${1:-}" = yes ] || confirm "在 $(fw_label "$backend") 中放行 $port/tcp？" y; then
                    if fw_allow "$backend" "$port"; then ok "已放行 $port/tcp"; else err "放行 $port/tcp 失败"; fi
                fi ;;
            bbr)
                if [ "${1:-}" = yes ] || confirm "开启 BBR？" y; then
                    if bbr_enable; then ok "BBR 已开启"; else err "开启失败，容器或当前内核可能不允许修改"; fi
                fi ;;
        esac
    done
}

doctor_page() {
    ui_page "诊断"
    doctor_run
    if [ ${#DOC_FIXES[@]} -gt 0 ]; then
        printf '\n'
        doctor_fix
    fi
}
