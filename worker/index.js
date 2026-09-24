const RAW_BASE = "https://raw.githubusercontent.com/charmtv/MTProxy";
const CACHE_TTL = 60;

const routes = new Map([
  ["/", "install.sh"],
  ["/install.sh", "install.sh"],
  ["/mtp.sh", "mtp.sh"],
  ["/mtp.sh.sha256", "mtp.sh.sha256"],
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

// 稳定版优先读取 stable 分支（由打 tag 的工作流更新），不存在时回退到 main。
function refsFor(url, env) {
  if (url.searchParams.get("ch") === "dev") {
    return ["main"];
  }
  return [env?.STABLE_REF || "stable", "main"];
}

// 固定的上游地址让 Cloudflare 边缘缓存真正生效，避免每次安装都回源。
async function fetchFirst(refs, filename, method) {
  for (const ref of refs) {
    const upstream = await fetch(`${RAW_BASE}/${ref}/${filename}`, {
      method,
      headers: { "user-agent": "mtproxy-launcher/3" },
      cf: { cacheTtl: CACHE_TTL, cacheEverything: true },
    });
    if (upstream.ok) {
      return { upstream, ref };
    }
    if (upstream.status !== 404) {
      throw new Error(`upstream ${ref}/${filename} returned ${upstream.status}`);
    }
  }
  return null;
}

function textHeaders(extra = {}) {
  return {
    "content-type": "text/plain; charset=utf-8",
    "cache-control": `public, max-age=${CACHE_TTL}`,
    "x-content-type-options": "nosniff",
    ...extra,
  };
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return json({ error: "Method not allowed" }, 405);
    }

    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json({ status: "ok", service: "mtproxy-launcher" });
    }

    try {
      const refs = refsFor(url, env);

      if (url.pathname === "/version") {
        const found = await fetchFirst(refs, "mtp.sh", "GET");
        const match = found && (await found.upstream.text()).match(/^MTP_VERSION="([0-9.]+)"$/m);
        if (!match) {
          return json({ error: "Version unavailable" }, 502);
        }
        return new Response(request.method === "HEAD" ? null : `${match[1]}\n`, {
          headers: textHeaders({ "x-mtp-ref": found.ref }),
        });
      }

      const filename = routes.get(url.pathname);
      if (!filename) {
        return json({ error: "Not found" }, 404);
      }

      const found = await fetchFirst(refs, filename, request.method);
      if (!found) {
        return json({ error: "Not found" }, 404);
      }
      return new Response(found.upstream.body, {
        status: 200,
        headers: textHeaders({
          "content-disposition": `inline; filename="${filename}"`,
          "x-mtp-ref": found.ref,
        }),
      });
    } catch (error) {
      console.error(JSON.stringify({ event: "upstream_fetch_failed", message: String(error) }));
      return json({ error: "Upstream unavailable" }, 502);
    }
  },
};
