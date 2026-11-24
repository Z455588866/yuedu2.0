// AList (and OpenList) v3 driver for the built-in "我的网盘" source.
//
// Ported from tvbox-silicon's `AList.swift` (GPL-3.0): the same public v3 API,
// the same recovery rules. A server is configured with its API address, the
// folder browsing starts in (`root`), an optional account (username/password)
// and an optional folder password. Tokens and folder passwords live for the
// lifetime of this module, as they do in the Swift host.
//
// The endpoint shapes are AList/OpenList's own; this is a re-implementation
// against those endpoints, not copied source.

const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

function text(value) {
  if (value === undefined || value === null) return "";
  const result = String(value);
  return result === "undefined" || result === "null" ? "" : result;
}
function number(value) {
  const result = Number(value);
  return Number.isFinite(result) ? result : 0;
}
async function readJSON(response) {
  const body = await response.text();
  if (!body) return {};
  try { return JSON.parse(body); } catch { return {}; }
}

/// "https://host/alist" takes the account before the path; the path that is
/// left after the API prefix is where browsing starts.
function splitAddress(raw) {
  let url;
  try { url = new URL(String(raw || "").trim()); } catch { return null; }
  if (!["http:", "https:"].includes(url.protocol)) return null;
  return url;
}

function baseOf(url) {
  const parts = new URL(url.href);
  parts.pathname = parts.pathname.replace(/\/$/, "");
  parts.search = ""; parts.hash = "";
  return parts.href.replace(/\/$/, "");
}

/// "/" or "/a/b", without a trailing slash; percent-decoded once. Matches
/// `AListServer.folder`.
export function alistFolder(path) {
  const parts = String(path || "").split("/").filter(Boolean).map((part) => {
    try { return decodeURIComponent(part); } catch { return part; }
  });
  return "/" + parts.join("/");
}

/// Parse a TVBox AList configuration — a bare array of `{name, server, password,
/// path, login}` or a `{"drives": [...]}` wrapper — as FongMi's AList spider
/// reads it. A subscription (`sites`/`lives`) is left alone.
export function alistServersFromConfig(raw) {
  let json;
  try { json = typeof raw === "string" ? JSON.parse(raw) : raw; } catch { return []; }
  const wrapper = json && !Array.isArray(json) && json.sites == null && json.lives == null ? json : null;
  const entries = Array.isArray(json) ? json : (Array.isArray(wrapper?.drives) ? wrapper.drives : []);
  const servers = [];
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    const url = splitAddress(entry.server ?? entry.address);
    if (!url) continue;
    const path = (typeof entry.path === "string" && entry.path.trim()) ? entry.path : url.pathname;
    const address = baseOf(url);
    const login = entry.login && typeof entry.login === "object" ? entry.login : {};
    servers.push({
      id: typeof entry.id === "string" && entry.id ? entry.id : `alist-${address}-${alistFolder(path)}`,
      name: (typeof entry.name === "string" && entry.name.trim()) || url.hostname || address,
      address,
      root: alistFolder(path),
      username: text(login.username),
      password: text(login.password),
      folderPassword: text(entry.password),
      kind: ["alist", "webdav", "emby", "fnos"].includes(entry.kind) ? entry.kind : "alist"
    });
  }
  return servers;
}

/// Probe whether a URL serves an AList/OpenList API, trying the host root and
/// up to two path prefixes (`AList.probe`). Returns a server descriptor or null.
export async function alistProbe(rawURL, fetchValue = fetch) {
  const url = splitAddress(rawURL);
  if (!url) return null;
  const segments = url.pathname.split("/").filter(Boolean);
  const base = baseOf(url);
  for (let depth = 0; depth <= Math.min(segments.length, 2); depth += 1) {
    const prefix = segments.slice(0, depth).map((s) => "/" + s).join("");
    const endpoint = `${base}${prefix}/api/public/settings`;
    try {
      const response = await fetchValue(endpoint, {
        headers: { "User-Agent": UA },
        signal: AbortSignal.timeout(8000)
      });
      const answer = await readJSON(response);
      if (number(answer.code) !== 200 || !answer.data || typeof answer.data !== "object") continue;
      const title = text(answer.data.site_title).trim();
      const name = !title || ["AList", "OpenList"].includes(title) ? url.hostname : title;
      const rootPath = segments.slice(depth).join("/");
      return { id: `alist-${base}${prefix}-${alistFolder(rootPath)}`, name, address: `${base}${prefix}`,
               root: alistFolder(rootPath), username: "", password: "", folderPassword: "", kind: "alist" };
    } catch { /* try the next depth */ }
  }
  return null;
}

/// A session for one server: token cache + folder-password cache, shared by
/// the list/search/link calls that come through this module.
export function createAListSession(server, fetchValue = fetch) {
  const tokens = { value: null, username: server.username || "", password: server.password || "" };
  const passwords = {};

  function folderPassword(path) {
    let folder = String(path || "");
    while (true) {
      if (Object.prototype.hasOwnProperty.call(passwords, folder)) return passwords[folder];
      if (folder === "/" || folder === "") return server.folderPassword || "";
      const index = folder.lastIndexOf("/");
      folder = index <= 0 ? "/" : folder.slice(0, index);
    }
  }

  async function login() {
    const response = await fetchValue(`${server.address}/api/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "User-Agent": UA },
      body: JSON.stringify({ username: server.username || "", password: server.password || "" }),
      signal: AbortSignal.timeout(20000)
    });
    const answer = await readJSON(response);
    const token = text(answer.data?.token);
    if (number(answer.code) !== 200 || !token) {
      throw new Error(`${server.name}没有接受这个账号和密码（${text(answer.message) || `code ${text(answer.code)}`}）`);
    }
    tokens.value = token;
    tokens.username = server.username || "";
    tokens.password = server.password || "";
    return token;
  }

  async function call(endpoint, body, retry = true) {
    const url = `${server.address}${endpoint}`;
    const headers = { "Content-Type": "application/json", "User-Agent": UA };
    if (tokens.value) headers.Authorization = tokens.value;
    const response = await fetchValue(url, {
      method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(20000)
    });
    const answer = await readJSON(response);
    const code = number(answer.code);
    const message = text(answer.message);
    if (code === 200) return answer.data && typeof answer.data === "object" ? answer.data : {};
    // A guest that may not browse, or an expired token: sign in once, then retry.
    if (code === 401) {
      if (!retry || !server.username) throw new Error(`请先为${server.name}填写账号密码`);
      await login();
      return call(endpoint, body, false);
    }
    if (code === 403 && /password/i.test(message)) {
      const error = new Error("这个文件夹需要密码");
      error.code = "ALIST_PASSWORD_REQUIRED";
      throw error;
    }
    throw new Error(`${server.name}：${message || `服务返回 ${code}`}`);
  }

  async function list(folder = server.root, password) {
    if (typeof password === "string" && password) passwords[folder] = password;
    const data = await call("/api/fs/list", {
      path: folder, password: folderPassword(folder), page: 1, per_page: 0, refresh: false
    });
    const items = Array.isArray(data.content) ? data.content : [];
    return items.map((item) => {
      const name = text(item.name);
      if (!name) return null;
      const id = (folder === "/" ? "" : folder.replace(/\/$/, "")) + "/" + name;
      return { id, name, isFolder: item.is_dir === true, size: number(item.size) };
    }).filter(Boolean);
  }

  async function search(keywords, page = 1, size = 50) {
    let data;
    try {
      data = await call("/api/fs/search", {
        parent: server.root, keywords, scope: 0, page, per_page: size, password: folderPassword(server.root)
      });
    } catch (error) {
      if (/search not available/i.test(error.message || "")) {
        throw new Error(`${server.name}没有开启搜索，管理员可以在 AList 设置里建立搜索索引`);
      }
      throw error;
    }
    const files = (Array.isArray(data.content) ? data.content : []).map((item) => {
      const name = text(item.name);
      let parent = text(item.parent).replace(/\/+$/, "");
      if (!name || !parent) return null;
      return { id: parent + "/" + name, name, isFolder: item.is_dir === true, size: number(item.size) };
    }).filter(Boolean);
    return { files, total: number(data.total) || files.length };
  }

  /// Where the file's bytes are. A storage's own `raw_url` wins; otherwise the
  /// server's `/d<path>` download address (with `sign`) is used. localhost links
  /// are rewritten to the address the server was added with (`AList.reachable`).
  async function link(file) {
    const folder = file.id.includes("/") ? file.id.slice(0, file.id.lastIndexOf("/")) || "/" : "/";
    const data = await call("/api/fs/get", { path: file.id, password: folderPassword(folder) });
    const size = number(data.size);
    let address = typeof data.raw_url === "string" ? data.raw_url : "";
    if (!/^https?:/i.test(address)) {
      const download = new URL(server.address);
      download.pathname = download.pathname.replace(/\/$/, "") + "/d" + (file.id.startsWith("/") ? file.id : "/" + file.id);
      const sign = text(data.sign);
      if (sign) download.searchParams.set("sign", sign);
      address = download.href;
    }
    try {
      const parsed = new URL(address);
      if (["localhost", "127.0.0.1", "0.0.0.0", "::1"].includes(parsed.hostname)) {
        const base = new URL(server.address);
        if (!["localhost", "127.0.0.1"].includes(base.hostname)) {
          parsed.protocol = base.protocol; parsed.hostname = base.hostname; parsed.port = base.port;
          address = parsed.href;
        }
      }
    } catch { /* not a URL; hand it back as-is */ }
    // Baidu's servers only answer their own client; FongMi's AList spider sends this.
    const headers = /baidupcs\.com/i.test((() => { try { return new URL(address).hostname; } catch { return ""; } })())
      ? { "User-Agent": "pan.baidu.com" } : {};
    return { url: address, headers, length: size };
  }

  return { server, login, call, list, search, link, folderPassword };
}

/// Turn a saved server descriptor into a drive object understood by
/// `cloud-files.mjs` and `pan-drivers.mjs`.
export function alistDrive(server, fetchValue = fetch) {
  const session = createAListSession(server, fetchValue);
  return {
    key: `alist.${server.id}`,
    name: server.name,
    credentialField: "alistConfig",
    root: server.root,
    kind: server.kind,
    list: (_credentials, folder) => session.list(folder && folder !== "0" ? folder : server.root),
    link: (_credentials, file) => session.link(file),
    search: (keywords, page, size) => session.search(keywords, page, size),
    probe: (url) => alistProbe(url, fetchValue),
    session
  };
}

export const alistTestSupport = { splitAddress, baseOf, alistFolder, alistServersFromConfig, createAListSession };
