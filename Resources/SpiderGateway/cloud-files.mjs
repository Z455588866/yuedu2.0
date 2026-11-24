// The built-in "我的网盘" source: the drives the person has signed in to under
// 管理猫源 → 网盘账号, browsed as a library and played straight from the drive.
//
// This is the piece tvbox-silicon has and a spider bundle does not: a bundle can
// only parse a link it is given, so a netdisk share it cannot resolve shows
// "没有可播放的剧集". Here the drive is read with the account's own credentials,
// and the link handed to the player is the drive's CDN address with the headers
// it wants — no share page, no transfer, no bundle involved.

import { driveFor, fileKind, isPlayable, signedInDrives } from "./pan-drivers.mjs";

const CLOUD_FILES_API = "/spider/myfiles/3";

export const cloudFilesSite = Object.freeze({
  key: "builtin_myfiles",
  name: "📁 我的网盘",
  api: CLOUD_FILES_API,
  type: 3,
  searchable: 0,
  quickSearch: 0,
  filterable: 0
});

export function isCloudFilesSite(site) {
  return site?.api === CLOUD_FILES_API;
}

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function decode(value) {
  try {
    return JSON.parse(Buffer.from(String(value), "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

function humanSize(bytes) {
  const size = Number(bytes) || 0;
  if (size <= 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = size;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value >= 100 || index === 0 ? Math.round(value) : value.toFixed(1)}${units[index]}`;
}

/// Episodes are named the way the file is, without the container extension:
/// "第01集.mp4" reads as "第01集" in a 76pt grid cell.
function episodeTitle(name) {
  return String(name || "").replace(/\.[a-z0-9]{2,5}$/iu, "").slice(0, 60) || "未命名";
}

function mediaItem(drive, file, parentName) {
  return {
    vod_id: encode({ drive: drive.key, id: file.id, name: file.name, folder: file.isFolder }),
    vod_name: file.isFolder ? file.name : episodeTitle(file.name),
    vod_pic: "",
    vod_remarks: file.isFolder ? "文件夹" : (humanSize(file.size) || drive.name),
    vod_tag: file.isFolder ? "folder" : "file",
    // Not a TVBox field: the sheet shows it under the poster so a season folder
    // and a single film are told apart before opening them.
    vod_area: parentName || drive.name
  };
}

/// One drive's folder as a page. Folders come first so a season folder is above
/// the loose files beside it.
async function category({ drive, credentials, folder, page }) {
  if (page > 1) return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] };
  const files = await drive.list(credentials, folder);
  const folders = files.filter((file) => file.isFolder);
  const playable = files.filter((file) => !file.isFolder && isPlayable(file.name));
  const others = files.length - folders.length - playable.length;
  const list = [...folders, ...playable].map((file) => mediaItem(drive, file));
  const empty = list.length === 0
    ? [{ vod_id: encode({ drive: drive.key, id: folder, name: "空文件夹", folder: false, empty: true }),
         vod_name: others > 0 ? "这个文件夹里没有视频" : "这个文件夹是空的",
         vod_pic: "", vod_remarks: others > 0 ? `${others} 个非视频文件` : drive.name }]
    : list;
  return { page: 1, pagecount: 1, limit: empty.length, total: empty.length, list: empty };
}

/// A folder becomes a series (one play line, one episode per video), a video a
/// single-episode series. Either way the sheet has something to play.
async function detail({ drive, credentials, id, name, isFolder }) {
  const files = isFolder ? await drive.list(credentials, id) : [{ id, name, isFolder: false, size: 0 }];
  const videos = files.filter((file) => !file.isFolder && isPlayable(file.name));
  if (videos.length === 0) {
    throw new Error("这个位置没有可播放的视频文件");
  }
  const playURL = videos.map((file) => {
    const title = episodeTitle(file.name);
    return `${String(title).replace(/[$#]/gu, " ")}$${encode({ drive: drive.key, id: file.id, name: file.name })}`;
  }).join("#");
  return {
    list: [{
      vod_id: encode({ drive: drive.key, id, name, folder: isFolder }),
      vod_name: name || (isFolder ? "文件夹" : episodeTitle(name)),
      vod_pic: "",
      vod_remarks: `${videos.length} 个视频`,
      vod_play_from: drive.name,
      vod_play_url: playURL
    }]
  };
}

async function player({ drive, credentials, id, name }) {
  const link = await drive.link(credentials, { id, name });
  if (!link?.url) throw new Error(`${drive.name}没有返回播放地址`);
  return { parse: 0, jx: 0, url: link.url, header: link.headers || {} };
}

export async function handleCloudFilesAction({ action, argumentsValue, credentials = {} }) {
  const drives = signedInDrives(credentials);
  // A fresh drive object per request, so one call's credentials never outlive
  // it on a shared module-level driver.
  const bound = drives.map((drive) => ({ ...drive }));
  const byKey = new Map(bound.map((drive) => [drive.key, drive]));

  if (action === "home") {
    return {
      class: bound.map((drive) => ({ type_id: drive.key, type_name: drive.name })),
      list: [],
      // Shown by the app when nothing is signed in.
      msg: bound.length === 0 ? "还没有登录任何网盘，先到「管理猫源 → 网盘账号」里填写 Cookie 或 Token。" : ""
    };
  }

  if (action === "category") {
    const key = String(argumentsValue.tid || argumentsValue.type_id || "");
    const drive = byKey.get(key) || bound[0];
    if (!drive) throw new Error("还没有登录任何网盘");
    const page = Math.max(1, Number(argumentsValue.page) || 1);
    const folder = String(argumentsValue.folder || argumentsValue.extend?.folder || drive.root || "0");
    return category({ drive, credentials, folder, page });
  }

  if (action === "detail") {
    const raw = Array.isArray(argumentsValue.ids) ? argumentsValue.ids[0] : argumentsValue.ids;
    const payload = decode(raw);
    if (!payload?.drive) throw new Error("这个条目的标识无效");
    const drive = byKey.get(payload.drive) || driveFor(payload.drive);
    if (!drive) throw new Error("这个网盘现在没有登录，请到「管理猫源 → 网盘账号」里重新填写");
    if (payload.empty) throw new Error("这个文件夹里没有可播放的视频");
    return detail({ drive, credentials, id: payload.id, name: payload.name, isFolder: payload.folder });
  }

  if (action === "player") {
    const payload = decode(argumentsValue.id);
    if (!payload?.drive) throw new Error("这个剧集的标识无效");
    const drive = byKey.get(payload.drive) || driveFor(payload.drive);
    if (!drive) throw new Error("这个网盘现在没有登录，请到「管理猫源 → 网盘账号」里重新填写");
    const result = await player({ drive, credentials, id: payload.id, name: payload.name });
    if (!isPlayable(payload.name) && fileKind(payload.name) !== "video") {
      // Still returned: the player decides, and a mis-named file plays fine.
      result.jx = 0;
    }
    return result;
  }

  throw new Error(`Unsupported action: ${action}`);
}

export const cloudFilesTestSupport = { encode, decode, episodeTitle, humanSize };
