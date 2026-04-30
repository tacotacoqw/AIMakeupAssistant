#!/usr/bin/env python3
"""
Gemini API 代理服务器
在 Mac 上运行,为 iOS 应用提供 Gemini API 访问
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import urllib.request
import urllib.error
import ssl
import base64
import struct

GEMINI_API_KEY = "AIzaSyAbBeRmDER_9sFhUvLYy1P5WsYj8QOE6yw"
GEMINI_MODEL = "gemini-2.5-flash"

# 创建不验证证书的 SSL 上下文
ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

def pcm_to_wav(pcm_data, sample_rate=24000, channels=1, bits_per_sample=16):
    """将 PCM 数据转换为 WAV 格式"""
    byte_rate = sample_rate * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8
    data_size = len(pcm_data)
    file_size = 36 + data_size

    # WAV header
    header = bytearray()
    header.extend(b'RIFF')
    header.extend(struct.pack('<I', file_size))
    header.extend(b'WAVE')
    header.extend(b'fmt ')
    header.extend(struct.pack('<I', 16))  # fmt chunk size
    header.extend(struct.pack('<H', 1))   # PCM format
    header.extend(struct.pack('<H', channels))
    header.extend(struct.pack('<I', sample_rate))
    header.extend(struct.pack('<I', byte_rate))
    header.extend(struct.pack('<H', block_align))
    header.extend(struct.pack('<H', bits_per_sample))
    header.extend(b'data')
    header.extend(struct.pack('<I', data_size))

    return bytes(header) + pcm_data

class ProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/api/chat":
            try:
                # 读取请求体
                content_length = int(self.headers['Content-Length'])
                post_data = self.rfile.read(content_length)
                request_data = json.loads(post_data.decode('utf-8'))

                # 构建 Gemini API 请求
                gemini_url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent?key={GEMINI_API_KEY}"

                gemini_request = urllib.request.Request(
                    gemini_url,
                    data=json.dumps(request_data).encode('utf-8'),
                    headers={'Content-Type': 'application/json'}
                )

                # 调用 Gemini API
                with urllib.request.urlopen(gemini_request, timeout=60, context=ssl_context) as response:
                    response_data = response.read()

                # 返回响应
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(response_data)

            except urllib.error.URLError as e:
                self.send_error(500, f"API Error: {str(e)}")
            except Exception as e:
                self.send_error(500, f"Server Error: {str(e)}")

        elif self.path == "/api/tts":
            try:
                # 读取请求体
                content_length = int(self.headers['Content-Length'])
                post_data = self.rfile.read(content_length)
                request_data = json.loads(post_data.decode('utf-8'))
                text = request_data.get('text', '')

                print(f"🔊 TTS 请求: {text[:50]}...")

                # 使用 Edge TTS 生成语音
                import edge_tts
                import asyncio
                import tempfile
                import os

                async def generate_speech():
                    # 使用中文女声（晓晓）
                    communicate = edge_tts.Communicate(text, "zh-CN-XiaoxiaoNeural")

                    # 保存到临时文件
                    temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp3')
                    temp_path = temp_file.name
                    temp_file.close()

                    await communicate.save(temp_path)
                    return temp_path

                # 运行异步任务
                audio_path = asyncio.run(generate_speech())

                # 读取音频文件
                with open(audio_path, 'rb') as f:
                    audio_data = f.read()

                # 删除临时文件
                os.unlink(audio_path)

                print(f"✓ Edge TTS 生成音频: {len(audio_data)} bytes")

                # 返回 MP3 音频
                self.send_response(200)
                self.send_header('Content-Type', 'audio/mpeg')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(audio_data)

            except Exception as e:
                print(f"❌ TTS 错误: {e}")
                import traceback
                traceback.print_exc()
                self.send_error(500, f"TTS Error: {str(e)}")
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {format % args}")

if __name__ == '__main__':
    PORT = 8888
    server = HTTPServer(('0.0.0.0', PORT), ProxyHandler)
    print(f"代理服务器启动在端口 {PORT}")
    print(f"iOS 应用请使用: http://192.168.1.114:{PORT}/api/chat")
    print("按 Ctrl+C 停止服务器")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n服务器已停止")
