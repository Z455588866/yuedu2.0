import path from 'node:path';
import { loadConfig } from './config.mjs';
import { createGateway } from './server.mjs';
import { CatVodManager } from './catvod-manager.mjs';
import { NodeBundleCache } from './node-bundle-cache.mjs';
import { createMobileCatVodProcess } from './mobile-catvod-process.mjs';

// This binding is available only on the native engine thread. Credentials never
// enter argv, environment variables, bootstrap files or provider workers.
export async function startMobileGateway(bridge, dependencies = {}) {
  const initial = JSON.parse(bridge.configuration());
  const config = loadConfig(initial);
  Object.assign(config, {
    host: '127.0.0.1', port: 0, workerCommand: '',
    cacheDir: path.join(initial.cacheRoot, 'jars'),
    nodeBundleCacheDir: path.join(initial.cacheRoot, 'bundles'),
    nodeBundleRuntimeDir: path.join(initial.cacheRoot, 'runtime'),
    nodeBundleAllowHTTP: initial.nodeBundleAllowedURLs.some(url => url.startsWith('http://')),
    // Bundles are kept warm the way the CatVod players keep them: each one's
    // engine starts once and is reused, because a cold start means download,
    // compile and server boot for every switch. The heap cap per worker keeps the
    // app inside the jetsam budget; idle only retires a session after half an hour.
    catVodMaxSessions: 4, catVodIdleMs: 30 * 60 * 1000,
    // The runner enforces short per-action budgets (browse 25s, detail/search
    // 30s, play 90s). This is only the outer backstop for a wedged child
    // process, so it just has to clear the longest one: 150s meant a stuck
    // source kept the UI spinning for two and a half minutes.
    workerTimeoutMs: 100000,
    // Bundles are immutable once imported; keep the resolved artifact much
    // longer so switching back does not re-download + re-hash a 16MB file.
    artifactCacheTTLms: 10 * 60 * 1000,
    // An imported interface rarely changes. Half an hour of manifest trust means
    // a warm launch reads the script from disk with zero network, instead of
    // paying an 0.2–2s manifest round-trip before the first category can render.
    nodeBundleManifestTTLms: 30 * 60 * 1000,
    nodeBundleManifestTimeoutMs: 6_000,
    responseCacheOptions: { ttlMs: 2 * 60 * 1000, maxEntries: 128 }
  });
  const nodeBundleCache = new NodeBundleCache(config);
  const catVod = new CatVodManager({ ...config, createProcess: createMobileCatVodProcess,
    cloudAccounts: () => config.cloudConfig || {} });
  const gateway = createGateway(config, {
    nodeBundleCache, catVod, ...dependencies,
    beforeRequest() {
      // 这个函数跑在**每个请求**前面。配置读坏了（空串、进程正在退出、
      // 序列化失败）不能让所有请求一起 500——那样界面看起来就是"引擎挂了"。
      // 出错就沿用上一份已知可用的配置。
      let current;
      try {
        current = JSON.parse(bridge.configuration());
      } catch {
        return;
      }
      // JSON.parse("null") 不抛错但会给出 null，直接取字段就是 TypeError。
      if (!current || typeof current !== 'object' || Array.isArray(current)) return;
      // 对齐 tvbox-silicon：不再按 URL 白名单/协议放行或拦截，导入的地址直接信任。
      if (current.cloudConfig && typeof current.cloudConfig === 'object' && !Array.isArray(current.cloudConfig)) {
        config.cloudConfig = current.cloudConfig;
      }
      if (typeof current.token === 'string') config.token = current.token;
      // Python 是后台启动的，往往比网关晚几秒就绪；端口到了这里才算生效，
      // 否则新端口要等到下次冷启动才被读到。
      config.pythonSpiderPort = current.pythonSpiderPort || undefined;
    }
  });
  const address = await gateway.listen();
  bridge.ready(`http://127.0.0.1:${address.port}`);
  return gateway;
}

if (process.argv[1]?.endsWith('/mobile-entry.mjs')) {
  const bridge = process._linkedBinding('yuedu_mobile');
  // 起来之前失败 = 引擎没服务，必须把原因带出去；起来之后的异常 = 单个请求
  // 的疏漏，只记日志，不能让整个引擎跟着陪葬。
  let serving = false;
  const report = (error) => {
    const reason = String(error?.stack ?? error?.message ?? error ?? 'unknown error');
    console.error('gateway failure:', reason);
    if (serving) return;
    try { bridge.failed(reason); } catch { bridge.failed(); }
  };
  // 之前这里什么都没兜：一个未接的 promise 或 throw 就直接把 V8 进程带走，
  // Swift 侧只看到线程结束，界面显示「手机内置脚本引擎已停止」，真实原因
  // （哪个请求、什么错）全丢，用户除了重启 App 没有任何办法。
  // Node 的默认行为是 unhandledRejection 直接退出进程，网关是长驻服务，
  // 这个默认值对它就是致命的。
  process.on('uncaughtException', report);
  process.on('unhandledRejection', report);
  startMobileGateway(bridge).then(() => { serving = true; }).catch((error) => {
    report(error);
    // 留出窗口让 Swift 那侧（25ms 轮询）读到 startupError 再退出。
    setTimeout(() => process.exit(1), 1500);
  });
}
