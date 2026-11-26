"""PKCS1_v1_5 加解密，接口照 pycryptodome。"""
from Crypto.PublicKey.RSA import PKCS1_v1_5_Cipher


def new(key, *args, **kwargs):
    return PKCS1_v1_5_Cipher(key)
