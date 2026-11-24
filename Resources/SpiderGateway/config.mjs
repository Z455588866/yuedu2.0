import path from "node:path";
import { parseBoundedJSONObject } from "./secure-config.mjs";

function integer(name, fallback, minimum = 1) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw new Error(`${name} must be an integer greater than or equal to ${minimum}`);
  }
  return value;
}

function boolean(name, fallback = false) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (["1", "true", "yes"].includes(raw.toLowerCase())) return true;
  if (["0", "false", "no"].includes(raw.toLowerCase())) return false;
  throw new Error(`${name} must be true or false`);
}

function jsonArray(name) {
  const raw = process.env[name];
  if (!raw) return [];
  const value = JSON.parse(raw);
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`${name} must be a JSON string array`);
  }
  return value;
}

const DEFAULT_CATVOD_BUNDLES = [
  "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js",
  "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js.md5"
];

function isLoopbackHost(host) {
  const normalized = String(host || "").trim().toLowerCase().replace(/^\[|\]$/g, "");
  return normalized === "localhost"
    || normalized === "::1"
    || /^127(?:\.\d{1,3}){3}$/.test(normalized);
}

export function loadConfig(overrides = {}) {
  const environmentToken = process.env.SPIDER_GATEWAY_TOKEN || "";
  const environmentCloudConfig = process.env.TVBOX_CLOUD_CONFIG
    ? parseBoundedJSONObject(process.env.TVBOX_CLOUD_CONFIG, undefined, "Cloud configuration")
    : {};
  delete process.env.SPIDER_GATEWAY_TOKEN;
  delete process.env.TVBOX_CLOUD_CONFIG;

  const token = overrides.token ?? environmentToken;
  if (typeof token !== "string" || Buffer.byteLength(token) > 512) {
    throw new Error("Gateway token must be a string no longer than 512 bytes");
  }
  const cloudConfig = overrides.cloudConfig ?? environmentCloudConfig;
  if (!cloudConfig || typeof cloudConfig !== "object" || Array.isArray(cloudConfig)) {
    throw new Error("Cloud configuration must be a JSON object");
  }
  const host = process.env.SPIDER_GATEWAY_HOST || "127.0.0.1";
  if (!isLoopbackHost(host) && token.length === 0) {
    throw new Error("A Gateway token is required when listening on a non-loopback address");
  }
  const overrideAllowedURLs = overrides.nodeBundleAllowedURLs;
  if (overrideAllowedURLs !== undefined && (
    !Array.isArray(overrideAllowedURLs)
      || overrideAllowedURLs.some((item) => typeof item !== "string")
  )) {
    throw new Error("CatVod bundle allowlist must be a string array");
  }
  if (overrides.nodeBundleAllowChecksumRedirects !== undefined
    && typeof overrides.nodeBundleAllowChecksumRedirects !== "boolean") {
    throw new Error("CatVod checksum redirect setting must be a boolean");
  }

  // 0 是 Swift 侧"Python 还没起来 / 这次不启用"的约定值，不是端口。
  // 早先把它当端口校验会直接抛错，导致网关整个起不来（启动超时）；
  // 这里先归一成 undefined，再对真实端口做范围检查。
  const requestedPythonPort = overrides.pythonSpiderPort;
  const pythonSpiderPort = (requestedPythonPort === undefined
    || requestedPythonPort === null
    || requestedPythonPort === 0)
    ? undefined
    : requestedPythonPort;
  if (pythonSpiderPort !== undefined
    && (!Number.isInteger(pythonSpiderPort) || pythonSpiderPort < 1 || pythonSpiderPort > 65535)) {
    throw new Error("Python spider port must be an integer between 1 and 65535");
  }

  return {
    host,
    port: integer("SPIDER_GATEWAY_PORT", 8787, 0),
    pythonSpiderPort,
    token,
    cloudConfig,
    panSouEndpoint: process.env.TVBOX_PANSOU_ENDPOINT || undefined,
    cacheDir: path.resolve(process.env.SPIDER_GATEWAY_CACHE_DIR || "spider-gateway/data/jars"),
    nodeBundleCacheDir: path.resolve(process.env.CATVOD_BUNDLE_CACHE_DIR || "spider-gateway/data/bundles"),
    nodeBundleAllowedURLs: overrideAllowedURLs
      ?? (process.env.CATVOD_BUNDLE_ALLOWED_URLS
        ? process.env.CATVOD_BUNDLE_ALLOWED_URLS.split(",").map((value) => value.trim()).filter(Boolean)
        : DEFAULT_CATVOD_BUNDLES),
    nodeBundleAllowHTTP: boolean("CATVOD_BUNDLE_ALLOW_HTTP", false),
    nodeBundleAllowChecksumRedirects: overrides.nodeBundleAllowChecksumRedirects
      ?? boolean("CATVOD_BUNDLE_ALLOW_CHECKSUM_REDIRECTS", false),
    nodeBundleAllowPrivateNetwork: boolean("CATVOD_BUNDLE_ALLOW_PRIVATE_NETWORK", false),
    nodeBundleMaxBytes: integer("CATVOD_BUNDLE_MAX_BYTES", 65 * 1024 * 1024),
    nodeBundleDownloadTimeoutMs: integer("CATVOD_BUNDLE_DOWNLOAD_TIMEOUT_MS", 40_000),
    // 对齐 TVBox/OkHttp 的 retryOnConnectionFailure：网络抖动/瞬时 5xx 时重试，
    // 而不是一次失败就把整个源判死。只重试连接类错误和 5xx，不重试 4xx。
    nodeBundleDownloadRetries: integer("CATVOD_BUNDLE_DOWNLOAD_RETRIES", 2, 0),
    // How long a `.js.md5` manifest is trusted from disk. Inside this window a
    // warm start reads the script straight from cache with no network at all.
    nodeBundleManifestTTLms: integer("CATVOD_BUNDLE_MANIFEST_TTL_MS", 10 * 60_000, 0),
    nodeBundleManifestTimeoutMs: integer("CATVOD_BUNDLE_MANIFEST_TIMEOUT_MS", 8_000, 1_000),
    nodeBundleRuntimeDir: path.resolve(process.env.CATVOD_RUNTIME_DIR || "spider-gateway/data/runtime"),
    jarAllowedHosts: (process.env.SPIDER_JAR_ALLOWED_HOSTS || "")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
    allowPrivateNetwork: boolean("SPIDER_JAR_ALLOW_PRIVATE_NETWORK", false),
    jarMaxBytes: integer("SPIDER_JAR_MAX_BYTES", 65 * 1024 * 1024),
    jarDownloadTimeoutMs: integer("SPIDER_JAR_DOWNLOAD_TIMEOUT_MS", 30_000),
    requestBodyMaxBytes: integer("SPIDER_REQUEST_MAX_BYTES", 1024 * 1024),
    workerCommand: process.env.SPIDER_WORKER_COMMAND || "",
    workerArgs: jsonArray("SPIDER_WORKER_ARGS"),
    // 20s was too tight: a cold CatVod site must download+compile a bundle and
    // hit an often-overseas upstream before it answers. 40s keeps the fast path
    // fast while giving slow-but-working sources a fair chance instead of
    // failing most of them outright.
    workerTimeoutMs: integer("SPIDER_WORKER_TIMEOUT_MS", 40_000),
    workerIdleMs: integer("SPIDER_WORKER_IDLE_MS", 10 * 60_000),
    workerMaxSessions: integer("SPIDER_WORKER_MAX_SESSIONS", 16),
    workerMaxLineBytes: integer("SPIDER_WORKER_MAX_LINE_BYTES", 8 * 1024 * 1024),
    artifactCacheTTLms: integer("SPIDER_ARTIFACT_CACHE_TTL_MS", 30_000, 1_000),
    artifactCacheEntries: integer("SPIDER_ARTIFACT_CACHE_ENTRIES", 32),
    catVodIdleMs: integer("CATVOD_IDLE_MS", 15_000),
    catVodMaxSessions: integer("CATVOD_MAX_SESSIONS", 2)
  };
}
