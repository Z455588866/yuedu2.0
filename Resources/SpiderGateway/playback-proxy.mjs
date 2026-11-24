import http from "node:http";
import https from "node:https";
import { createHash } from "node:crypto";
import { GatewayError } from "./errors.mjs";

/// Host-side playback proxy.
///
/// Why this exists: a CatVod bundle answers `player` with a URL on **its own
/// loopback server**, which the runner binds to an ephemeral port. That port
/// dies with the session (idle sweep / switching to another 猫源 / 4-session
/// cap), and the OS may hand the same port to a different bundle — the player
/// then asks the wrong router for the path and gets
/// "在此服务器上找不到所请求的 URL" (404). Handing the raw URL to AVPlayer also
/// loses the per-request headers the source needs on redirects and segments.
///
/// Mature CatVod hosts (tvbox-silicon / CatPaw) never give the player the
/// bundle's port: they keep a stable proxy of their own and resolve through it.
/// This is that proxy. Every playback URL becomes
/// `http://127.0.0.1:<gateway>/v1/media?k=<key>&s=<spec>`; the gateway holds the
/// bundle identity instead of the dead port, re-attaches headers on every hop,
/// and rewrites HLS playlists so segments come back through here too.

const MAX_PLAYLIST_BYTES = 8 * 1024 * 1024;
const MAX_REDIRECTS = 6;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

/// The media route cannot carry an `Authorization` header — AVPlayer requests it
/// directly. Instead the URL carries a value derived from the per-launch gateway
/// token: unusable after relaunch, and it never exposes the token itself.
export function playbackMediaKey(token) {
  return createHash("sha256").update(`media:${token || ""}`).digest("hex").slice(0, 32);
}

export function encodeMediaSpec(spec) {
  return Buffer.from(JSON.stringify(spec), "utf8").toString("base64url");
}

export function decodeMediaSpec(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 16 * 1024) {
    throw new GatewayError("INVALID_MEDIA_SPEC", "播放地址无效", 400);
  }
  let spec;
  try {
    spec = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
  } catch {
    throw new GatewayError("INVALID_MEDIA_SPEC", "播放地址无效", 400);
  }
  if (!spec || typeof spec !== "object" || Array.isArray(spec)) {
    throw new GatewayError("INVALID_MEDIA_SPEC", "播放地址无效", 400);
  }
  return spec;
}

function isLoopbackHost(hostname) {
  const value = String(hostname || "").toLowerCase();
  return LOOPBACK_HOSTS.has(value) || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(value);
}

function sanitizedHeaders(raw) {
  const out = {};
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return out;
  for (const [key, value] of Object.entries(raw)) {
    if (typeof key !== "string" || typeof value !== "string") continue;
    const name = key.toLowerCase();
    // Hop-by-hop and length headers are recomputed by this proxy.
    if (["host", "connection", "content-length", "transfer-encoding", "accept-encoding"].includes(name)) continue;
    out[name] = value;
  }
  return out;
}

function requestOnce(target, { method, headers, timeoutMs = 30_000 }) {
  return new Promise((resolve, reject) => {
    const transport = target.protocol === "https:" ? https : http;
    const request = transport.request(target, { method, headers }, resolve);
    request.setTimeout(timeoutMs, () => {
      request.destroy(new GatewayError("MEDIA_TIMEOUT", "源站响应超时", 504));
    });
    request.on("error", (error) => {
      reject(error instanceof GatewayError ? error
        : new GatewayError("MEDIA_UNREACHABLE", `源站连不上：${error?.code || error?.message || "网络错误"}`, 502));
    });
    request.end();
  });
}

/// Fetch following redirects, keeping the source's headers on every hop.
/// AVFoundation does not re-send `AVURLAssetHTTPHeaderFieldsKey` headers to the
/// redirect target, which is the usual reason a 302'd CDN answers 403.
async function openUpstream(target, { method, headers }) {
  let current = target;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
    const response = await requestOnce(current, { method, headers });
    const status = response.statusCode || 0;
    const location = response.headers.location;
    if ([301, 302, 303, 307, 308].includes(status) && location) {
      response.resume();
      current = new URL(location, current);
      if (!["http:", "https:"].includes(current.protocol)) {
        throw new GatewayError("MEDIA_UNREACHABLE", "源站跳转到了不支持的协议", 502);
      }
      continue;
    }
    return { response, finalURL: current, status };
  }
  throw new GatewayError("MEDIA_REDIRECT_LOOP", "源站跳转次数过多", 502);
}

function looksLikePlaylist(finalURL, headers) {
  const type = String(headers["content-type"] || "").toLowerCase();
  if (type.includes("mpegurl") || type.includes("m3u")) return true;
  return /\.m3u8?(?:$|\?)/i.test(finalURL.pathname + finalURL.search);
}

function readBody(response, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    response.on("data", (chunk) => {
      total += chunk.length;
      if (total > limit) {
        response.destroy();
        reject(new GatewayError("MEDIA_TOO_LARGE", "播放列表过大", 502));
        return;
      }
      chunks.push(chunk);
    });
    response.on("end", () => resolve(Buffer.concat(chunks)));
    response.on("error", reject);
  });
}

function passThroughHeaders(upstream) {
  const out = {};
  for (const [key, value] of Object.entries(upstream)) {
    if (typeof value === "string" && !["connection", "transfer-encoding", "set-cookie", "content-encoding"].includes(key)) {
      out[key] = value;
    }
  }
  return out;
}

/// Rewrite every URI in an HLS playlist so the player keeps asking this proxy.
/// Relative segment names, absolute CDN URLs, keys and init segments are all
/// covered — the old behaviour left relative segments pointing at the bundle's
/// dead port, which is why some lines played 3 seconds and then stalled.
function rewritePlaylist(text, { finalURL, spec, key, proxyOrigin }) {
  const rewriteOne = (raw) => {
    const value = raw.trim();
    if (!value) return raw;
    let absolute;
    try { absolute = new URL(value, finalURL); } catch { return raw; }
    if (!["http:", "https:"].includes(absolute.protocol)) return raw;
    const onLoopback = isLoopbackHost(absolute.hostname);
    const childSpec = onLoopback && spec.j
      ? { j: spec.j, p: absolute.pathname + absolute.search }
      : { u: absolute.href, ...(spec.h ? { h: spec.h } : {}) };
    return `${proxyOrigin}/v1/media?k=${key}&s=${encodeMediaSpec(childSpec)}`;
  };
  const lines = text.split(/\r?\n/);
  const output = lines.map((line) => {
    if (line.trim() === "") return line;
    if (line.startsWith("#")) {
      // EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA carry URIs in attributes.
      return line.replace(/URI="([^"]+)"/g, (_match, uri) => `URI="${rewriteOne(uri)}"`);
    }
    return rewriteOne(line);
  });
  return output.join("\n");
}

export async function handleMediaRequest({
  request,
  response,
  spec,
  token,
  proxyOrigin,
  resolveLoopback
}) {
  const method = request.method === "HEAD" ? "HEAD" : "GET";
  const headers = sanitizedHeaders(spec.h);
  let target;
  let loopback = false;

  if (typeof spec.p === "string" && typeof spec.j === "string") {
    const base = await resolveLoopback(spec.j);
    target = new URL(spec.p.startsWith("/") ? spec.p : `/${spec.p}`, base);
    loopback = true;
  } else if (typeof spec.u === "string") {
    try {
      target = new URL(spec.u);
    } catch {
      throw new GatewayError("INVALID_MEDIA_SPEC", "播放地址无效", 400);
    }
    if (!["http:", "https:"].includes(target.protocol)) {
      throw new GatewayError("INVALID_MEDIA_SPEC", "只支持 http/https 播放地址", 400);
    }
    if (isLoopbackHost(target.hostname)) {
      // Legacy answer that only carried a loopback URL: route it back through
      // the current session by path, never by the stale port in the string.
      loopback = true;
    }
  } else {
    throw new GatewayError("INVALID_MEDIA_SPEC", "播放地址无效", 400);
  }

  if (loopback && typeof spec.j === "string" && spec.j) {
    // Segment/playlist requests from a bundle's own proxy: same path, live port.
    const base = await resolveLoopback(spec.j);
    target = new URL(target.pathname + target.search, base);
  }

  if (request.headers.range) headers.range = request.headers.range;
  if (request.headers["if-range"]) headers["if-range"] = request.headers["if-range"];

  const { response: upstream, finalURL, status } = await openUpstream(target, { method, headers });

  if (looksLikePlaylist(finalURL, upstream.headers)) {
    const body = await readBody(upstream, MAX_PLAYLIST_BYTES);
    const text = body.toString("utf8");
    if (text.startsWith("#EXTM3U")) {
      const rewritten = rewritePlaylist(text, {
        finalURL,
        spec,
        key: playbackMediaKey(token),
        proxyOrigin
      });
      const payload = Buffer.from(rewritten, "utf8");
      response.writeHead(200, {
        "content-type": "application/vnd.apple.mpegurl",
        "content-length": payload.length,
        "cache-control": "no-store"
      });
      response.end(method === "HEAD" ? undefined : payload);
      return;
    }
    // Not actually a playlist: hand the bytes through untouched.
    response.writeHead(status, passThroughHeaders(upstream.headers));
    response.end(method === "HEAD" ? undefined : body);
    return;
  }

  if (status >= 400) {
    upstream.resume();
    // Give the player the source's own status so its UI stays truthful
    // (403 → 没有访问许可, 404 → 找不到 URL).
    response.writeHead(status, { "content-type": "text/plain; charset=utf-8" });
    response.end(`upstream ${status}`);
    return;
  }

  response.writeHead(status, passThroughHeaders(upstream.headers));
  if (method === "HEAD") {
    upstream.resume();
    response.end();
    return;
  }
  upstream.pipe(response);
  request.on("close", () => { try { upstream.destroy(); } catch { /* already gone */ } });
}

/// Builds the absolute proxy URL the app hands to AVPlayer.
export function mediaProxyURL(base, token, spec) {
  const url = new URL("/v1/media", base);
  url.searchParams.set("k", playbackMediaKey(token));
  url.searchParams.set("s", encodeMediaSpec(spec));
  return url;
}
