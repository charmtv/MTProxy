const REPOSITORY_API_URL = "https://api.github.com/repos/charmtv/MTProxy/contents";

const routes = new Map([
  ["/", "install.sh"],
  ["/install.sh", "install.sh"],
  ["/mtp.sh", "mtp.sh"],
]);

function json(data, status = 200) {
  return Response.json(data, {
    status,
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

export default {
  async fetch(request) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return json({ error: "Method not allowed" }, 405);
    }

    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({ status: "ok", service: "mtproxy-launcher" });
    }

    const filename = routes.get(url.pathname);
    if (!filename) {
      return json({ error: "Not found" }, 404);
    }

    try {
      const upstream = await fetch(`${REPOSITORY_API_URL}/${filename}?ref=main&t=${Date.now()}`, {
        method: request.method,
        headers: {
          accept: "application/vnd.github.raw+json",
          "user-agent": "mtproxy-launcher/2.5",
          "x-github-api-version": "2022-11-28",
        },
        cf: { cacheTtl: 60, cacheEverything: true },
      });

      if (!upstream.ok) {
        return json({ error: "Upstream unavailable" }, 502);
      }

      const headers = new Headers(upstream.headers);
      headers.set("content-type", "text/plain; charset=utf-8");
      headers.set("cache-control", "public, max-age=60");
      headers.set("content-disposition", "inline; filename=\"" + filename + "\"");
      headers.set("x-content-type-options", "nosniff");

      return new Response(upstream.body, { status: 200, headers });
    } catch (error) {
      console.error(JSON.stringify({ event: "upstream_fetch_failed", message: String(error) }));
      return json({ error: "Upstream unavailable" }, 502);
    }
  },
};
