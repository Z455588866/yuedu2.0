import { createRequire } from "node:module";
import { writeSync } from "node:fs";
import http from "node:http";
import { readFile } from "node:fs/promises";
import readline from "node:readline";
import { pathToFileURL } from "node:url";
import { readBoundedText } from "./bounded-response.mjs";
import { installFetch, installReq } from "./fetch-polyfill.mjs";
import { installTVBoxGlobals } from "./catvod-globals.mjs";
import { startParentWatchdog } from "./process-lifecycle.mjs";

// nodejs-mobile has no global `fetch`. Bundles target Electron (Node 18+), so
// every `player` that talks to its own API used to fail with
// `fetch is not defined` — the list loads, nothing plays. Install before the
// bundle is evaluated so its module scope sees the same globals Electron would.
installFetch();
installReq();

/// Base route for a site's provider endpoints.
///
/// Bundles sometimes declare their own api literally (`/spider/某个中文站/3`).
/// `http.request` aborts on a path with raw non-ASCII bytes
/// (ERR_UNESCAPED_CHARACTERS), so encode only that case. A gateway-normalised
/// api is already percent-encoded and ASCII, and re-encoding it would turn
/// `%E7%9B%B4` into `%25E7%259B%25B4`.
export function siteBasePath(api) {
  const trimmed = typeof api === "string" ? api.replace(/\/$/, "") : "";
  if (!trimmed) return "";
  return /^[\x20-\x7E]*$/.test(trimmed) ? trimmed : encodeURI(trimmed);
}

export function actionRequest(site, action, args) {
  // A malformed catalog entry can carry a non-string api; never let `.replace`
  // throw an opaque "r.replace is not a function" deep inside the runner.
  const rawAPI = typeof site.api === "string" ? site.api : "";
  if (!rawAPI) throw new Error("站点接口无效（配置站点不支持浏览）");
  const base = siteBasePath(rawAPI);
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
  // Everything the bundle's module scope reads from the host. Must run before
  // the bundle is evaluated (see the `new Function` below).
  installTVBoxGlobals({ runtimeDirectory: options.runtimeDirectory });
  // fd 3 is a dedicated control channel. Third-party bundles may write logs to
  // stdout even after console is replaced, so stdout cannot carry protocol data.
  const writeLine = options.writeLine || ((value) => writeSync(3, value));
  const log = (...values) => process.stderr.write(`${values.map(String).join(" ").slice(0, 2048)}\n`);
  console.log = log;
  console.info = log;
  console.warn = log;
  console.error = log;
  // A bundle reaches back to the host by POSTing {action, opt} to
  // http://127.0.0.1:<catDartServerPort()>/msg — the CatVod Open apps answer a
  // few of these (toast, cookie, user agent, what is playing, danmaku). A bundle
  // that gets no answer waits or gives up, so the bridge has to exist: it used
  // to answer port 0 and every such call failed.
  const bridgeState = {
    userAgent: options.userAgent || "",
    cookies: { ...(options.cookies || {}) },
    playing: { title: "", episodeName: "", flag: "" },
    danmaku: ""
  };
  // Bundles ask the host for a drive cookie by URL (`getCookie("https://drive.quark.cn")`),
  // not by the credential key the app stores. Without this mapping every ask
  // returned "" and the source behaved as if the person never signed in.
  const CLOUD_COOKIE_HOSTS = [
    [/quark\.cn/i, "quarkCookie"],
    [/uc\.cn|ucweb\.com/i, "ucCookie"],
    [/baidu\.com/i, "baiduCookie"],
    [/115\.com/i, "pan115Cookie"],
    [/xunlei/i, "xunleiCookie"]
  ];
  function cookieFor(url) {
    if (!url) return "";
    if (bridgeState.cookies[url]) return bridgeState.cookies[url];
    const accounts = options.cloudAccounts || {};
    for (const [pattern, key] of CLOUD_COOKIE_HOSTS) {
      const value = String(accounts[key] || "").trim();
      if (value && pattern.test(url)) return value;
    }
    return "";
  }
  const messagesServer = http.createServer((request, response) => {
    if (request.method !== "POST") { response.writeHead(404); response.end(); return; }
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      let message = {};
      try { message = JSON.parse(Buffer.concat(chunks).toString("utf8")) || {}; } catch { /* empty message */ }
      const action = String(message.action || "");
      const opt = message.opt && typeof message.opt === "object" ? message.opt : {};
      const answer = { success: true, code: 0 };
      if (action === "getPlayInfo") {
        Object.assign(answer, bridgeState.playing);
      } else if (action === "getUserAgent") {
        answer.userAgent = bridgeState.userAgent;
      } else if (action === "getCookie") {
        answer.cookie = cookieFor(String(opt.url || ""));
      } else if (action === "setCookie") {
        const url = String(opt.url || "");
        if (url) bridgeState.cookies[url] = String(opt.cookie || "");
      } else if (action === "danmuPush") {
        bridgeState.danmaku = String(opt.url || "");
        try { options.onDanmaku?.(bridgeState.danmaku); } catch { /* reporting must not fail */ }
      } else if (action === "openWeb" || action === "openInternalWebview") {
        try { options.onOpenWeb?.(String(opt.url || "")); } catch { /* ignore */ }
      } else if (action === "toast") {
        try { options.onToast?.(String(opt.message || opt.text || "")); } catch { /* ignore */ }
      } else {
        answer.success = false;
        answer.code = -1;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(answer));
    });
  });
  await new Promise((resolve) => messagesServer.listen(0, "127.0.0.1", resolve));
  const messagesPort = messagesServer.address().port;
  globalThis.catDartServerPort = () => messagesPort;

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
  // A bundle's settings sit beside it (index.js -> index.config.js). Without them
  // a config-centre bundle starts with no sites at all, which the app can only
  // read as "every source failed". Fall back to the empty compatibility shape
  // when the bundle ships none.
  let bundleConfig = null;
  if (options.configPath) {
    try {
      const loaded = await import(pathToFileURL(options.configPath).href);
      const value = loaded?.default ?? loaded;
      if (value && typeof value === "object" && !Array.isArray(value)) bundleConfig = value;
    } catch (error) {
      process.stderr.write(`CATVOD_CONFIG ${error?.message || error}\n`);
    }
  }
  await startBundle(bundleConfig && Object.keys(bundleConfig).length > 0 ? bundleConfig : {
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

  // Netdisk sources list their files only with a signed-in account. The host owns
  // the credentials and hands each drive to the bundle at the routes the CatVod
  // Open config centres expose (tvbox-silicon shares them the same way).
  async function shareAccounts() {
    const accounts = options.cloudAccounts || {};
    const drives = [
      ["quark", "quarkCookie"], ["uc", "ucCookie"], ["baidu", "baiduCookie"],
      ["pan115", "pan115Cookie"], ["aliyun", "token"], ["tianyi", "tianyiToken"],
      ["123", "pan123Token"], ["guangya", "guangyaToken"], ["xunlei", "xunleiCookie"]
    ];
    const layouts = [
      { route: (drive) => `/website/api/credential/${drive}/cookie`, body: (value) => ({ value }) },
      { route: (drive) => `/website/api/credential/${drive}/token`, body: (value) => ({ value }) },
      { route: (drive) => `/website/${drive}/cookie`, body: (value) => ({ cookie: value }) }
    ];
    for (const [drive, key] of drives) {
      const value = String(accounts[key] || "").trim();
      if (!value) continue;
      // 凭据形态决定先试哪个位置。天翼/阿里/123 的「token」在网页登录后其实
      // 是一整串 cookie（`sessionKey=...`），而 bundle 有的读 `/token`、有的读
      // `/cookie`，只写成功的那一个会让另一类 bundle 认为没登录——分类点开就是
      // 「暂无内容」。两种位置都写，bundle 读哪个都有值。
      const looksLikeCookie = value.includes("=") && !/^[\w-]+\.[\w-]+\.[\w-]+$/.test(value);
      const ordered = looksLikeCookie
        ? [layouts[0], layouts[2], layouts[1]]
        : [layouts[1], layouts[0], layouts[2]];
      for (const layout of ordered) {
        try {
          await injectOnce("put", layout.route(drive), layout.body(value));
        } catch {
          // A bundle may offer only one of the layouts, or none for this drive.
        }
      }
    }
  }
  await shareAccounts().catch(() => {});

  // What plays, so a bundle that asks the host ("getPlayInfo") gets an answer it
  // can match against its own danmaku list.
  const rememberedTitles = new Map();
  function rememberTitles(result) {
    const list = Array.isArray(result?.list) ? result.list : [];
    for (const video of list) {
      const title = String(video?.vod_name ?? "").trim();
      if (!title) continue;
      const flags = String(video?.vod_play_from ?? "").split("$$$");
      String(video?.vod_play_url ?? "").split("$$$").forEach((line, index) => {
        for (const item of String(line).split("#")) {
          const cut = item.indexOf("$");
          const episodeName = cut < 0 ? "" : item.slice(0, cut).trim();
          const id = cut < 0 ? item : item.slice(cut + 1);
          if (!id.trim()) continue;
          rememberedTitles.set(id, { title, episodeName, flag: flags[index] || "" });
        }
      });
    }
    while (rememberedTitles.size > 2000) rememberedTitles.delete(rememberedTitles.keys().next().value);
  }

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
      // permanent spinner. Budgets are per action, and deliberately short for
      // browsing: a source that needs 150s to answer a category is unusable, and
      // making the person stare at a spinner that long is worse than telling
      // them it failed and letting them tap 重试. Only playback keeps a long
      // budget — a signed-out netdisk line waits for its own poll.
      // Measured on real interfaces: a healthy site answers 推荐 in 0.5–0.9s and a
      // category in 0.2–0.3s, so 25s was not a safety net — it was 24 seconds of
      // spinner in front of a source that had already given up. 12s still covers a
      // slow mobile network and fails fast enough for 重试 or another site to feel
      // like a choice rather than a hang. Detail keeps a little more because some
      // bundles resolve their provider before they list episodes.
      const fallbackMs = Number(options.injectTimeoutMs) > 0 ? Number(options.injectTimeoutMs) : 16000;
      const timeoutMs = route.includes("/search") ? Math.min(fallbackMs, 16000)
        : route.includes("/play") ? Math.min(fallbackMs, 60000)
        : route.includes("/detail") ? Math.min(fallbackMs, 18000)
        : route.includes("/category") || route.includes("/home") ? Math.min(fallbackMs, 12000)
        : fallbackMs;
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
      const initBase = siteBasePath(site.api);
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
    if (message.action === "detail") rememberTitles(result);
    if (message.action === "player") {
      const known = rememberedTitles.get(String(message.arguments?.id ?? ""));
      bridgeState.playing = {
        title: known?.title || "",
        episodeName: known?.episodeName || "",
        flag: String(message.arguments?.flag || known?.flag || "")
      };
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
  messagesServer.close();
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
