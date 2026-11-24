"""PKCS7 / ISO 7816-4 / zero 填充，接口照 pycryptodome。"""


def pad(data, block_size, style="pkcs7"):
    data = bytes(data)
    if block_size < 1 or block_size > 255:
        raise ValueError("block_size 必须在 1..255")
    length = block_size - (len(data) % block_size)
    if style == "pkcs7":
        return data + bytes([length]) * length
    if style == "iso7816":
        return data + b"\x80" + b"\x00" * (length - 1)
    if style == "x923":
        return data + b"\x00" * (length - 1) + bytes([length])
    if style == "zero":
        return data + b"\x00" * length
    raise ValueError("不认识的填充方式：%r" % (style,))


def unpad(data, block_size, style="pkcs7"):
    data = bytes(data)
    if not data or len(data) % block_size:
        raise ValueError("Padding is incorrect.")
    if style == "pkcs7":
        length = data[-1]
        if length < 1 or length > block_size or data[-length:] != bytes([length]) * length:
            raise ValueError("Padding is incorrect.")
        return data[:-length]
    if style == "iso7816":
        index = len(data) - 1
        while index >= 0 and data[index] == 0:
            index -= 1
        if index < 0 or data[index] != 0x80:
            raise ValueError("Padding is incorrect.")
        return data[:index]
    if style == "x923":
        length = data[-1]
        if length < 1 or length > block_size:
            raise ValueError("Padding is incorrect.")
        return data[:-length]
    if style == "zero":
        return data.rstrip(b"\x00")
    raise ValueError("不认识的填充方式：%r" % (style,))
