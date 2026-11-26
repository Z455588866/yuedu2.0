import { playQuarkSourceEpisode, play123ShareEpisode, QUARK_SERVICES } from "./cloud-pan.mjs";
import {
  directPlaybackFromEpisode,
  shareURLFromEpisode,
  fileIDFromEpisode,
  playBaiduShare
} from "./cloud-share.mjs";
import { driveFor } from "./pan-drivers.mjs";
import { GatewayError } from "./errors.mjs";

function invalidEpisode() {
  throw new GatewayError("INVALID_CLOUD_EPISODE", "网盘剧集信息无效，请重新打开资源详情", 400);
}

function field(value, maximum) {
  if (typeof value !== "string" || !value.trim() || value.length > maximum || /[\x00-\x1f\x7f]/.test(value)) {
    invalidEpisode();
  }
  return value;
}

function decodeCatVodEpisode(id) {
  if (typeof id !== "string" || id.length > 4096 || !/^[A-Za-z0-9+/_-]+={0,2}(?![\s\S])/.test(id)) return null;
  let episode;
  try { episode = JSON.parse(Buffer.from(id, "base64").toString("utf8")); } catch { return null; }
  return episode && typeof episode === "object" && !Array.isArray(episode) ? episode : null;
}

// Decode the modern CatVod cloud contract without executing provider code.
// Account credentials never become part of this public episode descriptor.
//
// Quark and UC share one contract, so the same decoder serves both: the caller
// picks the service and only the `providerId` check differs.
export function parseCatVodQuarkEpisode(id, service = QUARK_SERVICES.quark) {
  const episode = decodeCatVodEpisode(id);
  if (episode?.providerId !== service.key) return null;
  let token;
  try { token = JSON.parse(episode.playToken); } catch { invalidEpisode(); }
  if (!token || typeof token !== "object" || Array.isArray(token)) invalidEpisode();
  const file = {
    provider: service.key,
    shareId: field(token.shareId, 256),
    stoken: field(token.stoken, 8192),
    fileId: field(token.fid, 256),
    fileToken: field(token.shareFidToken, 8192),
    fileName: field(token.fileName, 1024)
  };
  if (episode.shareId !== file.shareId || episode.fileId !== file.fileId) invalidEpisode();
  const mode = episode.mode || "original";
  if (!["original", "speed"].includes(mode)) invalidEpisode();
  return { file, mode };
}

function collectStrings(value, depth = 0, out = []) {
  if (value == null || depth > 5) return out;
  if (typeof value === "string") {
    if (/^https?:\/\//i.test(value)) out.push(value);
    return out;
  }
  if (typeof value !== "object") return out;
  for (const item of Object.values(value)) collectStrings(item, depth + 1, out);
  return out;
}

function tokenObject(episode) {
  const raw = episode?.playToken;
  if (typeof raw !== "string") return episode;
  try { return JSON.parse(raw); } catch { return episode; }
}

const SHARE_KEY_NAMES = ["shareKey", "share_key", "ShareKey", "sharekey", "pwdId", "pwd_id"];

function scanName(value, names, depth = 0) {
  if (!value || typeof value !== "object" || depth > 4) return "";
  for (const name of names) {
    const candidate = value[name];
    if (typeof candidate === "string" && candidate.trim()) return candidate.trim();
  }
  for (const item of Object.values(value)) {
    const found = scanName(item, names, depth + 1);
    if (found) return found;
  }
  return "";
}

/// 123 云盘 is the one drive whose share plays without being copied first, so a
/// CatVod episode only needs the share key. Bundles differ: some put it in the
/// token JSON, some only hand back `https://www.123pan.com/s/<key>`.
function share123FromEpisode(episode) {
  const token = tokenObject(episode);
  const declared = scanName(token, SHARE_KEY_NAMES) || scanName(episode, SHARE_KEY_NAMES);
  if (declared) {
    return { shareKey: declared, password: scanName(token, ["pwd", "password", "passcode"]) };
  }
  for (const raw of collectStrings(episode)) {
    const match = raw.match(/^https?:\/\/(?:www\.)?(?:123pan|123684|123865|123912)\.com\/s\/([^/?#]+)/i);
    if (match) {
      let password = "";
      try { password = new URL(raw).searchParams.get("pwd") || ""; } catch { /* Keep empty. */ }
      return { shareKey: match[1], password };
    }
  }
  return null;
}

/// Every netdisk the CatVod cloud contract can put in a play id, and whether this
/// gateway can resolve it. Quark, UC, 123 and Baidu are implemented; the rest must
/// fail with a name and a reason rather than being handed to AVPlayer, which would
/// only spin on a share page.
const CLOUD_PROVIDERS = {
  tianyi: "天翼云盘",
  aliyun: "阿里云盘",
  pan115: "115 网盘",
  "115": "115 网盘",
  guangya: "光雅/光年",
  xunlei: "迅雷云盘"
};

function unsupportedProvider(providerID) {
  const name = CLOUD_PROVIDERS[providerID] || "该网盘";
  return new GatewayError("CLOUD_PROVIDER_UNSUPPORTED",
    `这条线路是${name}，它的分享链接解析还没有接完。`
    + "可以先换这条资源的其他线路；已登录账号的网盘文件可在「我的网盘」里直接播。", 422);
}

/// Quark and UC: verify the share token, walk the share, copy into a private
/// cache folder, then ask the drive for a play address.
async function playQuarkFamily(id, credentials, fetchValue, service) {
  const episode = parseCatVodQuarkEpisode(id, service);
  if (!episode) return null;
  if (!credentials?.[service.cookieField]) {
    throw new GatewayError("CLOUD_AUTH_REQUIRED",
      `请先在「猫源 → 网盘账号配置」里保存${service.name}网盘 Cookie`, 401);
  }
  try {
    return await playQuarkSourceEpisode(episode.file, credentials, fetchValue,
      episode.mode === "original", service);
  } catch (error) {
    const authentication = error?.code === "CLOUD_AUTH_REQUIRED";
    throw new GatewayError(authentication ? "CLOUD_AUTH_REQUIRED" : "CLOUD_PLAYBACK_FAILED",
      authentication ? `${service.name}登录已失效，请在网盘账号配置里更新 Cookie`
        : `${service.name}播放地址解析失败，请重新打开资源详情或稍后重试`,
      authentication ? 401 : 502);
  }
}

export async function resolveCatVodCloudPlayer(argumentsValue, credentials, fetchValue) {
  const descriptor = decodeCatVodEpisode(argumentsValue.id);
  const providerID = String(descriptor?.providerId || "").toLowerCase();

  if (providerID === "quark") {
    return playQuarkFamily(argumentsValue.id, credentials, fetchValue, QUARK_SERVICES.quark);
  }
  if (providerID === "uc") {
    return playQuarkFamily(argumentsValue.id, credentials, fetchValue, QUARK_SERVICES.uc);
  }
  if (providerID === "123" || providerID === "pan123") {
    const share = share123FromEpisode(descriptor);
    if (share) {
      try {
        return await play123ShareEpisode({
          ...share,
          fileId: fileIDFromEpisode(descriptor, providerID),
          fetchValue
        });
      } catch (error) {
        if (error?.code) throw error;
        throw new GatewayError("CLOUD_PLAYBACK_FAILED",
          `123 网盘播放地址解析失败（${error?.message || "请稍后重试"}）`, 502);
      }
    }
  }

  if (!descriptor) return null;

  // 分享页：需要账号的走解析。百度已接，其余先看能不能退到直链。
  const share = shareURLFromEpisode(descriptor);
  if (share) {
    if (providerID === "baidu" || /pan\.baidu\.com|yun\.baidu\.com/i.test(share)) {
      return await playBaiduShare(share, credentials, fetchValue,
        fileIDFromEpisode(descriptor, providerID));
    }
    // 阿里云盘 / 115 / 天翼 / 光雅：插件若把 file_id 一起给了，且本机保存了
    // 对应账号，就能像「我的网盘」那样用账号凭证直接取链，不必啃分享页。
    const accountDriveKeys = { aliyun: "aliyun", "115": "pan115", pan115: "pan115", tianyi: "tianyi", guangya: "guangya" };
    const driveKey = accountDriveKeys[providerID];
    if (driveKey) {
      const fileID = fileIDFromEpisode(descriptor, providerID);
      const drive = driveFor(driveKey);
      if (fileID && drive && String(credentials?.[drive.credentialField] || "").length > 0) {
        try {
          const link = await drive.link(credentials, { id: fileID, name: fileID });
          if (link?.url) return { parse: 0, jx: 0, url: link.url, header: link.headers || {} };
        } catch { /* fall through to the explicit hint below */ }
        throw new GatewayError("CLOUD_PLAYBACK_FAILED",
          `这条${drive.name}线路没能取到播放地址，请确认账号有效，或到「我的网盘」里直接播放该文件`, 502);
      }
    }
    const fallback = directPlaybackFromEpisode(descriptor);
    if (fallback) return fallback;
    // 这个网盘本身支持账号取链，只是这条分享线路没给出文件 id 或本机没登录该
    // 账号——别笼统说「解析没接完」（会让已登录的人以为功能没做），给可行动的话。
    if (driveKey) {
      const drive = driveFor(driveKey);
      throw new GatewayError("CLOUD_SHARE_NEEDS_ACCOUNT",
        `这条${drive?.name || "网盘"}分享线路没有给出文件编号，无法直接解析。`
        + "可在「我的网盘」里登录该账号后直接播放这个文件，或换一条普通线路。", 422);
    }
    throw unsupportedProvider(providerID || "unknown");
  }

  // 已经解析好的 CDN 直链，或插件自己起的本地代理：带对头就能播。
  const direct = directPlaybackFromEpisode(descriptor);
  if (direct) return direct;

  if (providerID && providerID in CLOUD_PROVIDERS) {
    throw unsupportedProvider(providerID);
  }
  return null;
}
