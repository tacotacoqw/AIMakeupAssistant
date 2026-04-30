#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成豆包 TTS 的 Bearer Token
"""

import hmac
import hashlib
import time
import json
import os
from dotenv import load_dotenv

# 加载环境变量
load_dotenv()

# 从环境变量读取密钥
ACCESS_KEY_ID = os.getenv("ACCESS_KEY_ID", "your_access_key_id")
SECRET_ACCESS_KEY = os.getenv("SECRET_ACCESS_KEY", "your_secret_access_key")

# 生成 token
def generate_token():
    # 使用 HMAC-SHA256 生成签名
    timestamp = str(int(time.time()))
    message = f"{ACCESS_KEY_ID}{timestamp}"

    signature = hmac.new(
        SECRET_ACCESS_KEY.encode('utf-8'),
        message.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()

    # 组合成 token
    token = f"{ACCESS_KEY_ID}:{timestamp}:{signature}"
    return token

if __name__ == '__main__':
    token = generate_token()
    print(f"生成的 Token: {token}")
    print(f"\n请将这个 token 复制到 doubao_tts_proxy.py 的 DOUBAO_TOKEN 变量中")
