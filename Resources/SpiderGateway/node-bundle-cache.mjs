import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, open, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { GatewayError } from "./errors.mjs";
import { readBoundedBuffer } from "./bounded-response.mjs";

const MAX_REDIRECTS = 4;

/// 对齐成熟项目 PluginDownloads.refuseWebPageScript：脚本不会以标签开头，
/// 若下载到的是 HTML（源站把失效路径回退成首页/404 页），明确报错，而不是
/// 把一坨 HTML 交给引擎跑出难懂的 SyntaxError。
async function refuseWebPageScript(filePath) {
  const handle = await open(filePath, "r");
  try {
    const buffer = Buffer.alloc(64);
    const { bytesRead } = await handle.read(buffer, 0, 64, 0);
    const start = buffer.subarray(0, bytesRead).toString("utf8")
      .replace(/^\uFEFF/, "").trimStart().toLowerCase();
    if (start.startsWith("<!doctype") || start.startsWith("<html")) {
      throw new GatewayError("BUNDLE_IS_WEBPAGE", "CatVod download returned a web page, not a script", 422);
    }
  } finally {
    await handle.close();
  }
}

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

/// 对齐 tvbox-silicon：下载器用系统 URLSession 直接取用户给的地址，不做
/// 协议白名单、不做 URL 比对。http / https、带凭据的地址一律放行；信任边界
/// 是用户主动导入这件事本身。保留这些空函数只是让既有调用点无需逐个删改。
function assertAllowedProtocol() {}

/// 同上：成熟项目没有 URL 白名单这一层，恒放行。
/// 安全底线仍由 manifest/md5 校验、maxBytes 体积上限、refuseWebPageScript
/// 的 HTML 拦截承担——这些成熟项目也都做，故保留。
function assertAllowedURL() {}

export class NodeBundleCache {
  constructor(options) {
    this.cacheDir = options.nodeBundleCacheDir;
    this.allowChecksumRedirects = options.nodeBundleAllowChecksumRedirects === true;
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
    assertAllowedURL(parsed.url);
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
      assertAllowedURL(bundleURL);
    }
    let assumedIndex = false;
    if (!bundleURL.pathname.toLowerCase().endsWith(".js")) {
      // 只给了目录（仓库地址、`https://host/cat` 这类）时按 CatVod 惯例补
      // index.js。补出来的地址必须在白名单里——导入时 Swift 侧已按同样规则
      // 登记，所以这里不会放宽信任范围。
      const candidate = new URL(requestedURL.toString());
      candidate.pathname = `${requestedURL.pathname === "/" ? "" : requestedURL.pathname}/index.js`;
      try {
        assertAllowedURL(candidate);
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
      await refuseWebPageScript(temporaryPath);
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
      // 配置文件是 bundle 的兄弟文件，跟随其信任；按成熟项目只校验协议，
      // 私网拦截在 #fetch 里统一做。取不到就退回空配置，不影响源本身。
      assertAllowedProtocol(configURL);
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
      // 对齐 tvbox-silicon：下载走系统 URLSession，不做 DNS 解析后的私网拦截。
      // 用户主动导入的地址就是信任边界，checksum / 体积 / HTML 拦截仍保留。
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
        // 对齐 tvbox-silicon：跟随重定向，不判 HTTPS→HTTP 降级、不校验协议、
        // 不逐字符比对白名单。用户主动导入的地址及其跳转就是信任边界；
        // 完整字节仍由 manifest/md5 校验、体积上限与 HTML 拦截兜底。
        const redirected = parseBundleURL(new URL(location, currentURL).toString(), true);
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
