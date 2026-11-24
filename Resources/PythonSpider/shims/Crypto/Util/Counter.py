"""CTR 计数器对象，只保留插件会用到的字段。"""


class Counter:
    def __init__(self, nbits=128, prefix=b"", suffix=b"", initial_value=1,
                 little_endian=False, allow_wraparound=False):
        self.nbits = nbits
        self.prefix = bytes(prefix)
        self.suffix = bytes(suffix)
        self.initial_value = int(initial_value)
        self.little_endian = little_endian
        self.allow_wraparound = allow_wraparound

    def new(self, nbits, **kwargs):
        return Counter(nbits, **kwargs)


def new(nbits=128, prefix=b"", suffix=b"", initial_value=1, little_endian=False,
        allow_wraparound=False):
    return Counter(nbits, prefix, suffix, initial_value, little_endian, allow_wraparound)
