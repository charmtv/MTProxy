#!/usr/bin/env bash
# MTProxy 管理脚本安装器
#   bash <(curl -fsSL https://mtproxy.813099.xyz)
# 环境变量：
#   MTP_CHANNEL=dev      安装开发版
#   MTP_NO_RUN=1         安装后不打开菜单
#   MTP_INSTALL_PATH     安装位置，默认 /usr/local/bin/mtp

set -Eeuo pipefail

INSTALL_PATH="${MTP_INSTALL_PATH:-/usr/local/bin/mtp}"
SITE_URL="${MTP_SITE_URL:-https://mtproxy.813099.xyz}"
RAW_BASE="https://raw.githubusercontent.com/charmtv/MTProxy"
QUERY=""
if [[ "${MTP_CHANNEL:-stable}" == "dev" ]]; then
    QUERY="?ch=dev"
    SOURCES=("$SITE_URL/mtp.sh" "$RAW_BASE/main/mtp.sh")
else
    SOURCES=("$SITE_URL/mtp.sh" "$RAW_BASE/stable/mtp.sh" "$RAW_BASE/main/mtp.sh")
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C0=$'\e[0m' CD=$'\e[2m' CG=$'\e[32m' CR=$'\e[31m'
else
    C0='' CD='' CG='' CR=''
fi
ok() { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
fail() { printf '  %s✗%s %s\n' "$CR" "$C0" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "请使用 root 用户运行"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 "$1" -O "$2"
    else
        fail "系统缺少 curl 或 wget"
    fi
}

sha256() { sha256sum "$1" | awk '{ print $1 }'; }

printf '\n'
installed=""
for url in "${SOURCES[@]}"; do
    if [[ "$url" == "$SITE_URL/"* ]]; then
        src="$url$QUERY" sum="$url.sha256$QUERY"
    else
        src="$url" sum="$url.sha256"
    fi
    rm -f "$WORK/mtp.sh" "$WORK/sum"
    fetch "$src" "$WORK/mtp.sh" 2>/dev/null || continue
    [[ -s "$WORK/mtp.sh" ]] || continue
    bash -n "$WORK/mtp.sh" 2>/dev/null || continue
    grep -q '^MTP_VERSION="[0-9.]*"$' "$WORK/mtp.sh" || continue
    if fetch "$sum" "$WORK/sum" 2>/dev/null; then
        expected="$(awk '{ print $1; exit }' "$WORK/sum")"
        if [[ "$expected" =~ ^[0-9a-f]{64}$ && "$expected" != "$(sha256 "$WORK/mtp.sh")" ]]; then
            continue
        fi
        ok "SHA-256 校验通过"
    fi
    installed="$src"
    break
done
[[ -n "$installed" ]] || fail "下载管理脚本失败，请检查网络后重试"

mkdir -p "$(dirname "$INSTALL_PATH")"
install -m 0755 "$WORK/mtp.sh" "$INSTALL_PATH" || fail "无法写入 $INSTALL_PATH"
version="$(sed -n 's/^MTP_VERSION="\([0-9.]*\)"$/\1/p' "$INSTALL_PATH" | head -n 1)"
ok "已安装 mtp ${version:+v$version} 到 $INSTALL_PATH"
printf '  %s之后输入 mtp 即可打开管理菜单%s\n\n' "$CD" "$C0"

# 只有在交互终端中才自动打开菜单
if [[ "${MTP_NO_RUN:-0}" != "1" && -t 0 && -t 1 ]]; then
    exec "$INSTALL_PATH" "$@"
fi
