# AI Makeup Assistant

一个基于 Gemini Live API 的 iOS 美妆助手应用。

## 功能特性

- 实时语音对话
- 豆包 TTS 语音合成
- AI 美妆建议

## 环境配置

### 1. 安装依赖

```bash
pip install python-dotenv
```

### 2. 配置环境变量

复制 `.env.example` 文件为 `.env`：

```bash
cp .env.example .env
```

然后编辑 `.env` 文件，填入你的 VolcEngine API 密钥：

```
DOUBAO_APP_ID=你的应用ID
ACCESS_KEY_ID=你的AccessKeyID
SECRET_ACCESS_KEY=你的SecretAccessKey
```

### 3. 运行代理服务器

```bash
python3 doubao_tts_proxy.py
```

## TestFlight 分发

详见项目文档中的 TestFlight 配置指南。

## 开发环境

- iOS 14.0+
- Xcode 13.0+
- Python 3.7+
