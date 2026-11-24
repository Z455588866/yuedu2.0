"""TVBox / CatVod 的 Python 插件基类。

插件里写的是 `from base.spider import Spider`，然后继承它。这里只实现插件真正会调用到的
那一层：请求、正则、日志、缓存、依赖加载、代理地址。方法名和默认返回值沿用 TVBox 的
既有约定（那是生态里的事实标准），实现本身是本仓库自己的。

没有引入任何第三方框架，是因为 iOS 上装不了需要编译的 C 扩展；请求走 requests（纯 Python），
HTML 解析由插件自己选 bs4 / lxml 兼容层。
"""
import base64
import hashlib
import json
import os
import re
import time

import requests


class Runtime:
    """一个源一份：代理地址、缓存文件、依赖加载器。由宿主注入。"""

    proxy_url = "http://127.0.0.1:0/py-proxy?do=py"
    cache_file = None
    load_module = None
    directory = None


_runtime = Runtime()


def runtime_of(spider):
    return getattr(spider, "_tvbox_runtime", None) or _runtime


def _read_cache(runtime):
    if not runtime.cache_file:
        return {}
    try:
        with open(runtime.cache_file, encoding="utf-8") as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_cache(runtime, values):
    if not runtime.cache_file:
        return
    temporary = runtime.cache_file + ".tmp"
    try:
        with open(temporary, "w", encoding="utf-8") as stream:
            json.dump(values, stream, ensure_ascii=False)
        os.replace(temporary, runtime.cache_file)
    except OSError:
        pass


class Spider:
    def __init__(self):
        self.extend = ""

    # —— 插件要实现的部分，默认给空结果，免得少写一个方法就整站崩 ——

    def init(self, extend=""):
        pass

    def homeContent(self, filter=False):
        return {}

    def homeVideoContent(self):
        return {}

    def categoryContent(self, tid, pg, filter, extend):
        return {}

    def detailContent(self, ids):
        return {}

    def searchContent(self, key, quick=False, pg="1"):
        return {}

    def playerContent(self, flag, id, vipFlags=None):
        return {}

    def localProxy(self, param):
        return [404, "text/plain", ""]

    def liveContent(self, url):
        return ""

    def action(self, action):
        return ""

    def destroy(self):
        pass

    def getName(self):
        return ""

    def getDependence(self):
        return []

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def setExtendInfo(self, extend):
        self.extend = extend

    # —— 插件会调用的工具方法 ——

    def fetch(self, url, params=None, cookies=None, headers=None, timeout=10,
              verify=True, stream=False, allow_redirects=True):
        response = requests.get(url, params=params, cookies=cookies, headers=headers,
                                timeout=timeout, verify=verify, stream=stream,
                                allow_redirects=allow_redirects)
        response.encoding = "utf-8"
        return response

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None,
             timeout=10, verify=True, stream=False, allow_redirects=True):
        response = requests.post(url, params=params, data=data, json=json, cookies=cookies,
                                 headers=headers, timeout=timeout, verify=verify,
                                 stream=stream, allow_redirects=allow_redirects)
        response.encoding = "utf-8"
        return response

    def regStr(self, reg, src, group=1):
        match = re.search(reg, src)
        return match.group(group) if match else ""

    def removeHtmlTags(self, src):
        return re.sub("<.*?>", "", src or "")

    def cleanText(self, src):
        return re.sub("[\U0001F300-\U0001FAFF\u2600-\u27BF]", "", src or "")

    def html(self, content):
        from lxml import etree
        return etree.HTML(content)

    def str2json(self, text):
        return json.loads(text)

    def json2str(self, value):
        return json.dumps(value, ensure_ascii=False)

    def e64(self, text):
        return base64.b64encode(str(text).encode("utf-8")).decode("utf-8")

    def d64(self, text):
        return base64.b64decode(str(text).encode("utf-8")).decode("utf-8")

    def md5(self, text):
        return hashlib.md5(str(text).encode("utf-8")).hexdigest()

    def getProxyUrl(self, local=True):
        return runtime_of(self).proxy_url

    def log(self, message):
        if isinstance(message, (dict, list)):
            message = json.dumps(message, ensure_ascii=False)
        print(message, flush=True)

    def loadModule(self, name):
        runtime = runtime_of(self)
        if runtime.load_module:
            return runtime.load_module(name)
        from importlib.machinery import SourceFileLoader
        base = runtime.directory or "."
        return SourceFileLoader(name, os.path.join(base, name + ".py")).load_module()

    def loadSpider(self, name):
        spider = self.loadModule(name).Spider()
        spider._tvbox_runtime = runtime_of(self)
        return spider

    def getCache(self, key):
        value = _read_cache(runtime_of(self)).get(key)
        if isinstance(value, dict) and value.get("expiresAt", 0) < int(time.time()):
            self.delCache(key)
            return None
        return value

    def setCache(self, key, value):
        runtime = runtime_of(self)
        values = _read_cache(runtime)
        values[key] = value
        _write_cache(runtime, values)
        return "succeed"

    def delCache(self, key):
        runtime = runtime_of(self)
        values = _read_cache(runtime)
        values.pop(key, None)
        _write_cache(runtime, values)
        return "succeed"
