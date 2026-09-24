
# ============================================================
# Go 内核（mtg）
# ============================================================

mtg_installed() { [ -f "$MTG_STATE" ]; }

mtg_load() {
    MTG_PORT="" MTG_SECRET="" MTG_DOMAIN="" MTG_IP_MODE=""
    state_load "$MTG_STATE" MTG
    is_ip_mode "$MTG_IP_MODE" || MTG_IP_MODE="v4"
}

mtg_save() {
    printf 'PORT=%s\nSECRET=%s\nDOMAIN=%s\nIP_MODE=%s\n' \
        "$MTG_PORT" "$MTG_SECRET" "$MTG_DOMAIN" "$MTG_IP_MODE" | atomic_write "$MTG_STATE" 0600
}

mtg_ready() { svc_active mtg && port_owned_by "$MTG_PORT" mtg-go; }

# mtg_render_config 加固(1|0)：密钥写入配置文件，不再出现在进程参数里
mtg_render_config() {
    local bind pref mode=0600 owner="root:root"
    case $MTG_IP_MODE in
        v6) bind="[::]:$MTG_PORT"; pref="only-ipv6" ;;
        dual) bind="[::]:$MTG_PORT"; pref="prefer-ipv6" ;;
        *) bind="0.0.0.0:$MTG_PORT"; pref="only-ipv4" ;;
    esac
    if [ "$1" = 1 ]; then mode=0640; owner="root:$SVC_USER"; fi
    atomic_write "$MTG_CONF" "$mode" "$owner" <<EOF
# 由 mtp 生成，请通过 mtp 修改
secret = "$(secret_hex "$MTG_SECRET" "$MTG_DOMAIN")"
bind-to = "$bind"
prefer-ip = "$pref"
concurrency = 65535
domain-fronting-port = 443
allow-fallback-on-unknown-dc = true

[network]
doh-ip = "1.1.1.1"

[network.timeout]
tcp = "30s"
http = "30s"
idle = "30s"

[defense.anti-replay]
enabled = true
max-size = "1mib"
EOF
}

# mtg_render_service 加固(1|0)
mtg_render_service() {
    local harden="$1" log="$LOG_DIR/mtg.log"
    if [ "$INIT_SYSTEM" = openrc ]; then
        : >> "$log"
        chmod 0600 "$log"
        [ "$harden" = 1 ] && [ -z "$R" ] && chown "$SVC_USER:$SVC_USER" "$log"
        {
            cat <<EOF
#!/sbin/openrc-run
name="mtg"
description="MTProxy (Go · mtg)"
command="$BIN_DIR/mtg-go"
command_args="run $MTG_CONF"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 65535"
pidfile="/run/mtg.pid"
output_log="$log"
error_log="$log"
EOF
            if [ "$harden" = 1 ]; then
                printf 'command_user="%s:%s"\ncapabilities="^cap_net_bind_service"\n' "$SVC_USER" "$SVC_USER"
            fi
            printf '\ndepend() {\n    need net\n    after firewall\n}\n'
        } | atomic_write "$(svc_file mtg)" 0755
        return
    fi
    {
        cat <<EOF
[Unit]
Description=MTProxy (Go · mtg)
Documentation=https://github.com/$MTP_REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/mtg-go run $MTG_CONF
Restart=always
RestartSec=3
LimitNOFILE=65535
EOF
        if [ "$harden" = 1 ]; then
            cat <<EOF
User=$SVC_USER
Group=$SVC_USER
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
EOF
        fi
        printf '\n[Install]\nWantedBy=multi-user.target\n'
    } | atomic_write "$(svc_file mtg)" 0644
}

_mtg_start() {
    mtg_render_config "$1"
    mtg_render_service "$1"
    svc_enable mtg
    svc_ctl restart mtg
    wait_for "启动 Go 服务" 15 mtg_ready
}

# mtg_apply：写入配置并重启；加固模式失败时自动改用兼容模式
mtg_apply() { with_lock _mtg_apply; }

_mtg_apply() {
    local harden
    harden=$(setting_get HARDEN_MTG 1)
    [ "$harden" = 1 ] && ! ensure_service_user && harden=0
    # 服务账号需要能进入配置目录读取 mtg.toml
    ensure_dirs
    if _mtg_start "$harden"; then
        setting_set "HARDEN_MTG=$harden"
        return 0
    fi
    if [ "$harden" = 1 ]; then
        note "当前环境不支持加固模式，改用兼容模式"
        if _mtg_start 0; then
            setting_set "HARDEN_MTG=0"
            return 0
        fi
    fi
    err "Go 服务启动失败"
    svc_show_failure mtg
    return 1
}

# mtg_commit 描述：应用当前内存中的配置，失败时回滚到修改前
mtg_commit() {
    local existed=0
    [ -f "$MTG_STATE" ] && existed=1
    snap_take "$MTG_STATE" "$MTG_CONF" "$(svc_file mtg)"
    mtg_save
    if mtg_apply; then
        snap_drop
        ok "$1"
        return 0
    fi
    [ "$existed" = 0 ] && svc_remove mtg
    snap_restore
    snap_drop
    if [ "$existed" = 1 ]; then
        svc_reload_units
        svc_ctl restart mtg
        warn "已恢复修改前的配置"
    fi
    return 1
}

mtg_show_info() {
    mtg_installed || { warn "Go 内核未安装"; return 1; }
    mtg_load
    ui_header "Go · mtg" "$(svc_status_text mtg)"
    ui_rule
    ui_kv "端口" "$MTG_PORT"
    ui_kv "伪装域名" "$MTG_DOMAIN"
    ui_kv "监听" "$(ip_mode_label "$MTG_IP_MODE")"
    show_links "$MTG_IP_MODE" "$MTG_PORT" "$(secret_b64 "$MTG_SECRET" "$MTG_DOMAIN")"
}

mtg_install() {
    local domain mode port
    ui_page "安装 Go 内核" "mtg"
    if mtg_installed; then
        mtg_load
        note "已安装 · :$MTG_PORT · $MTG_DOMAIN · $(ip_mode_label "$MTG_IP_MODE")"
        printf '\n'
        menu_reset
        menu_add 1 "更新内核" "保留配置与链接" upgrade
        menu_add 2 "重新安装" "生成新密钥，旧链接失效" fresh
        menu_add 0 "返回" "" back
        menu_show
        printf '\n'
        menu_read || return 0
        case $MENU_ACTION in
            upgrade) printf '\n'; core_upgrade mtg; return ;;
            fresh) printf '\n' ;;
            *) return 0 ;;
        esac
    fi
    require_platform || return 1
    ensure_deps || return 1
    ip_refresh_ui
    printf '\n'
    wiz_domain domain "1/3" "www.apple.com" || return 1
    wiz_ip_mode mode "2/3" || return 1
    wiz_port port "3/3" "$(port_suggest mtg)" mtg || return 1
    printf '\n'
    ui_rule
    ui_kv "即将安装" "Go · $(ip_mode_label "$mode") · :$port · $domain"
    confirm "确认安装？" y || { note "已取消"; return 0; }
    printf '\n'

    core_install mtg || return 1
    MTG_SECRET=$(generate_secret) || return 1
    MTG_PORT="$port" MTG_DOMAIN="$domain" MTG_IP_MODE="$mode"
    ensure_dirs
    mtg_commit "Go 内核已启动，监听 $port" || return 1
    logrotate_install
    fw_offer "$port"
    printf '\n'
    mtg_show_info
}

# mtg_modify 项目(port|domain|mode|secret)
mtg_modify() {
    local v
    mtg_installed || { warn "Go 内核未安装"; return 1; }
    mtg_load
    case $1 in
        port)
            wiz_port v "" "$MTG_PORT" mtg || return 1
            [ "$v" = "$MTG_PORT" ] && { note "端口未变化"; return 0; }
            MTG_PORT="$v"
            mtg_commit "端口已改为 $v，密钥保持不变" || return 1 ;;
        domain)
            wiz_domain v "" "$MTG_DOMAIN" || return 1
            [ "$v" = "$MTG_DOMAIN" ] && { note "域名未变化"; return 0; }
            MTG_DOMAIN="$v"
            mtg_commit "伪装域名已改为 $v，链接已更新" || return 1 ;;
        mode)
            ip_load
            wiz_ip_mode v "" || return 1
            [ "$v" = "$MTG_IP_MODE" ] && { note "监听模式未变化"; return 0; }
            MTG_IP_MODE="$v"
            mtg_commit "监听模式已改为 $(ip_mode_label "$v")" || return 1 ;;
        secret)
            confirm "重置密钥后旧链接立即失效，继续？" n || return 0
            MTG_SECRET=$(generate_secret) || return 1
            mtg_commit "密钥已重置" || return 1 ;;
    esac
    printf '\n'
    mtg_show_info
}

mtg_uninstall() {
    svc_remove mtg
    rm -f "$MTG_STATE" "$MTG_CONF" "$BIN_DIR/mtg-go" "$BIN_DIR/mtg-go.bak" "$LOG_DIR/mtg.log"
    core_state_clear mtg
    ok "Go 内核已删除"
}
