import { EventEmitter } from 'node:events';
import os from 'node:os';
import { PassThrough, Writable } from 'node:stream';
import { Worker } from 'node:worker_threads';

// The manager owns the same bounded request protocol on both platforms. iOS
// cannot spawn a process, so each untrusted bundle gets a disposable V8 worker.
//
// Node's permission model cannot sandbox a third-party CatVod bundle. It
// resolves every file access against a fixed allowlist, but real bundles touch
// paths we cannot predict (their own settings database, module lookups above the
// bundle directory, /dev/urandom, os.tmpdir()). Started with `--permission` a
// real bundle aborts before its HTTP server ever listens, and no allowlist we
// can enumerate fixes that — verified against real sources, where smdl (58
// sites) and lmentor (40 sites) only run once the flag is gone. The proven
// approach (tvbox-silicon) is a disposable worker thread with a hard heap cap:
// a run-away bundle dies alone, its calls fail, and it restarts on the next
// call. Worker-level fs scoping in mobile-catvod-worker.mjs still confines
// relative paths to the runtime directory.
const DEFAULT_HEAP_MB = 256;
function workerHeapLimit() {
  try {
    const eighth = Math.round(os.totalmem() / 2 ** 20 / 8);
    if (!Number.isFinite(eighth) || eighth <= 0) return DEFAULT_HEAP_MB;
    return Math.min(512, Math.max(DEFAULT_HEAP_MB, eighth));
  } catch {
    return DEFAULT_HEAP_MB;
  }
}

// `runnerPath` is still accepted for callers that pass it; once the permission
// model is gone it is no longer needed for an allowlist.
export function createMobileCatVodProcess({ bundlePath, runtimeDir, maxLineBytes, configPath, cloudAccounts }) {
  const result = new EventEmitter();
  const control = new PassThrough();
  const worker = new Worker(new URL('./mobile-catvod-worker.mjs', import.meta.url), {
    workerData: { bundlePath, runtimeDir, maxLineBytes, configPath, cloudAccounts },
    env: {
      NODE_ENV: 'development',
      UNDICI_NO_WASM_SIMD: '1',
      // 源站证书链不完整很常见（实测 40 个站点里 4 个），TVBox/FongMi 的
      // OkHttp 也是 trust-all。这里和 fetch-polyfill 里各设一次：worker 的
      // process.env 是独立副本，只靠运行时那次会在原生 fetch 上漏掉。
      NODE_TLS_REJECT_UNAUTHORIZED: '0',
      // 网盘账号：catvod-runner.bundleAccounts() 只从 process.env.CATVOD_ACCOUNTS
      // 读取已登录账号并构造 hostDB（/quark.cookie、/baidu/baidu_cookie …）。
      // 桌面 spawn 路径由 manager 注入该 env，但 iOS worker 的 env 是显式白名单，
      // 之前漏了这一项 —— cloudAccounts 虽然进了 workerData，bundleAccounts 却
      // 不读它，导致 hostDB 里所有网盘凭据恒为空，douer 等源每条网盘线路都回
      // 「Cookie 未填写 / 登录状态失效」，表现为网盘内容不显示、不播放。
      // 这里按桌面路径的同一格式补上，两端行为一致。
      CATVOD_ACCOUNTS: JSON.stringify(
        typeof cloudAccounts === 'function' ? cloudAccounts() : (cloudAccounts || {})
      ),
      // 诊断开关透传（见 catvod-manager.mjs）；没有设置时不带这个键。
      ...(process.env.CATVOD_NET_LOG ? { CATVOD_NET_LOG: process.env.CATVOD_NET_LOG } : {})
    },
    argv: [], stdout: true, stderr: true,
    resourceLimits: { maxOldGenerationSizeMb: workerHeapLimit(), stackSizeMb: 4 },
    name: 'tvbox-catvod'
  });
  let closed = false;
  worker.stdout.resume();
  worker.stderr.resume();
  worker.on('message', line => {
    // The bundle's own server is being used (player segments on its loopback
    // port); forward it so the session is not swept away as idle.
    if (line && typeof line === 'object' && line.activity) {
      result.emit('activity');
      return;
    }
    if (typeof line !== 'string' || Buffer.byteLength(line) > maxLineBytes) {
      result.emit('error', new Error('CatVod response exceeds the size limit'));
      // Do not terminate() a worker mid-cleanup: on iOS that aborts the whole
      // app (uv__io_poll -> err() -> abort()). The graceful path below closes
      // stdin and lets the runner unwind its libuv loop before the thread ends.
      result.kill();
      return;
    }
    control.write(line);
  });
  worker.once('error', error => result.emit('error', error));
  worker.once('exit', code => {
    closed = true;
    control.end();
    result.emit('exit', code);
    result.emit('close', code);
  });
  result.stdin = new Writable({
    write(chunk, encoding, callback) {
      if (closed) return callback(new Error('CatVod worker is closed'));
      worker.postMessage({ line: chunk.toString('utf8') });
      callback();
    },
    final(callback) { worker.postMessage({ close: true }); callback(); }
  });
  result.stdio = [result.stdin, null, null, control];
  // SIGABRT (uv__io_poll -> err() -> abort()) came from terminating a worker
  // while its libuv loop was still inside messagesServer.close()/stop(). On
  // iOS the worker shares the OS process with native code, so that abort kills
  // the whole app. Ask it to close gracefully instead: stdin.end() already
  // posts {close:true} (see result.stdin.final), the runner drains its queue,
  // closes the loopback server and stops its provider before the thread ends.
  // terminate() stays only as a last-resort safety net, delayed well past a
  // graceful shutdown so a normally-exiting worker is never cut mid-cleanup.
  let terminateTimer = null;
  result.kill = () => {
    if (closed) return;
    try { result.stdin.end(); } catch { /* already ended */ }
    if (terminateTimer) return;
    terminateTimer = setTimeout(() => {
      terminateTimer = null;
      if (!closed) {
        try { void worker.terminate(); } catch { /* already gone */ }
      }
    }, 5_000);
    terminateTimer.unref();
  };
  worker.once('exit', () => {
    if (terminateTimer) { clearTimeout(terminateTimer); terminateTimer = null; }
  });
  return result;
}
