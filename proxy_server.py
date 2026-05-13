#!/usr/bin/env python3
"""
Mac 代理服务器（aiohttp 版）

iOS 端不直连 Google，所有流量都过这里：
  POST /api/chat   → 转发到 Gemini generateContent
  WS   /api/live   → 双向桥接 Gemini Live (BidiGenerateContent)
  GET  /health     → 状态检查

API key 从 .env 读取，不进 git。
"""
import asyncio
import os
import ssl
from pathlib import Path

from aiohttp import web, ClientSession, WSMsgType, ClientConnectorError


# ---- 读取 .env ----
def load_env():
    env_file = Path(__file__).parent / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().strip('"').strip("'")
        os.environ.setdefault(k.strip(), v)


load_env()
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "").strip()
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash").strip()
GEMINI_LIVE_MODEL = os.environ.get("GEMINI_LIVE_MODEL", "gemini-2.0-flash-exp").strip()
GEMINI_TTS_MODEL = os.environ.get("GEMINI_TTS_MODEL", "gemini-2.5-flash-preview-tts").strip()
GEMINI_TTS_VOICE = os.environ.get("GEMINI_TTS_VOICE", "Kore").strip()

# 火山豆包 TTS
VOLC_TTS_APP_ID = os.environ.get("VOLC_TTS_APP_ID", "").strip()
VOLC_TTS_ACCESS_TOKEN = os.environ.get("VOLC_TTS_ACCESS_TOKEN", "").strip()
VOLC_TTS_RESOURCE_ID = os.environ.get("VOLC_TTS_RESOURCE_ID", "volc.service_type.10029").strip()
VOLC_TTS_VOICE = os.environ.get("VOLC_TTS_VOICE", "zh_female_cancan_mars_bigtts").strip()

PORT = int(os.environ.get("PORT", "8888"))

# SSL: 关掉验证，避免 Mac 上自签证书问题
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


def key_missing() -> bool:
    return not GEMINI_API_KEY or GEMINI_API_KEY == "REPLACE_WITH_YOUR_NEW_KEY"


# ---- /api/chat ----
async def handle_chat(request: web.Request) -> web.Response:
    if key_missing():
        return web.json_response({"error": "GEMINI_API_KEY 未配置，请编辑 .env"}, status=500)
    try:
        body = await request.json()
    except Exception as e:
        return web.json_response({"error": f"bad json: {e}"}, status=400)

    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent?key={GEMINI_API_KEY}"
    )
    # 模型偶发返回 503/429/500（过载/限流），透明重试 2 次
    retry_status = {429, 500, 502, 503, 504}
    backoff = [0, 1.0, 2.5]
    last_data, last_status, last_ct = b"", 500, "application/json"
    try:
        async with ClientSession() as session:
            for attempt, delay in enumerate(backoff):
                if delay:
                    await asyncio.sleep(delay)
                async with session.post(url, json=body, ssl=SSL_CTX, timeout=60) as resp:
                    last_data = await resp.read()
                    last_status = resp.status
                    last_ct = resp.headers.get("Content-Type", "application/json")
                    if resp.status not in retry_status:
                        print(f"🗨️  /api/chat → {resp.status} ({len(last_data)} bytes)"
                              + (f" [重试 {attempt}]" if attempt else ""))
                        return web.Response(body=last_data, status=resp.status,
                                            headers={"Content-Type": last_ct})
                    # 可重试错误，打 log 后继续
                    print(f"⏳ Gemini {resp.status}（{len(last_data)}B），attempt {attempt+1}/{len(backoff)}")
            # 全部重试用完仍失败 — 把 Gemini 错误翻译成人话
            print(f"❌ /api/chat 重试耗尽 → {last_status}")
            try:
                print(f"   错误体: {last_data.decode('utf-8', errors='replace')[:500]}")
            except Exception:
                pass
            import json as _json
            friendly = _translate_gemini_error(last_status, last_data)
            return web.json_response({"error": friendly}, status=last_status)
    except Exception as e:
        print(f"❌ /api/chat 转发异常: {e}")
        return web.json_response({"error": f"代理服务异常: {e}"}, status=500)


def _translate_gemini_error(status: int, body: bytes) -> str:
    """把 Gemini 各种错误翻译成中文友好提示"""
    try:
        import json as _json
        j = _json.loads(body)
        err = j.get("error", {})
        gemini_status = err.get("status", "")
        message = err.get("message", "")
    except Exception:
        gemini_status, message = "", body.decode("utf-8", errors="replace")[:200]

    if status == 429 or gemini_status == "RESOURCE_EXHAUSTED":
        # 解析 retry-in 秒数
        import re
        m = re.search(r"retry in ([\d.]+)s", message, re.I)
        retry = f"约 {int(float(m.group(1)))} 秒后" if m else "稍后"
        return f"今天的免费额度用完啦~ 请{retry}再试 (或换个 Gemini 模型)"
    if status == 403 or gemini_status == "PERMISSION_DENIED":
        return "API key 权限有问题（可能已撤销或未启用 Gemini API）"
    if status == 400:
        return f"请求被拒绝：{message[:120]}"
    if status >= 500:
        return "Gemini 服务暂时不稳定，请稍后再试"
    return f"AI 出错了（{status}）：{message[:120]}"


# ---- /api/tts (火山豆包 TTS，主路径) ----
async def handle_tts(request: web.Request) -> web.Response:
    if not (VOLC_TTS_APP_ID and VOLC_TTS_ACCESS_TOKEN):
        return web.json_response({"error": "VOLC_TTS_* 未配置"}, status=500)
    try:
        body = await request.json()
    except Exception as e:
        return web.json_response({"error": f"bad json: {e}"}, status=400)

    text = (body.get("text") or "").strip()
    if not text:
        return web.json_response({"error": "missing text"}, status=400)
    voice = (body.get("voice") or VOLC_TTS_VOICE).strip()

    import uuid as _uuid
    upstream_body = {
        "user": {"uid": "ios"},
        "req_params": {
            "text": text,
            "speaker": voice,
            "audio_params": {"format": "mp3", "sample_rate": 24000},
        },
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer;{VOLC_TTS_ACCESS_TOKEN}",
        "X-Api-App-Id": VOLC_TTS_APP_ID,
        "X-Api-Access-Key": VOLC_TTS_ACCESS_TOKEN,
        "X-Api-Resource-Id": VOLC_TTS_RESOURCE_ID,
        "X-Api-Request-Id": str(_uuid.uuid4()),
    }
    url = "https://openspeech.bytedance.com/api/v3/tts/unidirectional"

    import json as _json
    import base64 as _b64
    try:
        async with ClientSession() as session:
            async with session.post(url, data=_json.dumps(upstream_body).encode(),
                                     headers=headers, ssl=SSL_CTX, timeout=30) as resp:
                data = await resp.read()
                # 火山 v3 unidirectional 永远返回 JSON: {"code":0,"message":"","data":"<base64 mp3>"}
                # 错误时 code != 0，或在 header 字段里
                # 火山 v3 unidirectional 返回的是多个 JSON 帧拼接（NDJSON 风格），每帧带一段 base64 音频
                text_payload = data.decode("utf-8", errors="replace")
                decoder = _json.JSONDecoder()
                idx, frames = 0, []
                length = len(text_payload)
                while idx < length:
                    # 跳过帧之间可能的空白/换行
                    while idx < length and text_payload[idx] in " \r\n\t":
                        idx += 1
                    if idx >= length:
                        break
                    try:
                        obj, consumed = decoder.raw_decode(text_payload, idx)
                    except _json.JSONDecodeError as e:
                        print(f"❌ /api/tts(volc) 解析失败 @ {idx}: {e}")
                        print(f"   前 80 字节 hex: {data[:80].hex()}")
                        return web.json_response({"error": "upstream parse error"}, status=502)
                    frames.append(obj)
                    idx = consumed

                if not frames:
                    return web.json_response({"error": "empty upstream response"}, status=502)

                # 拼接所有帧的 base64 音频；火山有些帧是"结束标记"无 data，跳过即可
                mp3_chunks = []
                terminal_codes = []
                for fr in frames:
                    if not isinstance(fr, dict):
                        continue
                    code = fr.get("code") if isinstance(fr.get("code"), int) else fr.get("header", {}).get("code")
                    if code is not None and code != 0:
                        terminal_codes.append((code, fr.get("message") or fr.get("header", {}).get("message") or ""))
                    chunk_b64 = fr.get("data")
                    if chunk_b64:
                        try:
                            mp3_chunks.append(_b64.b64decode(chunk_b64))
                        except Exception as e:
                            print(f"⚠️ 帧 base64 解码失败: {e}")
                mp3 = b"".join(mp3_chunks)

                if not mp3:
                    # 真的没拿到音频才报错
                    err_msg = "; ".join(f"{c}:{m}" for c, m in terminal_codes) or "no audio in upstream frames"
                    print(f"❌ /api/tts(volc) → {err_msg}")
                    return web.json_response({"error": err_msg[:300]}, status=502)

                print(f"🔊 /api/tts(volc) → {len(mp3)} bytes MP3 ({len(frames)} 帧, voice={voice})")
                return web.Response(body=mp3, status=200, headers={"Content-Type": "audio/mpeg"})
    except Exception as e:
        print(f"❌ /api/tts(volc) 异常: {e}")
        return web.json_response({"error": str(e)}, status=500)


# ---- /api/tts-gemini (Gemini 神经 TTS，备用路径) ----
async def handle_tts_gemini(request: web.Request) -> web.Response:
    if key_missing():
        return web.json_response({"error": "GEMINI_API_KEY 未配置"}, status=500)
    try:
        body = await request.json()
    except Exception as e:
        return web.json_response({"error": f"bad json: {e}"}, status=400)

    text = (body.get("text") or "").strip()
    if not text:
        return web.json_response({"error": "missing text"}, status=400)
    voice = (body.get("voice") or GEMINI_TTS_VOICE).strip()
    model = (body.get("model") or GEMINI_TTS_MODEL).strip()

    upstream_body = {
        "contents": [{"parts": [{"text": text}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {
                "voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}
            },
        },
    }
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:generateContent?key={GEMINI_API_KEY}"
    )

    import base64 as _b64
    try:
        async with ClientSession() as session:
            async with session.post(url, json=upstream_body, ssl=SSL_CTX, timeout=60) as resp:
                resp_data = await resp.read()
                if resp.status >= 400:
                    print(f"❌ /api/tts → {resp.status}: {resp_data.decode('utf-8','replace')[:300]}")
                    return web.Response(
                        body=resp_data, status=resp.status,
                        headers={"Content-Type": resp.headers.get("Content-Type", "application/json")},
                    )
                # 解出 inline_data 里的 PCM
                import json as _json
                payload = _json.loads(resp_data)
                parts = (payload.get("candidates", [{}])[0]
                         .get("content", {}).get("parts", []))
                for p in parts:
                    inline = p.get("inlineData") or p.get("inline_data")
                    if not inline or not inline.get("data"):
                        continue
                    pcm = _b64.b64decode(inline["data"])
                    mime = inline.get("mimeType") or inline.get("mime_type") or "audio/L16;rate=24000"
                    print(f"🔊 /api/tts → {len(pcm)} bytes PCM ({voice})")
                    return web.Response(
                        body=pcm, status=200,
                        headers={
                            "Content-Type": mime,
                            "X-Audio-SampleRate": "24000",
                            "X-Audio-BitsPerSample": "16",
                            "X-Audio-Channels": "1",
                        },
                    )
                return web.json_response({"error": "no audio in response"}, status=502)
    except Exception as e:
        print(f"❌ /api/tts 异常: {e}")
        return web.json_response({"error": str(e)}, status=500)


# ---- /api/live (WebSocket 桥接) ----
async def handle_live(request: web.Request) -> web.WebSocketResponse:
    ws_client = web.WebSocketResponse(heartbeat=30, max_msg_size=20 * 1024 * 1024)
    await ws_client.prepare(request)

    if key_missing():
        await ws_client.send_json({"error": "GEMINI_API_KEY 未配置"})
        await ws_client.close()
        return ws_client

    upstream_url = (
        "wss://generativelanguage.googleapis.com/ws/"
        "google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
        f"?key={GEMINI_API_KEY}"
    )

    print("⚡ /api/live 客户端已接入")
    session = ClientSession()
    try:
        async with session.ws_connect(
            upstream_url,
            ssl=SSL_CTX,
            heartbeat=30,
            max_msg_size=20 * 1024 * 1024,
        ) as ws_up:
            print("⚡ 已连接到 Gemini Live")

            async def pump(src, dst, label):
                try:
                    async for msg in src:
                        if msg.type == WSMsgType.TEXT:
                            await dst.send_str(msg.data)
                        elif msg.type == WSMsgType.BINARY:
                            await dst.send_bytes(msg.data)
                        elif msg.type == WSMsgType.ERROR:
                            print(f"❌ {label} 错误: {src.exception()}")
                            break
                        elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING):
                            break
                except Exception as e:
                    print(f"❌ {label} 异常: {e}")

            await asyncio.gather(
                pump(ws_client, ws_up, "client→gemini"),
                pump(ws_up, ws_client, "gemini→client"),
                return_exceptions=True,
            )
    except ClientConnectorError as e:
        print(f"❌ 无法连接 Gemini Live: {e}")
        try:
            await ws_client.send_json({"error": f"upstream connect failed: {e}"})
        except Exception:
            pass
    except Exception as e:
        print(f"❌ /api/live 异常: {e}")
        try:
            await ws_client.send_json({"error": str(e)})
        except Exception:
            pass
    finally:
        await session.close()
        if not ws_client.closed:
            await ws_client.close()
        print("⚡ /api/live 已断开")

    return ws_client


# ---- /health ----
async def handle_health(request: web.Request) -> web.Response:
    return web.json_response(
        {
            "ok": True,
            "key_present": not key_missing(),
            "model": GEMINI_MODEL,
            "live_model": GEMINI_LIVE_MODEL,
            "port": PORT,
        }
    )


def main():
    app = web.Application(client_max_size=20 * 1024 * 1024)
    app.router.add_post("/api/chat", handle_chat)
    app.router.add_post("/api/tts", handle_tts)
    app.router.add_post("/api/tts-gemini", handle_tts_gemini)
    app.router.add_get("/api/live", handle_live)
    app.router.add_get("/health", handle_health)

    print(f"代理服务器启动: http://0.0.0.0:{PORT}")
    print(f"  POST /api/chat        → Gemini {GEMINI_MODEL}")
    print(f"  POST /api/tts         → 火山豆包 TTS (voice={VOLC_TTS_VOICE})")
    print(f"  POST /api/tts-gemini  → Gemini TTS {GEMINI_TTS_MODEL} (备用)")
    print(f"  WS   /api/live        → Gemini Live {GEMINI_LIVE_MODEL}")
    print(f"  GET  /health          → 状态")
    if key_missing():
        print("⚠️  GEMINI_API_KEY 未配置 — 请编辑 .env 后重启")
    web.run_app(app, host="0.0.0.0", port=PORT, access_log=None)


if __name__ == "__main__":
    main()
