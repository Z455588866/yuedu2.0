import { GatewayError } from "./errors.mjs";

/// 宿主级 Cookie 池。
///
/// 成熟宿主（TVBox / FongMi）的网络层是 OkHttp + 全局 CookieJar：站点第一次回
/// `Set-Cookie`，之后同一域的所有请求自动带上，JS 爬虫完全不用自己拼。Node 的
/// fetch 没有这层，每个 bundle 各拼各的，于是「WebView 里登录过、spider 请求却
/// 是游客」这种断裂就只能靠 bundle 自己的代码补救——补不了的就报 403/缺少凭证。
///
/// 这里补的就是那一层：按域存、按域取、进程内共享，并接受 Swift 侧从
/// WKWebView 的 Cookie 池灌进来（见 server.mjs 的 /v1/cookies）。
export class CookieJar {
  constructor() {
    /// domain -> Map(name -> { value, expires, hostOnly })
    this.domains = new Map();
  }

  /// "a=b; Path=/; Domain=.quark.cn; Expires=Wed, 21 Oct 2026 07:28:00 GMT"
  setCookieString(rawValue, requestURL) {
    const text = String(rawValue || "").trim();
    if (!text) return;
    const parts = text.split(";").map((part) => part.trim()).filter(Boolean);
    const first = parts.shift() || "";
    const separator = first.indexOf("=");
    if (separator <= 0) return;
    const name = first.slice(0, separator).trim();
    const value = first.slice(separator + 1).trim();
    if (!name || /[\x00-\x1f\x7f]/.test(name)) return;

    let domain = "";
    let path = "/";
    let expires = null;
    let hostOnly = true;
    for (const part of parts) {
      const index = part.indexOf("=");
      const key = (index < 0 ? part : part.slice(0, index)).toLowerCase();
      const attributed = index < 0 ? "" : part.slice(index + 1);
      if (key === "domain") {
        domain = attributed.trim().replace(/^\./, "").toLowerCase();
        hostOnly = false;
      } else if (key === "path") {
        path = attributed.trim() || "/";
      } else if (key === "max-age") {
        const seconds = Number(attributed);
        if (Number.isFinite(seconds)) expires = Date.now() + seconds * 1000;
      } else if (key === "expires" && expires === null) {
        const parsed = Date.parse(attributed);
        if (Number.isFinite(parsed)) expires = parsed;
      }
    }

    let host = domain;
    if (!host) {
      try { host = new URL(String(requestURL)).hostname.toLowerCase(); } catch { return; }
    }
    if (!host) return;
    if (expires !== null && expires <= Date.now()) {
      this.remove(host, name, path);
      return;
    }
    let group = this.domains.get(host);
    if (!group) { group = new Map(); this.domains.set(host, group); }
    group.set(`${path}\0${name}`, { name, value, path, expires, hostOnly });
  }

  /// "a=b; c=d" —— Swift 侧 WKWebView 取出来的就是这种形状。
  setCookieHeader(rawHeader, requestURL) {
    for (const chunk of String(rawHeader || "").split(";")) {
      const text = chunk.trim();
      if (!text) continue;
      const separator = text.indexOf("=");
      if (separator <= 0) continue;
      this.setCookieString(text, requestURL);
    }
  }

  /// 一个 URL 应该带的 Cookie 头，按域与路径匹配，长的域优先。
  cookieHeaderFor(rawURL) {
    let url;
    try { url = new URL(String(rawURL)); } catch { return ""; }
    const host = url.hostname.toLowerCase();
    const path = url.pathname || "/";
    const matched = [];
    for (const [domain, group] of this.domains) {
      if (host !== domain && !host.endsWith(`.${domain}`)) continue;
      for (const cookie of group.values()) {
        if (cookie.expires !== null && cookie.expires <= Date.now()) continue;
        // host-only（没有 Domain 属性）的 cookie 只回原主机，不能下发子域，
        // 这是 RFC 6265 的行为，OkHttp 同样遵守。
        if (cookie.hostOnly && host !== domain) continue;
        if (cookie.path !== "/" && !path.startsWith(cookie.path)) continue;
        matched.push({ domain, cookie });
      }
    }
    if (matched.length === 0) return "";
    // 更具体的域覆盖更宽的域（`a.b.com` 的同名 cookie 优先于 `.b.com`）。
    matched.sort((lhs, rhs) => rhs.domain.length - lhs.domain.length);
    const seen = new Set();
    const pairs = [];
    for (const entry of matched) {
      if (seen.has(entry.cookie.name)) continue;
      seen.add(entry.cookie.name);
      pairs.push(`${entry.cookie.name}=${entry.cookie.value}`);
    }
    return pairs.join("; ");
  }

  /// 记录一次响应里的所有 Set-Cookie。
  absorb(url, headers) {
    if (!headers) return;
    let values = [];
    try {
      if (typeof headers.getSetCookie === "function") {
        values = headers.getSetCookie();
      } else {
        const single = headers.get?.("set-cookie");
        if (single) values = [single];
      }
    } catch {
      return;
    }
    for (const value of Array.isArray(values) ? values : []) this.setCookieString(value, url);
  }

  /// 宿主灌入：[{ url, cookie }] 或 [{ domain, cookie }]。
  ///
  /// 给的是 domain 时按「域 cookie」存（等价于响应里带 `Domain=`），这样
  /// `pan.baidu.com` 拿得到 `baidu.com` 的登录态；给的是 url 时按该主机存。
  import(items) {
    let count = 0;
    for (const item of Array.isArray(items) ? items : []) {
      const cookie = String(item?.cookie || item?.value || "");
      if (!cookie) continue;
      const rawURL = String(item?.url || "").trim();
      const rawDomain = String(item?.domain || "").trim().replace(/^\./, "");
      if (rawURL) {
        this.setCookieHeader(cookie, rawURL);
        count += 1;
      } else if (rawDomain) {
        // 逐个 cookie 单独加 Domain，不能把 "a=b; c=d; Domain=x" 整串丢进去——
        // 那样只有最后一段带 Domain，前面的会被当成 host-only。
        for (const pair of cookie.split(";")) {
          const text = pair.trim();
          if (!text.includes("=")) continue;
          this.setCookieString(`${text}; Domain=${rawDomain}`, `https://${rawDomain}/`);
        }
        count += 1;
      }
    }
    return count;
  }

  remove(domain, name, path) {
    const group = this.domains.get(domain);
    if (!group) return;
    for (const key of [...group.keys()]) {
      const [cookiePath, cookieName] = key.split("\0");
      if (cookieName === name && (!path || cookiePath === path)) group.delete(key);
    }
    if (group.size === 0) this.domains.delete(domain);
  }

  /// 落盘用：只保留未过期的。
  snapshot() {
    const items = [];
    for (const [domain, group] of this.domains) {
      for (const cookie of group.values()) {
        if (cookie.expires !== null && cookie.expires <= Date.now()) continue;
        items.push({ domain, name: cookie.name, value: cookie.value, path: cookie.path, expires: cookie.expires });
      }
    }
    return items;
  }

  restore(items) {
    for (const item of Array.isArray(items) ? items : []) {
      const domain = String(item?.domain || "").toLowerCase();
      const name = String(item?.name || "");
      if (!domain || !name) continue;
      let group = this.domains.get(domain);
      if (!group) { group = new Map(); this.domains.set(domain, group); }
      group.set(`${item.path || "/"}\0${name}`, {
        name,
        value: String(item.value ?? ""),
        path: String(item.path || "/"),
        expires: Number.isFinite(item.expires) ? Number(item.expires) : null,
        hostOnly: false
      });
    }
  }

  get size() {
    let total = 0;
    for (const group of this.domains.values()) total += group.size;
    return total;
  }
}

/// 整个 bundle 进程共享的一份。fetch 垫片与 /v1/cookies 都指向它。
export const sharedCookies = new CookieJar();

export function assertCookieInput(payload) {
  if (!payload || typeof payload !== "object") {
    throw new GatewayError("INVALID_COOKIE_PAYLOAD", "Cookie 数据格式无效", 400);
  }
  return payload;
}
