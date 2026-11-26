"""pycryptodome 的 RSA 最小纯 Python 替身。

内嵌 CPython 是 isolated 模式、包里没有 site-packages，装不了 pycryptodome；
.py 猫源用到 RSA 的地方基本只有：导入 115 之类的网盘公钥，做 PKCS#1 v1.5
加解密、签名校验，少数用 PKCS1_OAEP。这里覆盖这条路径，接口名照抄
pycryptodome，插件不用改。

刻意不做的事：素数生成、CRT 加速、OAEP 自定义 MGF、PSS。这些在猫源里没见过，
真遇到了会明确报错，而不是悄悄算出错的结果。
"""
import base64
import hashlib
import hmac
import os
import re

_RSA_OID = bytes.fromhex("2a864886f70d010101")


class _DERError(ValueError):
    pass


# —— 只看得懂 RSA 密钥会用到的那几种 ASN.1 标签 ——

def _tlv(data, offset):
    if offset + 2 > len(data):
        raise _DERError("DER 数据不完整")
    tag = data[offset]
    length = data[offset + 1]
    offset += 2
    if length & 0x80:
        count = length & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise _DERError("DER 长度非法")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    end = offset + length
    if end > len(data):
        raise _DERError("DER 内容超出长度")
    return tag, data[offset:end], end


def _sequence(data):
    tag, body, _ = _tlv(data, 0)
    if tag != 0x30:
        raise _DERError("期望 ASN.1 SEQUENCE")
    return body


def _integer(data, offset):
    tag, body, end = _tlv(data, offset)
    if tag != 0x02:
        raise _DERError("期望 ASN.1 INTEGER")
    return int.from_bytes(body, "big"), end


def _parse_der(der):
    """认四种常见编码：PKCS#1 公/私钥、SPKI 公钥、PKCS#8 私钥。"""
    body = _sequence(der)
    if not body:
        raise _DERError("空的 RSA 密钥")
    tag, value, pos = _tlv(body, 0)
    if tag == 0x30:
        # SubjectPublicKeyInfo：AlgorithmIdentifier + BIT STRING
        if _RSA_OID not in value:
            raise _DERError("不是 rsaEncryption 公钥")
        tag, bits, _ = _tlv(body, pos)
        if tag != 0x03 or not bits:
            raise _DERError("SPKI 公钥缺少 BIT STRING")
        return _parse_der(bits[1:])  # 第一个字节是「未用位数」
    if tag == 0x02:
        # PKCS#1：公钥两个 INTEGER；私钥是 version + n + e + d + p + q …
        values = []
        cursor = 0
        while cursor < len(body) and body[cursor] == 0x02:
            integer, cursor = _integer(body, cursor)
            values.append(integer)
        if len(values) == 2:
            return values[0], values[1], None, None, None
        if len(values) >= 6:
            return values[1], values[2], values[3], values[4], values[5]
        # PKCS#8 PrivateKeyInfo：INTEGER 版本 + AlgorithmIdentifier + OCTET STRING
        _, _, pos = _tlv(body, pos)
        tag, inner, _ = _tlv(body, pos)
        if tag != 0x04:
            raise _DERError("PKCS#8 私钥缺少 OCTET STRING")
        return _parse_der(inner)
    raise _DERError("不认识的 RSA 密钥编码")


_PEM_BLOCK = re.compile(rb"-----BEGIN ([A-Z0-9 ]+)-----\s*(.*?)\s*-----END \1-----", re.S)


def _import_key(blob):
    if isinstance(blob, str):
        blob = blob.encode("utf-8")
    blob = bytes(blob)
    match = _PEM_BLOCK.search(blob)
    if match:
        label = match.group(1)
        if b"RSA" not in label and b"PUBLIC KEY" not in label and b"PRIVATE KEY" not in label:
            raise ValueError("不支持的 PEM 密钥类型：%s" % label.decode("ascii", "replace"))
        der = base64.b64decode(re.sub(rb"\s+", b"", match.group(2)))
    else:
        der = blob
    n, e, d, p, q = _parse_der(der)
    return RsaKey(n, e, d, p, q)


def import_key(blob):
    return _import_key(blob)


def importKey(blob):
    return _import_key(blob)


def construct(values):
    """`RSA.construct((n, e[, d, p, q]))`。"""
    values = tuple(values)
    if len(values) < 2:
        raise ValueError("RSA.construct 至少需要 (n, e)")
    n, e = values[0], values[1]
    d = values[2] if len(values) > 2 else None
    p = values[3] if len(values) > 3 else None
    q = values[4] if len(values) > 4 else None
    return RsaKey(n, e, d, p, q)


class RsaKey:
    def __init__(self, n, e, d=None, p=None, q=None):
        self.n, self.e, self.d = int(n), int(e), (None if d is None else int(d))
        self.p, self.q = p, q
        self.k = (self.n.bit_length() + 7) // 8

    @property
    def size_in_bits(self):
        return self.n.bit_length()

    @property
    def size_in_bytes(self):
        return self.k

    @property
    def has_private(self):
        return self.d is not None

    def encrypt(self, plaintext):
        """PKCS#1 v1.5 加密（公钥）。"""
        message = bytes(plaintext)
        if len(message) > self.k - 11:
            raise ValueError("明文太长，PKCS#1 v1.5 最多 %d 字节" % (self.k - 11))
        em = b"\x00\x02" + _nonzero_padding(self.k - len(message) - 3) + b"\x00" + message
        return pow(int.from_bytes(em, "big"), self.e, self.n).to_bytes(self.k, "big")

    def decrypt(self, ciphertext):
        """PKCS#1 v1.5 解密。只有公钥时用 e 做幂运算（115 回包就是这种）。"""
        block = bytes(ciphertext)
        if len(block) != self.k:
            raise ValueError("密文长度必须等于密钥长度 %d 字节" % self.k)
        exponent = self.d if self.has_private else self.e
        em = pow(int.from_bytes(block, "big"), exponent, self.n).to_bytes(self.k, "big")
        # 网站有的用 00 02 加密填充，有的用 00 01 签名填充，两种都认。
        return _unpad_v15(em)


def _nonzero_padding(length):
    out = bytearray()
    while len(out) < length:
        out.extend(byte for byte in os.urandom(length - len(out)) if byte)
    return bytes(out)


def _unpad_v15(em):
    if len(em) < 11 or em[0] != 0:
        raise ValueError("PKCS#1 v1.5 填充错误")
    if em[1] == 2:
        index = em.find(b"\x00", 2)
    elif em[1] == 1:
        index = em.find(b"\x00", 2)
        if index > 0 and any(byte != 0xFF for byte in em[2:index]):
            raise ValueError("PKCS#1 v1.5 签名填充错误")
    else:
        raise ValueError("PKCS#1 v1.5 填充错误")
    if index < 10:
        raise ValueError("PKCS#1 v1.5 填充错误")
    return em[index + 1:]


# —— 签名用的 DigestInfo 前缀：OID + NULL + OCTET STRING 头 ——

_DIGEST_PREFIX = {
    "1.2.840.113549.2.5": bytes.fromhex("3020300c06082a864886f70d020505000410"),
    "1.3.14.3.2.26": bytes.fromhex("3021300906052b0e03021a05000414"),
    "2.16.840.1.101.3.4.2.4": bytes.fromhex("302d300d06096086480165030402040500041c"),
    "2.16.840.1.101.3.4.2.1": bytes.fromhex("3031300d060960864801650304020105000420"),
    "2.16.840.1.101.3.4.2.2": bytes.fromhex("3041300d060960864801650304020205000430"),
    "2.16.840.1.101.3.4.2.3": bytes.fromhex("3051300d060960864801650304020305000440"),
}
_PREFIX_BY_SIZE = {16: 0, 20: 1, 28: 2, 32: 3, 48: 4, 64: 5}
_PREFIX_LIST = list(_DIGEST_PREFIX.values())


def _digest_info(hash_obj):
    digest = hash_obj.digest()
    oid = getattr(hash_obj, "oid", None)
    prefix = _DIGEST_PREFIX.get(oid) if oid else None
    if prefix is None:
        index = _PREFIX_BY_SIZE.get(len(digest))
        if index is None:
            raise ValueError("不支持的摘要长度 %d" % len(digest))
        prefix = _PREFIX_LIST[index]
    return prefix + digest


def _mgf1(seed, length, factory):
    out = bytearray()
    counter = 0
    while len(out) < length:
        out.extend(factory(seed + counter.to_bytes(4, "big")).digest())
        counter += 1
    return bytes(out[:length])


def _hash_factory(algo):
    """同时接受 hashlib.sha256 和 pycryptodome 的 Crypto.Hash.SHA256。"""
    if algo is None:
        return hashlib.sha1
    if hasattr(algo, "new"):
        def factory(data=b""):
            state = algo.new()
            if data:
                state.update(data)
            return state
        return factory
    return algo


class PKCS1_v1_5_Cipher:
    def __init__(self, key):
        self._key = key

    def encrypt(self, message):
        return self._key.encrypt(message)

    def decrypt(self, ciphertext, sentinel=None):
        try:
            return self._key.decrypt(ciphertext)
        except ValueError:
            return sentinel


class PKCS1_OAEP_Cipher:
    def __init__(self, key, hashAlgo=None, mgfunc=None, label=b""):
        self._key = key
        self._hash = _hash_factory(hashAlgo)
        self._label = bytes(label or b"")
        if mgfunc is not None:
            raise NotImplementedError("OAEP 自定义 MGF 暂不支持")

    def encrypt(self, message):
        message = bytes(message)
        k, hlen = self._key.k, self._hash().digest_size
        if len(message) > k - 2 * hlen - 2:
            raise ValueError("明文太长，OAEP 装不下")
        db = self._hash(self._label).digest() + b"\x00" * (k - len(message) - 2 * hlen - 2) + b"\x01" + message
        seed = os.urandom(hlen)
        masked_db = bytes(a ^ b for a, b in zip(db, _mgf1(seed, len(db), self._hash)))
        masked_seed = bytes(a ^ b for a, b in zip(seed, _mgf1(masked_db, hlen, self._hash)))
        em = b"\x00" + masked_seed + masked_db
        return pow(int.from_bytes(em, "big"), self._key.e, self._key.n).to_bytes(k, "big")

    def decrypt(self, ciphertext):
        block = bytes(ciphertext)
        k, hlen = self._key.k, self._hash().digest_size
        if len(block) != k:
            raise ValueError("密文长度必须等于密钥长度 %d 字节" % k)
        em = pow(int.from_bytes(block, "big"), self._key.d, self._key.n).to_bytes(k, "big")
        if em[0] != 0:
            raise ValueError("OAEP 解密失败")
        masked_seed, masked_db = em[1:1 + hlen], em[1 + hlen:]
        seed = bytes(a ^ b for a, b in zip(masked_seed, _mgf1(masked_db, hlen, self._hash)))
        db = bytes(a ^ b for a, b in zip(masked_db, _mgf1(seed, len(masked_db), self._hash)))
        if not hmac.compare_digest(db[:hlen], self._hash(self._label).digest()):
            raise ValueError("OAEP 解密失败")
        index = db.find(b"\x01", hlen)
        if index < 0:
            raise ValueError("OAEP 解密失败")
        return db[index + 1:]


class PKCS1_v1_5_Signature:
    def __init__(self, key):
        self._key = key

    def sign(self, hash_obj):
        if not self._key.has_private:
            raise ValueError("签名需要私钥")
        encoded = _digest_info(hash_obj)
        if self._key.k < len(encoded) + 11:
            raise ValueError("密钥太短，装不下这个摘要")
        em = b"\x00\x01" + b"\xff" * (self._key.k - len(encoded) - 3) + b"\x00" + encoded
        return pow(int.from_bytes(em, "big"), self._key.d, self._key.n).to_bytes(self._key.k, "big")

    def verify(self, hash_obj, signature):
        signature = bytes(signature)
        if len(signature) != self._key.k:
            return False
        encoded = _digest_info(hash_obj)
        expected = b"\x00\x01" + b"\xff" * (self._key.k - len(encoded) - 3) + b"\x00" + encoded
        em = pow(int.from_bytes(signature, "big"), self._key.e, self._key.n).to_bytes(self._key.k, "big")
        return hmac.compare_digest(em, expected)
