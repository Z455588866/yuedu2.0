import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { attachBoundedLineReader } from "./bounded-lines.mjs";
import { GatewayError } from "./errors.mjs";
import { CatVodResponseCache, responseCacheKey } from "./catvod-response-cache.mjs";

const runnerPath = fileURLToPath(new URL("./catvod-runner.mjs", import.meta.url));

export function safeProxyEnvironment(environment = process.env) {
  const result = {};
  for (const name of ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]) {
    const value = environment[name];
    if (!value) continue;
    try {
      const url = new URL(value);
      if (!["http:", "https:", "socks:", "socks5:"].includes(url.protocol) || url.username || url.password) continue;
      result[name] = url.toString();
    } catch {
      // Ignore malformed or credential-bearing proxy settings.
    }
  }
  return result;
}

export function catVodPermissionArguments(flags = process.allowedNodeEnvironmentFlags) {
  const argumentsValue = ["--permission"];
  if (flags.has("--allow-net")) argumentsValue.push("--allow-net");
  return argumentsValue;
}

export function catVodFilePermissionArguments(artifactPath, runtimeDir) {
  return [
    // qist's database adapter opens "./db.json". Node 22 checks that relative
    // resource separately even when the resolved runtime directory is allowed.
    // The child cwd is runtimeDir, so "." remains scoped to this one session.
    "--allow-fs-read=.",
    "--allow-fs-write=.",
    `--allow-fs-read=${path.dirname(runnerPath)}`,
    `--allow-fs-read=${artifactPath}`,
    `--allow-fs-read=${runtimeDir}`,
    `--allow-fs-write=${runtimeDir}`
  ];
}

export function isCatVodSessionIdle(session, now, idleMs) {
  return session.closed || (session.pending.size === 0 && now - session.lastUsedAt >= idleMs);
}

class CatVodSession {
  constructor(processValue, options) {
    this.process = processValue;
    this.options = options;
    this.pending = new Map();
    this.lastUsedAt = Date.now();
    this.closed = false;
    this.lines = attachBoundedLineReader(processValue.stdio[3], {
      maximumBytes: options.maxLineBytes,
      onLine: (line) => this.#receive(line),
      onOverflow: () => {
        this.#fail(new GatewayError("CATVOD_RESPONSE_TOO_LARGE", "CatVod response is too large", 502));
        this.close();
      },
      onError: (error) => {
        this.#fail(new GatewayError("CATVOD_EXITED", "CatVod control channel failed", 502, { cause: error }));
        this.close();
      }
    });
    processValue.once("error", (error) => {
      this.closed = true;
      this.#fail(new GatewayError("CATVOD_START_FAILED", "Unable to start CatVod", 503, { cause: error }));
    });
    processValue.once("exit", () => {
      this.closed = true;
      this.#fail(new GatewayError("CATVOD_EXITED", "CatVod exited unexpectedly", 502));
    });
    // A bundle that hands the player a URL on its own loopback server keeps
    // serving segments there, outside this protocol. Those requests report
    // activity so the idle sweeper does not cut the stream short.
    processValue.on?.("activity", () => { this.lastUsedAt = Date.now(); });
  }

  request(payload) {
    if (this.closed) return Promise.reject(new GatewayError("CATVOD_EXITED", "CatVod is unavailable", 502));
    this.lastUsedAt = Date.now();
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new GatewayError("CATVOD_TIMEOUT", "CatVod execution timed out", 504));
        this.close();
      }, this.options.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.process.stdin.write(`${JSON.stringify({ id, ...payload })}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new GatewayError("CATVOD_WRITE_FAILED", "Unable to communicate with CatVod", 502, { cause: error }));
      });
    });
  }

  #receive(line) {
    let message;
    try { message = JSON.parse(line); } catch {
      this.#fail(new GatewayError("INVALID_CATVOD_RESPONSE", "CatVod returned invalid JSON", 502));
      return this.close();
    }
    const pending = this.pending.get(message.id);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(message.id);
    if (message.ok === true) pending.resolve(message.result ?? null);
    else pending.reject(new GatewayError(message.code || "CATVOD_ERROR", message.message || "CatVod execution failed", 502));
  }

  #fail(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.#fail(new GatewayError("CATVOD_STOPPED", "CatVod stopped", 502));
    this.lines.close();
    const child = this.process;
    child.stdin.end();
    child.kill("SIGTERM");
    const forceKill = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 1_000);
    forceKill.unref();
  }
}

export class CatVodManager {
  constructor(options) {
    this.runtimeRoot = options.nodeBundleRuntimeDir;
    this.timeoutMs = options.workerTimeoutMs;
    this.idleMs = options.catVodIdleMs;
    this.maxSessions = options.catVodMaxSessions;
    this.maxLineBytes = options.workerMaxLineBytes;
    this.sessions = new Map();
    this.creating = new Map();
    this.startingSessions = new Set();
    this.closed = false;
    this.responseCaches = new WeakMap();
    this.responseCacheOptions = options.responseCacheOptions;
    this.createProcess = options.createProcess;
    // Netdisk credentials live in the trusted parent and can change while the app
    // runs, so they are read through a callback when a session starts.
    this.cloudAccounts = options.cloudAccounts;
    this.accountsJSON = JSON.stringify(
      (typeof options.cloudAccounts === "function" ? options.cloudAccounts() : (options.cloudAccounts || {})) || {}
    );
    this.sweeper = setInterval(() => this.sweep(), Math.min(this.idleMs, 5_000));
    this.sweeper.unref();
  }

  async catalog(artifact) {
    const session = await this.#session(artifact);
    // #create already fetched catalog to initialize the bundle. Reuse that
    // result instead of paying a second loopback round-trip on every view.
    if (session.catalogValue !== undefined) return session.catalogValue;
    return session.request({ type: "catalog" });
  }

  async invoke(artifact, site, action, argumentsValue) {
    // Credentials are seeded into a bundle when its session starts. A session
    // opened before the person signed in would keep answering "请先保存 Cookie"
    // for the rest of its 30-minute life, so a change retires the sessions and
    // lets the next call start with the new accounts.
    this.#checkAccounts();
    // The parent resolves site.jar; it may contain private bundle credentials.
    // Remote code needs only the provider route and its initialization value.
    const runnerSite = { key: site.key, api: site.api, ext: site.ext || "" };
    const session = await this.#session(artifact);
    let cache = this.responseCaches.get(session);
    if (!cache) {
      cache = new CatVodResponseCache(this.responseCacheOptions);
      this.responseCaches.set(session, cache);
    }
    session.lastUsedAt = Date.now();
    return cache.load(responseCacheKey(runnerSite, action, argumentsValue), action, async () => {
      const result = await session.request({ type: "invoke", site: runnerSite, action, arguments: argumentsValue });
      if (!result || typeof result !== "object" || Array.isArray(result)) {
        throw new GatewayError("INVALID_CATVOD_RESPONSE", "CatVod result must be a JSON object", 502);
      }
      return result;
    }, argumentsValue.verifyResource === true);
  }

  #checkAccounts() {
    const value = typeof this.cloudAccounts === "function" ? this.cloudAccounts() : (this.cloudAccounts || {});
    const json = JSON.stringify(value || {});
    if (json === this.accountsJSON) return;
    this.accountsJSON = json;
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  async #session(artifact) {
    if (this.closed) {
      throw new GatewayError("CATVOD_STOPPED", "CatVod manager is stopped", 503);
    }
    const existing = this.sessions.get(artifact.digest);
    if (existing && !existing.closed) return existing;
    const inflight = this.creating.get(artifact.digest);
    if (inflight) return inflight;
    const creation = this.#create(artifact).finally(() => this.creating.delete(artifact.digest));
    this.creating.set(artifact.digest, creation);
    return creation;
  }

  async #create(artifact) {
    if (this.sessions.size >= this.maxSessions) this.#evictOldest();
    await mkdir(this.runtimeRoot, { recursive: true, mode: 0o700 });
    // Provider databases are disposable session state. Reusing a bundle-wide
    // directory lets a truncated db.json poison every future homepage, and
    // simultaneous app instances can overwrite each other's database.
    const runtimeDir = await mkdtemp(path.join(this.runtimeRoot, `${artifact.digest}-`));
    if (this.closed) {
      await rm(runtimeDir, { recursive: true, force: true });
      throw new GatewayError("CATVOD_STOPPED", "CatVod manager is stopped", 503);
    }
    // Node 26 also gates network access. CatVod providers inherently need
    // outbound HTTP, while older supported Node releases do not expose this flag.
    const child = this.createProcess
      ? this.createProcess({ bundlePath: artifact.path, runtimeDir, runnerPath,
          maxLineBytes: this.maxLineBytes, configPath: artifact.configPath,
          cloudAccounts: typeof this.cloudAccounts === "function" ? this.cloudAccounts() : (this.cloudAccounts || {}) })
      : spawn(process.execPath, [
      "--max-old-space-size=256",
      ...catVodPermissionArguments(),
      // The runner imports built-in source modules from the same bundled directory.
      ...catVodFilePermissionArguments(artifact.path, runtimeDir),
      runnerPath,
      artifact.path
    ], {
      cwd: runtimeDir,
      stdio: ["pipe", "ignore", "ignore", "pipe"],
      // qist bundle uses NODE_ENV to enable Fastify's stdout logger. Keep it off
      // because stdout is reserved for the JSON-lines control protocol.
      env: {
        PATH: process.env.PATH || "",
        LANG: "C.UTF-8",
        NODE_ENV: "development",
        NODE_PATH: runtimeDir,
        ...safeProxyEnvironment()
      }
    });
    // Wait for the process and its streams to close before removing its files.
    child.once("close", () => {
      void rm(runtimeDir, { recursive: true, force: true }).catch(() => {});
    });
    const session = new CatVodSession(child, { timeoutMs: this.timeoutMs, maxLineBytes: this.maxLineBytes });
    this.startingSessions.add(session);
    try {
      session.catalogValue = await session.request({ type: "catalog" });
      if (this.closed) {
        throw new GatewayError("CATVOD_STOPPED", "CatVod manager is stopped", 503);
      }
      this.sessions.set(artifact.digest, session);
      return session;
    } catch (error) {
      session.close();
      throw error;
    } finally {
      this.startingSessions.delete(session);
    }
  }

  #evictOldest() {
    const oldest = [...this.sessions.entries()].sort((a, b) => a[1].lastUsedAt - b[1].lastUsedAt)[0];
    if (!oldest) return;
    oldest[1].close();
    this.sessions.delete(oldest[0]);
  }

  sweep(now = Date.now()) {
    for (const [key, session] of this.sessions) {
      if (isCatVodSessionIdle(session, now, this.idleMs)) {
        session.close();
        this.sessions.delete(key);
      }
    }
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.sweeper);
    for (const session of this.startingSessions) session.close();
    this.startingSessions.clear();
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }
}
