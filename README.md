# AI Makeup Assistant

English | [简体中文](README.zh-CN.md)

An iOS makeup coach app. "Xiaomei" watches your face through the camera in real time, **teaches you makeup step by step, and warns you when you go off the line**.

## Features

- 💬 **Text / voice chat** — Gemini as primary, DeepSeek as automatic fallback, so rate limits never stop a conversation
- 🗣️ **AI voice** — Volcengine Doubao TTS 2.0 with the "Mao Xiaomei" end-to-end neural voice (streamed sentence by sentence)
- 📞 **Voice call mode** — speech recognition + AI reply + TTS that speaks while it generates, like a phone call
- 📸 **Real-time face detection** — native Apple Vision, tracks lips / eyebrows / face outline at 5 fps
- 💄 **Makeup task list** — ask Xiaomei to teach you a look; it is split into 3–6 steps and each step is checked automatically
- ⚠️ **Off-the-line detection** — if lipstick goes outside the lip line, the area is circled with a red dashed line and Xiaomei tells you out loud
- 🏪 **Nearby stores** — GPS location + cosmetics store recommendations
- ♿ **Full accessibility** — VoiceOver / aria-live / earcons / high-contrast text / reduced motion

## Architecture

```
┌────────────────────┐         ┌──────────────────────────────┐
│  iPhone (iOS App)  │ ──HTTP──┤ Cloud proxy (Singapore)      │
│  ─────────────     │         │ proxy_server.py (aiohttp)    │
│  Swift + WKWebView │         │ systemd, running 24/7        │
│  AVAudioPlayer     │         └──┬───────────────────────────┘
│  Apple Vision      │            │
│  Whisper STT       │            ├─→ Gemini (chat + vision)
│  Web UI  index.html│            ├─→ DeepSeek (chat fallback)
└────────────────────┘            └─→ Volcengine (TTS bigmodel)
```

**Key point**: the iOS app **never talks to** Google / DeepSeek / Volcengine directly. All API keys live in the cloud proxy's `.env`, so **nothing leaks through git**.

## Project structure

```
AIMakeupAssistant/                 (repo root)
├── AIMakeupAssistant/             iOS source
│   ├── ContentView.swift          Entry view, AI/TTS/STT managers, WebView bridge
│   ├── AIMakeupAssistantApp.swift App entry point
│   ├── index.html                 The whole web UI (~4,500 lines)
│   ├── Info.plist                 Permission descriptions
│   └── Assets.xcassets/           App icon (lipstick SVG theme)
│
├── AIMakeupAssistant.xcodeproj/   Xcode project
│
├── proxy_server.py                Cloud proxy (copy of what runs on the server)
├── .env                           API keys (not in git, listed in .gitignore)
├── .env.example                   Config template
│
├── TESTFLIGHT.md                  TestFlight release guide (Chinese)
├── README.md                      This file
└── README.zh-CN.md                Chinese README
```

## Run the iOS app

Requires macOS 14+ and Xcode 15+.

1. Open `AIMakeupAssistant.xcodeproj`
2. Select your iPhone as the run destination
3. Press ⌘R

Test on a real device — the simulator has no camera.

## Deploy the cloud proxy

### 1. Get a server

- It must be in a **region where Gemini is available** (Singapore, Tokyo, Seoul, Europe, US)
- Hong Kong and mainland China IPs are rejected by Google
- From about ¥24/month (Alibaba Cloud Simple Application Server, 1 vCPU / 1 GB / 30 Mbps)

### 2. SSH in and install

```bash
apt update -y && apt install -y python3-pip python3-venv
mkdir -p /opt/proxy && cd /opt/proxy
python3 -m venv venv
./venv/bin/pip install aiohttp
```

### 3. Upload `proxy_server.py`

```bash
# On your Mac
scp proxy_server.py root@YOUR_SERVER_IP:/opt/proxy/
```

### 4. Write `.env` (on the server)

```bash
cat > /opt/proxy/.env <<'EOF'
GEMINI_API_KEY=...
GEMINI_MODEL=gemini-2.5-flash-lite
DEEPSEEK_API_KEY=sk-...
VOLC_TTS_APP_ID=...
VOLC_TTS_ACCESS_TOKEN=...
VOLC_TTS_RESOURCE_ID=volc.service_type.10029
VOLC_TTS_VOICE=zh_female_cancan_mars_bigtts
PORT=8888
EOF
chmod 600 /opt/proxy/.env
```

### 5. systemd service

```bash
cat > /etc/systemd/system/ai-proxy.service <<'EOF'
[Unit]
Description=AI Makeup Assistant Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/proxy
EnvironmentFile=/opt/proxy/.env
ExecStart=/opt/proxy/venv/bin/python -u /opt/proxy/proxy_server.py
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ai-proxy
systemctl start ai-proxy
```

### 6. Open TCP port 8888

In your cloud console's firewall, add a rule: TCP / 8888 / `0.0.0.0/0`

### 7. Verify

```bash
curl http://YOUR_SERVER_IP:8888/health
curl -X POST http://YOUR_SERVER_IP:8888/api/chat \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Hello"}]}]}'
```

A 200 response with an AI reply means you're done.

### 8. Point the iOS app at your server

At the top of `AIMakeupAssistant/ContentView.swift`:

```swift
private static let proxyHost = "YOUR_SERVER_IP:8888"
```

Press ⌘R to reinstall on your iPhone.

## Proxy API endpoints

| Path | Method | Purpose |
|---|---|---|
| `/health` | GET | Health check |
| `/api/chat` | POST | Gemini text chat (with automatic DeepSeek fallback) |
| `/api/tts` | POST | Volcengine Doubao TTS (returns MP3) |
| `/api/tts-gemini` | POST | Gemini TTS backup |
| `/api/live` | WS | Gemini Live WebSocket relay (not used by the iOS app right now) |

## Maintenance

```bash
# Follow proxy logs
ssh root@YOUR_SERVER_IP 'journalctl -u ai-proxy -f'

# Redeploy after editing proxy_server.py
scp proxy_server.py root@YOUR_SERVER_IP:/opt/proxy/
ssh root@YOUR_SERVER_IP 'systemctl restart ai-proxy'

# Change environment variables
ssh root@YOUR_SERVER_IP 'nano /opt/proxy/.env && systemctl restart ai-proxy'
```

## TestFlight

Requires the Apple Developer Program ($99/year).
See [TESTFLIGHT.md](TESTFLIGHT.md) for the step-by-step guide (in Chinese).

## Where to get credentials

| Service | Sign-up | Price |
|---|---|---|
| Gemini API | https://aistudio.google.com/apikey | Free tier, ~1,000 requests/day |
| DeepSeek API | https://platform.deepseek.com/ | A ¥10 top-up lasts a long time |
| Volcengine Doubao TTS | https://console.volcengine.com/speech/service/8 | 100k characters/month free |
| Alibaba Cloud server | https://swas.console.aliyun.com/#/buy | ¥24/month (Singapore) |

## Tech stack

| Layer | Technology |
|---|---|
| iOS native | Swift, SwiftUI, WKWebView, AVFoundation, Vision, CoreLocation |
| Web UI | Plain HTML + CSS + JS (no framework) |
| Proxy | Python 3.12 + aiohttp |
| Deployment | Ubuntu 24.04 + systemd |
| AI | Gemini 2.5 Flash Lite / DeepSeek Chat |
| TTS | Volcengine Doubao speech synthesis 2.0 |
| STT | SiliconFlow Whisper (default) / Apple Speech Recognition (fallback) |
| Face detection | Apple Vision Framework |

## License

[MIT](LICENSE)
