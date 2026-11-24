"""pycryptodome 的纯 Python 替身。

iOS 上装不了需要编译的扩展，而这些源用到的只有 AES 的 CBC/ECB/CTR、ARC4 和 PKCS7 填充，
所以这里只实现这一小块：AES 交给 pyaes（成熟的纯 Python 实现），填充和计数器自己写十几行。
接口名与 pycryptodome 一致，插件不用改。
"""
