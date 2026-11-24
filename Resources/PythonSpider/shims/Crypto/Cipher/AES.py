"""AES：接口照 pycryptodome，底层用 pyaes。"""
import pyaes

block_size = 16
key_size = (16, 24, 32)

MODE_ECB = 1
MODE_CBC = 2
MODE_CFB = 3
MODE_OFB = 5
MODE_CTR = 6
MODE_OPENPGP = 7


class _Mode:
    """pycryptodome 的 AES 对象：`.encrypt(data)` / `.decrypt(data)` / `.block_size`。"""

    block_size = 16

    def __init__(self, key, mode, iv=None, counter=None, **options):
        self._mode = mode
        if mode == MODE_CTR:
            start = 0
            if counter is not None:
                start = int(getattr(counter, "initial_value", counter))
            self._engine = pyaes.AESModeOfOperationCTR(key, counter=pyaes.Counter(start))
        elif mode == MODE_CBC:
            if iv is None:
                raise ValueError("CBC 模式需要 iv")
            self._engine = pyaes.AESModeOfOperationCBC(key, iv=iv)
        elif mode == MODE_ECB:
            self._engine = pyaes.AESModeOfOperationECB(key)
        else:
            raise NotImplementedError("这里只实现了 ECB/CBC/CTR，收到 mode=%r" % (mode,))

    def encrypt(self, data):
        data = bytes(data)
        if self._mode != MODE_CTR and len(data) % 16:
            raise ValueError("数据长度必须是 16 的倍数")
        return self._engine.encrypt(data)

    def decrypt(self, data):
        data = bytes(data)
        if self._mode != MODE_CTR and len(data) % 16:
            raise ValueError("数据长度必须是 16 的倍数")
        return self._engine.decrypt(data)


def new(key=None, mode=MODE_ECB, *args, **kwargs):
    """支持 `AES.new(key, AES.MODE_CBC, iv)` 和 `AES.new(key=..., iv=...)` 两种写法。"""
    if key is None:
        key = kwargs.pop("key")
    # 旧写法把 iv 当第三个位置参数传
    if args and "iv" not in kwargs:
        kwargs["iv"] = args[0]
    return _Mode(key, mode, **kwargs)
