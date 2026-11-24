"""一个 Python 猫源 = 一个 Session。

Swift 侧内嵌 CPython 后 import 本模块，调 `Session(...)` 与 `session.call(action, args)`；
`bridge.py` 在本地起 HTTP，把同样的东西暴露给已有的 Node 网关。两种用法共用这一份实现，
所以哪边出问题都是同一个原因。

设计上和 JS 侧 catvod-runner 对齐：
- 每个源一个 Session，插件实例长期存活（很多源把登录态或 token 存在 self 上）；
- 一次只处理一个请求，避免插件内部可变状态被并发踩坏；
- 失败要能说清是"站点返回 403"还是"插件自己报错"，否则界面上只能看到空列表。
"""
import inspect
import json
import os
import re
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from urllib.parse import parse_qsl, urlsplit

import requests
import urllib3

from base import spider as base

urllib3.disable_warnings()

PYTHON = sys.version_info[:2]


def log(*values):
    print("PY", *values, file=sys.stderr, flush=True)


def _accepts(function, count):
    """插件的方法签名不统一（有的 searchContent 只有 2 个参数），按实际参数个数调用。"""
    try:
        parameters = inspect.signature(function).parameters.values()
    except (TypeError, ValueError):
        return True
    if any(p.kind == p.VAR_POSITIONAL for p in parameters):
        return True
    positional = [p for p in parameters if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
    return len(positional) >= count


class SourceFailure(Exception):
    """上游站点自己失败：403/超时/DNS。与插件写错代码区分开，界面提示不一样。"""

    def __init__(self, host, status, message):
        super().__init__(message)
        self.host = host
        self.status = status


class _Recording:
    """记录最近一次上游失败，好让"插件返回空"能解释成"站点 403"。"""

    def __init__(self):
        self.local = threading.local()

    def set(self, failure):
        self.local.failure = failure

    def get(self):
        return getattr(self.local, "failure", None)


recording = _Recording()
_original_send = requests.Session.send


def _send(session, prepared, **options):
    host = urlsplit(prepared.url).netloc
    if options.get("timeout") is None:
        options["timeout"] = 20
    try:
        try:
            response = _original_send(session, prepared, **options)
        except requests.exceptions.SSLError:
            # 这些站点的证书链常年不完整（少中间证书是常态）。宿主在 JS 那边
            # 对同一批站点本来就是放行的，这里保持一致：先按标准校验证书，失败
            # 才退一步，而不是一上来就全放开。
            if not options.get("verify", True):
                raise
            options["verify"] = False
            response = _original_send(session, prepared, **options)
    except requests.RequestException as error:
        recording.set(SourceFailure(host, 0, "连不上 %s（%s）" % (host, type(error).__name__)))
        raise
    if response.status_code >= 400:
        recording.set(SourceFailure(host, response.status_code,
                                    "%s 返回 HTTP %d" % (host, response.status_code)))
    elif (failure := recording.get()) and failure.host == host:
        recording.set(None)
    return response


# 只接管一次；插件自己的 Session 也走这里。
if requests.Session.send is not _send:
    requests.Session.send = _send


def envelope(error):
    """把异常翻成界面上能看懂的一句话。"""
    detail = "".join(traceback.format_exception(type(error), error, error.__traceback__))
    log(detail)
    if isinstance(error, requests.RequestException) and recording.get():
        error = recording.get()
    if isinstance(error, SourceFailure):
        return {
            "error": str(error),
            "errorCode": "source_http" if error.status else "source_network",
            "host": error.host,
            "status": error.status,
        }
    if isinstance(error, (SyntaxError, IndentationError)):
        return {"error": "这个源本身写坏了：%s" % error, "errorCode": "script_syntax"}
    if isinstance(error, ImportError):
        return {"error": "这个源需要本机没有的模块：%s" % error, "errorCode": "script_import"}
    return {"error": "%s: %s" % (type(error).__name__, error), "errorCode": "script_error"}


def load_source(name, path):
    loader = SourceFileLoader(name, path)
    module = module_from_spec(spec_from_loader(name, loader))
    sys.modules[name] = module
    loader.exec_module(module)
    return module


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    session = None

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.answer(True)

    def do_HEAD(self):
        self.answer(False)

    def answer(self, include_body):
        try:
            status, mime, headers, data = self.session.proxy_response(self.path)
        except Exception as error:  # noqa: BLE001 —— 代理里任何异常都不能让线程崩掉
            status, mime, headers, data = 500, "text/plain; charset=utf-8", {}, str(error).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        for key, value in (headers or {}).items():
            if key.lower() in ("content-length", "transfer-encoding", "connection"):
                continue
            self.send_header(str(key), str(value))
        if "Accept-Ranges" not in (headers or {}):
            self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if include_body and data:
            self.wfile.write(data)


class Session:
    def __init__(self, script, cache, ext="", api="", profile=None):
        self.script = script
        self.cache = cache
        self.profile = profile or os.path.join(cache, "profile")
        os.makedirs(self.profile, exist_ok=True)
        self.lock = threading.Lock()
        self.runtime = base.Runtime()
        self.runtime.directory = os.path.dirname(script)
        self.runtime.cache_file = os.path.join(self.profile, "cache.json")
        self.runtime.load_module = self.load_dependency
        self.server = None
        self.runtime.proxy_url = self.start_proxy()
        self.spider = self.initialize(api)
        if ext:
            self.spider.extend = ext

    # —— 依赖：插件 getDependence() 里点名的同目录模块 ——

    def load_dependency(self, name):
        if name in sys.modules:
            return sys.modules[name]
        if not re.fullmatch(r"[\w.-]{1,80}", str(name)):
            raise ValueError("模块名不合法：%r" % (name,))
        path = os.path.join(self.runtime.directory, str(name) + ".py")
        if not os.path.exists(path):
            raise ImportError("缺少依赖模块 %s（插件要的同目录 .py 文件）" % name)
        return load_source(str(name), path)

    def start_proxy(self):
        self.server = ThreadingHTTPServer(
            ("127.0.0.1", 0),
            type("S", (ProxyHandler,), {"session": self}),
        )
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return "http://127.0.0.1:%d/py-proxy?do=py" % self.server.server_address[1]

    def initialize(self, api):
        module = load_source("tvbox_spider_" + re.sub(r"\W", "_", os.path.basename(self.script))[:40],
                             self.script)
        if not hasattr(module, "Spider"):
            raise RuntimeError("这个 .py 里没有 Spider 类，不是猫源插件")
        instance = module.Spider()
        instance._tvbox_runtime = self.runtime
        # 有的插件自己写了 __init__ 却没调 super()，这时候 self.extend 根本不存在。
        extension = getattr(instance, "extend", "") or ""
        if not extension and api:
            extension = dict(parse_qsl(urlsplit(api).query)).get("extend", "")
        try:
            instance.extend = extension
        except AttributeError:
            pass
        for name in (getattr(instance, "getDependence", lambda: [])() or []):
            self.load_dependency(str(name))
        instance.init(extension)
        return instance

    # —— localProxy：播放地址由插件自己产出时，播放器读回环 ——

    def proxy_response(self, path):
        params = dict(parse_qsl(urlsplit(path).query, keep_blank_values=True))
        result = list(self.spider.localProxy(params) or [])
        status = int(result[0]) if result else 404
        mime = str(result[1]) if len(result) > 1 and result[1] else "application/octet-stream"
        body = result[2] if len(result) > 2 else b""
        headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
        if len(result) > 4 and str(result[4]) == "1" and isinstance(body, str):
            import base64
            body = base64.b64decode(body.split("base64,", 1)[-1])
        if isinstance(body, requests.Response):
            body = body.content
        elif hasattr(body, "read"):
            body = body.read()
        elif body is None:
            body = b""
        elif not isinstance(body, (bytes, bytearray, str)):
            body = b"".join(c if isinstance(c, bytes) else str(c).encode() for c in body)
        return status, mime, headers, body.encode("utf-8") if isinstance(body, str) else bytes(body)

    # —— 五种动作 ——

    def call(self, action, args=None):
        args = args or {}
        spider = self.spider
        recording.set(None)
        with self.lock:
            if action == "home":
                result = self._home(spider.homeContent(True))
            elif action == "category":
                result = self._category(args)
            elif action == "detail":
                ids = args.get("id") or args.get("ids") or ""
                result = spider.detailContent(ids if isinstance(ids, list) else [ids])
            elif action == "search":
                result = self._search(args)
            elif action == "play":
                result = spider.playerContent(args.get("flag") or "", args.get("id") or "",
                                              args.get("flags") or [])
                # 老插件用 playUrl 而不是 url；TVBox 现在两个都认，这里统一成 url。
                if isinstance(result, dict) and not result.get("url") and result.get("playUrl"):
                    result = dict(result)
                    result["url"] = result["playUrl"]
            else:
                raise ValueError("不认识的动作：%s" % action)
        if result in (None, "", {}):
            if recording.get():
                raise recording.get()
            result = {}
        return result

    def _home(self, result):
        if not isinstance(result, dict):
            return {"class": [], "list": []}
        if not result.get("list"):
            try:
                extra = self.spider.homeVideoContent()
            except Exception:  # noqa: BLE001 —— 推荐位抓不到不影响分类列表
                extra = {}
            if isinstance(extra, dict) and extra.get("list"):
                result = dict(result)
                result["list"] = extra["list"]
        return result

    def _category(self, args):
        spider = self.spider
        tid = str(args.get("id") or args.get("tid") or "")
        page = str(args.get("page") or "1")
        filters = args.get("filters")
        if isinstance(filters, str):
            try:
                filters = json.loads(filters or "{}")
            except ValueError:
                filters = {}
        filters = filters or {}
        if _accepts(spider.categoryContent, 4):
            return spider.categoryContent(tid, page, True, filters)
        if _accepts(spider.categoryContent, 3):
            return spider.categoryContent(tid, page, filters)
        return spider.categoryContent(tid, page)

    def _search(self, args):
        spider = self.spider
        keyword = str(args.get("wd") or args.get("keyword") or "")
        quick = bool(args.get("quick"))
        page = str(args.get("page") or "1")
        # 有的源把翻页单独拆成 searchContentPage，优先用它，否则按签名塞 pg。
        paged = getattr(spider, "searchContentPage", None)
        if callable(paged) and "searchContentPage" in type(spider).__dict__:
            return paged(keyword, quick, page)
        if _accepts(spider.searchContent, 3):
            return spider.searchContent(keyword, quick, page)
        return spider.searchContent(keyword, quick)

    def close(self):
        try:
            self.spider.destroy()
        except Exception as error:  # noqa: BLE001
            log("destroy failed", error)
        if self.server:
            try:
                self.server.shutdown()
                self.server.server_close()
            except Exception:  # noqa: BLE001
                pass
