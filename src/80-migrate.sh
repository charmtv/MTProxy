
# ============================================================
# 从 2.x 版本迁移：/opt/mtproxy/config + /etc/telemt.toml -> /etc/mtproxy
# ============================================================

legacy_mtg_present() {
    [ -f "$LEGACY_CONF_DIR/go.conf" ] && return 0
    [ ! -f "$MTG_STATE" ] && svc_exists mtg && grep -q 'simple-run' "$(svc_file mtg)" 2>/dev/null
}

legacy_telemt_present() { [ -f "$LEGACY_TELEMT_TOML" ]; }

legacy_present() {
    legacy_mtg_present || legacy_telemt_present || [ -f "$LEGACY_RESET_CONF" ] || [ -f "$LEGACY_CONF_DIR/telemt.conf" ]
}

# 旧版域名可能含大写等字符，这里只拒绝会破坏配置文件的内容
_legacy_domain_ok() { [[ "$1" =~ ^[A-Za-z0-9.-]{1,253}$ ]]; }

legacy_mtg_parse() {
    local full="" line L_PORT="" L_SECRET="" L_DOMAIN="" L_IP_MODE="" hex
    MTG_PORT="" MTG_SECRET="" MTG_DOMAIN="" MTG_IP_MODE=""
    if [ -f "$LEGACY_CONF_DIR/go.conf" ]; then
        state_load "$LEGACY_CONF_DIR/go.conf" L
        MTG_PORT="$L_PORT" full="$L_SECRET" MTG_DOMAIN="$L_DOMAIN" MTG_IP_MODE="$L_IP_MODE"
    fi
    if [ -z "$full" ] && svc_exists mtg; then
        line=$(grep -E 'ExecStart=|command_args=' "$(svc_file mtg)" | head -n 1)
        full=$(grep -oE 'ee[0-9a-fA-F]{32,}' <<< "$line" | head -n 1)
        [ -z "$MTG_PORT" ] && MTG_PORT=$(grep -oE ':[0-9]+([ "]|$)' <<< "$line" | tail -n 1 | tr -dc '0-9')
        if [ -z "$MTG_IP_MODE" ]; then
            case $line in
                *only-ipv6*) MTG_IP_MODE="v6" ;;
                *prefer-ipv6*) MTG_IP_MODE="dual" ;;
                *) MTG_IP_MODE="v4" ;;
            esac
        fi
    fi
    [[ "$full" =~ ^[eE][eE]([0-9a-fA-F]{32})([0-9a-fA-F]*)$ ]] || return 1
    MTG_SECRET="${BASH_REMATCH[1],,}"
    hex="${BASH_REMATCH[2]}"
    if [ -z "$MTG_DOMAIN" ] && [ -n "$hex" ]; then
        MTG_DOMAIN=$(printf '%b' "$(sed 's/../\\x&/g' <<< "$hex")")
    fi
    is_ip_mode "$MTG_IP_MODE" || MTG_IP_MODE="v4"
    is_port "$MTG_PORT" && _legacy_domain_ok "$MTG_DOMAIN"
}

legacy_telemt_parse() {
    local section="" line key val v4="" v6="" toml_port="" toml_domain="" n up down
    local T_PORT="" T_DOMAIN="" T_IP_MODE="" T_MAIN_USER=""
    local -A lp=() lq=() le=() lsp=()
    TELEMT_PORT="" TELEMT_DOMAIN="" TELEMT_IP_MODE="" TELEMT_MAIN_USER="" TELEMT_AD_TAG=""
    U_NAME=() U_SECRET=() U_PORT=() U_QUOTA=() U_EXPIRE=() U_UP=() U_DOWN=() U_CREATED=()
    [ -f "$LEGACY_CONF_DIR/telemt.conf" ] && state_load "$LEGACY_CONF_DIR/telemt.conf" T

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[\[?([A-Za-z0-9_.]+)\]\]? ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        [[ "$line" =~ ^\"?([A-Za-z0-9_.-]+)\"?[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
        case $section in
            server) [ "$key" = port ] && toml_port="$val" ;;
            censorship) [ "$key" = tls_domain ] && toml_domain="$val" ;;
            network)
                [ "$key" = ipv4 ] && v4="$val"
                [ "$key" = ipv6 ] && v6="$val" ;;
            general) [ "$key" = ad_tag ] && is_hex32 "$val" && TELEMT_AD_TAG="${val,,}" ;;
            access.users)
                if is_username "$key" && is_hex32 "$val"; then
                    U_NAME+=("$key") U_SECRET+=("${val,,}")
                fi ;;
            access.user_ports) is_port "$val" && lp["$key"]="$((10#$val))" ;;
            access.user_data_quota) [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 )) && lq["$key"]="$val" ;;
            access.user_expirations) iso_to_epoch "$val" && le["$key"]="$val" ;;
            access.user_speed_limits) lsp["$key"]="$val" ;;
        esac
    done < "$LEGACY_TELEMT_TOML"

    [ ${#U_NAME[@]} -gt 0 ] || return 1
    for n in "${U_NAME[@]}"; do
        U_PORT+=("${lp[$n]:--}") U_QUOTA+=("${lq[$n]:--}") U_EXPIRE+=("${le[$n]:--}") U_CREATED+=("-")
        up="-" down="-"
        if [ -n "${lsp[$n]:-}" ]; then
            read -r up down <<< "${lsp[$n]}"
            [ -z "$down" ] && down="$up"
            is_speed "$up" || up="-"
            is_speed "$down" || down="-"
        fi
        U_UP+=("$up") U_DOWN+=("$down")
    done

    TELEMT_PORT="${T_PORT:-$toml_port}"
    TELEMT_DOMAIN="${T_DOMAIN:-$toml_domain}"
    TELEMT_IP_MODE="$T_IP_MODE"
    if ! is_ip_mode "$TELEMT_IP_MODE"; then
        if [ "$v4" = false ]; then TELEMT_IP_MODE="v6"
        elif [ "$v6" = true ]; then TELEMT_IP_MODE="dual"
        else TELEMT_IP_MODE="v4"
        fi
    fi
    TELEMT_MAIN_USER="${T_MAIN_USER:-${U_NAME[0]}}"
    user_find "$TELEMT_MAIN_USER" || TELEMT_MAIN_USER="${U_NAME[0]}"
    is_port "$TELEMT_PORT" && _legacy_domain_ok "$TELEMT_DOMAIN"
}

# 迁移失败时恢复旧服务文件并重启
_legacy_restore_unit() {
    local name="$1" archive="$2" unit
    unit=$(svc_file "$name")
    svc_ctl stop "$name"
    tar -xzf "$archive" -C "${R:-/}" "${unit#"$R"/}" 2>/dev/null
    svc_reload_units
    svc_ctl start "$name"
}

# migrate_legacy [force]
migrate_legacy() {
    local ts archive f files=() failed="" done_parts="" L_MODE="" L_RESET_DAY="" L_ONCE_DATE=""
    legacy_present || return 0
    if [ -f "$MIGRATE_FAILED" ] && [ "${1:-}" != force ]; then
        return 0
    fi
    ensure_dirs
    ts=$(date +%Y%m%d-%H%M%S)
    info "检测到 2.x 版本的配置，正在迁移到 ${ETC_DIR#"$R"}"

    for f in "$LEGACY_CONF_DIR/go.conf" "$LEGACY_CONF_DIR/telemt.conf" "$LEGACY_TELEMT_TOML" \
        "$LEGACY_RESET_CONF" "$LEGACY_RESET_LOG" "$TELEMT_QUOTA_JSON" "$(svc_file mtg)" "$(svc_file telemt)"; do
        [ -f "$f" ] && files+=("${f#"$R"/}")
    done
    archive="$BACKUP_DIR/legacy-$ts.tar.gz"
    if ! tar -czf "$archive" -C "${R:-/}" "${files[@]}" 2>/dev/null; then
        err "备份旧配置失败，已取消迁移"
        return 1
    fi
    chmod 0600 "$archive"

    if legacy_mtg_present; then
        if ! legacy_mtg_parse; then
            failed+=" Go(无法解析旧配置)"
        elif [ ! -x "$BIN_DIR/mtg-go" ]; then
            failed+=" Go(内核文件缺失)"
        else
            mtg_save
            if mtg_apply; then
                rm -f "$LEGACY_CONF_DIR/go.conf"
                done_parts+=" Go"
            else
                rm -f "$MTG_STATE" "$MTG_CONF"
                _legacy_restore_unit mtg "$archive"
                failed+=" Go(启动失败)"
            fi
        fi
    fi

    if legacy_telemt_present; then
        if ! legacy_telemt_parse; then
            failed+=" Telemt(无法解析旧配置)"
        elif [ ! -x "$BIN_DIR/telemt" ]; then
            failed+=" Telemt(内核文件缺失)"
        else
            telemt_save
            users_save
            if telemt_apply; then
                rm -f "$LEGACY_TELEMT_TOML" "$LEGACY_CONF_DIR/telemt.conf"
                done_parts+=" Telemt(${#U_NAME[@]} 个用户)"
            else
                rm -f "$TELEMT_STATE" "$USERS_DB" "$TELEMT_CONF"
                _legacy_restore_unit telemt "$archive"
                failed+=" Telemt(启动失败)"
            fi
        fi
    elif [ -f "$LEGACY_CONF_DIR/telemt.conf" ]; then
        rm -f "$LEGACY_CONF_DIR/telemt.conf"
    fi

    if [ -f "$LEGACY_RESET_CONF" ]; then
        state_load "$LEGACY_RESET_CONF" L
        reset_load
        case $L_MODE in
            monthly) RESET_MODE="monthly"; [[ "$L_RESET_DAY" =~ ^[0-9]+$ ]] && RESET_DAY="$((10#$L_RESET_DAY))" ;;
            once) RESET_MODE="once"; RESET_DATE="$L_ONCE_DATE" ;;
            *) RESET_MODE="disabled" ;;
        esac
        reset_save
        rm -f "$LEGACY_RESET_CONF"
    fi
    if [ -f "$LEGACY_RESET_LOG" ]; then
        cat "$LEGACY_RESET_LOG" >> "$RESET_LOG" 2>/dev/null
        chmod 0600 "$RESET_LOG"
        rm -f "$LEGACY_RESET_LOG"
    fi
    # OpenRC 旧日志含连接密钥且权限为 644，迁移成功后移入新目录
    if [ -z "$failed" ]; then
        for f in mtg telemt; do
            if [ -f "$R/var/log/$f.log" ]; then
                cat "$R/var/log/$f.log" >> "$LOG_DIR/$f.log.old" 2>/dev/null
                chmod 0600 "$LOG_DIR/$f.log.old"
                rm -f "$R/var/log/$f.log"
            fi
        done
    fi
    rmdir "$LEGACY_CONF_DIR" 2>/dev/null

    [ -n "$done_parts" ] && ok "已迁移：${done_parts# }"
    if [ -n "$failed" ]; then
        printf '%s\n' "${failed# }" > "$MIGRATE_FAILED"
        err "未能迁移：${failed# }；服务仍按旧配置运行"
        detail "旧配置备份在 ${archive}，处理后可运行 mtp migrate 重试"
        return 1
    fi
    rm -f "$MIGRATE_FAILED"
    detail "旧配置已备份到 ${archive#"$R"}"
    return 0
}
