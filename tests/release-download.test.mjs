import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const script = await readFile(new URL("../mtp.sh", import.meta.url), "utf8");
const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));

test("内核文件名与 Release 资源一致", () => {
  assert.match(script, /mtg\) echo "mtg-go-\$ARCH"/);
  assert.match(script, /telemt\) echo "telemt-linux-\$ARCH"/);
});

test("下载器使用最新 Release 并校验 SHA-256", () => {
  assert.match(script, /https:\/\/github\.com\/\$\{RELEASE_REPO\}\/releases\/latest\/download/);
  assert.match(script, /core_release_url SHA256SUMS/);
  assert.match(script, /\[ "\$expected" != "\$actual" \]/);
  assert.doesNotMatch(script, /releases\/download\/Go-Rust\//);
});

test("mtg 密钥写入配置文件，不出现在进程参数中", () => {
  assert.match(script, /ExecStart=\$BIN_DIR\/mtg-go run \$MTG_CONF/);
  assert.doesNotMatch(script, /simple-run -n/);
});

test("脚本版本与 package.json 一致", () => {
  const match = script.match(/^MTP_VERSION="([0-9.]+)"$/m);
  assert.ok(match, "mtp.sh 中缺少 MTP_VERSION");
  assert.equal(match[1], pkg.version);
});

test("旧版定时任务命令保持兼容", () => {
  assert.match(script, /CRON_LINE="0 0 \* \* \* \/usr\/local\/bin\/mtp check_reset/);
  assert.match(script, /check_reset\) reset_check ;;/);
});
