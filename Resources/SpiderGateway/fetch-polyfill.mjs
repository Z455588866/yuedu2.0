import http from "node:http";
import https from "node:https";
import zlib from "node:zlib";
import { appendFileSync } from "node:fs";

/// Minimal `fetch` for CatVod bundles.
///
/// nodejs-mobile ships an older V8/Node without a global `fetch`, so any bundle
/// that talks to its own API with the WHATWG API dies with
/// `fetch is not defined` — the episode list loads but every play attempt fails,
/// which reads to the person as "this line is broken". CatVod's own desktop
/// runtime is Electron (Node 18+), so bundles assume `fetch` exists.
///
/// Only what spiders actually use is implemented: GET/POST with headers and a
/// string/Buffer body, redirects, gzip/deflate/br decoding, and `Response` with
/// `text`/`json`/`arrayBuffer`. No streams, no FormData, no CORS.

const MAX_REDIRECTS = 8;
const DEFAULT_TIMEOUT = 60_000;

/// Bundles run in a runtime with no browser identity: `node`/undici labels every
/// request `node` and axios labels it `axios/1.x`. Cloudflare-fronted CMS sites
/// answer those with 403 before the bundle ever sees a byte, while the same URL
/// opens fine in the app's WebView. TVBox and FongMi both hand their spiders the
/// host's mobile UA for exactly this reason; we do the same, and only where the
/// bundle did not set one itself.
export const DEFAULT_USER_AGENT =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
  + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";
const DEFAULT_HEADERS = {
  "user-agent": DEFAULT_USER_AGENT,
  "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "accept-language": "zh-CN,zh;q=0.9,en;q=0.8"
};

class FetchHeaders {
  constructor(init) {
    this._map = new Map();
    if (!init) return;
    if (init instanceof FetchHeaders) {
      for (const [key, value] of init._map) this._map.set(key, value);
    } else if (Array.isArray(init)) {
      for (const [key, value] of init) this.append(key, value);
    } else if (typeof init === "object") {
      for (const key of Object.keys(init)) {
        if (init[key] !== undefined && init[key] !== null) this.set(key, init[key]);
      }
    }
  }

  _key(name) { return String(name).toLowerCase(); }

  append(name, value) {
    const key = this._key(name);
    const previous = this._map.get(key);
    this._map.set(key, previous === undefined ? String(value) : `${previous}, ${value}`);
  }

  set(name, value) { this._map.set(this._key(name), String(value)); }

  get(name) {
    const value = this._map.get(this._key(name));
    return value === undefined ? null : value;
  }

  has(name) { return this._map.has(this._key(name)); }

  delete(name) { this._map.delete(this._key(name)); }

  forEach(callback, thisArg) {
    for (const [key, value] of this._map) callback.call(thisArg, value, key, this);
  }

  *entries() { yield* this._map.entries(); }
  *keys() { yield* this._map.keys(); }
  *values() { yield* this._map.values(); }
  [Symbol.iterator]() { return this.entries(); }

  /// Plain object for node's `http.request` options.
  toObject() {
    const object = {};
    for (const [key, value] of this._map) object[key] = value;
    return object;
  }
}

class FetchResponse {
  constructor(body, init = {}) {
    this._body = body ?? Buffer.alloc(0);
    this.status = init.status ?? 200;
    this.statusText = init.statusText ?? "";
    this.headers = init.headers instanceof FetchHeaders ? init.headers : new FetchHeaders(init.headers);
    this.url = init.url ?? "";
    this.redirected = Boolean(init.redirected);
    this.ok = this.status >= 200 && this.status < 300;
    this.type = "basic";
    this.bodyUsed = false;
  }

  get body() { return this._body; }

  _consume() {
    if (this.bodyUsed) throw new TypeError("Body has already been consumed");
    this.bodyUsed = true;
    return this._body;
  }

  async arrayBuffer() {
    const buffer = this._consume();
    return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
  }

  async buffer() { return this._consume(); }

  async text() { return this._consume().toString("utf8"); }

  async json() { return JSON.parse(await this.text()); }

  async blob() { return this._consume(); }

  clone() {
    return new FetchResponse(Buffer.from(this._body), {
      status: this.status,
      statusText: this.statusText,
      headers: this.headers,
      url: this.url,
      redirected: this.redirected
    });
  }
}

class FetchRequest {
  constructor(input, init = {}) {
    if (input instanceof FetchRequest) {
      this.url = input.url;
      this.method = init.method ?? input.method;
      this.headers = new FetchHeaders(init.headers ?? input.headers);
      this.body = init.body ?? input.body;
      this.signal = init.signal ?? input.signal;
      this.redirect = init.redirect ?? input.redirect;
    } else {
      this.url = String(input);
      this.method = String(init.method ?? "GET").toUpperCase();
      this.headers = new FetchHeaders(init.headers);
      this.body = init.body;
      this.signal = init.signal;
      this.redirect = init.redirect;
    }
  }
}

function decodeBody(buffer, encoding) {
  const name = String(encoding || "").toLowerCase().trim();
  if (!name || name === "identity") return buffer;
  try {
    if (name.includes("gzip")) return zlib.gunzipSync(buffer);
    if (name.includes("deflate")) return zlib.inflateSync(buffer);
    if (name.includes("br")) return zlib.brotliDecompressSync(buffer);
  } catch {
    // A truncated or mislabelled body is better handed over raw than dropped.
  }
  return buffer;
}

function abortError() {
  const error = new Error("The operation was aborted");
  error.name = "AbortError";
  return error;
}

function requestOnce(url, { method, headers, body, timeout, signal }) {
  return new Promise((resolve, reject) => {
    let target;
    try {
      target = new URL(url);
    } catch {
      reject(new TypeError(`Invalid URL: ${url}`));
      return;
    }
    const transport = target.protocol === "https:" ? https : http;
    const options = {
      method,
      headers: headers.toObject(),
      timeout,
      // Same two properties the transport patch applies, for the polyfill's own
      // path on runtimes without a global `fetch`.
      ALPNProtocols: TRANSPORT_ALPN,
      // Netdisk share pages and many CMS sites still ship broken chains; the
      // bundle only needs the bytes, so accepting them is the lesser evil.
      rejectUnauthorized: false
    };

    const request = transport.request(target, options, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        let buffer = Buffer.concat(chunks);
        buffer = decodeBody(buffer, response.headers["content-encoding"]);
        // `content-encoding` described the wire bytes; the body handed back is
        // already decoded, and node would otherwise re-report the stale header.
        const headers = new FetchHeaders(response.headers);
        headers.delete("content-encoding");
        headers.delete("content-length");
        resolve(new FetchResponse(buffer, {
          status: response.statusCode ?? 0,
          statusText: response.statusMessage ?? "",
          headers,
          url: target.href
        }));
      });
      response.on("error", reject);
    });

    request.on("timeout", () => {
      request.destroy(new Error(`timeout after ${timeout}ms: ${target.href}`));
    });
    request.on("error", reject);

    if (signal) {
      if (signal.aborted) {
        request.destroy(abortError());
        return;
      }
      const onAbort = () => request.destroy(abortError());
      typeof signal.addEventListener === "function"
        ? signal.addEventListener("abort", onAbort, { once: true })
        : null;
    }

    if (body !== undefined && body !== null && method !== "GET" && method !== "HEAD") {
      if (Buffer.isBuffer(body)) request.write(body);
      else if (typeof body === "string") request.write(body);
      else if (body instanceof ArrayBuffer) request.write(Buffer.from(body));
      else request.write(String(body));
    }
    request.end();
  });
}

async function fetchValue(input, init = {}) {
  const request = new FetchRequest(input, init);
  const redirectMode = request.redirect ?? "follow";
  const timeout = Number(init.timeout ?? DEFAULT_TIMEOUT) || DEFAULT_TIMEOUT;
  let url = request.url;
  let method = request.method;
  const headers = new FetchHeaders(request.headers);
  let body = request.body;
  // Let node pick the length; spiders hand over Chinese strings and a manual
  // `content-length` computed from `.length` would truncate the UTF-8 bytes.
  if (body !== undefined && body !== null && !headers.has("content-length")
      && !headers.has("transfer-encoding")) {
    if (typeof body === "string") headers.set("content-length", Buffer.byteLength(body));
    else if (Buffer.isBuffer(body)) headers.set("content-length", body.length);
  }

  for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
    const response = await requestOnce(url, {
      method, headers, body, timeout, signal: request.signal
    });
    const location = response.headers.get("location");
    const redirecting = [301, 302, 303, 307, 308].includes(response.status);
    if (!redirecting || !location || redirectMode === "manual") {
      response.url = url;
      return response;
    }
    if (redirectMode === "error") throw new TypeError(`redirect not allowed: ${url}`);
    url = new URL(location, url).href;
    // 303 (and the classic 302-for-POST) turn into a bodyless GET.
    if (response.status === 303 || ((response.status === 301 || response.status === 302)
        && method === "POST")) {
      method = "GET";
      body = undefined;
      headers.delete("content-length");
      headers.delete("content-type");
    }
  }
  throw new Error(`too many redirects: ${request.url}`);
}

/// Installs the globals a CatVod bundle expects. Safe to call more than once:
/// an existing (native) implementation always wins.
export function installFetch() {
  // Real sources ship incomplete or expired chains (measured: 4 of 40 sites in
  // one interface answer "unable to verify the first certificate" on Node 24's
  // undici, while the same URL opens in the app's WebView). TVBox/FongMi accept
  // them — OkHttp is configured trust-all — and the bundle only needs the bytes.
  // Without this the runtime reports "fetch failed" and the site looks dead.
  if (process.env.NODE_TLS_REJECT_UNAUTHORIZED !== "0") {
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  }
  if (typeof globalThis.fetch !== "function") globalThis.fetch = fetchValue;
  globalThis.fetch = withBrowserIdentity(globalThis.fetch);
  if (typeof globalThis.Headers !== "function") globalThis.Headers = FetchHeaders;
  if (typeof globalThis.Response !== "function") globalThis.Response = FetchResponse;
  if (typeof globalThis.Request !== "function") globalThis.Request = FetchRequest;
  installTransportIdentity();
}

/// Header pairs with the host's browser identity filled in, without touching a
/// value the bundle set for itself (some sources need their own app UA).
function withDefaultHeaderPairs(headers) {
  const pairs = [];
  if (headers) {
    if (Array.isArray(headers)) {
      for (const item of headers) if (Array.isArray(item) && item.length >= 2) pairs.push([String(item[0]), String(item[1])]);
    } else if (typeof headers.forEach === "function") {
      headers.forEach((value, key) => pairs.push([String(key), String(value)]));
    } else if (typeof headers === "object") {
      for (const [key, value] of Object.entries(headers)) {
        if (value !== undefined && value !== null) pairs.push([key, String(value)]);
      }
    }
  }
  const names = new Set(pairs.map(([name]) => name.toLowerCase()));
  for (const [name, value] of Object.entries(DEFAULT_HEADERS)) {
    if (!names.has(name)) pairs.push([name, value]);
  }
  return pairs;
}

/// `undici` reports a failed socket as `TypeError: fetch failed` and hides the
/// only useful sentence in `cause`; axios surfaces the raw OpenSSL text. Both
/// reached the app as "源站返回错误：fetch failed" or an English sentence about
/// a socket, which tells the person nothing. Flatten the chain so the host can
/// classify it (blocked / expired certificate / host gone) and say something
/// actionable.
export function describeNetworkError(error) {
  const parts = [];
  for (let item = error; item && parts.length < 4; item = item.cause) {
    const text = typeof item === "string" ? item : (item.message || String(item));
    const trimmed = String(text || "").trim();
    if (trimmed && !parts.includes(trimmed)) parts.push(trimmed);
  }
  const code = error?.code || error?.cause?.code || error?.cause?.errno || "";
  if (code && !parts.some((part) => part.includes(String(code)))) parts.push(String(code));
  return parts.join(" ← ") || "network error";
}

/// Optional on-device trace (`CATVOD_NET_LOG=/tmp/catvod-net.log`). Spider
/// failures are otherwise invisible: the bundle swallows them and the app only
/// gets the final sentence.
function traceNetwork(line) {
  const file = process.env.CATVOD_NET_LOG;
  if (!file) return;
  try { appendFileSync(file, `${new Date().toISOString()} ${line}\n`); } catch { /* tracing must not fail a request */ }
}

const RETRYABLE = /before secure TLS connection|ECONNRESET|EPIPE|socket hang up|ECONNABORTED/i;

/// Wraps whatever `fetch` the runtime provides (undici on Node 24, the polyfill
/// above on older nodejs-mobile builds) with the browser identity and one retry
/// on a connection the far end dropped. A fresh connection is what actually
/// fixes those: the pooled socket is already dead, and every later request on
/// it fails the same way.
function withBrowserIdentity(original) {
  const wrapped = async function fetch(input, init) {
    const method = String((init?.method || (typeof input === "object" && input?.method) || "GET")).toUpperCase();
    const traceURL = typeof input === "string" ? input
      : (input && typeof input.url === "string" ? input.url : String(input));
    let firstInput = input;
    let firstInit = init;
    try {
      if (init && "headers" in init) {
        firstInit = { ...init, headers: withDefaultHeaderPairs(init.headers) };
      } else if (typeof input === "string" || input instanceof URL) {
        firstInit = { ...(init || {}), headers: withDefaultHeaderPairs(undefined) };
      } else if (input && typeof input === "object" && "headers" in input && typeof Request === "function") {
        firstInput = new Request(input, { headers: withDefaultHeaderPairs(input.headers) });
        firstInit = init;
      }
    } catch { /* keep the caller's own shape */ }

    const started = Date.now();
    try {
      const response = await original(firstInput, firstInit);
      traceNetwork(`${response.status} ${method} ${traceURL} ${Date.now() - started}ms`);
      return response;
    } catch (error) {
      const attempt = `${method} ${traceURL} failed: ${describeNetworkError(error)}`;
      if ((method === "GET" || method === "HEAD") && !(firstInit?.body) && RETRYABLE.test(attempt)) {
        traceNetwork(`${attempt} — retrying on a fresh connection`);
        try {
          const retried = await original(firstInput, firstInit);
          traceNetwork(`${retried.status} ${method} ${traceURL} ${Date.now() - started}ms (retry)`);
          return retried;
        } catch (retryError) {
          retryError.message = describeNetworkError(retryError);
          traceNetwork(`${method} ${traceURL} retry failed: ${retryError.message}`);
          throw retryError;
        }
      }
      error.message = describeNetworkError(error);
      traceNetwork(attempt);
      throw error;
    }
  };
  return wrapped;
}

/// Libraries that predate `fetch` — axios above all — talk to `http.request`
/// directly, so the same identity has to be applied at the transport. Only
/// missing headers are added; a request that already names its UA is untouched.
///
/// `ALPNProtocols` is the part that actually rescues a whole class of sites:
/// Node's `https` sends a ClientHello with **no ALPN extension** unless asked,
/// and the CC/WAF in front of several CMS front-ends answers that with an
/// immediate RST — the app sees
/// "Client network socket disconnected before secure TLS connection was
/// established" while the same URL opens in curl and in the app's WebView
/// (measured: m.9zhoukj.com, RST without ALPN, HTTP 502 with `http/1.1`).
/// Safari, OkHttp and undici all advertise ALPN, which is why every mature host
/// reaches these sites and a bare `https.request` does not.
const TRANSPORT_ALPN = ["http/1.1"];

function withTransportHeaders(options) {
  if (!options || typeof options !== "object") return options;
  // Raw header arrays mean the caller builds the socket itself; leave the whole
  // request untouched rather than half-patching it.
  if (Array.isArray(options.headers)) return options;
  const merged = {};
  const present = new Set();
  for (const [key, value] of Object.entries(options.headers || {})) {
    if (value === undefined || value === null) continue;
    merged[key] = value;
    present.add(key.toLowerCase());
  }
  for (const [name, value] of Object.entries(DEFAULT_HEADERS)) {
    if (!present.has(name)) merged[name] = value;
  }
  return {
    ...options,
    headers: merged,
    ALPNProtocols: options.ALPNProtocols || TRANSPORT_ALPN,
    // 显式关掉证书校验：`NODE_TLS_REJECT_UNAUTHORIZED=0` 对自带 Agent／在
    // 模块加载时就建好 secure context 的库不一定生效（实测仍有站点回
    // `unable to verify the first certificate`），而这里一定生效。
    rejectUnauthorized: false
  };
}

function installTransportIdentity() {
  // 有些包在模块里预先 `new https.Agent({ keepAlive: true })`：Agent 自己的
  // options 会盖掉请求上的 rejectUnauthorized，证书链不完整的站点因此仍然
  // 报 "unable to verify the first certificate"（实测 piku / 小鹿快看 /
  // 小鸡看看）。继承原类再压实一次，任何 `new https.Agent(...)` 都拿到
  // trust-all 的语义，`instanceof https.Agent` 也仍然成立。
  const OriginalAgent = https.Agent;
  if (OriginalAgent && !OriginalAgent.__catvodTrustAll) {
    class CatVodAgent extends OriginalAgent {
      constructor(options = {}) {
        super({ ...options, rejectUnauthorized: false });
      }
    }
    CatVodAgent.__catvodTrustAll = true;
    https.Agent = CatVodAgent;
    if (https.globalAgent?.options) https.globalAgent.options.rejectUnauthorized = false;
  }
  for (const transport of [http, https]) {
    if (transport.__catvodIdentity) continue;
    const request = transport.request;
    const get = transport.get;
    const describe = (input, options) => {
      if (typeof input === "string" || input instanceof URL) return String(input);
      const target = options && typeof options === "object" ? options : input;
      if (!target || typeof target !== "object") return "?";
      const protocol = target.protocol || `${transport === https ? "https" : "http"}:`;
      const host = target.hostname || target.host || "?";
      return `${protocol}//${host}${target.path || "/"}`;
    };
    const observe = (handle, label, started) => {
      if (!process.env.CATVOD_NET_LOG) return;
      handle.once("response", (response) => {
        traceNetwork(`${response.statusCode} ${label} ${Date.now() - started}ms`);
      });
      handle.once("error", (error) => {
        traceNetwork(`${label} failed: ${describeNetworkError(error)}`);
      });
    };
    const patched = function requestWithIdentity(input, options, callback) {
      const started = Date.now();
      const label = describe(input, options);
      const handle = (typeof input === "string" || input instanceof URL)
        ? (typeof options === "function"
          ? request.call(this, input, withTransportHeaders({}), options)
          : request.call(this, input, withTransportHeaders(options), callback))
        : request.call(this, withTransportHeaders(input), options, callback);
      observe(handle, label, started);
      return handle;
    };
    patched.__catvodIdentity = true;
    transport.request = patched;
    if (typeof get === "function") {
      transport.get = function getWithIdentity(...args) {
        const handle = patched.apply(this, args);
        handle.end();
        return handle;
      };
    }
  }
}

/// CatVod's own JS API is `req(url, options, callback)`, and bundles mix it with
/// `fetch` freely (the official runtime is Electron, which has both). Without it
/// a bundle that resolves its play URL through `req` fails the same opaque way
/// `fetch is not defined` did, so the two are installed together.
/// Callback shape follows TVBox: `(error, {code, headers, content, buffer})`.
export function installReq() {
  if (typeof globalThis.req === "function") return;
  globalThis.req = function req(url, options, callback) {
    const settings = typeof options === "function" ? {} : (options || {});
    const done = typeof options === "function" ? options : callback;
    const timeout = Number(settings.timeout) > 0
      ? Number(settings.timeout)
      : DEFAULT_TIMEOUT;
    // Route through the installed `fetch` so `req` gets the same browser
    // identity and retry behaviour as everything else in the bundle.
    const fetchImpl = typeof globalThis.fetch === "function" ? globalThis.fetch : fetchValue;
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      if (typeof done === "function") done(error, value);
    };
    fetchImpl(url, {
      method: String(settings.method || "GET").toUpperCase(),
      headers: settings.headers,
      body: settings.body,
      // TVBox spells the abort handle both ways.
      signal: settings.signal,
      timeout
    }).then(async (response) => {
      // `buffer` and `content` are both read by real bundles; decoding once keeps
      // a binary response (m3u8 key, image) from being turned into UTF-8 twice.
      const buffer = await response.arrayBuffer();
      const bytes = Buffer.from(buffer);
      finish(null, {
        code: response.status,
        status: response.status,
        headers: response.headers.toObject(),
        url: response.url,
        get content() { return bytes.toString("utf8"); },
        get body() { return bytes.toString("utf8"); },
        buffer: () => buffer,
        arrayBuffer: async () => buffer,
        text: async () => bytes.toString("utf8"),
        json: async () => JSON.parse(bytes.toString("utf8"))
      });
    }).catch((error) => finish(error, null));
    // Bundles occasionally keep the handle to abort; nothing depends on it.
    return { abort() { settled = true; } };
  };
}
