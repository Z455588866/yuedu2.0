"""`lxml.html` 的替身：只有 fromstring / document_fromstring / tostring。"""
from .etree import HTML, tostring


def fromstring(html_text, parser=None, base_url=None):
    return HTML(html_text)


def document_fromstring(html_text, parser=None, base_url=None):
    return HTML(html_text)


def fragments_fromstring(html_text, **kwargs):
    return [HTML(html_text)]
