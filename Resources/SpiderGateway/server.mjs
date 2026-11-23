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
import { resolveCatVodCloudPlayer } from "./catvod-cloud-player.mjs";
import { requiresPlaybackConfirmation } from "./readonly-player.mjs";

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

function tokenMatches(header, expected) {
  if (!expected) return true;
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
      if (request.method !== "POST" || !["/v1/spider/invoke", "/v1/catvod/catalog"].includes(url.pathname)) {
        throw new GatewayError("NOT_FOUND", "Route not found", 404);
      }
      if (!tokenMatches(request.headers.authorization, config.token)) {
        throw new GatewayError("UNAUTHORIZED", "Invalid or missing Gateway token", 401);
      }

      const body = await readJSON(request, config.requestBodyMaxBytes);
      if (url.pathname === "/v1/catvod/catalog") {
        const catalog = validateCatalogRequest(body);
        const artifact = await nodeBundleCache.resolve(catalog.bundle);
        const result = await catVod.catalog(artifact);
        // Some bundles (e.g. the "配置"/config pseudo-site) declare `api` as an
        // object or omit it. Downstream requires a string route, so drop those
        // malformed entries here rather than letting `site.api.replace()` throw
        // deep in the runner ("r.replace is not a function").
        const spiderAPIPattern = /^\/spider\/[^/\s]+\/\d{1,2}$/u;
        let sites = Array.isArray(result?.sites)
          ? result.sites
              .filter((site) => site && typeof site === "object")
              .map((site) => {
                const key = String(site.key ?? "").trim();
                const rawAPI = typeof site.api === "string" ? site.api.trim() : "";
                // Normalize the route to the canonical /spider/<key>/3 form.
                // Some bundles emit an empty/absolute/odd api; derive it from
                // key so downstream validation never rejects a usable site.
                const api = spiderAPIPattern.test(rawAPI) || rawAPI.startsWith("csp_")
                  ? rawAPI
                  : (key ? `/spider/${encodeURIComponent(key)}/3` : "");
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
        sendJSON(response, 200, { sites });
        return;
      }

      const invoke = validateInvokeRequest(body);
      if (invoke.action === "player" && invoke.arguments.verifyResource === true
        && requiresPlaybackConfirmation(invoke.site, invoke.arguments)) {
        sendJSON(response, 200, { verification: "needs-playback", parse: 1, url: "" });
        return;
      }
      if (invoke.site.api.startsWith("/spider/")) {
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
      sendJSON(response, gatewayError.status, { code: gatewayError.code, message: gatewayError.message });
    }
  });
  server.requestTimeout = Math.max(
    config.workerTimeoutMs + Math.max(config.jarDownloadTimeoutMs, config.nodeBundleDownloadTimeoutMs) + 5_000,
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
      return server.address();
    },
    async close() {
      workers.close();
      catVod.close();
      if (!server.listening) return;
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
  };
}
