import { createHash } from "node:crypto";
import { readBoundedJSON } from "./bounded-response.mjs";
import { GatewayError } from "./errors.mjs";

const CLOUD_PAN_API = "/spider/cloudpan/3";
const DEFAULT_SEARCH_ENDPOINT = "https://so.252035.xyz/api/search";
const VIDEO_EXTENSIONS = new Set(["mp4", "mkv", "mov", "m4v", "avi", "ts", "m2ts", "webm", "flv"]);
const PAN123_DOMAINS = new Set(["123pan.com", "www.123pan.com", "123684.com", "www.123684.com", "123865.com", "www.123865.com"]);
const QUARK_DOMAINS = new Set(["pan.quark.cn"]);
const QUARK_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36";

/// Quark and UC share one drive API (`clouddrive`), the same share/transcode
/// contract and the same play token shape. Only the origin, the query prefix,
/// the Referer and the cookie field differ, so every step below is written once
/// and parameterised by this descriptor. TVBox hosts do the same: one driver,
/// two brands.
export const QUARK_SERVICES = Object.freeze({
  quark: Object.freeze({
    key: "quark",
    name: "夸克",
    apiBase: "https://drive-pc.quark.cn/1/clouddrive/",
    query: "pr=ucpro&fr=pc",
    referer: "https://pan.quark.cn/",
    cookieField: "quarkCookie",
    cookieDomains: Object.freeze(["quark.cn"]),
    domains: QUARK_DOMAINS
  }),
  uc: Object.freeze({
    key: "uc",
    name: "UC",
    apiBase: "https://pc-api.uc.cn/1/clouddrive/",
    query: "pr=UCBrowser&fr=pc",
    referer: "https://drive.uc.cn/",
    cookieField: "ucCookie",
    cookieDomains: Object.freeze(["uc.cn"]),
    domains: Object.freeze(new Set(["drive.uc.cn"]))
  })
});

/// `pr=ucpro&fr=pc` → `{ pr: "ucpro", fr: "pc" }`, so the share listing can set
/// the same two parameters it always did without hard-coding either brand.
function quarkQueryPairs(service) {
  return Object.fromEntries(new URLSearchParams(service.query).entries());
}

export const cloudPanSite = Object.freeze({
  key: "builtin_cloudpan",
  name: "☁️ 网盘聚合",
  api: CLOUD_PAN_API,
  type: 3,
  searchable: 1,
  quickSearch: 1,
  filterable: 0
});

export function isCloudPanSite(site) {
  return site?.api === CLOUD_PAN_API;
}

function encodePayload(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function decodePayload(value) {
  try {
    return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
  } catch {
    throw new Error("网盘资源标识无效");
  }
}

function tryDecodePayload(value) {
  try {
    return decodePayload(value);
  } catch {
    return null;
  }
}

function cleanText(value, fallback = "网盘资源") {
  const text = String(value || "").replace(/[\r\n\t]+/g, " ").trim();
  return text.slice(0, 300) || fallback;
}

function normalizeShareURL(raw, password = "") {
  const value = String(raw || "").trim();
  const urlValue = value.match(/https?:\/\/[^\s|，。]+/iu)?.[0] || value;
  const url = new URL(urlValue);
  const embeddedPassword = value.match(/(?:提取码|密码)[:：\s]*([A-Za-z0-9]{2,12})/u)?.[1] || "";
  const resolvedPassword = String(password || embeddedPassword).trim();
  if (resolvedPassword && !url.searchParams.has("pwd")) url.searchParams.set("pwd", resolvedPassword);
  return url.toString();
}

export function createCloudSearchResult(provider, entry) {
  const note = cleanText(entry.note);
  const image = Array.isArray(entry.images) ? String(entry.images.find(Boolean) || "") : "";
  const payload = {
    provider,
    url: normalizeShareURL(entry.url, entry.password),
    password: String(entry.password || ""),
    note,
    image
  };
  const providerName = provider === "123" ? "123网盘" : provider === "quark" ? "夸克网盘" : "阿里云盘";
  return {
    vod_id: encodePayload(payload),
    vod_name: note,
    vod_pic: image,
    vod_remarks: providerName
  };
}

export async function searchCloudResources(keyword, fetchValue = fetch, endpoint = DEFAULT_SEARCH_ENDPOINT) {
  const query = cleanText(keyword, "");
  if (!query) return [];
  const endpoints = String(endpoint || DEFAULT_SEARCH_ENDPOINT).split(",").map((value) => value.trim()).filter(Boolean);
  let body;
  let lastError;
  for (const endpointValue of endpoints) {
    const url = new URL(endpointValue);
    url.searchParams.set("kw", query);
    url.searchParams.set("res", "merge");
    url.searchParams.set("cloud_types", "quark,aliyun,123");
    for (const options of [
      { headers: { accept: "application/json" } },
      {
        method: "POST",
        headers: { accept: "application/json", "content-type": "application/json" },
        body: JSON.stringify({ kw: query, res: "merge", cloud_types: ["quark", "aliyun", "123"] })
      }
    ]) {
      try {
        const response = await fetchValue(url, options);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        body = await readBoundedJSON(response);
        if (body?.data?.merged_by_type || body?.merged_by_type) break;
        throw new Error(body?.message || "返回数据无效");
      } catch (error) {
        lastError = error;
      }
    }
    if (body?.data?.merged_by_type || body?.merged_by_type) break;
  }
  if (!body) throw new Error(`网盘搜索服务暂时不可用：${lastError?.message || "请求失败"}`);
  // Some PanSou deployments wrap the documented response in a data object.
  const data = body.data || body;
  if ((body?.code !== undefined && body.code !== 0) || !data?.merged_by_type) {
    throw new Error(body?.message || "网盘搜索服务返回无效数据");
  }
  const merged = data.merged_by_type;
  const values = [];
  const seen = new Set();
  for (const provider of ["quark", "aliyun", "123"]) {
    for (const entry of Array.isArray(merged[provider]) ? merged[provider] : []) {
      try {
        const item = createCloudSearchResult(provider, entry);
        const key = `${provider}\0${decodePayload(item.vod_id).url}`;
        if (seen.has(key)) continue;
        seen.add(key);
        values.push(item);
        if (values.length >= 80) return values;
      } catch {
        // Ignore malformed third-party search entries.
      }
    }
  }
  return values;
}

function cloudDetail(payload, playMap) {
  const entries = Object.entries(playMap || {}).filter(([, value]) => typeof value === "string" && value.length > 0);
  if (entries.length === 0) throw new Error("网盘分享中没有找到可播放视频，或凭据已失效");
  return {
    list: [{
      vod_id: encodePayload(payload),
      vod_name: payload.note,
      vod_pic: payload.image || "",
      vod_content: `${payload.provider === "quark" ? "夸克" : "阿里"}网盘分享`,
      vod_play_from: entries.map(([flag]) => flag).join("$$$"),
      vod_play_url: entries.map(([, value]) => value).join("$$$")
    }]
  };
}

function parseQuarkShare(payload, service = QUARK_SERVICES.quark) {
  const url = new URL(payload.url);
  if (!service.domains.has(url.hostname.toLowerCase())) throw new Error(`不支持的${service.name}网盘分享域名`);
  const match = url.pathname.match(/^\/s\/([^/?#]+)/);
  if (!match) throw new Error(`${service.name}网盘分享地址无效`);
  return {
    shareId: match[1],
    password: payload.password || url.searchParams.get("pwd") || ""
  };
}

function quarkHeaders(service, cookie = "") {
  const headers = {
    accept: "application/json, text/plain, */*",
    "content-type": "application/json",
    referer: service.referer,
    "user-agent": QUARK_USER_AGENT
  };
  if (cookie) headers.cookie = cookie;
  return headers;
}

function quarkPlaybackHeaders(service, playbackURL, cookie) {
  const headers = {
    referer: service.referer,
    "user-agent": QUARK_USER_AGENT
  };
  const hostname = new URL(playbackURL).hostname.toLowerCase();
  if (service.cookieDomains.some((domain) => hostname === domain || hostname.endsWith(`.${domain}`))) {
    headers.cookie = cookie;
  }
  return headers;
}

function updateQuarkCookie(service, credentials, response) {
  const field = service.cookieField;
  if (!credentials?.[field]) return;
  const setCookie = typeof response.headers.getSetCookie === "function"
    ? response.headers.getSetCookie().join(";")
    : response.headers.get("set-cookie") || "";
  const refreshed = setCookie.match(/(?:^|[;,]\s*)__puus=([^;,\s]+)/)?.[1];
  if (!refreshed) return;
  if (/(?:^|;\s*)__puus=[^;]*/.test(credentials[field])) {
    credentials[field] = credentials[field].replace(
      /(?:^|;\s*)__puus=[^;]*/,
      (value) => `${value.startsWith(";") ? "; " : ""}__puus=${refreshed}`
    );
  } else {
    credentials[field] = `${credentials[field]}; __puus=${refreshed}`;
  }
}

async function quarkJSON(pathValue, {
  body,
  credentials,
  fetchValue,
  method = body === undefined ? "GET" : "POST",
  service = QUARK_SERVICES.quark
}) {
  const response = await fetchValue(new URL(pathValue, service.apiBase), {
    method,
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
    headers: quarkHeaders(service, credentials?.[service.cookieField] || ""),
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });
  updateQuarkCookie(service, credentials, response);
  const originalDownload = new URL(pathValue, service.apiBase).pathname.endsWith("/file/download");
  if (!response.ok) {
    // The drive reports its original-file size restriction as HTTP 400. Classify
    // only this known endpoint/code; never expose the upstream diagnostic.
    if (response.status === 400 && originalDownload) {
      let failure;
      try { failure = await readBoundedJSON(response); } catch { /* Keep the HTTP error. */ }
      if (Number(failure?.code) === 23018) {
        throw new GatewayError("CLOUD_ORIGINAL_SIZE_LIMIT", `${service.name}限制该文件的原画地址`, 422);
      }
    }
    try { await response.body?.cancel(); } catch { /* Ignore disposal errors. */ }
    if ([401, 403].includes(response.status)) {
      throw new GatewayError("CLOUD_AUTH_REQUIRED", `${service.name}登录已失效`, 401);
    }
    if ([429, 503].includes(response.status)) {
      throw new GatewayError("CLOUD_BUSY", `${service.name}暂时繁忙`, 503);
    }
    throw new Error(`${service.name}网盘返回 HTTP ${response.status}`);
  }
  const value = await readBoundedJSON(response);
  const apiCode = value?.code ?? value?.status;
  if (originalDownload && Number(apiCode) === 23018) {
    throw new GatewayError("CLOUD_ORIGINAL_SIZE_LIMIT", `${service.name}限制该文件的原画地址`, 422);
  }
  if (apiCode !== undefined && ![0, 200].includes(Number(apiCode))) {
    throw new Error(value?.message || value?.msg || `${service.name}网盘请求失败（${apiCode}）`);
  }
  return value;
}

async function quarkShareToken(share, credentials, fetchValue, service = QUARK_SERVICES.quark) {
  const body = await quarkJSON(`share/sharepage/token?${service.query}`, {
    body: { pwd_id: share.shareId, passcode: share.password },
    credentials,
    fetchValue,
    service
  });
  const token = body?.data?.stoken;
  if (!token) throw new Error(`${service.name}分享链接已失效，或提取码不正确`);
  return token;
}

async function listQuarkFolder(share, stoken, folderId, credentials, fetchValue, service = QUARK_SERVICES.quark) {
  const files = [];
  for (let page = 1; page <= 20; page += 1) {
    const url = new URL("share/sharepage/detail", service.apiBase);
    for (const [name, value] of Object.entries({
      ...quarkQueryPairs(service),
      pwd_id: share.shareId,
      stoken,
      pdir_fid: String(folderId),
      force: "0",
      _page: String(page),
      _size: "200",
      _sort: "file_type:asc,file_name:asc"
    })) url.searchParams.set(name, value);
    const body = await quarkJSON(url, { credentials, fetchValue, service });
    const pageFiles = Array.isArray(body?.data?.list) ? body.data.list : [];
    files.push(...pageFiles);
    const total = Number(body?.metadata?._total ?? body?.data?.metadata?._total ?? pageFiles.length);
    if (pageFiles.length === 0 || page * 200 >= total) break;
  }
  return files;
}

async function collectQuarkVideos(share, stoken, credentials, fetchValue, targetFileId,
                                  service = QUARK_SERVICES.quark) {
  const videos = [];
  const queue = [{ id: "0", prefix: "" }];
  const visited = new Set();
  while (queue.length > 0 && visited.size < 100 && videos.length < 200) {
    const folder = queue.shift();
    if (visited.has(String(folder.id))) continue;
    visited.add(String(folder.id));
    const files = await listQuarkFolder(share, stoken, folder.id, credentials, fetchValue, service);
    for (const file of files) {
      if (file?.dir === true || Number(file?.dir) === 1) {
        queue.push({ id: file.fid, prefix: `${folder.prefix}${cleanText(file.file_name)}/` });
      } else if (
        file?.obj_category === "video"
        || VIDEO_EXTENSIONS.has(String(file?.file_name || "").split(".").pop()?.toLowerCase())
      ) {
        if (Number(file?.size || 0) < 5 * 1024 * 1024) continue;
        videos.push({
          displayName: `${folder.prefix}${cleanText(file.file_name)}`,
          fileId: file.fid,
          fileToken: file.share_fid_token || "",
          fileName: String(file.file_name || ""),
          size: Number(file.size || 0)
        });
        if (targetFileId && file.fid === targetFileId) return videos;
      }
    }
  }
  return videos;
}

const sourcePlaybackQueues = new WeakMap();

/// The CatVod cloud contract for Quark/UC carries a share pointer, not a stream.
/// TVBox hosts resolve it the same way: verify the share token, walk the shared
/// tree, copy the wanted file into a private cache folder, then ask the drive for
/// a play address (original quality first, transcoded HLS as the fallback).
export async function playQuarkSourceEpisode(file, credentials, fetchValue, originalFile,
                                             service = QUARK_SERVICES.quark) {
  const cookie = String(credentials?.[service.cookieField] || "");
  const owner = cookie.match(/(?:^|;\s*)__pus=([^;]+)/)?.[1] || cookie;
  const resource = createHash("sha256").update(owner).update("\0").update(file.shareId)
    .update("\0").update(file.fileId).digest("hex");
  let queues = sourcePlaybackQueues.get(credentials);
  if (!queues) { queues = new Map(); sourcePlaybackQueues.set(credentials, queues); }
  const operation = (queues.get(resource) || Promise.resolve()).then(async () => {
    const files = await collectQuarkVideos({ shareId: file.shareId }, file.stoken,
      credentials, fetchValue, file.fileId, service);
    const metadata = files.find(item => item.fileId === file.fileId);
    if (!metadata) throw new Error(`${service.name}分享中没有找到该剧集，请重新打开资源详情`);
    const verifiedFile = { ...file, ...metadata };
    const savedFileId = await cachedQuarkSourceFile(verifiedFile, resource, credentials, fetchValue, service);
    // 原画（file/download）只对 avplayable 容器有意义：AVPlayer 不认 mkv/avi/flv，
    // 就算取到直链也是黑屏，还会白白多打一次接口。旧实现在这里先撞原画、失败
    // 再降级，非会员等于每次播放都多等一个 400。
    const container = String(verifiedFile.fileName || "").split(".").pop().toLowerCase();
    const originalPlayable = ["mp4", "m4v", "mov"].includes(container);
    if (!originalFile || !originalPlayable) {
      const plan = await quarkPlaybackForSavedFile(savedFileId, credentials, fetchValue, service);
      if (originalFile && !originalPlayable) {
        return { ...plan, playbackNotice: `${service.key}-transcoded-container` };
      }
      return plan;
    }
    try {
      const body = await quarkJSON(`file/download?${service.query}`, {
        body: { fids: [savedFileId] }, credentials, fetchValue, service
      });
      const entries = Array.isArray(body?.data) ? body.data : [];
      const entry = entries.find(item => item?.fid === savedFileId)
        || (entries.length === 1 && !entries[0]?.fid ? entries[0] : undefined);
      const url = new URL(entry?.download_url);
      if (url.protocol !== "https:" || url.username || url.password) {
        throw new Error(`${service.name}原画地址无效`);
      }
      return { parse: 0, jx: 0, url: url.toString(), quality: "原画",
        header: quarkPlaybackHeaders(service, url.toString(), cookie) };
    } catch (error) {
      if (error?.code !== "CLOUD_ORIGINAL_SIZE_LIMIT") throw error;
      return { ...await quarkPlaybackForSavedFile(savedFileId, credentials, fetchValue, service),
        playbackNotice: `${service.key}-original-size-limit` };
    }
  });
  const tail = operation.then(() => {}, () => {});
  queues.set(resource, tail);
  tail.then(() => { if (queues.get(resource) === tail) queues.delete(resource); });
  return operation;
}

async function cachedQuarkSourceFile(file, resource, credentials, fetchValue,
                                     service = QUARK_SERVICES.quark) {
  const name = `.TVBox源播放-${resource.slice(0, 24)}`;
  let directoryId;
  for (let page = 1; page <= 100; page += 1) {
    const listing = await quarkJSON(`file/sort?${service.query}&pdir_fid=0&_page=${page}&_size=200&_sort=file_type:asc,updated_at:desc`, {
      credentials, fetchValue, service
    });
    const entries = listing?.data?.list || [];
    directoryId = entries.find(item => Number(item?.dir) === 1 && item.file_name === name)?.fid;
    if (directoryId) break;
    const total = Number(listing?.metadata?._total ?? listing?.data?.metadata?._total);
    if (entries.length < 200 || (Number.isFinite(total) && page * 200 >= total)) break;
    if (page === 100) throw new Error(`${service.name}目录过多，无法安全定位播放缓存`);
  }
  if (!directoryId) {
    const created = await quarkJSON(`file?${service.query}`, {
      body: { pdir_fid: "0", file_name: name, dir_path: "", dir_init_lock: false },
      credentials, fetchValue, service
    });
    directoryId = created?.data?.fid;
  }
  if (!directoryId) throw new Error(`无法创建${service.name}播放缓存目录`);
  const contents = await quarkJSON(`file/sort?${service.query}&pdir_fid=${encodeURIComponent(directoryId)}&_page=1&_size=200`, {
    credentials, fetchValue, service
  });
  const files = contents?.data?.list || [];
  if (files.length === 0) return saveQuarkShareFile(file, credentials, fetchValue, directoryId, service);
  if (files.length === 1 && Number(files[0].dir || 0) === 0 && files[0].fid
      && files[0].file_name === file.fileName && Number(files[0].size) === file.size) {
    return files[0].fid;
  }
  // Never delete or overwrite files added by the user to this resource's folder.
  throw new Error(`${service.name}播放缓存内容与原文件不一致`);
}

async function detailQuark(payload, credentials, fetchValue, service = QUARK_SERVICES.quark) {
  const share = parseQuarkShare(payload, service);
  const stoken = await quarkShareToken(share, credentials, fetchValue, service);
  const videos = await collectQuarkVideos(share, stoken, credentials, fetchValue, null, service);
  if (videos.length === 0) throw new Error(`${service.name}网盘分享中没有找到可播放视频`);
  const episodes = videos.map((file) => {
    const id = encodePayload({
      provider: service.key,
      shareId: share.shareId,
      stoken,
      fileId: file.fileId,
      fileToken: file.fileToken
    });
    return `${cleanText(file.displayName)}$${id}`;
  }).join("#");
  return {
    list: [{
      vod_id: encodePayload(payload),
      vod_name: payload.note,
      vod_pic: payload.image || "",
      vod_content: `${service.name}网盘分享`,
      vod_play_from: `${service.name}网盘-普画`,
      vod_play_url: episodes
    }]
  };
}

function shouldRetryQuarkShare(error) {
  return /HTTP 404|分享链接已失效|提取码不正确/u.test(String(error?.message || error));
}

async function detailQuarkWithFallback(payload, credentials, fetchValue, searchEndpoint,
                                       service = QUARK_SERVICES.quark) {
  try {
    return await detailQuark(payload, credentials, fetchValue, service);
  } catch (initialError) {
    if (!shouldRetryQuarkShare(initialError)) throw initialError;
    let alternatives;
    try {
      alternatives = await searchCloudResources(payload.note, fetchValue, searchEndpoint);
    } catch {
      throw initialError;
    }
    const originalURL = normalizeShareURL(payload.url, payload.password);
    for (const item of alternatives) {
      const candidate = tryDecodePayload(item?.vod_id);
      if (candidate?.provider !== service.key) continue;
      let candidateURL;
      try {
        candidateURL = normalizeShareURL(candidate.url, candidate.password);
      } catch {
        continue;
      }
      if (candidateURL === originalURL) continue;
      try {
        return await detailQuark(
          { ...candidate, note: payload.note, image: payload.image || candidate.image || "" },
          credentials,
          fetchValue,
          service
        );
      } catch {
        // Search indexes can contain multiple expired shares; try the next one.
      }
    }
    throw initialError;
  }
}

function quarkCacheDirectoryName(cookie) {
  const owner = createHash("sha256").update(cookie).digest("hex").slice(0, 10);
  return `.TVBox播放缓存-${owner}`;
}

async function ensureQuarkCacheDirectory(credentials, fetchValue, service = QUARK_SERVICES.quark) {
  const name = quarkCacheDirectoryName(credentials[service.cookieField]);
  const listing = await quarkJSON(`file/sort?${service.query}&pdir_fid=0&_page=1&_size=200&_sort=file_type:asc,updated_at:desc`, {
    credentials,
    fetchValue,
    service
  });
  const existing = listing?.data?.list?.find((file) => Number(file?.dir) === 1 && file?.file_name === name);
  if (existing?.fid) return existing.fid;
  const created = await quarkJSON(`file?${service.query}`, {
    body: { pdir_fid: "0", file_name: name, dir_path: "", dir_init_lock: false },
    credentials,
    fetchValue,
    service
  });
  if (!created?.data?.fid) throw new Error(`无法创建${service.name}播放缓存目录`);
  return created.data.fid;
}

async function clearQuarkCacheDirectory(directoryId, credentials, fetchValue,
                                        service = QUARK_SERVICES.quark) {
  const listing = await quarkJSON(`file/sort?${service.query}&pdir_fid=${encodeURIComponent(directoryId)}&_page=1&_size=200&_sort=file_type:asc,updated_at:desc`, {
    credentials,
    fetchValue,
    service
  });
  const fileIds = (listing?.data?.list || []).map((file) => file?.fid).filter(Boolean);
  if (fileIds.length === 0) return;
  await quarkJSON(`file/delete?${service.query}`, {
    body: { action_type: 2, filelist: fileIds, exclude_fids: [] },
    credentials,
    fetchValue,
    service
  });
}

async function saveQuarkShareFile(file, credentials, fetchValue, targetDirectoryId,
                                  service = QUARK_SERVICES.quark) {
  const directoryId = targetDirectoryId || await ensureQuarkCacheDirectory(credentials, fetchValue, service);
  if (!targetDirectoryId) await clearQuarkCacheDirectory(directoryId, credentials, fetchValue, service);
  const saved = await quarkJSON(`share/sharepage/save?${service.query}`, {
    body: {
      fid_list: [file.fileId],
      fid_token_list: [file.fileToken],
      to_pdir_fid: directoryId,
      pwd_id: file.shareId,
      stoken: file.stoken,
      pdir_fid: "0",
      scene: "link"
    },
    credentials,
    fetchValue,
    service
  });
  const taskId = saved?.data?.task_id;
  if (!taskId) throw new Error(`${service.name}网盘无法保存分享文件，请检查账号空间`);
  for (let retry = 0; retry < 6; retry += 1) {
    const task = await quarkJSON(`task?${service.query}&task_id=${encodeURIComponent(taskId)}&retry_index=${retry}`, {
      credentials,
      fetchValue,
      service
    });
    const fileId = task?.data?.save_as?.save_as_top_fids?.[0];
    if (fileId) return fileId;
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  throw new Error(`${service.name}网盘保存文件超时，请稍后重试`);
}

async function playQuark(episodeID, credentials, fetchValue, service = QUARK_SERVICES.quark) {
  if (!credentials?.[service.cookieField]) {
    throw new GatewayError("CLOUD_AUTH_REQUIRED",
      `请先在「猫源 → 网盘账号配置」里登录${service.name}网盘`, 401);
  }
  const file = decodePayload(episodeID);
  const savedFileId = await saveQuarkShareFile(file, credentials, fetchValue, undefined, service);
  return quarkPlaybackForSavedFile(savedFileId, credentials, fetchValue, service);
}

async function quarkPlaybackForSavedFile(savedFileId, credentials, fetchValue,
                                         service = QUARK_SERVICES.quark) {
  const body = await quarkJSON(`file/v2/play?${service.query}`, {
    body: {
      fid: savedFileId,
      resolutions: "normal,low,high,super,2k,4k",
      supports: "fmp4"
    },
    credentials,
    fetchValue,
    service
  });
  const videos = Array.isArray(body?.data?.video_list) ? body.data.video_list : [];
  const qualityNames = new Map([
    ["4k", "4K"],
    ["2k", "2K"],
    ["super", "超清"],
    ["high", "高清"],
    ["normal", "标清"],
    ["low", "流畅"]
  ]);
  // 只有拿到 `video_info.url` 的档位才真的能播。会员限制、转码未完成（
  // `accessable:false` / `trans_status` 未成功）都只表现在这里——按会员等级
  // 挑「最高可用」，而不是按顺序撞第一个。
  const playable = videos.filter((video) => video?.video_info?.url);
  const heightOf = (video) => Number(video?.video_info?.height || video?.video_info?.width || 0);
  playable.sort((lhs, rhs) => heightOf(rhs) - heightOf(lhs));
  const labelFor = (video, index) => {
    const height = heightOf(video);
    // 用真实分辨率标 1080P/720P，比「超清/高清」这类主观档位名更能说明画质，
    // 也是用户看到「为什么这么糊」时唯一能对上号的信息。
    if (height >= 2000) return "4K";
    if (height >= 1000) return "1080P";
    if (height >= 700) return "720P";
    if (height >= 500) return "480P";
    if (height >= 300) return "360P";
    const resolution = String(video?.resolution || "").toLowerCase();
    return qualityNames.get(resolution) || (height > 0 ? `${height}P` : `线路${index + 1}`);
  };
  const selected = playable[0];
  const playbackURL = selected?.video_info?.url;
  if (!playbackURL) throw new Error(`${service.name}网盘没有返回可播放地址，请检查 Cookie 是否已失效`);
  const qualityOptions = playable.map((video, index) => ({
    name: labelFor(video, index),
    width: Number(video?.video_info?.width || 0),
    height: heightOf(video),
    bitrate: Number(video?.video_info?.bitrate || 0),
    url: video.video_info.url
  }));
  return {
    parse: 0,
    jx: 0,
    url: playbackURL,
    quality: qualityOptions[0]?.name || "",
    header: quarkPlaybackHeaders(service, playbackURL, credentials[service.cookieField]),
    qualityOptions
  };
}

let crcTable;
function crc32(value) {
  crcTable ||= Array.from({ length: 256 }, (_, index) => {
    let current = index;
    for (let bit = 0; bit < 8; bit += 1) current = (current & 1) ? 0xedb88320 ^ (current >>> 1) : current >>> 1;
    return current >>> 0;
  });
  let current = 0xffffffff;
  for (const byte of Buffer.from(value)) current = crcTable[(current ^ byte) & 0xff] ^ (current >>> 8);
  return (current ^ 0xffffffff) >>> 0;
}

function signed123URL(rawURL, now = new Date(), randomValue = Math.random()) {
  const url = new URL(rawURL);
  const chinaTime = new Date(now.getTime() + 8 * 60 * 60 * 1000);
  const pad = (value) => String(value).padStart(2, "0");
  const digits = `${chinaTime.getUTCFullYear()}${pad(chinaTime.getUTCMonth() + 1)}${pad(chinaTime.getUTCDate())}${pad(chinaTime.getUTCHours())}${pad(chinaTime.getUTCMinutes())}`;
  const table = "adefghlmyijnopkqrstubcvwsz";
  const timeSign = String(crc32([...digits].map((digit) => table[Number(digit)]).join("")));
  const timestamp = String(Math.floor(now.getTime() / 1000));
  const random = String(Math.round(10_000_000 * randomValue));
  const dataSign = String(crc32([timestamp, random, url.pathname, "web", "3", timeSign].join("|")));
  url.searchParams.set(timeSign, `${timestamp}-${random}-${dataSign}`);
  return url;
}

function parse123Share(payload) {
  const url = new URL(payload.url);
  if (!PAN123_DOMAINS.has(url.hostname.toLowerCase())) throw new Error("不支持的 123 网盘分享域名");
  const match = url.pathname.match(/^\/s\/([^/?#]+)/);
  if (!match) throw new Error("123 网盘分享地址无效");
  return { shareKey: match[1], password: payload.password || url.searchParams.get("pwd") || "" };
}

function pan123Headers() {
  return {
    origin: "https://yun.123pan.com",
    referer: "https://yun.123pan.com/",
    platform: "web",
    "app-version": "3",
    "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) TVBox"
  };
}

async function pan123JSON(url, options, fetchValue) {
  const response = await fetchValue(url, options);
  if (!response.ok) throw new Error(`123 网盘返回 HTTP ${response.status}`);
  const body = await readBoundedJSON(response);
  if (body?.code !== 0) throw new Error(body?.message || "123 网盘请求失败");
  return body;
}

async function list123Folder(share, parentFileId, fetchValue) {
  const files = [];
  for (let page = 1; page <= 20; page += 1) {
    const url = signed123URL("https://yun.123pan.com/b/api/share/get");
    for (const [name, value] of Object.entries({
      limit: "100", next: "0", orderBy: "file_id", orderDirection: "desc",
      parentFileId: String(parentFileId), Page: String(page), shareKey: share.shareKey, SharePwd: share.password
    })) url.searchParams.set(name, value);
    const body = await pan123JSON(url, { headers: pan123Headers() }, fetchValue);
    const pageFiles = Array.isArray(body?.data?.InfoList) ? body.data.InfoList : [];
    files.push(...pageFiles);
    if (pageFiles.length === 0 || body?.data?.Next === "-1") break;
  }
  return files;
}

function isVideoFile(file) {
  if (Number(file.Type) === 1) return false;
  const extension = String(file.FileName || "").split(".").pop()?.toLowerCase() || "";
  return VIDEO_EXTENSIONS.has(extension) || Number(file.Size || 0) >= 50 * 1024 * 1024;
}

async function collect123Videos(share, fetchValue) {
  const videos = [];
  const queue = [{ id: 0, prefix: "" }];
  const visited = new Set();
  while (queue.length > 0 && visited.size < 100 && videos.length < 200) {
    const folder = queue.shift();
    if (visited.has(String(folder.id))) continue;
    visited.add(String(folder.id));
    const files = await list123Folder(share, folder.id, fetchValue);
    for (const file of files) {
      if (Number(file.Type) === 1) {
        queue.push({ id: file.FileId, prefix: `${folder.prefix}${cleanText(file.FileName)}/` });
      } else if (isVideoFile(file)) {
        videos.push({ ...file, displayName: `${folder.prefix}${cleanText(file.FileName)}` });
      }
    }
  }
  return videos;
}

async function detail123(payload, fetchValue) {
  const share = parse123Share(payload);
  const videos = await collect123Videos(share, fetchValue);
  if (videos.length === 0) throw new Error("123 网盘分享中没有找到可播放视频");
  const episodes = videos.map((file) => {
    const id = encodePayload({
      provider: "123", shareKey: share.shareKey, password: share.password,
      fileId: file.FileId, etag: file.Etag || "", s3KeyFlag: file.S3KeyFlag || "", size: Number(file.Size || 0)
    });
    return `${cleanText(file.displayName)}$${id}`;
  });
  return {
    list: [{
      vod_id: encodePayload(payload), vod_name: payload.note, vod_pic: payload.image || "",
      vod_content: "123 网盘分享", vod_play_from: "123网盘", vod_play_url: episodes.join("#")
    }]
  };
}

async function play123(episodeID, fetchValue) {
  return play123File(decodePayload(episodeID), fetchValue);
}

/// One 123 share file → stream. 123 is the only drive whose share can be turned
/// into a stream **without** copying it into the account first, so a CatVod
/// episode only needs the share key and a file id to play.
async function play123File(file, fetchValue) {
  const url = signed123URL("https://yun.123pan.com/b/api/share/download/info");
  const body = await pan123JSON(url, {
    method: "POST",
    headers: { ...pan123Headers(), "content-type": "application/json" },
    body: JSON.stringify({
      shareKey: file.shareKey, SharePwd: file.password || "", etag: file.etag || "",
      fileId: file.fileId, s3keyFlag: file.s3KeyFlag || "", size: file.size || 0
    })
  }, fetchValue);
  let playbackURL = body?.data?.DownloadURL || "";
  if (!playbackURL) throw new Error("123 网盘没有返回播放地址");
  const wrapped = new URL(playbackURL);
  const params = wrapped.searchParams.get("params");
  if (params) {
    try { playbackURL = Buffer.from(params, "base64").toString("utf8"); } catch { /* Keep original URL. */ }
  }
  const redirect = await fetchValue(playbackURL, { redirect: "manual", headers: { referer: "https://yun.123pan.com/" } });
  if (redirect.status >= 300 && redirect.status < 400 && redirect.headers.get("location")) {
    playbackURL = new URL(redirect.headers.get("location"), playbackURL).toString();
  } else if (redirect.ok && (redirect.headers.get("content-type") || "").includes("application/json")) {
    const value = await readBoundedJSON(redirect);
    playbackURL = value?.data?.redirect_url || playbackURL;
  }
  return { parse: 0, jx: 0, url: playbackURL, header: { Referer: "https://yun.123pan.com/" } };
}

/// Resolve a 123 share from the pieces a CatVod cloud episode may carry.
/// Only the share key is mandatory: the file list supplies etag/s3KeyFlag/size,
/// which the download endpoint needs to sign the URL.
export async function play123ShareEpisode({ shareKey, password = "", fileId = "", fetchValue = fetch }) {
  const key = String(shareKey || "").trim();
  if (!key) throw new Error("123 网盘分享标识缺失，请重新打开资源详情");
  const share = { shareKey: key, password: String(password || "") };
  const videos = await collect123Videos(share, fetchValue);
  if (videos.length === 0) throw new Error("123 网盘分享中没有找到可播放视频");
  const wanted = String(fileId || "").trim();
  const target = (wanted && videos.find((file) => String(file.FileId) === wanted))
    || videos[0];
  return play123File({
    shareKey: key,
    password: share.password,
    fileId: target.FileId,
    etag: target.Etag || "",
    s3KeyFlag: target.S3KeyFlag || "",
    size: Number(target.Size || 0)
  }, fetchValue);
}

export async function handleCloudPanAction({
  action,
  argumentsValue,
  cloud,
  credentials = {},
  initializeCloud = async () => {},
  fetchValue = fetch,
  searchEndpoint
}) {
  switch (action) {
    case "home": return { class: [], list: [] };
    case "category": return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] };
    case "search": return { list: await searchCloudResources(argumentsValue.keyword, fetchValue, searchEndpoint) };
    case "detail": {
      const payload = decodePayload(Array.isArray(argumentsValue.ids) ? argumentsValue.ids[0] : argumentsValue.ids);
      if (payload.provider === "quark" || payload.provider === "uc") {
        const service = payload.provider === "uc" ? QUARK_SERVICES.uc : QUARK_SERVICES.quark;
        // A resource check must describe this share, not an automatically substituted one.
        if (argumentsValue.verifyResource === true) return detailQuark(payload, credentials, fetchValue, service);
        return detailQuarkWithFallback(payload, credentials, fetchValue, searchEndpoint, service);
      }
      if (payload.provider === "123") return detail123(payload, fetchValue);
      await initializeCloud();
      if (!cloud?.detail) throw new Error("当前 CatVod 包没有提供云盘解析器");
      return cloudDetail(payload, await cloud.detail([payload.url], payload.note));
    }
    case "player": {
      const payload = tryDecodePayload(argumentsValue.id);
      if (payload?.provider === "quark") return playQuark(argumentsValue.id, credentials, fetchValue);
      if (payload?.provider === "uc") {
        return playQuark(argumentsValue.id, credentials, fetchValue, QUARK_SERVICES.uc);
      }
      if (argumentsValue.flag === "123网盘") return play123(argumentsValue.id, fetchValue);
      await initializeCloud();
      if (!cloud?.play) {
        throw new GatewayError("CLOUD_PROVIDER_UNSUPPORTED",
          `这条线路的网盘（${argumentsValue.flag || "未知"}）需要接口自带的解析器，当前猫源没有提供。`, 422);
      }
      const url = await cloud.play(argumentsValue.flag, argumentsValue.id, argumentsValue.vipFlags || []);
      if (!url) {
        throw new GatewayError("CLOUD_PLAYBACK_FAILED", "云盘没有返回播放地址，请检查 Cookie 或 Token", 502);
      }
      return { parse: 0, jx: 0, url, header: cloud.headers?.(argumentsValue.flag) || {} };
    }
    default: throw new Error(`Unsupported action: ${action}`);
  }
}

export const cloudPanTestSupport = {
  decodePayload,
  encodePayload,
  normalizeShareURL,
  quarkCacheDirectoryName,
  quarkPlaybackHeaders,
  signed123URL
};
