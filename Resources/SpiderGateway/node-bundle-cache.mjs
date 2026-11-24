import { createHash, randomUUID } from "node:crypto";
import dns from "node:dns/promises";
import { createReadStream } from "node:fs";
import { mkdir, open, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { GatewayError } from "./errors.mjs";
import { isPrivateAddress } from "./jar-reference.mjs";
import { readBoundedBuffer } from "./bounded-response.mjs";

const MAX_REDIRECTS = 4;

async function fileDigests(filePath) {
  const sha256 = createHash("sha256");
  const md5 = createHash("md5");
  for await (const chunk of createReadStream(filePath)) {
    sha256.update(chunk);
    md5.update(chunk);
  }
  return { sha256: sha256.digest("hex"), md5: md5.digest("hex") };
}

function parseBundleURL(value, allowCredentials = false) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new GatewayError("INVALID_BUNDLE_URL", "CatVod bundle must be an HTTP or HTTPS URL", 400);
  }
  url.hash = "";
  // 共用的规范化：`…/index.js.md5/` 与 `…/cat/` 这种结尾斜杠一律去掉。
  // 否则同一个地址带不带斜杠会被当成两条不同 URL，白名单对不上就 403。
  url.pathname = url.pathname.replace(/\/+$/, "") || "/";
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new GatewayError("INVALID_BUNDLE_URL", "CatVod bundle must be an HTTP or HTTPS URL", 400);
  }
  let authorization = "";
  if (url.username || url.password) {
    if (!allowCredentials) {
      throw new GatewayError("INVALID_BUNDLE_URL", "CatVod redirect credentials are not allowed", 400);
    }
    let username;
    let password;
    try {
      username = decodeURIComponent(url.username);
      password = decodeURIComponent(url.password);
    } catch {
      throw new GatewayError("INVALID_BUNDLE_URL", "CatVod Basic Auth credentials are invalid", 400);
    }
    authorization = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
    url.username = "";
    url.password = "";
  }
  return { url, authorization };
}

function assertAllowedProtocol(url, allowHTTP) {
  if (url.protocol !== "https:" && !allowHTTP) {
    throw new GatewayError("INVALID_BUNDLE_URL", "Allowlisted CatVod bundles must use HTTPS", 400);
  }
}

/// 白名单比对按 origin 信任，不再逐字符匹配完整 URL。
///
/// 成熟猫源客户端（FongMi/TVBox/tvbox-silicon）的原则是：用户主动导入的源地址
/// 本身就是信任边界，bundle 在带 heap 上限的一次性 worker 里隔离运行，不需要
/// 精确 URL 白名单。本 App 之前用 `allowedURLs.includes(url.toString())` 逐字符
/// 比对，Swift（URLComponents）与 node（URL）两侧对编码、尾斜杠、大小写、query
/// 的规范化只要差一个字符就误判成 403 —— 表现就是源能列出、却解析/播放失败。
///
/// 这里放宽为：协议合法 + 同一 origin（scheme+host+port）即视为该源的后继请求。
/// 既挡住"往白名单外任意 URL 注入"，又不会因规范化差异误伤正常源。
function normalizeOrigin(value) {
  try {
    const url = new URL(value);
    return `${url.protocol.toLowerCase()}//${url.host.toLowerCase()}`;
  } catch {
    return null;
  }
}

function isAllowedURL(url, allowedURLs) {
  const origin = normalizeOrigin(url.toString());
  if (!origin) return false;
  return allowedURLs.some((allowed) => normalizeOrigin(allowed) === origin);
}

function assertAllowedURL(url, allowedURLs, allowHTTP) {
  assertAllowedProtocol(url, allowHTTP);
  if (!isAllowedURL(url, allowedURLs)) {
    throw new GatewayError("BUNDLE_URL_NOT_ALLOWED", "CatVod bundle URL is not in the allowlist", 403);
  }
}

async function validateBundleDestination(url, allowPrivateNetwork) {
  if (allowPrivateNetwork) return;
  let addresses;
  try {
    addresses = await dns.lookup(url.hostname, { all: true, verbatim: true });
  } catch {
    throw new GatewayError("BUNDLE_DNS_FAILED", "Unable to resolve the CatVod bundle host", 400);
  }
  if (addresses.length === 0 || addresses.some(({ address }) => isPrivateAddress(address))) {
    throw new GatewayError("BUNDLE_PRIVATE_ADDRESS", "CatVod bundle downloads from private networks are blocked", 403);
  }
}

export class NodeBundleCache {
  constructor(options) {
    this.cacheDir = options.nodeBundleCacheDir;
    this.allowedURLs = options.nodeBundleAllowedURLs.map(
      (value) => parseBundleURL(value, true).url.toString()
    );
    this.allowHTTP = options.nodeBundleAllowHTTP === true;
    this.allowChecksumRedirects = options.nodeBundleAllowChecksumRedirects === true;
    this.allowPrivateNetwork = options.nodeBundleAllowPrivateNetwork === true;
    this.fetchValue = options.fetchValue || fetch;
    this.maxBytes = options.nodeBundleMaxBytes;
    this.timeoutMs = options.nodeBundleDownloadTimeoutMs;
    this.inflight = new Map();
    this.completed = new Map();
    this.artifactCacheTTLms = options.artifactCacheTTLms || 30_000;
    this.artifactCacheEntries = options.artifactCacheEntries || 32;
    // The `.js.md5` manifest is the only network call left on a warm start:
    // the script itself is on disk and md5-verified. Caching the manifest for a
    // short window is what turns "open 猫元" from a 1–3s wait into instant, and
    // it is what the CatVod players do (FongMi keeps a spider jar for hours).
    this.manifestTTLms = options.nodeBundleManifestTTLms || 10 * 60 * 1000;
    this.manifestTimeoutMs = options.nodeBundleManifestTimeoutMs || 8_000;
  }

  async resolve(reference) {
    const parsed = parseBundleURL(reference.trim(), true);
    assertAllowedURL(parsed.url, this.allowedURLs, this.allowHTTP);
    const key = createHash("sha256")
      .update(parsed.url.toString())
      .update("\0")
      .update(parsed.authorization)
      .digest("hex");
    const cached = this.completed.get(key);
    if (cached && cached.expiresAt > Date.now()) {
      this.completed.delete(key);
      this.completed.set(key, cached);
      return cached.artifact;
    }
    this.completed.delete(key);
    const current = this.inflight.get(key);
    if (current) return current;
    const operation = this.#resolve(parsed, key)
      .then((artifact) => {
        this.#remember(key, artifact);
        return artifact;
      })
      .finally(() => this.inflight.delete(key));
    this.inflight.set(key, operation);
    return operation;
  }

  #remember(key, artifact) {
    this.completed.delete(key);
    this.completed.set(key, {
      artifact,
      expiresAt: Date.now() + this.artifactCacheTTLms
    });
    while (this.completed.size > this.artifactCacheEntries) {
      this.completed.delete(this.completed.keys().next().value);
    }
  }

  async #resolve(parsed, cacheKey) {
    // 粘贴来的地址常常带尾斜杠（`/cat/index.js.md5/`），也有大小写不一致的。
    // 旧代码直接 `endsWith(".js")`，这类地址被判成「不是脚本」，用户只看到一句
    // 英文的「必须以 .js 结尾」，既不知道错在哪条源、也不知道该怎么改。
    const requestedURL = new URL(parsed.url.toString());
    requestedURL.pathname = requestedURL.pathname.replace(/\/+$/, "") || "/";
    const lowerPath = requestedURL.pathname.toLowerCase();
    let bundleURL = requestedURL;
    let expectedMD5 = null;
    let manifestStale = false;
    if (lowerPath.endsWith(".js.md5")) {
      const manifest = await this.#manifest(requestedURL, cacheKey, parsed.authorization);
      expectedMD5 = manifest.md5;
      // A cached-but-expired manifest still lets an on-disk bundle run while the
      // manifest host is unreachable. Only a fresh manifest may invalidate it.
      manifestStale = manifest.fromCache === "stale";
      bundleURL = new URL(requestedURL.toString());
      bundleURL.pathname = requestedURL.pathname.slice(0, -4);
      assertAllowedURL(bundleURL, this.allowedURLs, this.allowHTTP);
    }
    let assumedIndex = false;
    if (!bundleURL.pathname.toLowerCase().endsWith(".js")) {
      // 只给了目录（仓库地址、`https://host/cat` 这类）时按 CatVod 惯例补
      // index.js。补出来的地址必须在白名单里——导入时 Swift 侧已按同样规则
      // 登记，所以这里不会放宽信任范围。
      const candidate = new URL(requestedURL.toString());
      candidate.pathname = `${requestedURL.pathname === "/" ? "" : requestedURL.pathname}/index.js`;
      try {
        assertAllowedURL(candidate, this.allowedURLs, this.allowHTTP);
        bundleURL = candidate;
        assumedIndex = true;
      } catch {
        throw new GatewayError("INVALID_BUNDLE_URL",
          `这个地址不是猫源脚本（需要以 .js 或 .js.md5 结尾）：${requestedURL.toString()}`, 400);
      }
    }

    await mkdir(this.cacheDir, { recursive: true, mode: 0o700 });
    const filePath = path.join(this.cacheDir, `${cacheKey}.js`);
    try {
      const info = await stat(filePath);
      if (info.isFile() && info.size > 0 && info.size <= this.maxBytes) {
        const digests = await fileDigests(filePath);
        if (manifestStale || !expectedMD5 || digests.md5 === expectedMD5) {
          return this.#withConfig({ path: filePath, digest: digests.sha256, sourceURL: bundleURL.toString() },
            bundleURL, cacheKey, parsed.authorization);
        }
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }

    const temporaryPath = path.join(this.cacheDir, `.${cacheKey}.${randomUUID()}.part`);
    try {
      const result = await this.#download(
        bundleURL, temporaryPath, parsed.authorization,
        this.allowChecksumRedirects && expectedMD5 !== null
      );
      if (expectedMD5 && !manifestStale && result.md5 !== expectedMD5) {
        throw new GatewayError("BUNDLE_CHECKSUM_MISMATCH", "CatVod bundle checksum does not match", 422);
      }
      await rename(temporaryPath, filePath);
      return this.#withConfig({ path: filePath, digest: result.sha256, sourceURL: bundleURL.toString() },
        bundleURL, cacheKey, parsed.authorization);
    } catch (error) {
      await unlink(temporaryPath).catch(() => {});
      if (assumedIndex && error.code === "BUNDLE_DOWNLOAD_FAILED") {
        throw new GatewayError("INVALID_BUNDLE_URL",
          `这个地址下没有找到猫源脚本（应在 ${bundleURL.toString()}，需要以 .js 或 .js.md5 结尾）：`
          + requestedURL.toString(), 400);
      }
      throw error;
    }
  }

  /// A CatVod bundle keeps its settings beside itself (`index.js` ->
  /// `index.config.js`). A config-centre bundle started without them lists no
  /// sites at all — which the app can only read as "every source failed" — so the
  /// file is fetched once and cached next to the bundle. A bundle without one, or
  /// one unreachable right now, is not an error: the runner then starts it with
  /// the empty compatibility shape.
  async #withConfig(artifact, bundleURL, cacheKey, authorization) {
    const configURL = new URL(bundleURL);
    configURL.pathname = configURL.pathname.replace(/\.js$/, ".config.js");
    if (configURL.pathname === bundleURL.pathname) return artifact;
    const filePath = path.join(this.cacheDir, `${cacheKey}.config.js`);
    try {
      const info = await stat(filePath);
      if (info.isFile() && info.size > 0) return { ...artifact, configPath: filePath };
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    try {
      // The settings file is a sibling of an allowlisted bundle, so it inherits
      // that bundle's trust and never widens the list to a new origin.
      const allowedProtocol = configURL.protocol === "https:"
        || (this.allowHTTP && configURL.protocol === "http:");
      const permitted = allowedProtocol && isAllowedURL(configURL, this.allowedURLs);
      if (!permitted) return artifact;
      const text = await this.#fetchText(configURL, 4 * 1024 * 1024, authorization);
      if (!text.trim()) return artifact;
      await writeFile(filePath, text, { mode: 0o600 });
      return { ...artifact, configPath: filePath };
    } catch {
      return artifact;
    }
  }

  /// Resolves the pinned md5 for a `.js.md5` bundle, preferring a cached copy.
  ///
  /// Returns `{ md5, fromCache }` where `fromCache` is `false` (network),
  /// `"fresh"` (on-disk record inside the TTL window) or `"stale"` (network
  /// failed, old record reused). A `"stale"` md5 must not invalidate an on-disk
  /// bundle: the manifest may have moved on while its host is unreachable, and
  /// refusing to run the last verified copy is exactly how a working source
  /// turns into "加载不了".
  async #manifest(url, cacheKey, authorization) {
    await mkdir(this.cacheDir, { recursive: true, mode: 0o700 });
    const filePath = path.join(this.cacheDir, `${cacheKey}.manifest.json`);
    let record = null;
    try {
      const parsed = JSON.parse(await readFile(filePath, "utf8"));
      if (typeof parsed?.md5 === "string" && /^[a-f0-9]{32}$/.test(parsed.md5)
        && Number.isFinite(parsed.fetchedAt)) {
        record = parsed;
      }
    } catch {
      // Missing or corrupt record: fall through to the network.
    }
    if (record && Date.now() - record.fetchedAt < this.manifestTTLms) {
      return { md5: record.md5, fromCache: "fresh" };
    }
    try {
      const manifest = await this.#fetchText(url, 1024, authorization, this.manifestTimeoutMs);
      const match = manifest.trim().match(/^[a-fA-F0-9]{32}$/);
      if (!match) throw new GatewayError("INVALID_BUNDLE_MANIFEST", "CatVod MD5 manifest is invalid", 422);
      const md5 = match[0].toLowerCase();
      await writeFile(filePath, JSON.stringify({ md5, fetchedAt: Date.now() }), { mode: 0o600 })
        .catch(() => {});
      return { md5, fromCache: false };
    } catch (error) {
      if (record) return { md5: record.md5, fromCache: "stale" };
      throw error;
    }
  }

  async #fetchText(url, maximumBytes, authorization, timeoutMs) {
    const response = await this.#fetch(url, authorization, false, timeoutMs);
    const buffer = await readBoundedBuffer(response, {
      maximumBytes,
      code: "BUNDLE_MANIFEST_TOO_LARGE",
      message: "CatVod manifest is too large"
    });
    return buffer.toString("utf8");
  }

  async #download(initialURL, destination, authorization, allowChecksumRedirects) {
    const response = await this.#fetch(initialURL, authorization, allowChecksumRedirects);
    const declared = Number.parseInt(response.headers.get("content-length") || "0", 10);
    if (declared > this.maxBytes) throw new GatewayError("BUNDLE_TOO_LARGE", "CatVod bundle exceeds the size limit", 413);
    const file = await open(destination, "wx", 0o600);
    const sha256 = createHash("sha256");
    const md5 = createHash("md5");
    let total = 0;
    try {
      for await (const chunk of response.body) {
        total += chunk.length;
        if (total > this.maxBytes) throw new GatewayError("BUNDLE_TOO_LARGE", "CatVod bundle exceeds the size limit", 413);
        sha256.update(chunk);
        md5.update(chunk);
        await file.write(chunk);
      }
    } finally {
      await file.close();
    }
    if (total === 0) throw new GatewayError("INVALID_BUNDLE", "CatVod bundle is empty", 422);
    return { sha256: sha256.digest("hex"), md5: md5.digest("hex") };
  }

  async #fetch(initialURL, authorization, allowChecksumRedirects = false, timeoutMs = this.timeoutMs) {
    let currentURL = initialURL;
    const credentialOrigin = initialURL.origin;
    for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
      await validateBundleDestination(currentURL, this.allowPrivateNetwork);
      const requestAuthorization = currentURL.origin === credentialOrigin ? authorization : "";
      const response = await this.fetchValue(currentURL, {
        redirect: "manual",
        signal: AbortSignal.timeout(timeoutMs),
        headers: {
          "user-agent": "tvbox-spider-gateway/0.2",
          ...(requestAuthorization ? { authorization: requestAuthorization } : {})
        }
      }).catch((error) => {
        if (error.name === "TimeoutError") throw new GatewayError("BUNDLE_DOWNLOAD_TIMEOUT", "CatVod download timed out", 504);
        throw new GatewayError("BUNDLE_DOWNLOAD_FAILED", "Unable to download the CatVod bundle", 502, { cause: error });
      });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("location");
        if (!location || redirects === MAX_REDIRECTS) throw new GatewayError("BUNDLE_REDIRECT_FAILED", "Invalid CatVod redirect", 502);
        await response.body?.cancel().catch(() => {});
        const redirected = parseBundleURL(new URL(location, currentURL).toString());
        if (allowChecksumRedirects && currentURL.protocol === "https:" && redirected.url.protocol === "http:") {
          throw new GatewayError("INVALID_BUNDLE_URL", "CatVod redirects must not downgrade HTTPS", 400);
        }
        // CDN 常把脚本重定向到同域或第三方下载节点（如 github raw → objects）。
        // 只要不是 HTTPS 降级到 HTTP，就允许跟随；完整字节由 manifest/md5 校验，
        // 逐字符白名单在这里只会误挡正常下载。保留协议与同源底线。
        if (allowChecksumRedirects) {
          assertAllowedProtocol(redirected.url, this.allowHTTP);
        } else {
          assertAllowedURL(redirected.url, this.allowedURLs, this.allowHTTP);
        }
        currentURL = redirected.url;
        continue;
      }
      if (!response.ok || !response.body) {
        throw new GatewayError("BUNDLE_DOWNLOAD_FAILED", `CatVod server returned HTTP ${response.status}`, 502);
      }
      return response;
    }
    throw new GatewayError("BUNDLE_REDIRECT_FAILED", "Too many CatVod redirects", 502);
  }
}
