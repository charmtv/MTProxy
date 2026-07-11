import assert from "node:assert/strict";
import test from "node:test";
import worker from "../worker/index.js";

const originalFetch = globalThis.fetch;

test.afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("根路径返回安装器", async () => {
  globalThis.fetch = async (url) => {
    assert.match(
      String(url),
      /^https:\/\/api\.github\.com\/repos\/charmtv\/MTProxy\/contents\/install\.sh\?ref=main&t=\d+$/,
    );
    return new Response("#!/usr/bin/env bash\n", { status: 200 });
  };

  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/"));
  assert.equal(response.status, 200);
  assert.match(await response.text(), /usr\/bin\/env bash/);
});

test("脚本和健康检查路由可用", async () => {
  globalThis.fetch = async () => new Response("script", { status: 200 });
  const script = await worker.fetch(new Request("https://mtproxy.813099.xyz/mtp.sh"));
  assert.equal(script.status, 200);
  const health = await worker.fetch(new Request("https://mtproxy.813099.xyz/health"));
  assert.deepEqual(await health.json(), { status: "ok", service: "mtproxy-launcher" });
});

test("无效路径和方法返回正确状态码", async () => {
  const missing = await worker.fetch(new Request("https://mtproxy.813099.xyz/unknown"));
  assert.equal(missing.status, 404);
  const invalidMethod = await worker.fetch(
    new Request("https://mtproxy.813099.xyz/", { method: "POST" }),
  );
  assert.equal(invalidMethod.status, 405);
});

test("上游异常返回 502", async () => {
  globalThis.fetch = async () => new Response("not found", { status: 404 });
  const response = await worker.fetch(new Request("https://mtproxy.813099.xyz/"));
  assert.equal(response.status, 502);
});
