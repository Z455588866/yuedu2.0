"""lxml.etree 的替身：解析用 html5lib，XPath 用 elementpath。

为什么不用 lxml 本身：它是 C 扩展，iOS 上必须交叉编译，而这里的目标是"拿来就能跑"。
html5lib 是纯 Python 的 HTML5 解析器（容错规则和浏览器一致，脏页面的表现比 lxml 还接近
真实浏览器）；elementpath 是纯 Python 的 XPath 1.0 实现，`//a[contains(@href,"/m/")]`
这种写法都支持。两者合起来覆盖了这批源实际用到的全部语法。
"""
import xml.etree.ElementTree as _etree

import html5lib
from elementpath import select as _select

HTMLParser = html5lib.HTMLParser

# lxml 里这几个常量偶尔会被读到，给个等价物。
XMLParser = HTMLParser


class _Element:
    """包一层，让结果像 lxml 的元素：`.xpath()` / `.get()` / `.text` / `.tag`。"""

    __slots__ = ("_node",)

    def __init__(self, node):
        self._node = node

    def xpath(self, path, namespaces=None, **kwargs):
        return _wrap_all(_select(self._node, path, namespaces=namespaces))

    def get(self, key, default=None):
        return self._node.get(key, default)

    def getparent(self):
        return None

    def __getattr__(self, name):
        return getattr(self._node, name)

    def __iter__(self):
        return iter(_wrap_all(list(self._node)))

    def __len__(self):
        return len(self._node)

    def __getitem__(self, index):
        value = self._node[index]
        return _Element(value) if isinstance(value, _etree.Element) else value

    def __repr__(self):
        return "<Element %s>" % self._node.tag


def _wrap_all(values):
    if not isinstance(values, list):
        return values
    return [_Element(v) if isinstance(v, _etree.Element) else v for v in values]


def _root(value):
    if isinstance(value, _Element):
        return value
    if isinstance(value, _etree.Element):
        return _Element(value)
    return None


def HTML(text, parser=None, base_url=None):
    """`etree.HTML(html)`：接受 str 或 bytes，返回根元素。"""
    if isinstance(text, _Element):
        return text
    if isinstance(text, (bytes, bytearray)):
        text = bytes(text).decode("utf-8", "ignore")
    # html5lib 的 etree 树构建器直接产出 ElementTree 元素，带正确的 text/tail。
    document = html5lib.parse(text or "", treebuilder="etree", namespaceHTMLElements=False)
    return _Element(document)


def fromstring(text, parser=None, base_url=None):
    return HTML(text)


def tostring(element, encoding="unicode", **kwargs):
    node = element._node if isinstance(element, _Element) else element
    data = _etree.tostring(node, encoding="unicode")
    if encoding in ("unicode", str):
        return data
    return data.encode(encoding or "utf-8")


def Element(tag, attrib=None, **extra):
    return _Element(_etree.Element(tag, attrib or {}, **extra))


def SubElement(parent, tag, attrib=None, **extra):
    node = parent._node if isinstance(parent, _Element) else parent
    return _Element(_etree.SubElement(node, tag, attrib or {}, **extra))


def _is_element(value):
    return isinstance(value, (_Element, _etree.Element))


def strip_tags(element, encoding=None):
    node = element._node if isinstance(element, _Element) else element
    return "".join(node.itertext())


def tostringlist(*args, **kwargs):  # 极少用到，保持导入不报错
    return [tostring(*args, **kwargs)]


class _XPath:
    def __init__(self, path):
        self.path = path

    def __call__(self, element):
        node = element._node if isinstance(element, _Element) else element
        return _wrap_all(_select(node, self.path))


def XPath(path):
    return _XPath(path)
