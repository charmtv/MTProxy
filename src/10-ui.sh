
# ============================================================
# 界面组件：一个强调色、灰色辅助信息，只用单宽符号
# ============================================================

UI_W=56
UI_TTY=0
_DW=0

ui_init() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        C0=$'\e[0m' CB=$'\e[1m' CD=$'\e[2m' CA=$'\e[36m' CG=$'\e[32m' CY=$'\e[33m' CR=$'\e[31m'
    else
        C0='' CB='' CD='' CA='' CG='' CY='' CR=''
    fi
    [ -t 0 ] && [ -t 1 ] && UI_TTY=1
    UI_RULE=$(printf '─%.0s' $(seq 1 "$UI_W"))
    [ "$UI_TTY" = 1 ] && trap ui_restore EXIT
}

# 等待动画期间隐藏光标并关闭输入回显，避免按键打乱动画；退出时一定恢复
ui_busy() {
    [ "$UI_TTY" = 1 ] || return 0
    stty -echo 2>/dev/null
    printf '\033[?25l'
}

ui_restore() {
    [ "$UI_TTY" = 1 ] || return 0
    stty echo 2>/dev/null
    printf '\033[?25h'
}

# 终端显示宽度（与语言环境无关）：中日韩字符占 2 列，其余占 1 列。
dwidth() {
    local LC_ALL=C s="${1//$'\e'\[*([0-9;])m/}"
    local cont="${s//[^$'\x80'-$'\xbf']/}"
    local wide="${s//[^$'\xe3'-$'\xef'$'\xf0'-$'\xf4']/}"
    _DW=$(( ${#s} - ${#cont} + ${#wide} ))
}

# pad 文本 宽度：右侧补空格到指定显示宽度
pad() {
    dwidth "$1"
    local gap=$(( $2 - _DW ))
    (( gap < 0 )) && gap=0
    printf '%s%*s' "$1" "$gap" ''
}

# 截断到指定显示宽度（仅用于 ASCII 字段，如用户名）
clip() {
    local s="$1" w="$2"
    if (( ${#s} > w )); then printf '%s…' "${s:0:$((w - 1))}"; else printf '%s' "$s"; fi
}

ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }
err()  { printf '  %s✗%s %s\n' "$CR" "$C0" "$*" >&2; }
info() { printf '  %s›%s %s\n' "$CA" "$C0" "$*"; }
note() { printf '  %s%s%s\n' "$CD" "$*" "$C0"; }
detail() { printf '    %s%s%s\n' "$CD" "$*" "$C0"; }
die()  { err "$*"; exit 1; }

ui_rule() { printf '  %s%s%s\n' "$CD" "$UI_RULE" "$C0"; }
ui_blank() { printf '\n'; }

ui_clear() {
    [ "$UI_TTY" = 1 ] && printf '\033[H\033[2J'
    printf '\n'
}

# ui_header 标题 [右侧说明]
ui_header() {
    local left="$1" right="${2:-}" lw gap
    dwidth "$left"; lw=$_DW
    dwidth "$right"
    gap=$(( UI_W - lw - _DW ))
    (( gap < 2 )) && gap=2
    printf '  %s%s%s%*s%s%s%s\n' "$CB" "$left" "$C0" "$gap" '' "$CD" "$right" "$C0"
}

# ui_page 标题 [右侧说明]：清屏并输出页头
ui_page() {
    ui_clear
    ui_header "$1" "${2:-}"
    ui_rule
}

ui_section() { printf '\n  %s%s%s\n' "$CD" "$1" "$C0"; }

# ui_item 按键 名称 [说明] [按键颜色]
ui_item() {
    local key="$1" label="$2" hint="${3:-}" kc="${4:-$CA}"
    if [ -n "$hint" ]; then
        printf '    %s%s%s  %s%s%s%s\n' "$kc" "$key" "$C0" "$(pad "$label" 30)" "$CD" "$hint" "$C0"
    else
        printf '    %s%s%s  %s\n' "$kc" "$key" "$C0" "$label"
    fi
}

# ui_kv 名称 值
ui_kv() { printf '  %s%s%s%s\n' "$CD" "$(pad "$1" 10)" "$C0" "$2"; }

# ui_bar 百分比 [格数]：输出 ▰▰▰▱▱ 进度条
ui_bar() {
    local pct="$1" cells="${2:-10}" filled i out=''
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    filled=$(( (pct * cells + 50) / 100 ))
    (( pct > 0 && filled == 0 )) && filled=1
    for (( i = 0; i < cells; i++ )); do
        if (( i < filled )); then out+='▰'; else out+='▱'; fi
    done
    printf '%s' "$out"
}

# 读取一行输入；遇到 EOF（Ctrl-D 或输入流结束）直接退出。
_ui_read() {
    local __v
    if ! IFS= read -r -p "$2" __v; then
        printf '\n'
        exit 0
    fi
    __v="${__v//$'\r'/}"
    __v="${__v#"${__v%%[![:space:]]*}"}"
    __v="${__v%"${__v##*[![:space:]]}"}"
    printf -v "$1" '%s' "$__v"
}

# ask 变量名 提示 [默认值] [默认值的显示文字]
ask() {
    local __var="$1" __prompt="$2" __def="${3-}" __show="${4-}" __in
    [ -z "$__show" ] && __show="$__def"
    if [ -n "$__show" ]; then
        _ui_read __in "  $__prompt ${CD}[$__show]${C0} › "
    else
        _ui_read __in "  $__prompt › "
    fi
    printf -v "$__var" '%s' "${__in:-$__def}"
}

# ask_valid 变量名 提示 默认值 显示文字 校验函数 错误提示
# 输入无效时重新询问，最多 3 次；空值（且无默认值）直接接受。
ask_valid() {
    local __var="$1" __prompt="$2" __def="$3" __show="$4" __check="$5" __msg="$6" __val __try
    for __try in 1 2 3; do
        ask __val "$__prompt" "$__def" "$__show"
        if [ -z "$__val" ] || "$__check" "$__val"; then
            printf -v "$__var" '%s' "$__val"
            return 0
        fi
        err "$__msg"
    done
    return 1
}

# confirm 问题 [y|n]
confirm() {
    local q="$1" def="${2:-n}" a hint
    if [ "$def" = y ]; then hint="Y/n"; else hint="y/N"; fi
    _ui_read a "  $q ${CD}[$hint]${C0} › "
    a="${a,,}"
    [ -z "$a" ] && a="$def"
    [[ "$a" == y || "$a" == yes ]]
}

# confirm_word 关键词：危险操作要求手动输入关键词
confirm_word() {
    local a
    _ui_read a "  输入 ${CR}$1${C0} 以确认 › "
    [ "$a" = "$1" ]
}

ui_prompt() { _ui_read "$1" "  ${CA}›${C0} "; }

pause() {
    [ "$UI_TTY" = 1 ] || return 0
    printf '\n  %s按任意键返回%s' "$CD" "$C0"
    IFS= read -r -s -n 1 _ || true
    printf '\n'
}

UI_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# wait_for 描述 超时秒数 命令...：反复执行命令直到成功，期间显示进度
wait_for() {
    local msg="$1" limit="$2" start now n=0
    shift 2
    start=$(date +%s)
    ui_busy
    while :; do
        if "$@"; then
            [ "$UI_TTY" = 1 ] && printf '\r\033[K'
            ui_restore
            return 0
        fi
        now=$(date +%s)
        (( now - start >= limit )) && break
        if [ "$UI_TTY" = 1 ]; then
            printf '\r  %s%s%s %s %s%ss%s' "$CA" "${UI_SPIN[n % 10]}" "$C0" "$msg" "$CD" "$(( now - start ))" "$C0"
        fi
        n=$(( n + 1 ))
        sleep 0.5
    done
    [ "$UI_TTY" = 1 ] && printf '\r\033[K'
    ui_restore
    return 1
}

# spin_run 描述 命令...：后台执行并显示动画，不输出结果（只适合仅产生文件副作用的命令）
spin_run() {
    local msg="$1" rc pid n=0
    shift
    if [ "$UI_TTY" != 1 ]; then
        "$@"
        return
    fi
    ui_busy
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$CA" "${UI_SPIN[n % 10]}" "$C0" "$msg"
        n=$(( n + 1 ))
        sleep 0.1
    done
    wait "$pid"
    rc=$?
    printf '\r\033[K'
    ui_restore
    return "$rc"
}

_to_log() {
    local log="$1"
    shift
    "$@" >"$log" 2>&1
}

# run_step 描述 命令...：同上，完成后显示 ✓ 或 ✗ 与错误输出
run_step() {
    local msg="$1" log rc
    shift
    log=$(mktemp)
    spin_run "$msg" _to_log "$log" "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$msg"
    else
        err "$msg"
        tail -n 8 "$log" | sed "s/^/    /" >&2
    fi
    rm -f "$log"
    return "$rc"
}

# 简单菜单：先 menu_reset，再 menu_add / menu_sep，最后 menu_show 与 menu_read
menu_reset() { MENU_KEYS=(); MENU_LABELS=(); MENU_HINTS=(); MENU_ACTS=(); MENU_COLORS=(); }
menu_add() {
    MENU_KEYS+=("$1"); MENU_LABELS+=("$2"); MENU_HINTS+=("${3:-}"); MENU_ACTS+=("${4:-}"); MENU_COLORS+=("${5:-$CA}")
}
menu_sep() { menu_add "" "$1"; }
menu_show() {
    local i
    for i in "${!MENU_KEYS[@]}"; do
        if [ -z "${MENU_KEYS[$i]}" ]; then
            ui_section "${MENU_LABELS[$i]}"
        else
            ui_item "${MENU_KEYS[$i]}" "${MENU_LABELS[$i]}" "${MENU_HINTS[$i]}" "${MENU_COLORS[$i]}"
        fi
    done
}
# menu_read：读取选择，结果放入 MENU_CHOICE（按键）与 MENU_ACTION（动作）
menu_read() {
    local i
    MENU_ACTION=""
    ui_prompt MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE,,}"
    for i in "${!MENU_KEYS[@]}"; do
        if [ -n "${MENU_KEYS[$i]}" ] && [ "${MENU_KEYS[$i]}" = "$MENU_CHOICE" ]; then
            MENU_ACTION="${MENU_ACTS[$i]}"
            return 0
        fi
    done
    return 1
}
