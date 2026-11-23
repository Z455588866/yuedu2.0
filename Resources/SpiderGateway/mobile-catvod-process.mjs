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
    env: { NODE_ENV: 'development', UNDICI_NO_WASM_SIMD: '1' },
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
      void worker.terminate();
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
  result.kill = () => { void worker.terminate(); };
  return result;
}
