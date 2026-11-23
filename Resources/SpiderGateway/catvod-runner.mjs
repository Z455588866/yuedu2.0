import { createRequire } from "node:module";
import { writeSync } from "node:fs";
import http from "node:http";
import { readFile } from "node:fs/promises";
import readline from "node:readline";
import { pathToFileURL } from "node:url";
import { readBoundedText } from "./bounded-response.mjs";
import { startParentWatchdog } from "./process-lifecycle.mjs";

export function actionRequest(site, action, args) {
  // A malformed catalog entry can carry a non-string api; never let `.replace`
  // throw an opaque "r.replace is not a function" deep inside the runner.
  const rawAPI = typeof site.api === "string" ? site.api : "";
  if (!rawAPI) throw new Error("站点接口无效（配置站点不支持浏览）");
  const base = rawAPI.replace(/\/$/, "");
  switch (action) {
    case "home": return { path: `${base}/home`, payload: { filter: args.filter } };
    case "category": return { path: `${base}/category`, payload: { id: args.tid, page: args.page, filter: args.filter, filters: args.extend } };
    case "detail": return { path: `${base}/detail`, payload: { id: args.ids } };
    case "search": return { path: `${base}/search`, payload: { wd: args.keyword, quick: args.quick, page: args.page } };
    case "player": return { path: `${base}/play`, payload: { flag: args.flag, id: args.id, flags: args.vipFlags } };
    default: throw new Error(`Unsupported action: ${action}`);
  }
}

export function normalizePlayerResult(result, episodeID) {
  const currentURL = Array.isArray(result?.url) ? result.url.find(Boolean) : result?.url;
  if (currentURL) return result;
  try {
    const directURL = new URL(episodeID);
    if (!["http:", "https:"].includes(directURL.protocol)) return result;
    return { ...result, parse: 0, jx: 0, url: episodeID };
  } catch {
    return result;
  }
}

function htmlAttribute(value) {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&#39;", "'")
    .replaceAll("&quot;", '"')
    .replaceAll("\\/", "/");
}

const MEDIA_PATH = /\.(?:m3u8|mp4|mkv|avi|mov|flv|ts|m4v|mp3|m4a)(?:$|\?)/i;

function httpURL(value, base) {
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const url = base ? new URL(value, base) : new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

/// Ported from tvbox-silicon's WebPlayback.embeddedMedia: MacCMS pages embed
/// `player_aaaa = {"url": ..., "encrypt": 0|1|2}`, other players write the stream
/// inline as an escaped m3u8/mp4. Pure HTTP + regex — no web view required.
function embeddedMedia(html, base) {
  const player = html.match(/player_[A-Za-z0-9_]*\s*=\s*(\{.*?\})\s*[;<]/s);
  if (player) {
    try {
      const object = JSON.parse(player[1]);
      let address = object.url;
      if (typeof address === "string" && address.trim()) {
        const encrypt = Number(object.encrypt ?? 0);
        if (encrypt === 1) address = decodeURIComponent(address);
        else if (encrypt === 2) {
          const decoded = Buffer.from(address, "base64").toString("utf8");
          address = decodeURIComponent(decoded);
        }
        const resolved = httpURL(htmlAttribute(address), base);
        if (resolved && MEDIA_PATH.test(new URL(resolved).pathname + new URL(resolved).search)) return resolved;
      }
    } catch { /* fall through to inline match */ }
  }
  const inline = html.match(/https?:(?:\\?\/){2}[^"'\s<>()]+?\.(?:m3u8|mp4)(?:\?[^"'\s<>()]*)?/i);
  const resolved = inline ? httpURL(htmlAttribute(inline[0]), base) : null;
  return resolved;
}

/// A `json:`/`parse:` URL names an external parse service. TVBox's JSON contract
/// is GET service(+page) answering {"url": ...} (sometimes under `data`).
async function askParseService(value, episodeID, fetchValue) {
  const service = value.replace(/^(?:json|parse):/i, "").trim();
  const page = httpURL(episodeID);
  let target;
  try { target = new URL(service, page || undefined); } catch { return null; }
  if (page && !target.searchParams.has("url") && !target.searchParams.has("v")) {
    target.searchParams.set("url", page);
  }
  try {
    const response = await fetchValue(target, {
      headers: { "user-agent": "Mozilla/5.0", accept: "application/json, text/plain, */*" },
      redirect: "follow",
      signal: AbortSignal.timeout(10_000)
    });
    if (!response.ok) { try { await response.body?.cancel(); } catch {} return null; }
    const text = await readBoundedText(response);
    let object;
    try { object = JSON.parse(text); } catch {
      const inline = text.match(/https?:\/\/[^"'\s]+\.(?:m3u8|mp4)/i);
      return inline ? inline[0] : null;
    }
    const payload = object?.data && typeof object.data === "object" ? object.data : object;
    const address = payload?.url || payload?.link || payload?.playurl;
    const resolved = httpURL(address, target.href);
    if (resolved && resolved !== page) return resolved;
  } catch { /* unreachable service: fall back to page sniffing */ }
  return null;
}

const SNIFF_HEADERS = {
  "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
};

/// Follow at most one iframe level, the pattern xb6v and many MacCMS sites use.
async function sniffPage(pageURL, headers, fetchValue) {
  const response = await fetchValue(pageURL, {
    headers: { ...SNIFF_HEADERS, ...(headers || {}) },
    redirect: "follow",
    signal: AbortSignal.timeout(12_000)
  });
  if (!response.ok) { try { await response.body?.cancel(); } catch {} return null; }
  const page = await readBoundedText(response);
  const direct = embeddedMedia(page, pageURL);
  if (direct) return direct;

  const frame = page.match(/<iframe\b[^>]*\bsrc=["']([^"']+)["']/i);
  if (!frame) return null;
  const frameURL = httpURL(htmlAttribute(frame[1]), pageURL);
  if (!frameURL) return null;
  const frameResponse = await fetchValue(frameURL, {
    headers: { ...SNIFF_HEADERS, referer: pageURL, ...(headers || {}) },
    redirect: "follow",
    signal: AbortSignal.timeout(12_000)
  });
  if (!frameResponse.ok) { try { await frameResponse.body?.cancel(); } catch {} return null; }
  const frameHTML = await readBoundedText(frameResponse);
  const inFrame = embeddedMedia(frameHTML, frameURL);
  if (inFrame) return inFrame;
  const declared = frameHTML.match(/\b(?:const|var|let)\s+(?:url|playurl|videoUrl)\s*=\s*(["'])(.*?)\1\s*;/s);
  return declared ? httpURL(htmlAttribute(declared[2]), frameURL) : null;
}

/// Resolve `parse=1`/`jx=1` and `json:`/`parse:` lines to a direct stream on the
/// HTTP fast path. Returns the original result unchanged when nothing resolves,
/// so the app can fall back to its headless WebView sniffer for JS-driven pages.
export async function resolvePlayerResult(site, result, episodeID, fetchValue = fetch) {
  const normalized = normalizePlayerResult(result, episodeID);
  const parse = Number(normalized?.parse ?? 0);
  const jx = Number(normalized?.jx ?? 0);
  const rawURL = Array.isArray(normalized?.url) ? normalized.url.find(Boolean) : normalized?.url;
  const headers = normalized?.header && typeof normalized.header === "object" ? normalized.header : {};

  if (typeof rawURL === "string" && /^(?:json|parse):/i.test(rawURL)) {
    const resolved = await askParseService(rawURL, episodeID, fetchValue);
    if (resolved) return { ...normalized, parse: 0, jx: 0, url: resolved };
    return normalized;
  }
  if (parse === 0 && jx === 0) return normalized;

  // The play page is the returned url when it is HTTP; otherwise the episode id.
  const page = httpURL(rawURL) || httpURL(episodeID);
  if (!page) return normalized;
  try {
    const resolved = await sniffPage(page, headers, fetchValue);
    if (resolved) return { ...normalized, parse: 0, jx: 0, url: resolved };
  } catch { /* keep the flagged result for the WebView fallback */ }
  return normalized;
}

// A route can hold mutable parser state shared by its category/detail handlers.
// Keep requests to that route ordered while allowing different sites to overlap.
export function createSiteRequestQueue() {
  const tails = new Map();
  return function enqueue(siteAPI, operation) {
    const previous = tails.get(siteAPI) || Promise.resolve();
    const result = previous.then(operation);
    const tail = result.then(() => {}, () => {});
    tails.set(siteAPI, tail);
    tail.then(() => {
      if (tails.get(siteAPI) === tail) tails.delete(siteAPI);
    });
    return result;
  };
}

export async function runCatVod(bundlePath, options = {}) {
  if (!bundlePath) throw new Error("Bundle path is required");
  // fd 3 is a dedicated control channel. Third-party bundles may write logs to
  // stdout even after console is replaced, so stdout cannot carry protocol data.
  const writeLine = options.writeLine || ((value) => writeSync(3, value));
  const log = (...values) => process.stderr.write(`${values.map(String).join(" ").slice(0, 2048)}\n`);
  console.log = log;
  console.info = log;
  console.warn = log;
  console.error = log;
  globalThis.catDartServerPort = () => 0;

  // Mature loader (proven in tvbox-silicon): require the bundle and call its
  // exported start(). The bundle builds its HTTP app on the server returned by
  // catServerFactory, which we bind to an ephemeral 127.0.0.1 port and drive
  // with real loopback requests. Source is never patched, so this works with any
  // packaging (Fastify/CatPaw/websiteBundle and future variants) — the old
  // regex-based patch only matched one specific minified shape and failed on
  // every real-world bundle.
  let loopbackServer;
  globalThis.catServerFactory = (handler) => {
    // Every request that reaches the bundle's own server counts as activity:
    // providers answer `player` with a URL on this very server (their
    // `m3u8-proxy` route), so the player keeps fetching segments long after the
    // last gateway call. Without this the session is dropped as idle mid-play
    // and the stream dies.
    const served = (request, response) => {
      try { options.onActivity?.(); } catch { /* activity must never fail a request */ }
      handler(request, response);
    };
    loopbackServer = http.createServer(served);
    const originalListen = loopbackServer.listen.bind(loopbackServer);
    loopbackServer.listen = (...args) =>
      originalListen(0, "127.0.0.1", args.find((arg) => typeof arg === "function"));
    return loopbackServer;
  };

  const baseRequire = createRequire(pathToFileURL(bundlePath));
  const localRequire = options.wrapRequire ? options.wrapRequire(baseRequire) : baseRequire;
  // Execute the bundle as-is (no source patching — real bundles use many
  // packaging styles and the old regex approach only matched one). The bundle
  // exports {start, stop}; we take start from module.exports (or a bundle that
  // assigns globalThis.__catvodExports itself).
  const source = await readFile(bundlePath, "utf8");
  const bundleModule = { exports: {} };
  const factory = new Function(
    "require", "module", "exports", "__filename", "__dirname", source
  );
  factory(localRequire, bundleModule, bundleModule.exports, bundlePath,
          bundlePath.replace(/\/[^/]+$/, ""));
  globalThis.__catvodExports = bundleModule.exports;
  const startBundle = bundleModule.exports?.start ?? globalThis.__catvodExports?.start;
  if (typeof startBundle !== "function") throw new Error("CatVod start export is unavailable");
  // Account credentials remain in the trusted Gateway parent process. Remote
  // CatVod bundles receive only an empty compatibility configuration.
  await startBundle({
    biliCookie: "",
    pans: { list: [] },
    cms: { list: [] },
    sites: { list: [] }
  });
  const listenDeadline = Date.now() + 20_000;
  while (!loopbackServer?.listening) {
    if (Date.now() > listenDeadline) throw new Error("CatVod server did not start listening");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  const port = loopbackServer.address().port;
  const initialized = new Map();

  function injectOnce(method, route, payload) {
    return new Promise((resolve, reject) => {
      const body = payload === undefined ? undefined : JSON.stringify(payload);
      const req = http.request({
        host: "127.0.0.1",
        port,
        path: route,
        method: method.toUpperCase(),
        headers: body === undefined
          ? {}
          : { "content-type": "application/json", "content-length": Buffer.byteLength(body) }
      }, (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let value;
          if (!text || text.trim() === "") value = {};
          else {
            try { value = JSON.parse(text); }
            catch { return reject(new Error(`CatVod returned invalid JSON for ${route}`)); }
          }
          if (settled) return;
          if (res.statusCode >= 400) {
            const error = new Error(value?.message || `CatVod returned HTTP ${res.statusCode}`);
            error.status = res.statusCode;
            settled = true;
            return reject(error);
          }
          settled = true;
          resolve(value);
        });
      });
      let settled = false;
      const fail = (error) => { if (!settled) { settled = true; reject(error); } };
      req.on("error", fail);
      // A bundle whose loopback route never answers must not leave this promise
      // pending forever: that would wedge the per-site queue and show an
      // permanent spinner. Bound every inject with a hard timeout.
      const timeoutMs = Number(options.injectTimeoutMs) > 0 ? Number(options.injectTimeoutMs) : 20000;
      req.setTimeout(timeoutMs, () => {
        fail(new Error(`CatVod request timed out for ${route}`));
        req.destroy();
      });
      if (body !== undefined) req.write(body);
      req.end();
    });
  }

  // Providers keep their upstream connections in keep-alive agents and reuse
  // sockets the far end has already dropped; the bundle then answers 500 with
  // "socket hang up". One retry on a fresh connection (as tvbox-silicon does)
  // rescues those calls without masking a source that fails every time.
  async function inject(method, route, payload) {
    const started = Date.now();
    try {
      return await injectOnce(method, route, payload);
    } catch (error) {
      if (error.status !== 500 || !/socket hang up|ECONNRESET|EPIPE/.test(error.message || "")
          || Date.now() - started > 2500) throw error;
      return injectOnce(method, route, payload);
    }
  }

  async function handle(message) {
    if (message.type === "catalog") {
      const config = await inject("get", "/config");
      const sites = Array.isArray(config?.video?.sites) ? config.video.sites : [];
      return { sites };
    }
    if (message.type !== "invoke") throw new Error("Unsupported runner request");
    const site = message.site;
    const initKey = `${site.api}\0${site.ext || ""}`;
    // The queue serializes each route, whose provider owns one mutable state.
    // Remember only its active configuration; A -> B -> A must initialize A again.
    if (initialized.get(site.api) !== initKey) {
      // A failed init may already have changed provider state.
      initialized.delete(site.api);
      // Sites without an init route answer 404 and are ready as they are (the
      // 玩偶/花卷/原盘 family). Treat only other failures as fatal.
      const initBase = typeof site.api === "string" ? site.api.replace(/\/$/, "") : "";
      if (initBase) {
        await inject("post", `${initBase}/init`, { ext: site.ext || "" })
          .catch((error) => { if (error.status !== 404) throw error; });
      }
      initialized.set(site.api, initKey);
    }
    const request = actionRequest(site, message.action, message.arguments);
    let result;
    try {
      result = await inject("post", request.path, request.payload);
    } catch (error) {
      // A search with no matches answers 404 or an empty body in many bundles;
      // neither is a failure, it is simply an empty result page.
      if (message.action === "search" && (error.status === 404 || error.message === "No results")) {
        return { list: [] };
      }
      throw error;
    }
    return message.action === "player"
      ? await resolvePlayerResult(site, result, message.arguments.id)
      : result;
  }

  const lines = readline.createInterface({ input: options.input || process.stdin, crlfDelay: Infinity });
  const active = new Set();
  const enqueueSiteRequest = createSiteRequestQueue();
  const maximumConcurrentRequests = 6;
  for await (const line of lines) {
    const task = (async () => {
      let message;
      try {
        message = JSON.parse(line);
        const result = await enqueueSiteRequest(
          message.site?.api || "__catalog__",
          () => handle(message)
        );
        writeLine(`${JSON.stringify({ id: message.id, ok: true, result })}\n`);
      } catch (error) {
        writeLine(`${JSON.stringify({ id: message?.id, ok: false, code: "CATVOD_ERROR", message: error.message || "CatVod execution failed" })}\n`);
      }
    })();
    active.add(task);
    task.finally(() => active.delete(task));
    if (active.size >= maximumConcurrentRequests) await Promise.race(active);
  }
  await Promise.allSettled(active);
  await globalThis.__catvodExports.stop?.();
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  startParentWatchdog(async () => {
    await globalThis.__catvodExports?.stop?.();
  });
  runCatVod(process.argv[2]).catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
  });
}
