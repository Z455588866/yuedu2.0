import { GatewayError } from "./errors.mjs";

/// 把 CatVod 的 `player` 返回里那些「不是分享页、就是一条能播的地址」挑出来直接播。
///
/// 现实里这批接口（Lee / Austin / 豆儿…）大量线路是两种形态：
///   1. 已经解析好的 CDN 直链，如 `https://dl-uf-zb.pds.uc.cn/…`
///   2. 插件自己起的本地代理，如 `http://127.0.0.1:33803/spider/bdjuhe/3/proxy/quark/…`
/// 两者都不需要网盘账号，只要带上对应的 UA/Referer 就能出流。以前这里对任何
/// 非夸克的 providerId 直接抛「未接入」，把这两类本来能播的线路也一起挡掉了。

const BROWSER_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
  + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

/// 这些域名下的 `/s/…`、`/web/share` 是分享页，必须走各自的解析，不能直接播。
const SHARE_HOSTS = new Set([
  "pan.baidu.com", "yun.baidu.com",
  "pan.quark.cn", "drive.uc.cn", "fast.uc.cn",
  "cloud.189.cn", "h5.cloud.189.cn",
  "115.com", "115cdn.com", "anxia.com",
  "123pan.com", "123684.com", "123865.com", "123912.com", "www.123pan.com"
]);

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

/// 把 episode 里所有字符串摊平。各家 jar 塞进 `playToken` 的字段名并不统一
/// （surl / shareId / url / playUrl / downloadUrl…），逐字段猜必然漏，直接扫。
function collectStrings(value, depth = 0, out = []) {
  if (depth > 6 || out.length > 64) return out;
  if (typeof value === "string") {
    // `playToken` 常常是一段 JSON 字符串，直接当文本收集会漏掉里面的地址。
    const trimmed = value.trim();
    if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
      try { collectStrings(JSON.parse(trimmed), depth + 1, out); return out; } catch { /* 不是 JSON，按普通字符串处理 */ }
    }
    if (value.length <= 8192) out.push(value);
    return out;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, depth + 1, out);
    return out;
  }
  if (value && typeof value === "object") {
    for (const item of Object.values(value)) collectStrings(item, depth + 1, out);
  }
  return out;
}

function playbackHeaders(url) {
  let host = "";
  try { host = new URL(url).hostname.toLowerCase(); } catch { return {}; }
  if (host === "127.0.0.1" || host === "localhost") {
    // 插件自己的代理，只认它自己，别塞多余的头。
    return {};
  }
  if (host.endsWith("pds.uc.cn") || host.endsWith("uc.cn")) {
    return { "User-Agent": BROWSER_UA, Referer: "https://drive.uc.cn/" };
  }
  if (host.endsWith("baidupcs.com") || host.endsWith("baidu.com")) {
    return { "User-Agent": "pan.baidu.com", Referer: "https://pan.baidu.com/" };
  }
  if (host.endsWith("quark.cn")) {
    return { "User-Agent": BROWSER_UA, Referer: "https://pan.quark.cn/" };
  }
  if (host.endsWith("189.cn")) {
    return { "User-Agent": BROWSER_UA, Referer: "https://cloud.189.cn/" };
  }
  if (host.endsWith("115.com") || host.endsWith("115cdn.com") || host.endsWith("anxia.com")) {
    return { "User-Agent": BROWSER_UA, Referer: "https://115.com/" };
  }
  if (host.endsWith("123pan.com") || host.endsWith("123684.com")
      || host.endsWith("123865.com") || host.endsWith("123912.com")) {
    return { "User-Agent": BROWSER_UA, Referer: "https://www.123pan.com/" };
  }
  return {};
}

function isSharePage(url) {
  let parsed;
  try { parsed = new URL(url); } catch { return false; }
  const host = parsed.hostname.toLowerCase();
  if (!SHARE_HOSTS.has(host)) return false;
  // `?download=1` 之类的已经从分享页转成直链，仍按直链处理。
  return !/\.(m3u8|mp4|mkv|flv|ts)(\?|$)/i.test(parsed.pathname);
}

/// 插件自己的媒体代理地址里，`pst` 参数是 base64url 的 `{url, headers}`：真实
/// 网盘直链和它需要的请求头。影匣（tvbox-silicon）靠它把 4K 文件的字节从 Node
/// 里挪出来——Node 只负责登录和解析，字节由播放器直连 CDN，否则中转会把手机上
/// 的 Node 堆撑爆（它的 #530）。
export function revealedLink(raw) {
  let parsed;
  try { parsed = new URL(raw); } catch { return null; }
  if (!["127.0.0.1", "localhost"].includes(parsed.hostname)) return null;
  if (!/^\/spider\/[^/]+\/[^/]+\/proxy\//.test(parsed.pathname)) return null;
  const value = parsed.searchParams.get("pst");
  if (!value) return null;
  let base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  base64 += "=".repeat((4 - (base64.length % 4)) % 4);
  try {
    const payload = JSON.parse(Buffer.from(base64, "base64").toString("utf8"));
    const url = String(payload?.url || "");
    if (!/^https?:\/\//i.test(url)) return null;
    const header = {};
    for (const [name, item] of Object.entries(payload?.headers || {})) {
      if (typeof item === "string" && item) header[name] = item;
    }
    return { url, header };
  } catch {
    return null;
  }
}

/// 从 episode 描述里挑一条可播地址。返回 null 表示这条 id 里没有直链。
export function directPlaybackFromEpisode(episode) {
  const candidates = collectStrings(episode);
  // 先看有没有「代理地址里藏着真实直链」的：能直连就不必让 Node 中转。
  for (const raw of candidates) {
    if (!/^https?:\/\//i.test(raw)) continue;
    const revealed = revealedLink(raw);
    if (revealed) return { parse: 0, jx: 0, url: revealed.url, header: revealed.header };
  }
  for (const raw of candidates) {
    if (!/^https?:\/\//i.test(raw)) continue;
    if (isSharePage(raw)) continue;
    const headers = playbackHeaders(raw);
    return { parse: 0, jx: 0, url: raw, header: headers };
  }
  return null;
}

/// 从 episode 描述里挑出分享页地址（给需要账号的解析用）。
export function shareURLFromEpisode(episode) {
  for (const raw of collectStrings(episode)) {
    if (/^https?:\/\//i.test(raw) && isSharePage(raw)) return raw;
  }
  return "";
}

/// 各家 jar 给文件 id 用的字段名不一样，按出现频率猜一轮。
export function fileIDFromEpisode(episode, providerID = "") {
  const token = (() => {
    const raw = episode?.playToken;
    if (typeof raw !== "string") return episode;
    try { return JSON.parse(raw); } catch { return episode; }
  })();
  const names = ["fid", "fs_id", "fsId", "fileId", "file_id", "fid_token", "fileID"];
  const scan = (value, depth = 0) => {
    if (!value || typeof value !== "object" || depth > 4) return "";
    for (const name of names) {
      const candidate = value[name];
      if (typeof candidate === "string" || typeof candidate === "number") {
        const text = String(candidate).trim();
        // 明显是 base64 令牌而不是数字 id 的跳过。
        if (text && text.length <= 64 && /^[\w-]+$/.test(text)) return text;
      }
    }
    for (const item of Object.values(value)) {
      const found = scan(item, depth + 1);
      if (found) return found;
    }
    return "";
  };
  return scan(token) || scan(episode);
}

// ------------------------------------------------------------------ 百度网盘

const BAIDU = {
  api: "https://pan.baidu.com/api",
  appID: "250528",
  userAgent: BROWSER_UA
};

function baiduURL(path, query) {
  const all = [...query, ["app_id", BAIDU.appID], ["channel", "chunlei"],
    ["clienttype", "0"], ["web", "1"]];
  const encoded = all
    .map(([key, value]) => `${key}=${encodeURIComponent(String(value))}`)
    .join("&");
  return `${BAIDU.api}${path}?${encoded}`;
}

function cookieValue(cookie, name) {
  const match = String(cookie || "").match(new RegExp(`(?:^|;\\s*)${name}=([^;]*)`));
  return match ? match[1] : "";
}

/// 百度分享：verify 拿 randsk/BDCLND → share/list 拿 uk 与文件 → filemetas 拿 dlink。
/// 没有会员的账号原画会被限速，所以先要 m3u8 转码流；失败再退回 dlink。
export async function playBaiduShare(shareURL, credentials, fetchValue, wantedFileID) {
  const cookie = text(credentials?.baiduCookie);
  if (!cookie || !cookie.includes("BDUSS")) {
    throw new GatewayError("CLOUD_AUTH_REQUIRED",
      "这条线路是百度网盘，请先在「猫源 → 网盘账号配置」里填写百度 Cookie（需要 BDUSS）", 401);
  }
  const parsed = new URL(shareURL);
  const surl = (parsed.pathname.match(/\/s\/([^/?#]+)/) || [])[1] || "";
  const password = parsed.searchParams.get("pwd") || "";
  if (!surl) {
    throw new GatewayError("CLOUD_SHARE_INVALID", "百度网盘分享地址无法识别", 400);
  }

  const jar = new Map();
  const absorb = (response) => {
    for (const line of String(response.headers.get("set-cookie") || "").split(/,(?=[^;]+=)/)) {
      const pair = line.split(";")[0];
      const index = pair.indexOf("=");
      if (index > 0) jar.set(pair.slice(0, index).trim(), pair.slice(index + 1).trim());
    }
  };
  const header = () => [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
  const call = async (url, options = {}) => {
    const cookies = [cookie, header()].filter(Boolean).join("; ");
    const response = await fetchValue(url, {
      redirect: "follow",
      ...options,
      headers: {
        Cookie: cookies,
        "User-Agent": BAIDU.userAgent,
        Referer: `https://pan.baidu.com/s/${surl}`,
        ...(options.headers || {})
      },
      signal: AbortSignal.timeout(20_000)
    });
    absorb(response);
    return response;
  };

  // 1) verify
  const timestamp = Date.now();
  const verify = await call(
    `https://pan.baidu.com/share/verify?surl=${encodeURIComponent(surl)}&t=${timestamp}`
      + `&channel=chunlei&web=1&app_id=${BAIDU.appID}&clienttype=0`,
    {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: `pwd=${encodeURIComponent(password)}&vcode=&vcode_str=`
    }
  );
  const verifyBody = await verify.json().catch(() => ({}));
  const errno = Number(verifyBody?.errno ?? -1);
  if (errno !== 0) {
    throw new GatewayError("CLOUD_SHARE_INVALID",
      errno === -9 ? "百度网盘分享提取码不正确"
        : errno === -62 ? "百度网盘分享已失效或被取消"
        : `百度网盘分享解析失败（errno ${errno}）`, 422);
  }
  if (verifyBody.randsk) jar.set("BDCLND", verifyBody.randsk);

  // 2) 列表：先根目录；目标不在根上就下钻两层（整季一般装在文件夹里）
  let uk = text(verifyBody.uk);
  const listDir = async (dir) => {
    const url = baiduURL("/share/list", [
      ["uk", uk], ["shareid", verifyBody.shareid || ""],
      ["order", "other"], ["desc", "1"], ["showempty", "0"],
      ["page", "1"], ["num", "1000"], ["dir", dir], ["t", String(timestamp)],
      ["bdstoken", ""], ["shorturl", surl], ["root", "1"]
    ]);
    const body = await (await call(url)).json().catch(() => ({}));
    uk = text(body?.uk) || uk;
    return Array.isArray(body?.list) ? body.list : [];
  };
  const isVideo = (item) => Number(item?.isdir) !== 1
    && /\.(mp4|mkv|avi|flv|ts|mov|m4v)$/i.test(text(item?.server_filename));
  const wanted = text(wantedFileID);

  let target = null;
  const roots = await listDir("/");
  if (wanted) target = roots.find((item) => String(item?.fs_id) === wanted) || null;
  if (!target) target = roots.find(isVideo) || null;
  if (!target) {
    for (const folder of roots.filter((item) => Number(item?.isdir) === 1).slice(0, 4)) {
      const children = await listDir(text(folder.path));
      target = (wanted && children.find((item) => String(item?.fs_id) === wanted))
        || children.find(isVideo) || null;
      if (target) break;
    }
  }
  if (!target) {
    throw new GatewayError("CLOUD_SHARE_EMPTY",
      "百度网盘分享里没有找到这个视频文件，请重新打开资源详情", 404);
  }

  // 3) 取流：优先 m3u8 转码（免会员也能流畅），再退回 dlink
  const streamURL = baiduURL("/streaming", [
    ["path", text(target.path)], ["type", "M3U8_AUTO_1080"],
    ["uk", uk], ["shareid", verifyBody.shareid || ""]
  ]);
  const streamResponse = await call(streamURL);
  const streamBody = await streamResponse.text();
  if (streamBody.trimStart().startsWith("#EXTM3U")) {
    return {
      parse: 0, jx: 0, url: streamURL,
      header: { Cookie: [cookie, header()].filter(Boolean).join("; "), "User-Agent": BAIDU.userAgent }
    };
  }

  const metaURL = baiduURL("/filemetas", [
    ["target", JSON.stringify([String(target.fs_id)])], ["dlink", "1"],
    ["origin", "dlna"], ["uk", uk], ["primaryid", verifyBody.shareid || ""]
  ]);
  const metaBody = await (await call(metaURL)).json().catch(() => ({}));
  const dlink = text(Array.isArray(metaBody?.info) ? metaBody.info[0]?.dlink : "");
  if (!dlink) {
    throw new GatewayError("CLOUD_PLAYBACK_FAILED",
      "百度网盘没有返回这个文件的播放地址（可能分享已过期）", 502);
  }
  return {
    parse: 0, jx: 0, url: dlink,
    header: { Cookie: [cookie, header()].filter(Boolean).join("; "), "User-Agent": "pan.baidu.com" }
  };
}
