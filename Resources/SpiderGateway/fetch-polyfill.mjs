import http from "node:http";
import https from "node:https";
import zlib from "node:zlib";

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
  if (typeof globalThis.fetch !== "function") globalThis.fetch = fetchValue;
  if (typeof globalThis.Headers !== "function") globalThis.Headers = FetchHeaders;
  if (typeof globalThis.Response !== "function") globalThis.Response = FetchResponse;
  if (typeof globalThis.Request !== "function") globalThis.Request = FetchRequest;
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
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      if (typeof done === "function") done(error, value);
    };
    fetchValue(url, {
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
