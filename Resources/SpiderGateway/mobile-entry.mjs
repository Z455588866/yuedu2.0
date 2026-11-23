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
    catVodMaxSessions: 5, catVodIdleMs: 30 * 60 * 1000,
    // A cold bundle plus a slow upstream needs the CatVod players' own budget
    // (search 60s, play 90s, the rest 150s); 40s failed healthy-but-slow sources.
    workerTimeoutMs: 150000,
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
      const current = JSON.parse(bridge.configuration());
      nodeBundleCache.allowedURLs = current.nodeBundleAllowedURLs;
      nodeBundleCache.allowHTTP = current.nodeBundleAllowedURLs.some(url => url.startsWith('http://'));
      config.cloudConfig = current.cloudConfig || {};
      config.token = current.token;
    }
  });
  const address = await gateway.listen();
  bridge.ready(`http://127.0.0.1:${address.port}`);
  return gateway;
}

if (process.argv[1]?.endsWith('/mobile-entry.mjs')) {
  const bridge = process._linkedBinding('yuedu_mobile');
  startMobileGateway(bridge).catch(() => bridge.failed());
}
