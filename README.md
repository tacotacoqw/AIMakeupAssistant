# AI Makeup Assistant

一个基于 Gemini API 的 iOS 美妆助手应用。

## 功能特性

- AI 美妆建议
- Edge TTS 语音合成（免费云端 Neural 语音，晓伊 gentle 风格）

## 环境配置

iOS 端通过 `proxy_server.py` 访问 Gemini API。在 Mac 上运行：

```bash
python3 proxy_server.py
```

代理监听 `http://0.0.0.0:8888`，iOS 端默认连接 `192.168.1.114:8888`。

## TestFlight 分发

详见项目文档中的 TestFlight 配置指南。

## 开发环境

- iOS 14.0+
- Xcode 13.0+
- Python 3.7+
