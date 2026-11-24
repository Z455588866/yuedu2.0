"""`Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()` 这一套。"""
from Crypto.Cipher import AES as _AES


class _Algorithm:
    def __init__(self, key):
        self.key = bytes(key)


class algorithms:
    AES = _Algorithm


class _Mode:
    def __init__(self, name, iv=None, nonce=None):
        self.name = name
        self.iv = iv if iv is not None else nonce


class modes:
    CBC = lambda iv: _Mode("cbc", iv=iv)          # noqa: E731
    ECB = lambda: _Mode("ecb")                     # noqa: E731
    CTR = lambda nonce: _Mode("ctr", nonce=nonce)  # noqa: E731
    OFB = lambda iv: _Mode("ofb", iv=iv)           # noqa: E731
    CFB = lambda iv: _Mode("cfb", iv=iv)           # noqa: E731


_MODES = {"cbc": _AES.MODE_CBC, "ecb": _AES.MODE_ECB, "ctr": _AES.MODE_CTR}


class _Context:
    def __init__(self, algorithm, mode, decrypting):
        code = _MODES.get(mode.name)
        if code is None:
            raise NotImplementedError("这里只实现了 CBC/ECB/CTR，收到 %r" % (mode.name,))
        kwargs = {}
        if code == _AES.MODE_CBC:
            kwargs["iv"] = mode.iv
        self._cipher = _AES.new(algorithm.key, code, **kwargs)
        self._decrypting = decrypting
        self._buffer = b""

    def update(self, data):
        data = bytes(data)
        if not self._buffer:
            return self._cipher.decrypt(data) if self._decrypting else self._cipher.encrypt(data)
        data = self._buffer + data
        return self._cipher.decrypt(data) if self._decrypting else self._cipher.encrypt(data)

    def finalize(self):
        self._buffer = b""
        return b""

    def update_into(self, data, buffer):
        raise NotImplementedError("update_into 没有实现")


class Cipher:
    def __init__(self, algorithm, mode):
        self.algorithm = algorithm
        self.mode = mode

    def encryptor(self):
        return _Context(self.algorithm, self.mode, False)

    def decryptor(self):
        return _Context(self.algorithm, self.mode, True)
