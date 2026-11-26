"""PKCS1_OAEP 加解密，接口照 pycryptodome。"""
from Crypto.PublicKey.RSA import PKCS1_OAEP_Cipher


def new(key, hashAlgo=None, mgfunc=None, label=b"", **kwargs):
    return PKCS1_OAEP_Cipher(key, hashAlgo, mgfunc, label)
