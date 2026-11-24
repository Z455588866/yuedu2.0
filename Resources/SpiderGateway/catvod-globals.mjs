import crypto from "node:crypto";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";

/// HTML 选择器用的 cheerio，打成了单文件放在 `vendor/`。1.3 MB，只在脚本第一次
/// 调 `pdfh` / `pdfa` / `pd` 时才 require —— 纯 JSON 源的启动开销不受影响。
let cheerioModule = null;
function cheerio() {
  if (cheerioModule) return cheerioModule;
  const require = createRequire(import.meta.url);
  cheerioModule = require("./vendor/cheerio.cjs");
  return cheerioModule;
}

/// The rest of the TVBox script globals, ported from tvbox-silicon's
/// `ScriptAssets/tvbox/prelude.js` (the QuickJS prelude that runs CatVod JS
/// spiders on iOS). That prelude defines far more than `fetch`:
///
///   req / _http / fetch / http, local, joinUrl, base64Encode/Decode,
///   btoa/atob, md5X, gzip/ungzip, s2t/t2s, getProxy/getPort,
///   global/window/self aliases
///
/// A bundle that reaches for any of these used to die with
/// `X is not defined` — the same opaque failure the missing `fetch` caused.
/// Node already supplies URL, URLSearchParams, Buffer and TextEncoder; the
/// rest is installed here. Nothing overwrites a global the bundle brought.

const STORE_FILENAME = "tvbox-local.json";

/// `local` is the bundle's key-value store (cookies, tokens, caches). The
/// prelude routes it to the host; here it is a JSON file in the runtime
/// directory so a value survives the session, or memory when no directory was
/// provided.
function makeLocalStore(directory) {
  let table = {};
  let file = null;
  if (directory) {
    try {
      mkdirSync(directory, { recursive: true });
      file = path.join(directory, STORE_FILENAME);
      table = JSON.parse(readFileSync(file, "utf8")) || {};
    } catch {
      table = {};
    }
  }
  let lastWrite = 0;
  let scheduled = false;
  const write = () => {
    lastWrite = Date.now();
    try { writeFileSync(file, JSON.stringify(table)); } catch { /* best effort */ }
  };
  const flush = () => {
    if (!file) return;
    // Coalesce: spiders write cookie after cookie while scraping. The trailing
    // write is deliberately NOT unref'd — the session process is killed as soon
    // as it goes idle, and an unref'd timer would never run, losing exactly the
    // token the spider just stored.
    if (Date.now() - lastWrite < 300) {
      if (scheduled) return;
      scheduled = true;
      setTimeout(() => { scheduled = false; write(); }, 300);
      return;
    }
    write();
  };
  const group = (name) => {
    const key = String(name ?? "");
    if (!table[key] || typeof table[key] !== "object") table[key] = {};
    return table[key];
  };
  return {
    get(name, key) {
      const value = group(name)[String(key ?? "")];
      return value === undefined || value === null ? "" : String(value);
    },
    set(name, key, value) {
      group(name)[String(key ?? "")] = String(value ?? "");
      flush();
    },
    delete(name, key) {
      delete group(name)[String(key ?? "")];
      flush();
    }
  };
}

export function installTVBoxGlobals(options = {}) {
  const g = globalThis;
  // Bundles from the web assume a browser-ish host; CatVod's own runtime exposes
  // these as aliases, and code like `window.location` or `self.setTimeout`
  // otherwise throws before reaching the actual API.
  if (!g.global) g.global = g;
  if (!g.window) g.window = g;
  if (!g.self) g.self = g;

  if (typeof g.joinUrl !== "function") {
    g.joinUrl = (parent, child) => new URL(String(child), String(parent)).href;
  }
  if (typeof g.base64Encode !== "function") {
    g.base64Encode = (text) => Buffer.from(String(text ?? ""), "utf8").toString("base64");
  }
  if (typeof g.base64Decode !== "function") {
    g.base64Decode = (text) => Buffer.from(String(text ?? ""), "base64").toString("utf8");
  }
  if (typeof g.btoa !== "function") {
    g.btoa = (text) => Buffer.from(String(text ?? ""), "latin1").toString("base64");
  }
  if (typeof g.atob !== "function") {
    g.atob = (text) => Buffer.from(String(text ?? ""), "base64").toString("latin1");
  }
  if (typeof g.md5X !== "function") {
    g.md5X = (text) => crypto.createHash("md5").update(String(text ?? ""), "utf8").digest("hex");
  }
  if (typeof g.md5 !== "function") {
    g.md5 = (text) => crypto.createHash("md5").update(String(text ?? ""), "utf8").digest("hex");
  }
  if (typeof g.gzip !== "function") {
    g.gzip = (text) => zlib.gzipSync(Buffer.from(String(text ?? ""), "utf8")).toString("base64");
  }
  if (typeof g.ungzip !== "function") {
    g.ungzip = (text) => {
      try { return zlib.gunzipSync(Buffer.from(String(text ?? ""), "base64")).toString("utf8"); }
      catch { return ""; }
    };
  }
  // Simplified/traditional conversion is a real feature on Android; a no-op
  // returns the input unchanged instead of throwing, which is what bundles do
  // with a missing implementation anyway.
  if (typeof g.s2t !== "function") g.s2t = (text) => String(text ?? "");
  if (typeof g.t2s !== "function") g.t2s = (text) => String(text ?? "");
  // The bundle's own loopback player. Spiders use these as markers (`getProxy()`
  // is compared for equality), so an empty address is the honest answer.
  if (typeof g.getProxy !== "function") g.getProxy = () => "";
  if (typeof g.getPort !== "function") g.getPort = () => 0;

  // `http(url, options)` is the Promise-flavoured alias; the prelude answers a
  // `{code, headers, content, url}` object, and bundles read exactly those four
  // fields (`.content` far more often than a parsed body).
  if (typeof g.http !== "function") {
    g.http = function http(url, options = {}) {
      const settings = typeof options === "function" ? {} : (options || {});
      const promise = (typeof g.fetch === "function" ? g.fetch : async () => {
        throw new Error("http is unavailable");
      })(String(url), {
        method: String(settings.method || "GET").toUpperCase(),
        headers: settings.headers || settings.header,
        body: settings.body ?? settings.data,
        timeout: Number(settings.timeout) || undefined
      }).then(async (response) => {
        const text = await response.text();
        const answer = {
          code: response.status,
          status: response.status,
          headers: response.headers.toObject ? response.headers.toObject() : response.headers,
          content: text,
          url: response.url
        };
        if (typeof settings.complete === "function") settings.complete(answer);
        return answer;
      });
      return promise;
    };
  }

  if (!g.local) {
    const directory = options.runtimeDirectory
      || path.join(os.tmpdir(), "yuedu-catvod-local");
    g.local = makeLocalStore(directory);
  }

  // ---------------------------------------------------------------------------
  // HTML 选择器：TVBox 的 pdfh / pdfa / pd
  //
  // 大量 JS 源靠这几个函数解析站点 HTML，缺了就是 `pdfh is not defined`。
  // 语义照影匣 `ScriptAssets/tvbox/prelude.js`（它自己也是照 TVBox 的 JsApi）：
  //   pdfh(html, 'div&&a&&Text')   取文本
  //   pdfh(html, 'div&&a&&href')   取属性
  //   pdfh(html, 'div&&a&&Html')   取内部 HTML
  //   pdfa(html, 'div&&a')         取每个匹配元素的外层 HTML
  //   pd(html, 'div&&a&&href', base) 取地址并按 base 补全
  // 每一段按 `&&` 依次向下 find，前一段的结果是后一段的根。
  // ---------------------------------------------------------------------------
  if (typeof g.pdfh !== "function") {
    const select = (html, expression, single) => {
      const $ = cheerio().load(String(html ?? ""));
      let node = $.root();
      for (const selector of expression.split("&&").filter(Boolean)) {
        node = node.find(selector.trim());
        if (single) node = node.first();
      }
      return { $, node };
    };
    g.pdfh = (html, expression) => {
      const parts = String(expression ?? "").split("&&");
      const attribute = parts.pop();
      try {
        const { node } = select(html, parts.join("&&"), true);
        if (attribute === "Text") return node.text().trim();
        if (attribute === "Html") return node.html() || "";
        return node.attr(attribute) || "";
      } catch {
        return "";
      }
    };
    g.pdfa = (html, expression) => {
      try {
        const { $, node } = select(html, String(expression ?? ""), false);
        return node.toArray().map((element) => $.html(element));
      } catch {
        return [];
      }
    };
    g.pd = (html, expression, base) => {
      const value = g.pdfh(html, expression);
      // 源里常见的写法：pd(html, 'a&&href', base) 拿相对地址再补全。
      try {
        return base ? new URL(value, String(base)).href : value;
      } catch {
        return value;
      }
    };
  }
}
