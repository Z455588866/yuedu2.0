// Chunked parallel read-ahead cache for the host playback proxy.
//
// This is the HTTP-layer equivalent of tvbox-silicon's `CloudStreams`: byte
// ranges are served from fixed-size chunks fetched over a few parallel
// connections (drives throttle each connection), with a bounded read-ahead
// window. Unlike the Swift resource loader this sits in the proxy, so it works
// for both the system player and VLC, which is what this host uses for MKV and
// friends.
//
// It is deliberately dependency-free and side-effect-free: callers supply a
// `resolve(start, end)` that fetches one byte range and returns a Buffer. Any
// failure is caught by the caller, which falls back to the plain passthrough —
// so a cache bug can never make playback worse than the verified baseline.

export const CHUNK_SIZE = 2 << 20;   // 2 MiB, same as CloudStreams.chunkSize
const MAX_STREAMS = 3;
const MAX_CHUNKS = 64;
const TTL_MS = 5 * 60 * 1000;

/// One cached media stream: a bounded LRU of aligned chunks.
export class StreamCache {
  constructor(total, headers, resolve, { parallel = 6, readAhead = 4, chunkSize = CHUNK_SIZE } = {}) {
    this.total = total;
    this.headers = headers;
    this.resolve = resolve;
    this.parallel = Math.max(1, parallel);
    this.readAhead = Math.max(0, readAhead);
    this.chunkSize = chunkSize;
    this.chunks = new Map();          // index -> Buffer
    this.inflight = new Map();        // index -> Promise<Buffer>
    this.recent = [];                 // LRU, oldest first
    this.touched = Date.now();
  }

  get chunkCount() { return Math.ceil(this.total / this.chunkSize); }

  touch() { this.touched = Date.now(); }
  get expired() { return Date.now() - this.touched > TTL_MS; }

  remember(index, bytes) {
    this.chunks.set(index, bytes);
    const at = this.recent.indexOf(index);
    if (at >= 0) this.recent.splice(at, 1);
    this.recent.push(index);
    while (this.recent.length > MAX_CHUNKS) {
      const old = this.recent.shift();
      this.chunks.delete(old);
    }
    this.touched = Date.now();
  }

  async chunk(index) {
    if (this.chunks.has(index)) {
      const at = this.recent.indexOf(index);
      if (at >= 0) this.recent.splice(at, 1);
      this.recent.push(index);
      this.touched = Date.now();
      return this.chunks.get(index);
    }
    if (this.inflight.has(index)) return this.inflight.get(index);
    const first = index * this.chunkSize;
    const last = Math.min(this.total, first + this.chunkSize) - 1;
    const task = Promise.resolve()
      .then(() => this.resolve(first, last))
      .then((bytes) => {
        if (!Buffer.isBuffer(bytes) || bytes.length !== last - first + 1) {
          throw new Error(`short chunk ${index}`);
        }
        this.remember(index, bytes);
        return bytes;
      })
      .finally(() => { this.inflight.delete(index); });
    this.inflight.set(index, task);
    return task;
  }

  /// All bytes in [start, end], fetched chunk-by-chunk with at most `parallel`
  /// requests in flight. `end` is inclusive, as in an HTTP Range header.
  async read(start, end) {
    this.touch();
    if (!(start >= 0 && end >= start && start < this.total)) {
      throw new Error("invalid range");
    }
    end = Math.min(end, this.total - 1);
    const first = Math.floor(start / this.chunkSize);
    const last = Math.floor(end / this.chunkSize);
    const parts = [];
    // Fetch needed chunks in bounded parallel batches, keeping order.
    for (let batch = first; batch <= last; batch += this.parallel) {
      const stop = Math.min(last + 1, batch + this.parallel);
      const indices = [];
      for (let i = batch; i < stop; i += 1) indices.push(i);
      parts.push(...await Promise.all(indices.map((i) => this.chunk(i))));
    }
    const merged = Buffer.concat(parts);
    const from = start - first * this.chunkSize;
    const to = from + (end - start + 1);
    // Fire-and-forget read-ahead; failures are ignored, the next read retries.
    const aheadEnd = Math.min(this.chunkCount - 1, last + this.readAhead);
    for (let i = last + 1; i <= aheadEnd; i += 1) {
      if (!this.chunks.has(i) && !this.inflight.has(i)) {
        this.chunk(i).catch(() => {});
      }
    }
    return merged.subarray(from, to);
  }
}

/// Bounded registry of streams, keyed by a stable hash of the media spec.
export class MediaCache {
  constructor() {
    this.streams = new Map();
  }

  get(key) {
    const value = this.streams.get(key);
    if (!value) return null;
    if (value.expired) { this.streams.delete(key); return null; }
    // Refresh LRU order at the registry level too.
    this.streams.delete(key);
    this.streams.set(key, value);
    return value;
  }

  put(key, stream) {
    this.streams.set(key, stream);
    while (this.streams.size > MAX_STREAMS) {
      const oldest = this.streams.keys().next().value;
      this.streams.delete(oldest);
    }
    return stream;
  }

  remove(key) { this.streams.delete(key); }
  clear() { this.streams.clear(); }
}

/// Parse a single `Range: bytes=A-B` / `bytes=A-` header against a known total.
export function parseRange(header, total) {
  const match = /^\s*bytes=(\d*)-(\d*)\s*$/.exec(String(header || ""));
  if (!match || (!match[1] && !match[2])) return null;
  let start;
  let end;
  if (match[1] === "") {
    // suffix range: last N bytes
    const n = Number(match[2]);
    if (!Number.isFinite(n) || n <= 0) return null;
    start = Math.max(0, total - n);
    end = total - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === "" ? total - 1 : Number(match[2]);
  }
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  if (start >= total) return { unsatisfiable: true, total };
  return { start, end: Math.min(end, total - 1), total };
}

/// Total length from an upstream 206 Content-Range ("bytes A-B/T") or a plain
/// Content-Length. Returns 0 when it cannot be determined.
export function totalFromHeaders(headers = {}) {
  const range = String(headers["content-range"] || "");
  const match = /bytes\s+\d+-\d+\/(\d+)/i.exec(range);
  if (match) return Number(match[1]) || 0;
  const length = Number(headers["content-length"]);
  return Number.isFinite(length) && length > 0 ? length : 0;
}

export const mediaCacheTestSupport = { MAX_STREAMS, MAX_CHUNKS, TTL_MS };
