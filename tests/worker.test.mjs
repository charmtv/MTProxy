import assert from "node:assert/strict";
import test from "node:test";
import worker from "../worker/index.js";

const originalFetch = globalThis.fetch;

test.afterEach(() => {
  globalThis.fetch = originalFetch;
});

function mockUpstream(files) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const path = String(url).replace("https://raw.githubusercontent.com/charmtv/MTProxy/", "");
    if (path in files) {
      return new Response(files[path], { status: 200 });
    }
    return new Response("404: Not Found", { status: 404 });
  };
  return calls;
}

test("根路径返回安装器，并使用可缓存的固定地址", async () => {
  const calls = mockUpstream({ "stable/install.sh": "#!/usr/bin/env bash\n" });
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/"));
  assert.equal(response.status, 200);
  assert.match(await response.text(), /usr\/bin\/env bash/);
  assert.equal(calls[0].url, "https://raw.githubusercontent.com/charmtv/MTProxy/stable/install.sh");
  assert.deepEqual(calls[0].init.cf, { cacheTtl: 60, cacheEverything: true });
  assert.equal(response.headers.get("x-mtp-ref"), "stable");
});

test("stable 分支不存在时回退到 main", async () => {
  const calls = mockUpstream({ "main/mtp.sh": "script" });
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/mtp.sh"));
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "script");
  assert.deepEqual(
    calls.map((c) => c.url.split("/MTProxy/")[1]),
    ["stable/mtp.sh", "main/mtp.sh"],
  );
  assert.equal(response.headers.get("x-mtp-ref"), "main");
});

test("开发版通道直接读取 main", async () => {
  const calls = mockUpstream({ "main/mtp.sh.sha256": "abc  mtp.sh\n", "stable/mtp.sh.sha256": "old" });
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/mtp.sh.sha256?ch=dev"));
  assert.equal(await response.text(), "abc  mtp.sh\n");
  assert.equal(calls.length, 1);
});

test("可通过环境变量指定稳定版分支或标签", async () => {
  const calls = mockUpstream({ "v3.0.0/mtp.sh": "tagged" });
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/mtp.sh"), { STABLE_REF: "v3.0.0" });
  assert.equal(await response.text(), "tagged");
  assert.equal(calls[0].url.split("/MTProxy/")[1], "v3.0.0/mtp.sh");
});

test("版本接口返回脚本中的版本号", async () => {
  mockUpstream({ "stable/mtp.sh": '#!/bin/bash\nMTP_VERSION="3.1.2"\n' });
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/version"));
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "3.1.2\n");
});

test("健康检查、无效路径和方法", async () => {
  const health = await worker.fetch(new Request("https://mtproxy.813099.xyz/health"));
  assert.deepEqual(await health.json(), { status: "ok", service: "mtproxy-launcher" });
  const missing = await worker.fetch(new Request("https://mtproxy.813099.xyz/unknown"));
  assert.equal(missing.status, 404);
  const invalidMethod = await worker.fetch(new Request("https://mtproxy.813099.xyz/", { method: "POST" }));
  assert.equal(invalidMethod.status, 405);
});

test("上游异常返回 502", async () => {
  globalThis.fetch = async () => new Response("rate limited", { status: 429 });
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/"));
  assert.equal(response.status, 502);
});

test("所有分支都不存在时返回 404", async () => {
  mockUpstream({});
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/mtp.sh"));
  assert.equal(response.status, 404);
});
