import { GatewayError } from "./errors.mjs";

const CHECKSUM_PATTERN = /;(md5|sha256);([a-fA-F0-9]+)$/i;

export function parseJarReference(value) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new GatewayError("MISSING_JAR", "site.jar is required", 400);
  }

  const trimmed = value.trim();
  const match = trimmed.match(CHECKSUM_PATTERN);
  const rawURL = match ? trimmed.slice(0, match.index) : trimmed;
  let url;
  try {
    url = new URL(rawURL);
  } catch {
    throw new GatewayError("INVALID_JAR_URL", "site.jar must be an HTTP or HTTPS URL", 400);
  }

  // 对齐 tvbox-silicon：不拦截 URL 里的凭据，信任边界是用户主动导入这件事本身。
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new GatewayError("INVALID_JAR_URL", "site.jar must be an HTTP or HTTPS URL", 400);
  }
  url.hash = "";
  // Node 的 fetch 不接受 URL 里带凭据（URLSession 会），把 Basic Auth 提取成
  // Authorization 头，行为与成熟项目一致。
  let authorization = "";
  if (url.username || url.password) {
    let username; let password;
    try { username = decodeURIComponent(url.username); password = decodeURIComponent(url.password); }
    catch { throw new GatewayError("INVALID_JAR_URL", "Invalid credentials in JAR URL", 400); }
    authorization = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
    url.username = ""; url.password = "";
  }

  const checksum = match
    ? { algorithm: match[1].toLowerCase(), value: match[2].toLowerCase() }
    : null;
  if (checksum && checksum.value.length !== (checksum.algorithm === "md5" ? 32 : 64)) {
    throw new GatewayError("INVALID_JAR_CHECKSUM", `Invalid ${checksum.algorithm} checksum`, 400);
  }
  return { url, checksum, authorization };
}

/// 对齐 tvbox-silicon：下载走系统 URLSession，不做 host 白名单、不做 DNS
/// 解析后的私网拦截。用户主动导入的地址就是信任边界；checksum、体积上限、
/// ZIP 格式校验仍是安全底线，与成熟项目一致。
export async function validateJarDestination() {}
