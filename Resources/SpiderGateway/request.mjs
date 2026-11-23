import { GatewayError } from "./errors.mjs";

const ACTIONS = new Set(["home", "category", "detail", "search", "player"]);
// `<key>` is whatever the catalog declared, percent-encoded by the gateway when
// it is not URL-safe. Real catalogs use keys like 「直」亿茶正经的Alist库 or
// "a b", which appear here as `%E3%80%8C...` after encoding. Accepting only
// \p{L}\p{N}_- rejected every one of them with
// "site.api must be csp_* or a valid /spider/<key>/<type> path" — which the app
// surfaced as "分类加载不了". A key can be any non-empty segment without a
// slash or whitespace; the path is only routed, never concatenated into a URL.
const CATVOD_API = /^\/spider\/[^/\s]+\/\d{1,2}$/u;

function requiredString(value, name, maximum = 4096) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new GatewayError("INVALID_REQUEST", `${name} must be a non-empty string`, 400);
  }
  if (value.length > maximum) {
    throw new GatewayError("INVALID_REQUEST", `${name} is too long`, 400);
  }
  return value;
}

// CatVod catalogs declare `site.ext` either as a string or as an object (for
// example `{"configurable":true}`). Spiders parse the JSON text on `init`, so an
// object is accepted here and flattened, instead of failing the whole request.
function optionalExt(value, name) {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") {
    if (value.length > 256 * 1024) throw new GatewayError("INVALID_REQUEST", `${name} is too long`, 400);
    return value;
  }
  if (typeof value !== "object") {
    throw new GatewayError("INVALID_REQUEST", `${name} must be a string or an object`, 400);
  }
  const text = JSON.stringify(value);
  if (text.length > 256 * 1024) throw new GatewayError("INVALID_REQUEST", `${name} is too long`, 400);
  return text;
}

export function validateInvokeRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new GatewayError("INVALID_REQUEST", "Request body must be a JSON object", 400);
  }
  if (body.version !== 1) throw new GatewayError("UNSUPPORTED_VERSION", "Only protocol version 1 is supported", 400);
  if (!ACTIONS.has(body.action)) throw new GatewayError("UNSUPPORTED_ACTION", "Unsupported Spider action", 400);
  if (!body.site || typeof body.site !== "object" || Array.isArray(body.site)) {
    throw new GatewayError("INVALID_REQUEST", "site must be an object", 400);
  }
  const site = {
    key: requiredString(body.site.key, "site.key", 256),
    api: requiredString(body.site.api, "site.api", 512),
    jar: requiredString(body.site.jar, "site.jar", 8192),
    ext: optionalExt(body.site.ext, "site.ext"),
    quickSearch: body.site.quickSearch === true
  };
  if (!site.api.startsWith("csp_") && !CATVOD_API.test(site.api)) {
    throw new GatewayError("UNSUPPORTED_API", "site.api must be csp_* or a valid /spider/<key>/<type> path", 400);
  }
  const args = body.arguments;
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    throw new GatewayError("INVALID_REQUEST", "arguments must be an object", 400);
  }
  validateArguments(body.action, args);
  return { action: body.action, site, arguments: args };
}

export function validateCatalogRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new GatewayError("INVALID_REQUEST", "Request body must be a JSON object", 400);
  }
  return { bundle: requiredString(body.bundle, "bundle", 8192) };
}

function validateArguments(action, args) {
  switch (action) {
    case "home":
      if (typeof args.filter !== "boolean") invalid("arguments.filter must be a boolean");
      break;
    case "category":
      requiredString(args.tid, "arguments.tid");
      requiredString(args.page, "arguments.page", 32);
      if (typeof args.filter !== "boolean") invalid("arguments.filter must be a boolean");
      if (!args.extend || typeof args.extend !== "object" || Array.isArray(args.extend)) invalid("arguments.extend must be an object");
      break;
    case "detail":
      if (!Array.isArray(args.ids) || args.ids.length === 0 || args.ids.length > 100 || args.ids.some((id) => typeof id !== "string" || id === "")) {
        invalid("arguments.ids must be a non-empty string array");
      }
      break;
    case "search":
      requiredString(args.keyword, "arguments.keyword");
      requiredString(args.page, "arguments.page", 32);
      if (typeof args.quick !== "boolean") invalid("arguments.quick must be a boolean");
      break;
    case "player":
      if (typeof args.flag !== "string") invalid("arguments.flag must be a string");
      requiredString(args.id, "arguments.id");
      if (!Array.isArray(args.vipFlags) || args.vipFlags.some((flag) => typeof flag !== "string")) invalid("arguments.vipFlags must be a string array");
      if (args.verifyResource !== undefined && typeof args.verifyResource !== "boolean") invalid("arguments.verifyResource must be a boolean");
      break;
  }
}

function invalid(message) {
  throw new GatewayError("INVALID_REQUEST", message, 400);
}
