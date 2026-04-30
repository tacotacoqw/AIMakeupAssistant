#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
豆包 TTS 代理服务器
用于处理 iOS 应用的 TTS 请求并转发到豆包 API
"""

import http.server
import socketserver
import json
import urllib.request
import ssl
import base64
import hmac
import hashlib
import time
import uuid
import os
from dotenv import load_dotenv

# 加载环境变量
load_dotenv()

PORT = 8889
DOUBAO_APP_ID = os.getenv("DOUBAO_APP_ID", "your_app_id")
ACCESS_KEY_ID = os.getenv("ACCESS_KEY_ID", "your_access_key_id")
SECRET_ACCESS_KEY = os.getenv("SECRET_ACCESS_KEY", "your_secret_access_key")
DOUBAO_TTS_URL = "https://openspeech.bytedance.com/api/v1/tts"

def generate_token():
    """动态生成 Bearer Token"""
    timestamp = str(int(time.time()))
    message = f"{ACCESS_KEY_ID}{timestamp}"
    signature = hmac.new(
        SECRET_ACCESS_KEY.encode('utf-8'),
        message.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()
    return f"{ACCESS_KEY_ID}:{timestamp}:{signature}"

class DoubaoTTSHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/tts':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)

            try:
                request_data = json.loads(post_data.decode('utf-8'))
                text = request_data.get('text', '')

                if not text:
                    self.send_error(400, "Missing text parameter")
                    return

                # 构建豆包 TTS 请求
                doubao_request = {
                    "app": {
                        "appid": DOUBAO_APP_ID,
                        "token": "access",  # token字段可以是任意值
                        "cluster": "volcano_tts"
                    },
                    "user": {
                        "uid": "user_001"
                    },
                    "audio": {
                        "voice_type": "BV001_streaming",
                        "encoding": "mp3",
                        "speed_ratio": 1.0,
                        "volume_ratio": 1.0,
                        "pitch_ratio": 1.0
                    },
                    "request": {
                        "reqid": str(uuid.uuid4()),
                        "text": text,
                        "text_type": "plain",
                        "operation": "query"
                    }
                }

                # 使用 Access Key 生成 Authorization 签名
                auth_token = generate_token()

                print(f"→ 发送请求: text={text[:30]}..., appid={DOUBAO_APP_ID}")

                # 发送请求到豆包
                req = urllib.request.Request(
                    DOUBAO_TTS_URL,
                    data=json.dumps(doubao_request).encode('utf-8'),
                    headers={
                        'Content-Type': 'application/json',
                        'Authorization': f'Bearer; {auth_token}'
                    }
                )

                # 禁用 SSL 验证
                ssl_context = ssl.create_default_context()
                ssl_context.check_hostname = False
                ssl_context.verify_mode = ssl.CERT_NONE

                with urllib.request.urlopen(req, context=ssl_context) as response:
                    response_data = response.read()
                    response_json = json.loads(response_data.decode('utf-8'))

                    # 检查响应状态
                    if 'data' not in response_json:
                        print(f"❌ 豆包API错误: {response_json}")
                        self.send_error(500, f"Doubao API error: {json.dumps(response_json)}")
                        return

                    # 解码base64音频数据
                    audio_base64 = response_json['data']
                    audio_data = base64.b64decode(audio_base64)

                    print(f"✓ 豆包TTS成功: 文本长度={len(text)}, 音频大小={len(audio_data)} bytes")

                    # 返回音频数据
                    self.send_response(200)
                    self.send_header('Content-Type', 'audio/mpeg')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.send_header('Content-Length', str(len(audio_data)))
                    self.end_headers()
                    self.wfile.write(audio_data)

            except urllib.error.HTTPError as e:
                error_body = e.read().decode('utf-8', errors='replace')
                print(f"❌ HTTP错误 {e.code}: {error_body}")
                self.send_error(e.code, error_body)
            except Exception as e:
                print(f"❌ 错误: {e}")
                self.send_error(500, f"Internal server error: {str(e)}")
        else:
            self.send_error(404, "Not found")

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

if __name__ == '__main__':
    with socketserver.TCPServer(("", PORT), DoubaoTTSHandler) as httpd:
        print(f"豆包 TTS 代理服务器运行在端口 {PORT}")
        print(f"AppID: {DOUBAO_APP_ID}")
        print(f"AccessKey: {ACCESS_KEY_ID[:10]}...")
        print("等待请求...")
        httpd.serve_forever()
