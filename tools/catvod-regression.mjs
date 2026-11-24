#!/usr/bin/env node
/// 猫源回归检查：把「接口能不能加载、站点首页能不能出内容」变成一条命令。
///
/// 之前这套验证是手工跑出来的（8 个接口、401 个站点逐个 home），改一次网络层
/// 就得重来一遍，而且没有基线可比。这里把它固化成脚本：
///
///   node tools/catvod-regression.mjs                     # 跑全部 bundle
///   node tools/catvod-regression.mjs --bundle 7a041d     # 只跑一个（digest 前缀）
///   node tools/catvod-regression.mjs --json out.json     # 落一份结果供对比
///   node tools/catvod-regression.mjs --fail-over 15      # 失败率超过 15% 时退出码 1
///
/// bundle 目录默认读 App 运行时缓存，可用 `--bundles <dir>` 指定。
/// 需要 `CATVOD_DISABLE_PERMISSION=1`（脚本会自动设，仅本机调试用）。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CatVodManager } from "../Resources/SpiderGateway/catvod-manager.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = (name, fallback = "") => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};

const bundleDir = path.resolve(flag("bundles",
  path.join(here, "../Resources/SpiderGateway/spider-gateway/data/bundles")));
const only = flag("bundle");
const jsonPath = flag("json");
const failOver = Number(flag("fail-over", "0"));
const concurrency = Number(flag("concurrency", "6"));

process.env.CATVOD_DISABLE_PERMISSION = "1";

if (!fs.existsSync(bundleDir)) {
  console.error(`找不到 bundle 目录：${bundleDir}\n先让 App 拉一次接口，或指向自己的缓存目录。`);
  process.exit(2);
}

const bundles = fs.readdirSync(bundleDir)
  .filter((name) => name.endsWith(".js") && !name.endsWith(".config.js"))
  .filter((name) => !only || name.startsWith(only));

if (bundles.length === 0) {
  console.error("没有匹配的 bundle");
  process.exit(2);
}

const runtimeRoot = fs.mkdtempSync(path.join(os.tmpdir(), "catvod-regression-"));
const manager = new CatVodManager({
  nodeBundleRuntimeDir: runtimeRoot,
  workerTimeoutMs: 60_000,
  catVodIdleMs: 15 * 60_000,
  catVodMaxSessions: 2,
  workerMaxLineBytes: 8 * 1024 * 1024,
  responseCacheOptions: {},
  cloudAccounts: {}
});

const started = Date.now();
const results = [];

for (const file of bundles) {
  const bundlePath = path.join(bundleDir, file);
  const configPath = bundlePath.replace(/\.js$/, ".config.js");
  const artifact = {
    path: bundlePath,
    digest: file,
    sourceURL: file,
    configPath: fs.existsSync(configPath) ? configPath : undefined
  };
  const row = { bundle: file, sites: 0, ok: 0, errors: [] };
  try {
    const catalog = await manager.catalog(artifact);
    const sites = (catalog.sites || []).filter((site) => typeof site?.api === "string");
    row.sites = sites.length;
    const queue = [...sites];
    const worker = async () => {
      while (queue.length > 0) {
        const site = queue.shift();
        try {
          await manager.invoke(artifact,
            { key: site.key, api: site.api, ext: site.ext || "" },
            "home", { filter: false });
          row.ok += 1;
        } catch (error) {
          row.errors.push({ site: site.key, error: String(error.message || error).slice(0, 160) });
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, sites.length) }, worker));
  } catch (error) {
    row.errors.push({ site: "(catalog)", error: String(error.message || error).slice(0, 160) });
  }
  const rate = row.sites ? ((row.ok / row.sites) * 100).toFixed(1) : "0.0";
  const failed = row.sites - row.ok;
  console.log(`${file.slice(0, 8)}  ${String(row.ok).padStart(3)}/${String(row.sites).padEnd(3)}  ${rate}%  失败 ${failed}`);
  for (const item of row.errors.slice(0, 6)) {
    console.log(`          ✗ ${item.site}  ${item.error}`);
  }
  row.bundlePath = bundlePath;
  results.push(row);
}

function summarize(results) {
  const sites = results.reduce((sum, row) => sum + row.sites, 0);
  const ok = results.reduce((sum, row) => sum + row.ok, 0);
  return { sites, ok, failed: sites - ok, rate: sites ? (ok / sites) * 100 : 0 };
}

const summary = summarize(results);
console.log(`\n合计 ${summary.ok}/${summary.sites} 可加载（${summary.rate.toFixed(1)}%），`
  + `失败 ${summary.failed}，耗时 ${((Date.now() - started) / 1000).toFixed(1)}s`);

if (jsonPath) {
  const payload = { generatedAt: new Date().toISOString(), summary, bundles: results };
  fs.writeFileSync(jsonPath, JSON.stringify(payload, null, 2));
  console.log(`已写入 ${jsonPath}`);
}

manager.close();
process.exit(failOver > 0 && summary.rate < 100 - failOver ? 1 : 0);
