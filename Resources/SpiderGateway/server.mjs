import { timingSafeEqual } from "node:crypto";
import http from "node:http";
import { asGatewayError, GatewayError } from "./errors.mjs";
import { JarCache } from "./jar-cache.mjs";
import { CatVodManager } from "./catvod-manager.mjs";
import { NodeBundleCache } from "./node-bundle-cache.mjs";
import { validateCatalogRequest, validateInvokeRequest } from "./request.mjs";
import { WorkerManager } from "./worker-manager.mjs";
import { cloudPanSite, handleCloudPanAction, isCloudPanSite } from "./cloud-pan.mjs";
import { handlePanSearchAction, isPanSearchSite } from "./pan-search.mjs";
import { cloudFilesSite, handleCloudFilesAction, isCloudFilesSite } from "./cloud-files.mjs";
import { resolveCatVodCloudPlayer } from "./catvod-cloud-player.mjs";
import { normalizePlayerResult } from "./catvod-runner.mjs";
import { requiresPlaybackConfirmation } from "./readonly-player.mjs";
import { decodeMediaSpec, handleMediaRequest, playbackMediaKey } from "./playback-proxy.mjs";

/// Python 源统一走本机那个 Python 服务：它按 /py/<token>/<动作> 答话，回的就是
/// TVBox 的 JSON，和 JS 源在网关后半段享受同一套处理。没起 Python 就返回空，
/// 界面上少几个源，而不是整页报错。
const PYTHON_SITE_PREFIX = "py-";

function pythonBase(config) {
  return config.pythonSpiderPort ? `http://127.0.0.1:${config.pythonSpiderPort}` : "";
}

async function pythonCatalog(config, bundle) {
  const base = pythonBase(config);
  if (!base) return [];
  try {
    const response = await fetch(`${base}/v1/pyspider/sites`, { signal: AbortSignal.timeout(1500) });
    if (!response.ok) return [];
    const body = await response.json();
    const sites = Array.isArray(body?.sites) ? body.sites : [];
    return sites
      .map((site) => {
        // token 是 Python 侧给的哈希；源名多是中文，直接清洗名字会得到空串，
        // 多个源就撞成同一个 key、全部指到最后一个。旧版服务没有 token 时
        // 退回从 api（/py/<token>）里截。
        const raw = String(site?.token ?? (String(site?.api ?? "").split("/py/")[1] ?? ""));
        const token = raw.split("/")[0].replace(/[^\w-]/gu, "");
        if (!token) return null;
        const key = PYTHON_SITE_PREFIX + token;
        return {
          key,
          name: String(site.name ?? site.key ?? token),
          // 形状和 JS 源一致，界面不用为它做特判；jar 只是过校验用，
          // 因为 py 站点在下面就被拦下，不会进 CatVod 运行时。
          api: `/spider/${encodeURIComponent(key)}/4`,
          type: 4,
          jar: bundle,
          ext: String(site.ext ?? ""),
          searchable: true,
          py: true
        };
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

/// 网关的入参名字和插件的名字不一样（tid/keyword/ids），在这里一次翻清楚。
/// App 与网关之间用的动作名是 TVBox 的 `player`，而 Python 插件协议里叫 `play`
/// （`playerContent`）。两个名字必须在这里对齐，否则 /py/<token>/player 会落到
/// Python 侧的 else 分支，每个 .py 源播放都报「不认识的动作」。
function pythonAction(action) {
  return action === "player" ? "play" : action;
}

function pythonPayload(action, args) {
  switch (action) {
    case "home": return { filter: args.filter };
    case "category": return { id: args.tid, page: args.page, filter: args.filter, filters: args.extend ?? {} };
    case "detail": return { id: Array.isArray(args.ids) ? args.ids[0] : args.ids };
    case "search": return { wd: args.keyword, quick: args.quick, page: args.page };
    case "player": return { flag: args.flag, id: args.id, flags: args.vipFlags ?? [] };
    default: throw new GatewayError("UNSUPPORTED_ACTION", `Python 源不支持 ${action}`, 400);
  }
}

async function callPythonSite(config, invoke) {
  const base = pythonBase(config);
  if (!base) {
    throw new GatewayError("PYTHON_UNAVAILABLE",
      "这个源要 Python，但本机没有可用的 Python 运行时（需要重新构建安装包）", 503);
  }
  const token = invoke.site.key.slice(PYTHON_SITE_PREFIX.length);
  const remote = pythonAction(invoke.action);
  let response;
  try {
    response = await fetch(`${base}/py/${encodeURIComponent(token)}/${remote}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(pythonPayload(invoke.action, invoke.arguments)),
      signal: AbortSignal.timeout(120000)
    });
  } catch (error) {
    throw new GatewayError("PYTHON_UNAVAILABLE", `Python 源没有响应（${error.message}）`, 503);
  }
  if (!response.ok) {
    throw new GatewayError("PYTHON_ERROR", `Python 源返回 HTTP ${response.status}`, 502);
  }
  const result = await response.json();
  if (result && typeof result === "object" && typeof result.error === "string" && result.errorCode) {
    throw new GatewayError("PYTHON_SOURCE_ERROR", result.error, 502);
  }
  if (invoke.action === "player") return normalizePlayerResult(result, invoke.arguments.id);
  return result;
}

function sendJSON(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff"
  });
  response.end(body);
}

/// Config 里的 `lives`：TVBox 各家写法不一样，统一成
/// `{ name, url, type, epg, ua, playerType }`，只保留有地址的项。
/// `url` 可以是字符串，也可以是 `urls: [{name, url}]`（多线路）。
function normaliseLives(value) {
  if (!Array.isArray(value)) return [];
  const lives = [];
  for (const item of value) {
    if (!item || typeof item !== "object") continue;
    const urls = Array.isArray(item.urls) ? item.urls : [];
    const declared = typeof item.url === "string" ? item.url.trim() : "";
    const list = declared ? [declared] : urls.map((entry) => String(entry?.url || "").trim());
    for (const url of list) {
      if (!url) continue;
      lives.push({
        name: String(item.name ?? item.title ?? "直播").slice(0, 120),
        url,
        type: Number.isFinite(Number(item.type)) ? Number(item.type) : 0,
        epg: typeof item.epg === "string" ? item.epg : "",
        ua: typeof item.ua === "string" ? item.ua : (typeof item.userAgent === "string" ? item.userAgent : ""),
        playerType: Number.isFinite(Number(item.playerType)) ? Number(item.playerType) : 0
      });
    }
  }
  return lives.slice(0, 200);
}

function tokenMatches(header, expected) {  if (!expected) return true;
  const prefix = "Bearer ";
  if (typeof header !== "string" || !header.startsWith(prefix)) return false;
  const actualBuffer = Buffer.from(header.slice(prefix.length));
  const expectedBuffer = Buffer.from(expected);
  return actualBuffer.length === expectedBuffer.length && timingSafeEqual(actualBuffer, expectedBuffer);
}

async function readJSON(request, maximumBytes) {
  const contentType = request.headers["content-type"] || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new GatewayError("UNSUPPORTED_MEDIA_TYPE", "Content-Type must be application/json", 415);
  }
  const declared = Number.parseInt(request.headers["content-length"] || "0", 10);
  if (declared > maximumBytes) throw new GatewayError("REQUEST_TOO_LARGE", "Request body is too large", 413);
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maximumBytes) throw new GatewayError("REQUEST_TOO_LARGE", "Request body is too large", 413);
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new GatewayError("INVALID_JSON", "Request body contains invalid JSON", 400);
  }
}

/// Bundles disagree on how a content list looks. TVBox's own contract is
/// `{list, class, page, pagecount}`, but real sources answer `{data:[...]}`,
/// `{data:{list:[...]}}`, `{vodlist:[...]}`, `{items:[...]}` or even a JSON
/// string. Left alone, those all reach the app as "暂无内容" while the source
/// actually returned a full page — so flatten them once here, in the trusted
/// parent process, instead of teaching every caller the same aliases.
export function normalizeCatVodResult(raw) {
  let value = raw;
  if (typeof value === "string") {
    try { value = JSON.parse(value); } catch { return raw; }
  }
  if (Array.isArray(value)) return { list: value };
  if (!value || typeof value !== "object") return raw;

  const result = { ...value };
  if (!Array.isArray(result.list)) {
    const nested = result.data && typeof result.data === "object" && !Array.isArray(result.data)
      ? result.data.list
      : undefined;
    const candidate = [result.vodlist, result.vodList, result.items, result.videos,
      result.data, nested].find(Array.isArray);
    if (candidate) result.list = candidate;
  }
  if (!Array.isArray(result.class)) {
    const candidate = [result.classes, result.categories, result.types].find(Array.isArray);
    if (candidate) result.class = candidate;
  }
  if (Array.isArray(result.class)) {
    // `type_id` / `type_name` is the TVBox spelling; some spiders emit
    // `id` / `name`, and numeric ids must become strings or the app drops them.
    result.class = result.class.map((entry) => {
      if (!entry || typeof entry !== "object") return entry;
      const id = entry.type_id ?? entry.id ?? entry.typeId;
      const name = entry.type_name ?? entry.name ?? entry.typeName;
      return {
        ...entry,
        type_id: id === undefined || id === null ? "" : String(id),
        type_name: name === undefined || name === null ? "" : String(name)
      };
    });
  }
  if (Array.isArray(result.list)) {
    // Same story for the entries: `vod_id` / `vod_name` / `vod_pic` are the
    // TVBox names, but plenty of spiders answer `id` / `name` / `pic`. Without
    // the mapping those rows decode to an empty title and never show up.
    const pick = (entry, keys) => {
      for (const key of keys) {
        const value = entry[key];
        if (value !== undefined && value !== null && value !== "") return value;
      }
      return undefined;
    };
    const text = (value) => {
      if (value === undefined) return "";
      if (Array.isArray(value)) return value.length ? String(value[0]) : "";
      return String(value);
    };
    result.list = result.list.map((entry) => {
      if (!entry || typeof entry !== "object") return entry;
      return {
        ...entry,
        vod_id: text(pick(entry, ["vod_id", "id", "vodId", "vid"])),
        vod_name: text(pick(entry, ["vod_name", "name", "vodName", "title"])),
        vod_pic: text(pick(entry, ["vod_pic", "pic", "vodPic", "cover", "poster"])),
        vod_remarks: text(pick(entry, ["vod_remarks", "remarks", "vodRemarks", "note"])),
        vod_year: text(pick(entry, ["vod_year", "year", "vodYear"])),
        vod_type: text(pick(entry, ["vod_type", "type_name", "vodTypeName", "typeName"]))
      };
    });
  }
  return result;
}

function catVodListLength(result) {
  return Array.isArray(result?.list) ? result.list.length : 0;
}

export function createGateway(config, dependencies = {}) {
  const jarCache = dependencies.jarCache || new JarCache(config);
  const workers = dependencies.workers || new WorkerManager(config);
  const nodeBundleCache = dependencies.nodeBundleCache || new NodeBundleCache(config);
  // Third-party CatVod code runs in a separate process that never receives
  // account cookies or refresh tokens. Built-in cloud actions stay here in the
  // trusted parent process.
  // Netdisk sources stay empty without a signed-in account, so the drives the
  // user configured are handed to the bundle that asks for them (the same trust
  // boundary as running the bundle at all: it already has outbound network).
  const catVod = dependencies.catVod || new CatVodManager({ ...config });
  const trustedFetch = dependencies.fetchValue || fetch;

  /// Normalise a bundle reply, and when a list comes back empty try the two
  /// argument shapes real spiders are known to require. Empty is the single
  /// most common "source looks broken" report, and both causes are cheap to
  /// rule out: a spider that compares `tid === 3` sees nothing when we send
  /// `"3"`, and a handful paginate from 0 while TVBox starts at 1.
  const invokeBundle = async (artifact, site, action, args) => {
    let result = normalizeCatVodResult(await catVod.invoke(artifact, site, action, args));
    if (!["category", "search"].includes(action) || catVodListLength(result) > 0) return result;
    const retries = [];
    if (typeof args.tid === "string" && /^\d+$/.test(args.tid)) retries.push({ tid: Number(args.tid) });
    if (action === "category" && String(args.page) === "1") retries.push({ page: 0 });
    for (const patch of retries) {
      try {
        const retried = normalizeCatVodResult(await catVod.invoke(artifact, site, action,
          { ...args, ...patch }));
        if (catVodListLength(retried) > 0) return retried;
      } catch { /* keep the original — an empty page is a valid answer */ }
    }
    return result;
  };
  // Trusted parent process only. Expose every provider the app configured so
  // built-in cloud actions (quark/123/aliyun/baidu/115/...) can read them.
  // Third-party spider bundles still never receive these values.
  const credentialOverrides = {};
  const cloudCredentials = new Proxy(credentialOverrides, {
    get(target, key) {
      if (typeof key !== "string") return Reflect.get(target, key);
      // A refreshed cookie written back by the cloud module wins over the
      // initial config snapshot for the lifetime of this request path.
      if (Object.prototype.hasOwnProperty.call(target, key)) return target[key];
      return String(config.cloudConfig?.[key] ?? "");
    },
    set(target, key, value) {
      target[key] = value;
      return true;
    },
    has(_target, key) {
      return typeof key === "string" && (key in (config.cloudConfig || {}));
    },
    ownKeys() { return Reflect.ownKeys(config.cloudConfig || {}); },
    getOwnPropertyDescriptor(_target, key) {
      if (typeof key === "string" && key in (config.cloudConfig || {})) {
        return { enumerable: true, configurable: true };
      }
      return undefined;
    }
  });
  // Filled in by `listen()`; playback URLs must point at the port this process
  // actually bound, so HLS segments can be rewritten back through here.
  let proxyOrigin = "";
  const server = http.createServer(async (request, response) => {
    try {
      await dependencies.beforeRequest?.();
      const url = new URL(request.url || "/", "http://gateway.local");
      if (request.method === "GET" && url.pathname === "/health") {
        sendJSON(response, 200, {
          status: "ok",
          protocol: 1,
          workerConfigured: Boolean(config.workerCommand),
          catVodConfigured: true
        });
        return;
      }
      // Playback proxy. AVPlayer cannot send an Authorization header, so this
      // route authenticates with a value derived from the per-launch token and
      // is only reachable on loopback.
      if (["GET", "HEAD"].includes(request.method) && url.pathname === "/v1/media") {
        if (url.searchParams.get("k") !== playbackMediaKey(config.token)) {
          throw new GatewayError("UNAUTHORIZED", "Invalid media key", 401);
        }
        const spec = decodeMediaSpec(url.searchParams.get("s"));
        await handleMediaRequest({
          request,
          response,
          spec,
          token: config.token,
          proxyOrigin,
          resolveLoopback: async (bundleURL) => {
            const artifact = await nodeBundleCache.resolve(bundleURL);
            return catVod.loopbackBase(artifact);
          }
        });
        return;
      }
      if (request.method !== "POST" || !["/v1/spider/invoke", "/v1/catvod/catalog", "/v1/cookies"].includes(url.pathname)) {
        throw new GatewayError("NOT_FOUND", "Route not found", 404);
      }
      if (!tokenMatches(request.headers.authorization, config.token)) {
        throw new GatewayError("UNAUTHORIZED", "Invalid or missing Gateway token", 401);
      }

      const body = await readJSON(request, config.requestBodyMaxBytes);
      if (url.pathname === "/v1/cookies") {
        // Swift 侧把 WKWebView 的登录态推给 bundle 的 Cookie 池（等价于 OkHttp
        // CookieJar）。只接受当前配置里出现过的 bundle，避免被当成任意代码入口。
        const bundle = String(body?.bundle || "").trim();
        const items = Array.isArray(body?.items) ? body.items.slice(0, 300) : [];
        if (!bundle) throw new GatewayError("INVALID_COOKIES", "bundle is required", 400);
        const artifact = await nodeBundleCache.resolve(bundle);
        const imported = await catVod.setCookies(artifact, items);
        sendJSON(response, 200, { imported });
        return;
      }
      if (url.pathname === "/v1/catvod/catalog") {
        const catalog = validateCatalogRequest(body);
        // JS 接口的 bundle 下载/校验失败时，整个 catalog 以前直接抛错——连本机
        // 的 py 源和内置网盘站点一起消失，表现就是「导入 py 后一个源都看不到」。
        // py 源（callPythonSite）和内置网盘站点根本不依赖这个 bundle，改为降级：
        // JS 站点为空，但仍把独立可用的站点返回给界面。
        let result = { sites: [] };
        try {
          const artifact = await nodeBundleCache.resolve(catalog.bundle);
          result = await catVod.catalog(artifact);
        } catch {
          // 静默降级：独立站点照常返回，JS 站点这一轮为空。
        }
        // Some bundles (e.g. the "配置"/config pseudo-site) declare `api` as an
        // object or omit it. Downstream requires a string route, so drop those
        // malformed entries here rather than letting `site.api.replace()` throw
        // deep in the runner ("r.replace is not a function").
        let sites = Array.isArray(result?.sites)
          ? result.sites
              .filter((site) => site && typeof site === "object")
              .map((site) => {
                const key = String(site.key ?? "").trim();
                // Keep whatever the bundle declared. Its own router resolves by
                // that spelling, and the display key often differs from the
                // spider name — rebuilding the path from `key` is what made
                // sites answer "站源不存在". Only synthesise a route when the
                // bundle gave nothing usable.
                const rawAPI = typeof site.api === "string" ? site.api.trim().replace(/\/+$/u, "") : "";
                const usableAPI = /^\/spider\/[^/\s]+\/\d{1,2}$/u.test(rawAPI) || rawAPI.startsWith("csp_");
                const api = usableAPI ? rawAPI : (key ? `/spider/${encodeURIComponent(key)}/3` : "");
                return {
                  ...site,
                  key,
                  name: String(site.name ?? site.key ?? ""),
                  api,
                  type: 3,
                  jar: catalog.bundle
                };
              })
              .filter((site) => site.key !== "" && site.api !== "")
          : [];
        if (!sites.some((site) => isCloudPanSite(site))) {
          sites = [...sites, { ...cloudPanSite, jar: catalog.bundle }];
        }
        // "我的网盘" reads the drives the person signed in to, with the account's
        // own credentials — the one library a spider bundle cannot provide.
        if (!sites.some((site) => isCloudFilesSite(site))) {
          sites = [...sites, { ...cloudFilesSite, jar: catalog.bundle }];
        }
        // 直播源：TVBox 的 `lives` 一直是 config 的顶层字段，以前直接丢掉了。
        // 形状各家不同（url 字符串 / urls 数组 / type+playerType），这里只做最基本
        // 的规整，真正的 M3U/TXT 解析在 Swift 侧（离线也能解析、能单测）。
        const lives = normaliseLives(result?.lives);
        // Python 源：本机 Python 服务自己知道有哪些，这里只把它并进目录。
        const pythonSites = await pythonCatalog(config, catalog.bundle);
        if (pythonSites.length) sites = [...sites, ...pythonSites];
        sendJSON(response, 200, { sites, lives });
        return;
      }

      const invoke = validateInvokeRequest(body);
      if (invoke.site.py) {
        const result = await callPythonSite(config, invoke);
        sendJSON(response, 200, result);
        return;
      }
      if (invoke.action === "player" && invoke.arguments.verifyResource === true
        && requiresPlaybackConfirmation(invoke.site, invoke.arguments)) {
        sendJSON(response, 200, { verification: "needs-playback", parse: 1, url: "" });
        return;
      }
      if (invoke.site.api.startsWith("/spider/")) {
        if (isCloudFilesSite(invoke.site)) {
          const result = await handleCloudFilesAction({
            action: invoke.action,
            argumentsValue: invoke.arguments,
            credentials: cloudCredentials
          });
          sendJSON(response, 200, result);
          return;
        }
        if (isCloudPanSite(invoke.site) || isPanSearchSite(invoke.site)) {
          const options = {
            action: invoke.action,
            argumentsValue: invoke.arguments,
            site: invoke.site,
            credentials: cloudCredentials,
            fetchValue: trustedFetch,
            searchEndpoint: config.panSouEndpoint
          };
          const result = isPanSearchSite(invoke.site)
            ? await handlePanSearchAction(options)
            : await handleCloudPanAction(options);
          sendJSON(response, 200, result);
          return;
        }
        if (invoke.action === "player") {
          const cloudPlayer = await resolveCatVodCloudPlayer(invoke.arguments, cloudCredentials, trustedFetch);
          if (cloudPlayer) {
            sendJSON(response, 200, cloudPlayer);
            return;
          }
        }
        const artifact = await nodeBundleCache.resolve(invoke.site.jar);
        sendJSON(response, 200, await invokeBundle(artifact, invoke.site, invoke.action, invoke.arguments));
      } else {
        const artifact = await jarCache.resolve(invoke.site.jar);
        sendJSON(response, 200, await workers.invoke(artifact, invoke.site, invoke.action, invoke.arguments));
      }
    } catch (error) {
      const gatewayError = asGatewayError(error);
      // Surface a short diagnostic to the app log. The `message` alone (often a
      // generic "must be a JSON object" / "internal error") never showed *why*;
      // the underlying stack/cause did, but used to die at the worker's stderr.
      // Truncate and strip newlines so it stays one log line and cannot leak a
      // whole response body into an exported log.
      let diagnostic = "";
      const cause = gatewayError.cause || error;
      if (cause && cause !== gatewayError) {
        diagnostic = String(cause.stack || cause.message || cause)
          .split("\n").slice(0, 2).join(" ").replace(/\s+/g, " ").trim()
          .slice(0, 200);
      }
      // Prefix action + site so one exported line identifies which spider step
      // broke. site.key is an id; api/arguments (tokens, share urls) are omitted.
      const actionTag = typeof invoke?.action === "string" ? invoke.action : "-";
      const siteTag = typeof invoke?.site?.key === "string" ? invoke.site.key : "-";
      sendJSON(response, gatewayError.status, {
        code: gatewayError.code,
        message: gatewayError.message,
        diagnostic: `action=${actionTag} site=${siteTag}${diagnostic ? ` ${diagnostic}` : ""}`.slice(0, 240)
      });
    }
  });
  // 下载失败会按 nodeBundleDownloadRetries 重试，最坏情况是 (retries+1) 次下载；
  // requestTimeout 必须覆盖这个上限，否则连接先被 Node 断开，重试等于白做。
  const downloadAttempts = Math.max(1, (config.nodeBundleDownloadRetries ?? 2) + 1);
  server.requestTimeout = Math.max(
    config.workerTimeoutMs
      + Math.max(config.jarDownloadTimeoutMs, config.nodeBundleDownloadTimeoutMs * downloadAttempts)
      + 5_000,
    30_000
  );
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;

  return {
    server,
    async listen() {
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(config.port, config.host, () => {
          server.off("error", reject);
          resolve();
        });
      });
      const address = server.address();
      if (address && typeof address === "object") proxyOrigin = `http://127.0.0.1:${address.port}`;
      return address;
    },
    async close() {
      workers.close();
      catVod.close();
      if (!server.listening) return;
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
  };
}
