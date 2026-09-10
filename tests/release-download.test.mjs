import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const script = await readFile(new URL("../mtp.sh", import.meta.url), "utf8");

test("MTG 从最新 Release 下载对应架构的资源", () => {
  assert.match(script, /TARGET_NAME="mtg-go-\$\{MTG_ARCH\}"/);
  assert.match(
    script,
    /releases\/latest\/download\/\$\{TARGET_NAME\}/,
  );
});

test("Telemt 从最新 Release 下载 linux 架构资源", () => {
  assert.match(script, /TARGET_BIN="telemt-linux-\$\{TELEMT_ARCH\}"/);
  assert.match(
    script,
    /releases\/latest\/download\/\$\{TARGET_BIN\}/,
  );
});

test("脚本不再引用已删除的 Go-Rust 标签", () => {
  assert.doesNotMatch(script, /releases\/download\/Go-Rust\//);
});
