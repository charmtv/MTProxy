#!/usr/bin/env bash
# 集成测试：用真实的 mtg / Telemt 二进制验证脚本生成的配置能够启动并监听。
# 用法：bash tests/shell/cores.sh [内核目录]
#       未指定目录时从最新 Release 下载（需要网络）。

# shellcheck disable=SC2016,SC2034,SC2153,SC2209
set -u
cd "$(dirname "$0")/../.." || exit 1

ROOT=$(mktemp -d)
PIDS=()
# shellcheck disable=SC2329
cleanup() {
    local p
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    rm -rf "$ROOT"
}
trap cleanup EXIT

export MTP_ROOT="$ROOT" MTP_SOURCE_ONLY=1 MTP_INIT=test NO_COLOR=1
# shellcheck source=/dev/null
source ./mtp.sh
ui_init
detect_os
[ -n "$ARCH" ] || { echo "不支持的架构，跳过"; exit 0; }
ensure_dirs

CORE_DIR="${1:-}"
if [ -z "$CORE_DIR" ]; then
    CORE_DIR="$ROOT/cores"
    mkdir -p "$CORE_DIR"
    for k in mtg telemt; do
        core_download "$k" "$CORE_DIR" || { echo "下载 $k 失败"; exit 1; }
        [ "$(core_expected_sha "$k" "$CORE_DIR")" = "$(sha256_of "$CORE_DIR/$(core_asset "$k")")" ] || { echo "$k 校验失败"; exit 1; }
    done
fi
cp "$CORE_DIR/$(core_asset mtg)" "$BIN_DIR/mtg-go"
cp "$CORE_DIR/$(core_asset telemt)" "$BIN_DIR/telemt"
chmod +x "$BIN_DIR/mtg-go" "$BIN_DIR/telemt"

fail=0
wait_port() {
    local _
    for _ in $(seq 1 "$2"); do
        port_is_listening "$1" && return 0
        sleep 1
    done
    return 1
}

# ---- mtg ----
MTG_PORT=18443 MTG_SECRET=0123456789abcdef0123456789abcdef MTG_DOMAIN=www.apple.com MTG_IP_MODE=v4
mtg_render_config 0
"$BIN_DIR/mtg-go" run "$MTG_CONF" > "$ROOT/mtg.log" 2>&1 &
PIDS+=($!)
if wait_port 18443 10 && port_owned_by 18443 mtg-go; then
    echo "  ✓ mtg 使用生成的配置启动并监听 18443"
else
    echo "  ✗ mtg 未能启动"; tail -n 20 "$ROOT/mtg.log"; fail=1
fi

# ---- Telemt ----
TELEMT_PORT=18444 TELEMT_DOMAIN=www.apple.com TELEMT_IP_MODE=v4 TELEMT_MAIN_USER=admin TELEMT_AD_TAG=""
U_NAME=(admin bob) U_SECRET=(0123456789abcdef0123456789abcdef 00112233445566778899aabbccddeeff)
U_PORT=(- 18445) U_QUOTA=(- 1073741824) U_UP=(- 1.5) U_DOWN=(- -) U_CREATED=(- -)
parse_expire +30d && U_EXPIRE=(- "$_EXPIRE")
telemt_render_config
(cd "$TELEMT_WORKDIR" && exec "$BIN_DIR/telemt" "$TELEMT_CONF") > "$ROOT/telemt.log" 2>&1 &
PIDS+=($!)
if wait_port 18444 60 && wait_port 18445 5 && port_owned_by 18444 telemt; then
    echo "  ✓ Telemt 使用生成的配置启动并监听 18444 与专属端口 18445"
else
    echo "  ✗ Telemt 未能启动"; sed 's/\x1b\[[0-9;]*m//g' "$ROOT/telemt.log" | tail -n 20; fail=1
fi

exit "$fail"
