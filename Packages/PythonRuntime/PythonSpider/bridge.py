"""把 Python 猫源包装成"站点 API"，接在已有的 Node 网关后面。

为什么要这一层：App 里所有源都走同一条路——站点有个 `api` 地址，网关按 `/home`、
`/category`、`/detail`、`/search`、`/play` 去 POST，拿回来的就是 TVBox 那套 JSON。
Python 源只要也用这套路径答话，网关和界面一行都不用改，就不用为它单开一条分支。

所以这里起一个只在 127.0.0.1 上监听的 HTTP 服务：
    POST /py/<key>/home       {"filter": true}
    POST /py/<key>/category   {"id": "...", "page": "1", "filters": {...}}
    POST /py/<key>/detail     {"id": "..."}
    POST /py/<key>/search     {"wd": "...", "quick": false, "page": "1"}
    POST /py/<key>/play       {"flag": "...", "id": "...", "flags": []}
    GET  /v1/pyspider/sites   给网关的站点清单

每个源一个 Session（插件实例长期存活），并按 LRU 淘汰，避免 83 个源各留一份解释器状态。
"""
import argparse
import hashlib
import json
import os
import re
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
for extra in ("vendor", "shims", HERE):
    candidate = os.path.join(HERE, extra)
    if candidate not in sys.path:
        sys.path.append(candidate)

import host as pyhost  # noqa: E402

MAX_SESSIONS = 6


def log(*values):
    print("PYBRIDGE", *values, file=sys.stderr, flush=True)


class Registry:
    """源清单 + 会话池。"""

    def __init__(self, cache_root, sources, scan=None):
        self.cache_root = cache_root
        self.scripts = os.path.join(cache_root, "scripts")
        os.makedirs(self.scripts, exist_ok=True)
        self.sources = {}   # token -> 源
        self.sessions = {}
        self.used = 0
        self.lock = threading.Lock()
        for source in sources or []:
            self.add(source)
        for source in self.discover(scan):
            self.add(source)

    @staticmethod
    def discover(directory):
        """扫描目录里的 .py：放进去就能用，不必再维护一份清单。"""
        if not directory or not os.path.isdir(directory):
            return []
        found = []
        for name in sorted(os.listdir(directory)):
            if not name.lower().endswith(".py") or name.startswith("."):
                continue
            stem = os.path.splitext(name)[0]
            found.append({
                "key": "file:" + stem,
                "name": stem,
                "api": os.path.join(directory, name),
                "ext": "",
            })
        return found

    @staticmethod
    def token(key):
        """源的稳定标识。名字里常有中文和方括号，放进 URL 里不合适，统一取哈希。"""
        return hashlib.sha256(str(key).encode("utf-8")).hexdigest()[:16]

    def add(self, source):
        key = str(source.get("key") or "").strip()
        api = str(source.get("api") or "").strip()
        if not key or not api or len(key) > 200:
            return
        token = self.token(key)
        self.sources[token] = {
            "key": key,
            "token": token,
            "name": str(source.get("name") or key),
            "api": api,
            "ext": str(source.get("ext") or ""),
        }

    # —— 脚本落地：远程地址只下一次，按内容哈希存 ——

    def script_path(self, source):
        api = source["api"]
        if api.startswith("file://"):
            return api[7:]
        if not api.lower().startswith(("http://", "https://")):
            return api
        name = hashlib.sha256(api.encode("utf-8")).hexdigest()[:32] + ".py"
        path = os.path.join(self.scripts, name)
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return path
        headers = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)"}
        response = requests.get(api, headers=headers, timeout=30)
        response.raise_for_status()
        text = response.text
        if "class Spider" not in text and "def homeContent" not in text:
            raise RuntimeError("下载到的不是 Python 猫源（%s）" % api)
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, path)
        return path

    def session(self, token):
        with self.lock:
            self.used += 1
            entry = self.sessions.get(token)
            if entry:
                entry["used"] = self.used
                return entry["session"]
            source = self.sources.get(token)
            if not source:
                raise KeyError("没有这个 Python 源：%s" % token)
            path = self.script_path(source)
            created = pyhost.Session(
                script=path,
                cache=os.path.join(self.cache_root, "runtime", token),
                ext=source["ext"],
                api=source["api"],
            )
            self.sessions[token] = {"session": created, "used": self.used}
            self._trim(exclude=token)
            return created

    def _trim(self, exclude):
        """超过上限就关掉最久没用的那个（持锁调用）。"""
        while len(self.sessions) > MAX_SESSIONS:
            candidates = [(v["used"], k) for k, v in self.sessions.items() if k != exclude]
            if not candidates:
                return
            _, oldest = min(candidates)
            entry = self.sessions.pop(oldest)
            try:
                entry["session"].close()
            except Exception as error:  # noqa: BLE001
                log("close failed", oldest, error)

    def catalog(self, base):
        """给网关的站点清单。

        `token` 必须显式给出：源名多半是中文（`file:韩小圈`），网关要拿它
        拼站点 key，直接清洗名字会得到空串、多个源互相覆盖；哈希后的 token
        是纯 ASCII 且唯一。`api` 也用它，网关会原样转发到 /py/<token>。
        """
        return [
            {
                "key": source["key"],
                "token": token,
                "name": source["name"],
                "type": 4,
                "api": "%s/py/%s" % (base, token),
                "searchable": True,
                "filterable": True,
                "quickSearch": False,
                "ext": source["ext"],
            }
            for token, source in self.sources.items()
        ]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    registry = None
    base = ""

    def log_message(self, *args):
        pass

    def send_json(self, status, value):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/health":
            return self.send_json(200, {"ok": True, "sites": len(self.registry.sources)})
        if path == "/v1/pyspider/sites":
            return self.send_json(200, {"sites": self.registry.catalog(self.base)})
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        split = urlsplit(self.path)
        pieces = split.path.strip("/").split("/")
        if len(pieces) != 3 or pieces[0] != "py":
            return self.send_json(404, {"error": "not found"})
        key, action = pieces[1], pieces[2]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            return self.send_json(400, {"error": "请求体不是 JSON"})
        if not isinstance(payload, dict):
            payload = {}
        # 网关在站点初始化时 POST /init，Python 源在 Session 创建时已经 init 过了。
        if action == "init":
            return self.send_json(200, {"ok": True})
        try:
            session = self.registry.session(key)
            result = session.call(action, payload)
            return self.send_json(200, result if isinstance(result, dict) else {"result": result})
        except KeyError as error:
            return self.send_json(404, {"error": str(error)})
        except Exception as error:  # noqa: BLE001 —— 单个源出错不能拖垮整个服务
            return self.send_json(200, pyhost.envelope(error))


class Bridge:
    def __init__(self, cache_root, sources, port=0, scan=None):
        self.registry = Registry(cache_root, sources, scan)
        handler = type("H", (Handler,), {"registry": self.registry})
        self.server = ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.base = "http://127.0.0.1:%d" % self.port
        handler.base = self.base
        self.registry.base = self.base
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return self.port

    def stop(self):
        try:
            self.server.shutdown()
            self.server.server_close()
        except Exception:  # noqa: BLE001
            pass


def start(cache_root, sources, port=0, scan=None):
    """给 Swift 用的入口：起服务并返回 Bridge（取 .port）。"""
    bridge = Bridge(cache_root, sources, port, scan)
    bridge.start()
    log("listening", bridge.port, "sites", len(bridge.registry.sources))
    return bridge


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    parser.add_argument("--sources", help="源清单 JSON 文件：{sources: [...]}")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--scan", help="扫描这个目录里的 .py 作为源")
    parser.add_argument("--announce", help="把端口写进这个文件，供宿主读取")
    options = parser.parse_args(argv)
    sources = []
    if options.sources and os.path.exists(options.sources):
        with open(options.sources, encoding="utf-8") as stream:
            value = json.load(stream)
        sources = value.get("sources", value) if isinstance(value, dict) else value
    try:
        bridge = Bridge(options.cache, sources, options.port, options.scan)
    except Exception as error:  # noqa: BLE001
        print(json.dumps({"error": "%s: %s" % (type(error).__name__, error)}, ensure_ascii=False))
        return 1
    if options.announce:
        with open(options.announce, "w", encoding="utf-8") as stream:
            json.dump({"port": bridge.port}, stream)
    print(json.dumps({"port": bridge.port, "sites": len(bridge.registry.sources)}), flush=True)
    bridge.start()
    try:
        while True:
            threading.Event().wait(3600)
    except KeyboardInterrupt:
        bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
