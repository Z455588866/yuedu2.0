// Cloud-drive drivers for the built-in "我的网盘" source.
//
// Each drive answers two questions: what is in a folder, and where the bytes of
// one file are. Everything else (listing a folder, turning it into episodes,
// handing AVPlayer a link) is `cloud-files.mjs`.
//
// The protocols follow tvbox-silicon's `TianyiFiles` / `BaiduFiles` /
// `QuarkFiles` / `Pan123Files` (GPL-3.0). They are re-implemented here against
// the same public endpoints rather than copied, so this module stays ours; the
// endpoint shapes are what the vendors' own web and TV clients use.

import { createHash, createHmac } from "node:crypto";

const BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
const VIDEO_EXTENSIONS = new Set(["mp4", "mkv", "mov", "m4v", "avi", "ts", "m2ts", "webm", "flv", "wmv", "rmvb", "mpg", "mpeg", "3gp"]);

export function fileKind(name) {
  const extension = String(name || "").split(".").pop()?.toLowerCase() || "";
  if (VIDEO_EXTENSIONS.has(extension) || extension === "m3u8") return "video";
  if (["mp3", "m4a", "aac", "flac", "wav", "ape", "ogg"].includes(extension)) return "audio";
  if (["srt", "ass", "ssa", "vtt"].includes(extension)) return "subtitle";
  return "other";
}

export function isPlayable(name) {
  return ["video", "audio"].includes(fileKind(name));
}

/// Cookies as one `Cookie` header, kept current with what responses set. Quark
/// and Baidu rotate `__puus` / `STOKEN` on nearly every answer and refuse the
/// CDN without the newest one, so the jar has to outlive a single request.
class CookieJar {
  constructor(header = "") {
    this.order = [];
    this.values = {};
    for (const part of String(header || "").split(";")) {
      const index = part.indexOf("=");
      if (index <= 0) continue;
      this.set(part.slice(0, index).trim(), part.slice(index + 1).trim());
    }
  }

  set(name, value) {
    if (!name) return;
    if (!(name in this.values)) this.order.push(name);
    this.values[name] = value;
  }

  get header() {
    return this.order.map((name) => `${name}=${this.values[name]}`).join("; ");
  }

  absorb(response) {
    const values = typeof response.headers.getSetCookie === "function"
      ? response.headers.getSetCookie()
      : [response.headers.get("set-cookie")].filter(Boolean);
    for (const line of values) {
      for (const cookie of String(line).split(/,(?=[^;]+=)/u)) {
        const pair = cookie.split(";")[0];
        const index = pair.indexOf("=");
        if (index <= 0) continue;
        this.set(pair.slice(0, index).trim(), pair.slice(index + 1).trim());
      }
    }
  }
}

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
  try {
    return JSON.parse(body);
  } catch {
    return {};
  }
}

// ---------------------------------------------------------------- 天翼云盘

/// The TV app's key pair; requests before a session exist are signed with it.
const TIANYI = {
  api: "https://api.cloud.189.cn",
  appKey: "600100885",
  appSecret: "fe5734c74c2f96a38157f420b32dc995",
  userAgent: "EcloudTV/6.5.5 (PJX110; unknown; home02) Android/35",
  client: [
    ["clientType", "FAMILY_TV"], ["version", "6.5.5"], ["channelId", "home02"], ["clientSn", "unknown"],
    ["model", "PJX110"], ["osFamily", "Android"], ["osVersion", "35"], ["networkAccessMode", "WIFI"],
    ["telecomsOperator", "46011"]
  ],
  root: "-11",
  pageSize: 130
};

const HTTP_DATE_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const HTTP_DATE_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function httpDate(date) {
  const pad = (value) => String(value).padStart(2, "0");
  return `${HTTP_DATE_DAYS[date.getUTCDay()]}, ${pad(date.getUTCDate())} ${HTTP_DATE_MONTHS[date.getUTCMonth()]} `
    + `${date.getUTCFullYear()} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())} GMT`;
}

function tianyiSignature(secret, value) {
  return createHmac("sha1", secret).update(value, "utf8").digest("hex").toUpperCase();
}

function tianyiAddress(path, query) {
  const url = new URL(TIANYI.api + path);
  for (const [key, value] of [...TIANYI.client, ...query]) url.searchParams.append(key, String(value));
  // A `+` in a value would read as a space once it is in the query.
  return url.toString().replace(/\+/gu, "%2B");
}

/// The session a saved access token opens. Cached for the life of the process:
/// it is what every request afterwards is signed with.
const tianyiSessions = new Map();

async function tianyiSession(token) {
  const cached = tianyiSessions.get(token);
  if (cached) return cached;
  const path = "/family/manage/loginFamilyMerge.action";
  const timestamp = String(Date.now());
  const url = tianyiAddress(path, [["e189AccessToken", token]]);
  const response = await fetch(url, {
    headers: {
      Timestamp: timestamp,
      "X-Request-ID": randomUUID(),
      AppKey: TIANYI.appKey,
      AppSignature: tianyiSignature(TIANYI.appSecret, `AppKey=${TIANYI.appKey}&Operate=GET&RequestURI=${path}&Timestamp=${timestamp}`),
      Accept: "application/json;charset=UTF-8",
      "User-Agent": TIANYI.userAgent
    }
  });
  const answer = await readJSON(response);
  const key = text(answer.sessionKey);
  const secret = text(answer.sessionSecret);
  if (!key || !secret) {
    throw new Error(`天翼云盘登录已失效（${text(answer.res_msg) || text(answer.res_message) || "没有拿到会话"}），请重新填写 TV 版 Access Token`);
  }
  const session = { key, secret };
  tianyiSessions.set(token, session);
  return session;
}

async function tianyiCall(token, path, query) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const session = await tianyiSession(token);
    const date = httpDate(new Date());
    const response = await fetch(tianyiAddress(path, query), {
      headers: {
        Date: date,
        SessionKey: session.key,
        "X-Request-ID": randomUUID(),
        Signature: tianyiSignature(session.secret, `SessionKey=${session.key}&Operate=GET&RequestURI=${path}&Date=${date}`),
        Accept: "application/json;charset=UTF-8",
        "User-Agent": TIANYI.userAgent
      }
    });
    const body = await response.text();
    // An expired session: drop it and sign in once more from the saved token.
    if (body.includes("InvalidSessionKey") || body.includes("userSessionBO is null")) {
      tianyiSessions.delete(token);
      continue;
    }
    const answer = (() => { try { return JSON.parse(body) || {}; } catch { return {}; } })();
    const failure = tianyiFailure(answer);
    if (failure) throw new Error(`天翼云盘：${failure}`);
    if (!response.ok) throw new Error(`天翼云盘 HTTP ${response.status}`);
    return answer;
  }
  throw new Error("天翼云盘登录已失效，请重新填写 TV 版 Access Token");
}

function tianyiFailure(answer) {
  if (answer.res_code !== undefined && answer.res_code !== null) {
    const code = String(answer.res_code);
    if (code === "0" || code === "") return "";
    return text(answer.res_message) || code;
  }
  if (text(answer.errorCode)) return text(answer.errorMsg) || text(answer.errorCode);
  if (text(answer.code) && text(answer.code) !== "SUCCESS") return text(answer.msg) || text(answer.message) || text(answer.code);
  return "";
}

const tianyi = {
  key: "tianyi",
  name: "天翼云盘",
  credentialField: "tianyiToken",
  root: TIANYI.root,
  async list(token, folder = TIANYI.root) {
    const files = [];
    for (let page = 1; page <= 50; page += 1) {
      const answer = await tianyiCall(token, "/listFiles.action", [
        ["folderId", folder || TIANYI.root], ["fileType", "0"], ["mediaAttr", "0"], ["iconOption", "5"],
        ["pageNum", String(page)], ["pageSize", String(TIANYI.pageSize)], ["recursive", "0"],
        ["orderBy", "filename"], ["descending", "false"]
      ]);
      const listing = answer.fileListAO || answer;
      const page_files = [
        ...(Array.isArray(listing.folderList) ? listing.folderList : []).map((item) => tianyiFile(item, true)),
        ...(Array.isArray(listing.fileList) ? listing.fileList : []).map((item) => tianyiFile(item, false))
      ].filter(Boolean);
      files.push(...page_files);
      if (page_files.length < TIANYI.pageSize) break;
    }
    return files;
  },
  async link(token, file) {
    const answer = await tianyiCall(token, "/getFileDownloadUrl.action", [["fileId", file.id], ["dt", "3"], ["flag", "1"]]);
    let address = text(answer.fileDownloadUrl).replace(/&amp;/gu, "&");
    if (address.startsWith("http://")) address = `https://${address.slice(7)}`;
    if (!address) throw new Error("天翼云盘没有返回这个文件的地址");
    const headers = { "User-Agent": TIANYI.userAgent };
    const resolved = await followLink(address, headers);
    return { ...resolved, headers };
  }
};

function tianyiFile(item, isFolder) {
  const id = text(item.id);
  const name = text(item.name);
  if (!id || !name) return null;
  return { id, name, isFolder, size: isFolder ? 0 : number(item.size) };
}

// ---------------------------------------------------------------- 百度网盘

const BAIDU = {
  api: "https://pan.baidu.com/api",
  appID: "250528",
  userAgent: BROWSER_UA,
  /// Download links are only handed to this agent; anything else gets a 403.
  downloadAgent: "pan.baidu.com",
  pageSize: 1000,
  qualities: ["M3U8_AUTO_1080", "M3U8_AUTO_720", "M3U8_AUTO_480"]
};

function baiduAddress(path, query, web = "1") {
  const all = [...query, ["app_id", BAIDU.appID], ["channel", "chunlei"], ["clienttype", "0"], ["web", web]];
  const kept = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/";
  const encoded = all.map(([key, value]) => `${key}=${encodeURIComponent(String(value)).replace(
    /[!'()*]/gu, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)}`).join("&");
  return `${BAIDU.api}${path}?${encoded}`;
}

async function baiduFetch(credentials, url, jar) {
  const saved = text(credentials.baiduCookie);
  if (!saved.includes("BDUSS")) throw new Error("还没有填写百度网盘 Cookie（需要 BDUSS）");
  const headers = { Cookie: jar.header, "User-Agent": BAIDU.userAgent, Referer: "https://pan.baidu.com/disk/home" };
  const response = await fetch(url, { headers });
  jar.absorb(response);
  return response;
}

async function baiduJSON(credentials, jar, path, query, web = "1") {
  const response = await baiduFetch(credentials, baiduAddress(path, query, web), jar);
  const answer = await readJSON(response);
  const code = number(answer.errno);
  if (code === 0 && response.ok) return answer;
  const message = text(answer.errmsg) || text(answer.show_msg);
  if ([-6, 9019, 31045].includes(code) || response.status === 401) {
    throw new Error(`百度网盘登录已失效（${message || `errno ${code}`}），请重新填写 Cookie`);
  }
  throw new Error(`百度网盘：${message || `errno ${code}`}`);
}

const baidu = {
  key: "baidu",
  name: "百度网盘",
  credentialField: "baiduCookie",
  root: "/",
  async list(credentials, folder = "/") {
    const jar = new CookieJar(credentials.baiduCookie);
    const files = [];
    for (let page = 1; page <= 50; page += 1) {
      const answer = await baiduJSON(credentials, jar, "/list", [
        ["dir", folder || "/"], ["order", "name"], ["desc", "0"], ["showempty", "0"],
        ["page", String(page)], ["num", String(BAIDU.pageSize)]
      ]);
      const items = Array.isArray(answer.list) ? answer.list : [];
      files.push(...items.map(baiduFile).filter(Boolean));
      if (items.length < BAIDU.pageSize) break;
    }
    return files;
  },
  /// The drive's own HLS copy when it has one — Baidu throttles downloads of
  /// the original for accounts without a membership but streams the copy at
  /// full speed — otherwise the original file.
  async link(credentials, file) {
    const jar = new CookieJar(credentials.baiduCookie);
    if (fileKind(file.name) === "video") {
      const copy = await baiduPlaylist(credentials, jar, file.id);
      if (copy) return copy;
    }
    const target = JSON.stringify([file.id]);
    const answer = await baiduJSON(credentials, jar, "/filemetas", [
      ["target", target], ["dlink", "1"], ["origin", "dlna"]
    ], "5");
    const item = Array.isArray(answer.info) ? answer.info[0] : null;
    const address = text(item?.dlink);
    if (!address) throw new Error("百度网盘没有返回这个文件的下载地址");
    return {
      url: address,
      headers: { Cookie: jar.header, "User-Agent": BAIDU.downloadAgent },
      length: number(item?.size)
    };
  }
};

function baiduFile(item) {
  const path = text(item.path);
  if (!path) return null;
  const name = text(item.server_filename) || path.split("/").pop();
  if (!name) return null;
  return { id: path, name, isFolder: number(item.isdir) === 1, size: number(item.size) };
}

async function baiduPlaylist(credentials, jar, path) {
  let token = "";
  for (const quality of BAIDU.qualities) {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const query = [["path", path], ["type", quality]];
      if (token) query.push(["adToken", token]);
      const url = baiduAddress("/streaming", query);
      const response = await baiduFetch(credentials, url, jar);
      const body = await response.text();
      if (body.trimStart().startsWith("#EXTM3U")) {
        return { url, headers: { Cookie: jar.header, "User-Agent": BAIDU.userAgent }, length: 0 };
      }
      let answer = {};
      try { answer = JSON.parse(body) || {}; } catch { answer = {}; }
      const code = number(answer.errno ?? -1);
      if ([-6, 9019, 31045].includes(code)) throw new Error("百度网盘登录已失效，请重新填写 Cookie");
      // A free account is asked to watch an ad first (errno 133); the answer
      // hands back a token that makes the next ask succeed.
      if (code === 133 && text(answer.adToken) && text(answer.adToken) !== token) {
        token = text(answer.adToken);
        const wait = Math.min(Math.max(number(answer.adTime), 0), 30);
        if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait * 1000));
        continue;
      }
      break;
    }
  }
  return null;
}

// ---------------------------------------------------------------- 夸克 / UC

const QUARK = {
  quark: {
    api: "https://drive-pc.quark.cn/1/clouddrive",
    query: "pr=ucpro&fr=pc&uc_param_str=",
    referer: "https://pan.quark.cn/",
    name: "夸克网盘"
  },
  uc: {
    api: "https://pc-api.uc.cn/1/clouddrive",
    query: "pr=UCBrowser&fr=pc&uc_param_str=",
    referer: "https://drive.uc.cn/",
    name: "UC网盘"
  }
};

async function quarkCall(service, cookie, path, body) {
  const jar = new CookieJar(cookie);
  const url = `${service.api}${path}`;
  const headers = { Cookie: jar.header, "User-Agent": BROWSER_UA, Referer: service.referer };
  const options = { method: body ? "POST" : "GET", headers };
  if (body) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const response = await fetch(url, options);
  jar.absorb(response);
  const answer = await readJSON(response);
  if (number(answer.code) === 0 && response.ok) return answer;
  const message = text(answer.message);
  if (response.status === 401 || number(answer.code) === 31001 || /login/iu.test(message)) {
    throw new Error(`${service.name}登录已失效（${message || `code ${answer.code}`}），请重新填写 Cookie`);
  }
  throw new Error(`${service.name}：${message || `code ${answer.code}`}`);
}

function quarkDrive(key) {
  const service = QUARK[key];
  return {
    key,
    name: service.name,
    credentialField: key === "quark" ? "quarkCookie" : "ucCookie",
    root: "0",
    async list(credentials, folder = "0") {
      const cookie = text(credentials[key === "quark" ? "quarkCookie" : "ucCookie"]);
      if (!cookie) throw new Error(`还没有填写${service.name} Cookie`);
      const files = [];
      for (let page = 1; page <= 50; page += 1) {
        const answer = await quarkCall(service, cookie,
          `/file/sort?${service.query}&pdir_fid=${encodeURIComponent(folder || "0")}&_page=${page}&_size=100`
          + "&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc");
        const items = Array.isArray(answer.data?.list) ? answer.data.list : [];
        files.push(...items.map(quarkFile).filter(Boolean));
        const total = number(answer.metadata?._total);
        if (items.length === 0 || (total > 0 && files.length >= total)) break;
      }
      return files;
    },
    async link(credentials, file) {
      const cookie = text(credentials[key === "quark" ? "quarkCookie" : "ucCookie"]);
      if (!cookie) throw new Error(`还没有填写${service.name} Cookie`);
      const answer = await quarkCall(service, cookie, `/file/download?${service.query}`, { fids: [file.id] });
      const item = Array.isArray(answer.data) ? answer.data[0] : null;
      const address = text(item?.download_url);
      if (!address) throw new Error(`${service.name}没有返回这个文件的地址，请稍后再试`);
      return {
        url: address,
        headers: { Cookie: new CookieJar(cookie).header, "User-Agent": BROWSER_UA, Referer: service.referer },
        length: number(item?.size)
      };
    }
  };
}

function quarkFile(item) {
  const id = text(item.fid);
  const name = text(item.file_name);
  if (!id || !name) return null;
  return { id, name, isFolder: item.dir === true, size: number(item.size) };
}

// ---------------------------------------------------------------- 123 云盘

const PAN123 = {
  api: "https://yun.123pan.com/b/api",
  headers: (token) => ({
    Authorization: `Bearer ${token}`,
    Origin: "https://yun.123pan.com",
    Referer: "https://yun.123pan.com/",
    "User-Agent": BROWSER_UA
  })
};

const pan123 = {
  key: "pan123",
  name: "123 云盘",
  credentialField: "pan123Token",
  root: "0",
  async list(credentials, folder = "0") {
    const token = text(credentials.pan123Token);
    if (!token) throw new Error("还没有填写 123 云盘 Token");
    const files = [];
    for (let page = 1; page <= 50; page += 1) {
      const url = `${PAN123.api}/file/list/new?driveId=0&limit=100&next=0&orderBy=file_name&orderDirection=asc`
        + `&parentFileId=${encodeURIComponent(folder || "0")}&trashed=false&SearchData=&Page=${page}&NeverSort=0&type=0`;
      const response = await fetch(url, { headers: PAN123.headers(token) });
      const answer = await readJSON(response);
      if (number(answer.code) !== 0) {
        if ([401, 403].includes(response.status) || number(answer.code) === 401) {
          throw new Error("123 云盘 Token 已过期（有效期约 90 天），请重新填写");
        }
        throw new Error(`123 云盘：${text(answer.message) || `code ${answer.code}`}`);
      }
      const items = Array.isArray(answer.data?.InfoList) ? answer.data.InfoList : [];
      files.push(...items.map((item) => {
        const id = text(item.FileId);
        const name = text(item.FileName);
        if (!id || !name) return null;
        return { id, name, isFolder: number(item.Type) === 1, size: number(item.Size) };
      }).filter(Boolean));
      if (items.length < 100) break;
    }
    return files;
  },
  async link(credentials, file) {
    const token = text(credentials.pan123Token);
    if (!token) throw new Error("还没有填写 123 云盘 Token");
    const url = `${PAN123.api}/file/download_info?` + new URLSearchParams({
      driveId: "0", etag: "", fileId: file.id, s3keyFlag: "", type: "0", fileName: file.name, size: String(file.size || 0)
    }).toString();
    const response = await fetch(url, { headers: PAN123.headers(token) });
    const answer = await readJSON(response);
    let address = text(answer.data?.DownloadUrl) || text(answer.data?.DownloadURL);
    if (!address) throw new Error(`123 云盘：${text(answer.message) || "没有返回下载地址"}`);
    // The answer wraps the address in a signed URL whose `params` names it.
    try {
      const wrapped = new URL(address);
      const params = wrapped.searchParams.get("params");
      if (params) {
        const decoded = Buffer.from(params, "base64").toString("utf8");
        if (/^https?:/u.test(decoded)) address = decoded;
      }
    } catch { /* Not wrapped; use it as it is. */ }
    return { url: address, headers: { Referer: "https://yun.123pan.com/" }, length: number(file.size) };
  }
};

// ---------------------------------------------------------------- 公共

/// Follows a download link to where the bytes are: the address after its
/// redirects, and the file's length from a one-byte range request. A link may
/// answer with JSON naming the address instead (`redirect_url`).
export async function followLink(address, headers, hops = 0) {
  const response = await fetch(address, { headers: { ...headers, Range: "bytes=0-0" }, redirect: "follow" });
  const type = response.headers.get("content-type") || "";
  if (type.includes("json") && hops < 2) {
    const answer = await readJSON(response);
    const next = text(answer.data?.redirect_url) || text(answer.redirect_url);
    if (next) return followLink(next, headers, hops + 1);
  }
  if (!response.ok && response.status !== 206) throw new Error(`下载地址打不开（HTTP ${response.status}）`);
  const range = response.headers.get("content-range") || "";
  const total = Number(range.split("/").pop());
  const length = Number.isFinite(total) && total > 0 ? total : Number(response.headers.get("content-length") || 0);
  return { url: response.url || address, length };
}

export const panDrives = {
  tianyi,
  baidu,
  quark: quarkDrive("quark"),
  uc: quarkDrive("uc"),
  pan123
};

export function driveFor(key) {
  return panDrives[String(key || "").toLowerCase()] || null;
}

/// Drives the person has signed in to, in the order they are offered.
export function signedInDrives(credentials = {}) {
  const order = ["quark", "uc", "tianyi", "baidu", "pan123"];
  return order.map(driveFor).filter((drive) => drive && text(credentials[drive.credentialField]).length > 1);
}

export const panDriveTestSupport = { CookieJar, baiduAddress, tianyiSignature, quarkFile, baiduFile };

// `crypto.randomUUID` is only on `crypto`, not on the global namespace of every
// runtime this module is bundled into.
function randomUUID() {
  const bytes = createHash("sha256").update(`${Date.now()}-${Math.random()}`).digest();
  const hex = bytes.toString("hex").slice(0, 32).split("");
  hex[12] = "4";
  return `${hex.slice(0, 8).join("")}-${hex.slice(8, 12).join("")}-${hex.slice(12, 16).join("")}`
    + `-${hex.slice(16, 20).join("")}-${hex.slice(20, 32).join("")}`;
}
