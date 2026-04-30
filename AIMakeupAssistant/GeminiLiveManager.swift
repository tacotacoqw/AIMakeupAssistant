import Foundation
import AVFoundation

class GeminiLiveManager: NSObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let apiKey: String
    private let model = "gemini-2.5-flash-preview-05-20"

    var onTextResponse: ((String) -> Void)?
    var onAudioResponse: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func connect() {
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            onError?(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        // 发送初始化配置
        sendSetup()

        // 开始接收消息
        receiveMessage()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func interrupt() {
        // 发送中断信号，停止当前生成
        let interruptMessage: [String: Any] = [
            "client_content": [
                "turn_complete": true
            ]
        ]
        sendMessage(interruptMessage)
    }

    private func sendSetup() {
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generation_config": [
                    "response_modalities": ["TEXT", "AUDIO"],
                    "speech_config": [
                        "voice_config": [
                            "prebuilt_voice_config": [
                                "voice_name": "Aoede"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        sendMessage(setup)
    }

    func sendText(_ text: String) {
        let message: [String: Any] = [
            "client_content": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": text]
                        ]
                    ]
                ],
                "turn_complete": true
            ]
        ]

        sendMessage(message)
    }

    func sendImage(_ base64Image: String, withText text: String = "") {
        var parts: [[String: Any]] = []

        if !text.isEmpty {
            parts.append(["text": text])
        }

        parts.append([
            "inline_data": [
                "mime_type": "image/jpeg",
                "data": base64Image
            ]
        ])

        let message: [String: Any] = [
            "client_content": [
                "turns": [
                    [
                        "role": "user",
                        "parts": parts
                    ]
                ],
                "turn_complete": true
            ]
        ]

        sendMessage(message)
    }

    private func sendMessage(_ message: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { [weak self] error in
            if let error = error {
                self?.onError?(error)
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleResponse(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleResponse(text)
                    }
                @unknown default:
                    break
                }

                // 继续接收下一条消息
                self.receiveMessage()

            case .failure(let error):
                self.onError?(error)
            }
        }
    }

    private func handleResponse(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // 解析服务器内容
        if let serverContent = json["serverContent"] as? [String: Any],
           let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // 文本响应
                if let text = part["text"] as? String {
                    DispatchQueue.main.async {
                        self.onTextResponse?(text)
                    }
                }

                // 音频响应
                if let inlineData = part["inlineData"] as? [String: Any],
                   let base64Audio = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64Audio) {
                    DispatchQueue.main.async {
                        self.onAudioResponse?(audioData)
                    }
                }
            }
        }
    }
}

extension GeminiLiveManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("Gemini Live WebSocket connected")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("Gemini Live WebSocket disconnected")
    }
}
