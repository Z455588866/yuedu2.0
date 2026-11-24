"""pyquery 的替身：用 bs4 + soupsieve 实现。

pyquery 是按 jQuery 的写法操作 HTML，底层是 lxml。这里换成 bs4，是因为选择器语法
本来就是 CSS，soupsieve 的支持度和 pyquery 用的那部分是重合的；而 bs4 是纯 Python，
iOS 上不用编译。

覆盖的是这批源实际会写的调用：`pq(html)`、`doc('script')`、`.find()`、`.eq()`、
`.attr()`、`.text()`、`.html()`、`.items()`、`len()`、遍历。
"""
import bs4
from bs4 import BeautifulSoup

__all__ = ["PyQuery", "pq"]


def _soup(value):
    if isinstance(value, BeautifulSoup):
        return value
    if isinstance(value, bs4.element.Tag):
        return value
    if isinstance(value, (bytes, bytearray)):
        return BeautifulSoup(bytes(value).decode("utf-8", "ignore"), "html.parser")
    return BeautifulSoup(str(value or ""), "html.parser")


class PyQuery:
    def __init__(self, *args, **kwargs):
        self._nodes = []
        if not args:
            return
        first = args[0]
        if isinstance(first, PyQuery):
            self._nodes = list(first._nodes)
        elif isinstance(first, (list, tuple)):
            self._nodes = [n for n in first if isinstance(n, bs4.element.Tag)]
        elif isinstance(first, bs4.element.Tag):
            selector = args[1] if len(args) > 1 else None
            self._nodes = first.select(selector) if selector else [first]
        else:
            soup = _soup(first)
            selector = args[1] if len(args) > 1 else None
            if selector:
                self._nodes = soup.select(selector)
            else:
                # pq(html) 得到的是整个文档，和 pyquery 一样能继续 .find()。
                self._nodes = [soup]

    # —— 选择 ——

    def __call__(self, selector, **kwargs):
        found = []
        for node in self._nodes:
            found.extend(node.select(selector))
        return PyQuery(found)

    def find(self, selector):
        return self(selector)

    def filter(self, selector):
        import soupsieve
        return PyQuery([n for n in self._nodes if soupsieve.match(selector, n)])

    def eq(self, index):
        try:
            return PyQuery([self._nodes[index]])
        except IndexError:
            return PyQuery([])

    def children(self, selector=None):
        found = []
        for node in self._nodes:
            found.extend(node.find_all(recursive=False))
        return PyQuery(found).filter(selector) if selector else PyQuery(found)

    def parent(self):
        seen, found = set(), []
        for node in self._nodes:
            parent = node.parent
            if parent is not None and id(parent) not in seen:
                seen.add(id(parent))
                found.append(parent)
        return PyQuery(found)

    def closest(self, selector):
        import soupsieve
        found = []
        for node in self._nodes:
            current = node
            while current is not None:
                if soupsieve.match(selector, current):
                    found.append(current)
                    break
                current = current.parent
        return PyQuery(found)

    # —— 读值 ——

    def attr(self, name, value=None):
        if not self._nodes:
            return None
        if value is not None:
            for node in self._nodes:
                node[name] = value
            return self
        return self._nodes[0].get(name)

    def text(self, value=None):
        if value is not None:
            for node in self._nodes:
                node.string = value
            return self
        return " ".join(" ".join(n.get_text().split()) for n in self._nodes).strip() if len(self._nodes) > 1 \
            else (" ".join(self._nodes[0].get_text().split()) if self._nodes else "")

    def html(self, value=None):
        if not self._nodes:
            return None
        if value is not None:
            for node in self._nodes:
                node.clear()
                node.append(BeautifulSoup(str(value), "html.parser"))
            return self
        return self._nodes[0].decode_contents()

    def outer_html(self):
        return str(self._nodes[0]) if self._nodes else ""

    def val(self):
        return self.attr("value")

    def items(self, selector=None):
        for node in self._nodes:
            for child in (node.select(selector) if selector else [node]):
                yield PyQuery([child])

    def remove(self):
        for node in self._nodes:
            node.decompose()
        self._nodes = []
        return self

    def has_class(self, name):
        return bool(self._nodes) and self._nodes[0].has_attr("class") and name in self._nodes[0]["class"]

    # —— 容器行为，让它能直接当 list 用 ——

    def __len__(self):
        return len(self._nodes)

    def __iter__(self):
        return iter(self._nodes)

    def __getitem__(self, index):
        if isinstance(index, slice):
            return PyQuery(self._nodes[index])
        try:
            return PyQuery([self._nodes[index]])
        except IndexError:
            return PyQuery([])

    def __bool__(self):
        return bool(self._nodes)

    def __str__(self):
        return "".join(str(n) for n in self._nodes)

    def __repr__(self):
        return "<PyQuery %r>" % (self._nodes[:1],)

    # 断言相等时偶尔会被用到
    def __eq__(self, other):
        return isinstance(other, PyQuery) and self._nodes == other._nodes


pq = PyQuery
