#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_PATH="${MTP_INSTALL_PATH:-/usr/local/bin/mtp}"
PRIMARY_URL="${MTP_SCRIPT_URL:-https://mtproxy.813099.xyz/mtp.sh}"
FALLBACK_URL="${MTP_FALLBACK_URL:-https://raw.githubusercontent.com/charmtv/MTProxy/main/mtp.sh}"
TEMP_FILE="$(mktemp)"

cleanup() {
    rm -f "$TEMP_FILE"
}
trap cleanup EXIT

download() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 10 --retry 2 --retry-delay 1 -sS "$url" -o "$TEMP_FILE"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 "$url" -O "$TEMP_FILE"
    else
        echo "错误：系统未安装 curl 或 wget。" >&2
        return 1
    fi
}

if ! download "$PRIMARY_URL"; then
    echo "主下载地址不可用，正在切换备用地址..." >&2
    : >"$TEMP_FILE"
    download "$FALLBACK_URL"
fi

if [[ ! -s "$TEMP_FILE" ]] || ! bash -n "$TEMP_FILE"; then
    echo "错误：下载的脚本无效。" >&2
    exit 1
fi

mkdir -p "$(dirname "$INSTALL_PATH")"
if ! install -m 0755 "$TEMP_FILE" "$INSTALL_PATH"; then
    echo "错误：无法写入 $INSTALL_PATH，请使用 root 用户运行。" >&2
    exit 1
fi

echo "MTProxy 管理脚本已安装到 $INSTALL_PATH"
if [[ "${MTP_NO_RUN:-0}" != "1" ]]; then
    exec "$INSTALL_PATH" "$@"
fi
