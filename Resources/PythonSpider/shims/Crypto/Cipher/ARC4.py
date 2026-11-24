"""RC4。算法只有十几行，且是公开的标准实现，直接写出比拉一个包更可控。"""


class ARC4Cipher:
    def __init__(self, key):
        key = bytes(key)
        if not key:
            raise ValueError("RC4 需要非空 key")
        box = list(range(256))
        index = 0
        for position in range(256):
            index = (index + box[position] + key[position % len(key)]) & 0xFF
            box[position], box[index] = box[index], box[position]
        self._box = box
        self._i = 0
        self._j = 0
        self.block_size = 1

    def _stream(self, length):
        box, i, j = self._box, self._i, self._j
        out = bytearray(length)
        for n in range(length):
            i = (i + 1) & 0xFF
            j = (j + box[i]) & 0xFF
            box[i], box[j] = box[j], box[i]
            out[n] = box[(box[i] + box[j]) & 0xFF]
        self._i, self._j = i, j
        return bytes(out)

    def encrypt(self, data):
        data = bytes(data)
        stream = self._stream(len(data))
        return bytes(a ^ b for a, b in zip(data, stream))

    decrypt = encrypt


def new(key=None, *args, **kwargs):
    if key is None:
        key = kwargs.get("key")
    return ARC4Cipher(key)
