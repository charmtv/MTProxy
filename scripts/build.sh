#!/usr/bin/env bash
# 把 src/*.sh 按文件名顺序合并为单文件 mtp.sh，并生成 mtp.sh.sha256。
# 用法：scripts/build.sh          构建
#       scripts/build.sh --check  检查 mtp.sh 是否与 src/ 一致（CI 使用）

set -euo pipefail

cd "$(dirname "$0")/.."

out="mtp.sh"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

first=1
for f in src/*.sh; do
    if [ "$first" = 1 ]; then
        cat "$f" > "$tmp"
        first=0
    else
        # 模块之间只保留一个空行
        printf '\n' >> "$tmp"
        sed '1{/^$/d}' "$f" >> "$tmp"
    fi
done

bash -n "$tmp"

if [ "${1:-}" = "--check" ]; then
    if ! cmp -s "$tmp" "$out"; then
        echo "mtp.sh 与 src/ 不一致，请运行 scripts/build.sh 并提交结果。" >&2
        exit 1
    fi
    if [ "$(sha256sum "$out" | awk '{print $1}')" != "$(awk '{print $1}' mtp.sh.sha256)" ]; then
        echo "mtp.sh.sha256 已过期，请运行 scripts/build.sh 并提交结果。" >&2
        exit 1
    fi
    echo "mtp.sh 与 src/ 一致"
    exit 0
fi

install -m 0755 "$tmp" "$out"
sha256sum "$out" > "$out.sha256"
echo "已生成 $out ($(wc -l < "$out") 行) 与 $out.sha256"
