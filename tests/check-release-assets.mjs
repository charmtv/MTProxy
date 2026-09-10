import assert from "node:assert/strict";

const baseUrl =
  process.env.MTP_RELEASE_BASE_URL ??
  "https://github.com/0xdabiaoge/MTProxy/releases/latest/download";

const assets = [
  "mtg-go-amd64",
  "mtg-go-arm64",
  "telemt-linux-amd64",
  "telemt-linux-arm64",
  "SHA256SUMS",
];

for (const asset of assets) {
  const url = `${baseUrl}/${asset}`;
  const response = await fetch(url, {
    method: "HEAD",
    redirect: "follow",
    signal: AbortSignal.timeout(30_000),
  });

  assert.equal(response.status, 200, `${asset} returned HTTP ${response.status}`);

  const contentLength = Number(response.headers.get("content-length"));
  assert.ok(contentLength > 0, `${asset} has no content-length`);
  console.log(`${asset}: HTTP 200, ${contentLength} bytes`);
}
