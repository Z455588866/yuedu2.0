"""PKCS1_v1_5 签名校验，接口照 pycryptodome。"""
from Crypto.PublicKey.RSA import PKCS1_v1_5_Signature


def new(key, *args, **kwargs):
    return PKCS1_v1_5_Signature(key)
