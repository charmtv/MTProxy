import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const script = await readFile(new URL("../mtp.sh", import.meta.url), "utf8");

test("MTG 从最新 Release 下载对应架构的资源", () => {
  assert.match(script, /TARGET_NAME="mtg-go-\$\{MTG_ARCH\}"/);
  assert.match(script, /download_release_binary "\$TARGET_NAME" "\$BIN_DIR\/mtg-go"/);
});

test("Telemt 从最新 Release 下载 linux 架构资源", () => {
  assert.match(script, /TARGET_BIN="telemt-linux-\$\{TELEMT_ARCH\}"/);
  assert.match(script, /download_release_binary "\$TARGET_BIN" "\$BIN_DIR\/telemt"/);
});

test("下载器使用最新 Release 并校验 SHA256", () => {
  assert.match(
    script,
    /https:\/\/github\.com\/\$\{RELEASE_REPO\}\/releases\/latest\/download/,
  );
  assert.match(script, /SHA256SUMS/);
  assert.match(script, /actual_hash=\$\(sha256sum "\$temp_path"/);
  assert.match(script, /"\$actual_hash" != "\$expected_hash"/);
  assert.doesNotMatch(script, /releases\/download\/Go-Rust\//);
});
