import { playQuarkSourceEpisode } from "./cloud-pan.mjs";
import {
  directPlaybackFromEpisode,
  shareURLFromEpisode,
  fileIDFromEpisode,
  playBaiduShare
} from "./cloud-share.mjs";
import { GatewayError } from "./errors.mjs";

function invalidEpisode() {
  throw new GatewayError("INVALID_CLOUD_EPISODE", "夸克剧集信息无效，请重新打开资源详情", 400);
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
export function parseCatVodQuarkEpisode(id) {
  const episode = decodeCatVodEpisode(id);
  if (episode?.providerId !== "quark") return null;
  let token;
  try { token = JSON.parse(episode.playToken); } catch { invalidEpisode(); }
  if (!token || typeof token !== "object" || Array.isArray(token)) invalidEpisode();
  const file = {
    provider: "quark",
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

/// Every netdisk the CatVod cloud contract can put in a play id, and whether this
/// gateway can resolve it. Only Quark is implemented (`cloud-pan.mjs`, ported from
/// the Quark share/transcode API). The rest must fail with a name and a reason —
/// the bundle hands these ids to the host and expects the host to play them, so
/// passing them on to AVPlayer just spins on a share page.
const CLOUD_PROVIDERS = {
  quark: null,
  baidu: "百度网盘",
  tianyi: "天翼云盘",
  aliyun: "阿里云盘",
  uc: "UC 网盘",
  pan115: "115 网盘",
  "115": "115 网盘",
  pan123: "123 云盘",
  "123": "123 云盘",
  guangya: "光雅/光年",
  xunlei: "迅雷云盘"
};

function unsupportedProvider(providerID) {
  const name = CLOUD_PROVIDERS[providerID] || "该网盘";
  return new GatewayError("CLOUD_PROVIDER_UNSUPPORTED",
    `这条线路是${name}，它的分享解析还没有接完（夸克、百度已接入）。`
    + "可以先换这条资源的其他线路；自己盘里的文件可以在「我的网盘」里直接播。", 422);
}

export async function resolveCatVodCloudPlayer(argumentsValue, credentials, fetchValue) {
  const descriptor = decodeCatVodEpisode(argumentsValue.id);
  const providerID = String(descriptor?.providerId || "").toLowerCase();

  // 夸克：分享/转码的完整解析（最早接的一家）。
  if (providerID === "quark") {
    const episode = parseCatVodQuarkEpisode(argumentsValue.id);
    if (!episode) return null;
    if (!credentials.quarkCookie) {
      throw new GatewayError("CLOUD_AUTH_REQUIRED",
        "请先在「猫源 → 网盘账号配置」里保存夸克 Cookie", 401);
    }
    try {
      return await playQuarkSourceEpisode(episode.file, credentials, fetchValue, episode.mode === "original");
    } catch (error) {
      const authentication = error?.code === "CLOUD_AUTH_REQUIRED";
      throw new GatewayError(authentication ? "CLOUD_AUTH_REQUIRED" : "CLOUD_PLAYBACK_FAILED",
        authentication ? "夸克登录已失效，请在网盘账号配置里更新 Cookie"
          : "夸克播放地址解析失败，请重新打开资源详情或稍后重试", authentication ? 401 : 502);
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
    const fallback = directPlaybackFromEpisode(descriptor);
    if (fallback) return fallback;
    throw unsupportedProvider(providerID || "unknown");
  }

  // 已经解析好的 CDN 直链，或插件自己起的本地代理：带对头就能播。
  const direct = directPlaybackFromEpisode(descriptor);
  if (direct) return direct;

  if (providerID && providerID !== "quark" && providerID in CLOUD_PROVIDERS) {
    throw unsupportedProvider(providerID);
  }
  return null;
}
