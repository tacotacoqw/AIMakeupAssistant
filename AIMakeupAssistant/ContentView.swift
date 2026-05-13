import SwiftUI
import WebKit
import AVFoundation
import Speech
import CoreLocation
import Security
import Vision
import CryptoKit

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "AIMakeupAssistant"
        ]

        SecItemDelete(query as CFDictionary)

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "AIMakeupAssistant",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "AIMakeupAssistant",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }
}

struct ContentView: View {
    @State private var permissionsGranted = false
    @State private var showingPermissionAlert = false

    var body: some View {
        ZStack {
            if permissionsGranted {
                WebViewContainer()
                    .ignoresSafeArea()
            } else {
                PermissionRequestView(permissionsGranted: $permissionsGranted)
            }
        }
        .onAppear {
            checkPermissions()

            // 测试 API 是否工作
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let testService = AIService()
                let testMessages: [[String: Any]] = [
                    ["role": "user", "content": "你好"]
                ]
                testService.chatStream(messages: testMessages, onChunk: { chunk in
                    print("✅ API 测试成功，收到响应: \(chunk)")
                }, completion: { result in
                    switch result {
                    case .success(let text):
                        print("✅ API 完整响应: \(text)")
                    case .failure(let error):
                        print("❌ API 测试失败: \(error.localizedDescription)")
                    }
                })
            }
        }
    }

    func checkPermissions() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if cameraStatus == .authorized && micStatus == .authorized {
            permissionsGranted = true
        }
    }
}

struct PermissionRequestView: View {
    @Binding var permissionsGranted: Bool
    @State private var cameraGranted = false
    @State private var micGranted = false
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.pink)

            Text("AI 美妆助手")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("为了提供最佳体验，我们需要以下权限：")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(icon: "camera.fill", title: "摄像头", description: "用于实时查看你的面部", granted: cameraGranted)
                PermissionRow(icon: "mic.fill", title: "麦克风", description: "用于语音对话", granted: micGranted)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .padding(.horizontal)

            Button(action: requestPermissions) {
                HStack {
                    if isRequesting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("授权并开始")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.pink)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isRequesting)
            .padding(.horizontal)

            Spacer()
        }
        .onAppear {
            updatePermissionStatus()
        }
    }

    func updatePermissionStatus() {
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPermissions() {
        isRequesting = true

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                cameraGranted = granted

                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        micGranted = granted
                        isRequesting = false

                        if cameraGranted && micGranted {
                            permissionsGranted = true
                        }
                    }
                }
            }
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.pink)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? .green : .gray)
        }
    }
}

// MARK: - AI Service (Gemini)

class AIService {
    // 代理服务器配置 — 所有 Gemini 流量都过 Mac 代理（API key 在代理的 .env 里）
    // 切换网络环境时改这里的 IP
    private static let proxyHost = "192.168.0.164:8888"
    private let proxyURL = "http://\(AIService.proxyHost)/api/chat"
    private let liveProxyURL = "ws://\(AIService.proxyHost)/api/live"

    weak var ttsManager: TTSManager?

    // Gemini Live（实时语音对话）
    private var geminiLiveManager: GeminiLiveManager?
    var onGeminiLiveResponse: ((String) -> Void)?
    var onGeminiLiveAudio: (() -> Void)?

    private let systemPrompt = """
    你是"小美"，一个专业的AI美妆助手。你的职责是：
    1. 一步步指导用户化妆，从护肤到完整妆容
    2. 根据用户描述推荐适合的化妆品和色号
    3. 分析用户的肤质问题并给出建议
    4. 讲解化妆技巧，用简单易懂的语言
    5. 推荐适合不同场合的妆容风格
    6. 当系统附带了面部照片时，仔细分析照片中的皮肤状态（肤色、毛孔、痘痘、黑眼圈、肤质类型等），给出专业但通俗的分析和护肤建议

    重要：本APP的摄像头是一直开着的，你可以随时通过摄像头看到用户。用户不需要主动拍照，系统会在需要时自动截取画面发给你分析。所以你绝对不要说"请拍一张照片"、"需要看到你的照片"之类的话，你已经能看到用户了。

    任务清单功能（非常重要！你必须严格遵守以下格式规则）：

    【何时必须返回任务清单】
    当用户请求以下任何类型的指导时，你必须立即返回任务清单：
    - 化妆教程：如"教我化妆"、"怎么化妆"、"日常妆怎么画"、"教我画淡妆"、"教我画眼妆"
    - 护肤步骤：如"怎么护肤"、"护肤步骤"、"教我护肤"
    - 卸妆步骤：如"怎么卸妆"、"卸妆步骤"
    - 任何包含"教我"、"怎么"、"步骤"、"教程"等关键词的请求

    【任务清单格式 - 必须严格按照此格式】
    [CHECKLIST]
    步骤名称1|简短说明
    步骤名称2|简短说明
    步骤名称3|简短说明
    [/CHECKLIST]
    然后说一句引导语，引导用户开始第一步。

    格式要求：
    1. 必须以 [CHECKLIST] 开始，以 [/CHECKLIST] 结束
    2. 每个步骤占一行
    3. 步骤名称和说明之间用竖线 | 分隔（注意是竖线，不是其他符号）
    4. 步骤控制在3-6步
    5. 步骤名称要简短（2-6个字），说明要具体（8-15个字）

    【示例1 - 日常妆教程】
    用户："教我画日常妆"
    你的回复：
    [CHECKLIST]
    洁面|用洗面奶清洁面部
    涂防晒|取适量防晒霜均匀涂抹
    涂粉底|用美妆蛋轻拍全脸
    画眉毛|用眉笔勾勒眉形
    涂口红|选择自然色号涂抹双唇
    [/CHECKLIST]
    好的，我们开始第一步吧！先用洗面奶把脸洗干净~

    【示例2 - 护肤步骤】
    用户："怎么护肤"
    你的回复：
    [CHECKLIST]
    洁面|温水打湿后用洗面奶按摩
    爽肤水|用化妆棉轻拍全脸
    精华液|取2-3滴按摩至吸收
    面霜|均匀涂抹锁住水分
    [/CHECKLIST]
    好的，我们从洁面开始！用温水把脸打湿，然后取适量洗面奶~


    任务完成检测说明（极其重要！）：
    本APP配备了AI视觉检测系统，会自动通过摄像头检测用户是否完成了当前步骤。同时也支持语音关键词识别（用户说"完成了"等会自动标记）。
    所以当你在指导任务步骤时：
    - 不要问用户"完成了吗？"、"好了吗？"、"做好了告诉我"
    - 你只需要详细讲解当前步骤怎么做就行，完成检测交给系统
    - 如果用户在对话中顺带提到完成了，你的回复可以以 [DONE:步骤序号] 开头（备用机制）

    示例：当前进行第1步"洁面清洁"，用户主动说"洗好了" → 回复以 [DONE:1] 开头
    所有步骤都完成 → 回复以 [ALLDONE] 开头

    回复要求：
    - 用亲切友好的语气，像闺蜜一样聊天
    - 每次回复控制在150字以内，简洁实用
    - 如果是教程步骤，直接详细讲解当前步骤的操作方法和技巧
    - 分析皮肤时，先说整体评价，再分点说明具体问题和建议
    - 可以适当使用"~"等语气词让对话更自然

    语音输入纠错规则（极其重要！必须严格遵守）：
    用户的输入来自实时语音识别，可能存在误识别、残词、不完整等问题。你必须：
    1. 忽略明显的环境杂音识别结果（旁人说话、回声、电视背景音）
    2. 如果识别文本是单字、残词、无主语无谓词、明显不完整（如"像""啊""嗯""这个"），必须结合对话上下文自动修正为最合理的完整句子
    3. 若修正后仍有歧义，优先还原为"最常见、最自然的人类口语表达"，而不是字面发音
    4. 禁止把识别错误直接当成用户意图。语义明显异常时，优先修正后回答正确问题
    5. 只有在完全无法判断用户真实意图时，才简短确认，如："你是想问xxx吗？"
    6. 所有你理解的用户意图，必须是语义完整、口语自然、符合人类真实表达的句子
    """

    var isConfigured: Bool { true }
    var isVisionConfigured: Bool { true }

    func chat(messages: [[String: Any]], images: [String] = [], temperature: Double = 0.8, completion: @escaping (Result<String, Error>) -> Void) {
        // 统一使用 Gemini（文本和图片）
        chatWithGemini(messages: messages, images: images, temperature: temperature, completion: completion)
    }

    // Gemini 流式聊天（边生成边返回）
    private var streamDelegate: GeminiStreamingDelegate?

    func chatStream(messages: [[String: Any]], maxTokens: Int = 500, onChunk: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: proxyURL) else {
            return
        }

        // 构建对话历史
        var contents: [[String: Any]] = []

        // 添加历史消息（排除 system）
        for msg in messages.dropLast() {
            guard let role = msg["role"] as? String, role != "system" else { continue }
            let geminiRole = role == "assistant" ? "model" : "user"
            if let content = msg["content"] as? String {
                contents.append([
                    "role": geminiRole,
                    "parts": [["text": content]]
                ])
            }
        }

        // 最后一条消息
        if let lastMsg = messages.last {
            let content = lastMsg["content"] as? String ?? ""
            contents.append([
                "role": "user",
                "parts": [["text": systemPrompt + "\n\n" + content]]
            ])
        }

        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": 0.8,
                "maxOutputTokens": maxTokens
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "请求构造失败"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 120

        // 打印请求信息用于调试
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 Gemini 请求长度: \(jsonString.count), 前500字符: \(jsonString.prefix(500))")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 240

        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Gemini API 错误: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                print("📥 HTTP 状态码: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                print("❌ 无响应数据")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])))
                }
                return
            }

            // 打印原始响应用于调试
            if let responseString = String(data: data, encoding: .utf8) {
                print("📥 Gemini 原始响应长度: \(responseString.count), 前500字符: \(responseString.prefix(500))")
            }

            // HTTP 非 200 → 优先读代理 / Gemini 返回的 error.message，给用户人话
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                let friendly: String
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let topErr = json["error"] as? String {
                        friendly = topErr
                    } else if let errObj = json["error"] as? [String: Any],
                              let m = errObj["message"] as? String {
                        friendly = m
                    } else {
                        friendly = "AI 出错了 (HTTP \(httpResp.statusCode))"
                    }
                } else {
                    friendly = "AI 出错了 (HTTP \(httpResp.statusCode))"
                }
                print("❌ chatStream HTTP \(httpResp.statusCode): \(friendly.prefix(200))")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "", code: httpResp.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: friendly])))
                }
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String {

                    print("✅ Gemini 返回文本长度: \(text.count)")

                    // 逐句发送，模拟流式效果（使用后台队列避免阻塞主线程）
                    DispatchQueue.global(qos: .userInitiated).async {
                        let sentences = text.components(separatedBy: CharacterSet(charactersIn: "。！？.!?\n"))
                        var delay: TimeInterval = 0
                        for sentence in sentences {
                            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    onChunk(trimmed)
                                }
                                delay += 0.05 // 每句延迟 50ms
                            }
                        }

                        // 最后发送完成回调
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            completion(.success(text))
                        }
                    }
                } else {
                    // 200 但 JSON 结构异常（如 finishReason=MAX_TOKENS 没文本、内容被过滤）
                    var friendly = "AI 这次没回出内容，请换个问法试试"
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let cands = json["candidates"] as? [[String: Any]],
                       let first = cands.first {
                        if let reason = first["finishReason"] as? String {
                            switch reason {
                            case "MAX_TOKENS": friendly = "回复太长被截断了，请让 AI 简短回答"
                            case "SAFETY": friendly = "AI 觉得这个话题不合适，请换个问题"
                            case "RECITATION": friendly = "AI 拒绝了重复输出，请换个问法"
                            default: friendly = "AI 提前结束 (\(reason))，请重试"
                            }
                        }
                    }
                    print("❌ chatStream 结构异常: \(friendly)")
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: friendly])))
                    }
                }
            } catch {
                print("❌ JSON 解析错误: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // Gemini 视觉分析（支持文本和图片）
    private func chatWithGemini(messages: [[String: Any]], images: [String], temperature: Double = 0.8, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: proxyURL) else { return }

        // 构建对话历史
        var contents: [[String: Any]] = []

        // 添加历史消息（排除 system）
        for msg in messages.dropLast() {
            guard let role = msg["role"] as? String, role != "system" else { continue }
            let geminiRole = role == "assistant" ? "model" : "user"
            if let content = msg["content"] as? String {
                contents.append([
                    "role": geminiRole,
                    "parts": [["text": content]]
                ])
            }
        }

        // 最后一条消息 + 图片
        if let lastMsg = messages.last {
            let content = lastMsg["content"] as? String ?? ""
            var parts: [[String: Any]] = [["text": systemPrompt + "\n\n" + content]]

            // 添加图片
            for img in images {
                parts.append([
                    "inline_data": [
                        "mime_type": "image/jpeg",
                        "data": img
                    ]
                ])
            }

            contents.append([
                "role": "user",
                "parts": parts
            ])
        }

        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": 2000
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "请求构造失败"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 120

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 240
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String {
                    completion(.success(text))
                } else {
                    let errorMsg = String(data: data, encoding: .utf8) ?? "解析失败"
                    completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gemini 响应格式错误: \(errorMsg)"])))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // 通用请求发送
    // MARK: - Gemini Live Methods（Google Gemini Live 实时语音对话）

    func startGeminiLive() {
        // 复用既有连接（避免重复 connect）
        if geminiLiveManager != nil { return }

        let manager = GeminiLiveManager(proxyURL: liveProxyURL)
        manager.onTextResponse = { [weak self] text in
            self?.onGeminiLiveResponse?(text)
        }
        manager.onAudioResponse = { [weak self] pcmData in
            // Gemini Live 返回 24kHz 16bit 单声道裸 PCM，TTSManager 内套 WAV 头再播放
            self?.ttsManager?.playLivePCMAudio(pcmData)
            self?.onGeminiLiveAudio?()
        }
        manager.onError = { error in
            print("❌ Gemini Live error: \(error.localizedDescription)")
        }
        manager.connect()
        geminiLiveManager = manager
    }

    func stopGeminiLive() {
        geminiLiveManager?.disconnect()
        geminiLiveManager = nil
        ttsManager?.stopSpeaking()
    }

    func sendToGeminiLive(text: String) {
        geminiLiveManager?.sendText(text)
    }

    func sendTextToGeminiLive(text: String) {
        geminiLiveManager?.sendText(text)
    }

    func sendImageToGeminiLive(base64Image: String, withText text: String = "") {
        geminiLiveManager?.sendImage(base64Image, withText: text)
    }

    func interruptGeminiLive() {
        geminiLiveManager?.interrupt()
        ttsManager?.stopSpeaking()
    }
}

// MARK: - Streaming Delegate (SSE 流式解析)

// MARK: - Gemini Streaming Delegate (SSE 流式解析)

class GeminiStreamingDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = ""
    private var fullText = ""
    private let onChunk: (String) -> Void
    private let completion: (Result<String, Error>) -> Void

    init(onChunk: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        self.onChunk = onChunk
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let str = String(data: data, encoding: .utf8) else {
            return
        }
        buffer += str
        processBuffer()
    }

    private func processBuffer() {
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[range.upperBound...])

            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if jsonStr == "[DONE]" {
                continue
            }

            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else {
                continue
            }

            fullText += text
            DispatchQueue.main.async { self.onChunk(text) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !buffer.isEmpty { processBuffer() }

        DispatchQueue.main.async {
            if let error = error {
                self.completion(.failure(error))
            } else {
                self.completion(.success(self.fullText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}

// MARK: - TTS Manager (Native Text-to-Speech)

class TTSManager: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    private var synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var currentVoiceId: String
    private var intentionallyStopped = false
    private var pendingText: String?
    private var wsTask: URLSessionWebSocketTask?
    private let wsSession = URLSession(configuration: .default)
    private var edgeFallbackTimer: DispatchWorkItem?

    // Edge TTS 云端语音
    private var edgeVoice: String
    private var useCloudTTS: Bool

    var onSpeakStart: (() -> Void)?
    var onSpeakEnd: (() -> Void)?
    var onCloudTTSError: ((String) -> Void)?

    override init() {
        // 系统语音回退
        let preferredVoices = [
            "com.apple.voice.premium.zh-CN.Tingting",
            "com.apple.voice.enhanced.zh-CN.Tingting",
            "com.apple.voice.compact.zh-CN.Tingting"
        ]
        let savedVoice = UserDefaults.standard.string(forKey: "tts_voice_id") ?? ""
        if !savedVoice.isEmpty {
            currentVoiceId = savedVoice
        } else {
            currentVoiceId = preferredVoices.first(where: { AVSpeechSynthesisVoice(identifier: $0) != nil }) ?? ""
        }

        // Edge TTS 配置：默认晓伊（更自然、温柔），从旧默认晓晓一次性迁移
        let defaultEdgeVoice = "zh-CN-XiaoyiNeural"
        let savedEdgeVoice = UserDefaults.standard.string(forKey: "edge_voice_id")
        let didMigrateVoice = UserDefaults.standard.bool(forKey: "edge_voice_migrated_v2")
        if !didMigrateVoice && savedEdgeVoice == "zh-CN-XiaoxiaoNeural" {
            edgeVoice = defaultEdgeVoice
            UserDefaults.standard.set(defaultEdgeVoice, forKey: "edge_voice_id")
        } else {
            edgeVoice = savedEdgeVoice ?? defaultEdgeVoice
        }
        UserDefaults.standard.set(true, forKey: "edge_voice_migrated_v2")

        useCloudTTS = UserDefaults.standard.object(forKey: "use_cloud_tts") != nil
            ? UserDefaults.standard.bool(forKey: "use_cloud_tts")
            : true // 默认启用 Edge TTS 云端语音

        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Gemini 原生语音合成

    private var isPlayingGeminiAudio = false
    private let geminiTTSProxyUrl = "http://192.168.0.164:8888/api/tts"

    private func speakWithGemini(_ text: String) {
        intentionallyStopped = false
        isPlayingGeminiAudio = false
        onSpeakStart?()
        print("🔊 Edge TTS: 请求朗读 \(text.prefix(30))...")

        // 通过代理请求 Gemini TTS
        guard let url = URL(string: geminiTTSProxyUrl) else {
            fallbackToSystemTTS(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let requestBody: [String: Any] = ["text": text]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            fallbackToSystemTTS(text)
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ Gemini TTS 网络错误: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.fallbackToSystemTTS(text)
                }
                return
            }

            guard let data = data else {
                print("❌ Gemini TTS 无数据返回")
                DispatchQueue.main.async {
                    self.fallbackToSystemTTS(text)
                }
                return
            }

            print("✓ Gemini TTS 收到音频数据: \(data.count) bytes")

            // 播放音频（Edge TTS 返回 MP3 格式）
            DispatchQueue.main.async {
                self.playGeminiMP3(data)
            }
        }.resume()
    }

    private func playGeminiMP3(_ mp3Data: Data) {
        guard !intentionallyStopped else {
            print("⚠️ 播放被取消（intentionallyStopped）")
            onSpeakEnd?()
            return
        }

        print("🎵 开始播放 Edge TTS MP3: \(mp3Data.count) bytes")

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)

            audioPlayer = try AVAudioPlayer(data: mp3Data)
            audioPlayer?.delegate = self

            guard let player = audioPlayer else {
                print("❌ AVAudioPlayer 初始化失败")
                onSpeakEnd?()
                return
            }

            let duration = player.duration
            print("✓ 音频时长: \(String(format: "%.2f", duration))秒")

            let success = player.play()
            if success {
                print("✓ 开始播放音频")
            } else {
                print("❌ 播放失败")
                onSpeakEnd?()
            }
        } catch {
            print("❌ Edge TTS 音频播放错误: \(error.localizedDescription)")
            onSpeakEnd?()
        }
    }

    private func fallbackToSystemTTS(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: currentVoiceId)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.1
        synthesizer.speak(utterance)
    }

    // MARK: - Edge TTS 云端语音（免费）

    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "1-143.0.3650.75"
    private static let winEpoch: Int64 = 11644473600

    private static func generateSecMsGec() -> String {
        var ticks = Int64(Date().timeIntervalSince1970)
        ticks += winEpoch
        ticks -= ticks % 300
        ticks *= 10_000_000 // 100ns intervals
        let strToHash = "\(ticks)\(trustedClientToken)"
        let hash = SHA256.hash(data: Data(strToHash.utf8))
        return hash.map { String(format: "%02X", $0) }.joined()
    }

    func setCloudVoice(_ voiceId: String) {
        edgeVoice = voiceId
        UserDefaults.standard.set(voiceId, forKey: "edge_voice_id")
    }

    func getCloudVoiceId() -> String {
        return edgeVoice
    }

    func setUseCloudTTS(_ enabled: Bool) {
        useCloudTTS = enabled
        UserDefaults.standard.set(enabled, forKey: "use_cloud_tts")
    }

    func getUseCloudTTS() -> Bool {
        return useCloudTTS
    }

    private func speakWithEdge(_ text: String, isRetry: Bool = false) {
        intentionallyStopped = false
        pendingText = text

        let connId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let secGec = TTSManager.generateSecMsGec()
        let urlStr = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(TTSManager.trustedClientToken)&ConnectionId=\(connId)&Sec-MS-GEC=\(secGec)&Sec-MS-GEC-Version=\(TTSManager.secMsGecVersion)"

        guard let url = URL(string: urlStr) else {
            speakWithSystem(text)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let ws = wsSession.webSocketTask(with: request)
        self.wsTask = ws
        ws.resume()

        // 整体超时：8秒内没播放就回退
        let fallback = DispatchWorkItem { [weak self] in
            guard let self = self, !self.intentionallyStopped, self.pendingText == text else { return }
            // 超时时如果还没开始播放音频，则回退
            if !(self.audioPlayer?.isPlaying ?? false) {
                ws.cancel(with: .normalClosure, reason: nil)
                if !isRetry {
                    self.speakWithEdge(text, isRetry: true)
                } else {
                    self.speakWithSystem(text)
                }
            }
        }
        self.edgeFallbackTimer = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: fallback)

        // 1) 发送配置消息
        let configMsg = "Content-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"
        ws.send(.string(configMsg)) { [weak self] error in
            guard let self = self, !self.intentionallyStopped else { return }
            if error != nil {
                DispatchQueue.main.async {
                    fallback.cancel()
                    if !isRetry {
                        self.speakWithEdge(text, isRetry: true)
                    } else {
                        self.speakWithSystem(text)
                    }
                }
                return
            }

            // 2) 发送 SSML
            let escapedText = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")

            let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            // gentle 风格 + 略慢语速，听感更自然温柔
            let ssmlMsg = "X-RequestId:\(requestId)\r\nContent-Type:application/ssml+xml\r\nPath:ssml\r\n\r\n<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='http://www.w3.org/2001/mstts' xml:lang='zh-CN'><voice name='\(self.edgeVoice)'><mstts:express-as style='gentle' styledegree='1.3'><prosody pitch='+0Hz' rate='-5%' volume='+0%'>\(escapedText)</prosody></mstts:express-as></voice></speak>"

            ws.send(.string(ssmlMsg)) { sendError in
                if sendError != nil {
                    DispatchQueue.main.async {
                        fallback.cancel()
                        if !isRetry {
                            self.speakWithEdge(text, isRetry: true)
                        } else {
                            self.speakWithSystem(text)
                        }
                    }
                    return
                }
                // onSpeakStart 移到 playAudioData 中触发，确保音频真正开始播放时才通知JS
                // 避免SSML发送后、音频到达前这段空窗期导致音量监听误判
            }
        }

        // 3) 接收音频数据
        var audioChunks = Data()
        func receive() {
            ws.receive { [weak self] result in
                guard let self = self, !self.intentionallyStopped else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let str):
                        if str.contains("Path:turn.end") {
                            fallback.cancel()
                            if !audioChunks.isEmpty {
                                DispatchQueue.main.async { self.playAudioData(audioChunks) }
                            } else if !isRetry {
                                DispatchQueue.main.async { self.speakWithEdge(text, isRetry: true) }
                            } else {
                                DispatchQueue.main.async { self.speakWithSystem(text) }
                            }
                            ws.cancel(with: .normalClosure, reason: nil)
                            return
                        }
                        receive()
                    case .data(let data):
                        if data.count > 2 {
                            let headerLen = Int(data[0]) << 8 | Int(data[1])
                            let audioStart = headerLen + 2
                            if data.count > audioStart {
                                audioChunks.append(data.subdata(in: audioStart..<data.count))
                            }
                        }
                        receive()
                    @unknown default:
                        receive()
                    }
                case .failure(_):
                    fallback.cancel()
                    if !audioChunks.isEmpty {
                        DispatchQueue.main.async { self.playAudioData(audioChunks) }
                    } else if !isRetry {
                        DispatchQueue.main.async { self.speakWithEdge(text, isRetry: true) }
                    } else {
                        DispatchQueue.main.async { self.speakWithSystem(text) }
                    }
                }
            }
        }
        receive()
    }

    private func playAudioData(_ data: Data) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 使用 .default 模式播放，音量更大（.voiceChat 会降低音量走听筒）
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)

            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.volume = 1.0
            audioPlayer?.play()
            // 音频真正开始播放时才触发 onSpeakStart
            // 确保JS端的音量监听在有实际TTS音频时才开始校准
            onSpeakStart?()
        } catch {
            onSpeakEnd?()
        }
    }

    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("🎵 音频播放完成: \(flag ? "成功" : "失败")")
        audioPlayer = nil
        isPlayingGeminiAudio = false
        DispatchQueue.main.async { self.onSpeakEnd?() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("❌ 音频解码错误: \(error?.localizedDescription ?? "未知错误")")
        audioPlayer = nil
        DispatchQueue.main.async { self.onSpeakEnd?() }
    }

    // MARK: - 系统 TTS（回退方案）

    func getChineseVoices() -> [[String: String]] {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        return voices.map { voice in
            var qualityLabel = "普通"
            if voice.quality == .enhanced {
                qualityLabel = "增强"
            }
            if voice.identifier.contains("premium") {
                qualityLabel = "高级"
            }
            return [
                "id": voice.identifier,
                "name": voice.name,
                "lang": voice.language,
                "quality": qualityLabel,
                "selected": voice.identifier == currentVoiceId ? "true" : "false"
            ]
        }
    }

    func setVoice(_ voiceId: String) {
        currentVoiceId = voiceId
        UserDefaults.standard.set(voiceId, forKey: "tts_voice_id")
    }

    func getCurrentVoiceId() -> String {
        return currentVoiceId
    }

    // MARK: - 主入口

    func speak(_ text: String, rate: Float = 0.52, pitch: Float = 1.1) {
        stopSpeaking()
        intentionallyStopped = false
        pendingText = text

        // 优先用 Gemini 2.5 神经 TTS（端到端，自然度远超 Edge），失败回 Edge，再失败回系统
        if useCloudTTS {
            speakWithGeminiTTS(text)
        } else {
            speakWithSystem(text, rate: rate, pitch: pitch)
        }
    }

    // MARK: - 云端神经 TTS（默认火山豆包；通过 Mac 代理）

    private static let ttsProxyURL = "http://192.168.0.164:8888/api/tts"
    private static let defaultVolcVoice = "zh_female_cancan_mars_bigtts"

    func setVolcVoice(_ voiceId: String) {
        UserDefaults.standard.set(voiceId, forKey: "volc_voice_id")
    }

    func getVolcVoiceId() -> String {
        return UserDefaults.standard.string(forKey: "volc_voice_id") ?? TTSManager.defaultVolcVoice
    }

    private func speakWithGeminiTTS(_ text: String) {
        guard let url = URL(string: TTSManager.ttsProxyURL) else {
            speakWithEdge(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = ["text": text, "voice": getVolcVoiceId()]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, !self.intentionallyStopped, self.pendingText == text else { return }

            if let error = error {
                print("❌ 云 TTS 网络错: \(error.localizedDescription)")
                DispatchQueue.main.async { self.speakWithEdge(text) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("❌ 云 TTS HTTP \(http.statusCode)")
                DispatchQueue.main.async { self.speakWithEdge(text) }
                return
            }
            guard let audio = data, !audio.isEmpty else {
                DispatchQueue.main.async { self.speakWithEdge(text) }
                return
            }

            // 代理返回的是 MP3（火山）或 WAV/PCM（Gemini 备用）；AVAudioPlayer 都能直接吃 MP3 和 WAV
            DispatchQueue.main.async { self.playAudioData(audio) }
        }.resume()
    }

    private func speakWithSystem(_ text: String, rate: Float = 0.52, pitch: Float = 1.1) {
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.1

        if !currentVoiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: currentVoiceId) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 使用 .default 模式播放，音量更大（.voiceChat 会降低音量走听筒）
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
        } catch {}

        synthesizer.speak(utterance)

        // Watchdog：1秒后检查是否真的在播放
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, !self.intentionallyStopped, self.pendingText == text else { return }
            if !self.synthesizer.isSpeaking {
                self.synthesizer = AVSpeechSynthesizer()
                self.synthesizer.delegate = self

                let retry = AVSpeechUtterance(string: text)
                retry.rate = rate
                retry.pitchMultiplier = pitch
                retry.volume = 1.0
                retry.preUtteranceDelay = 0.0
                if !self.currentVoiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: self.currentVoiceId) {
                    retry.voice = voice
                } else {
                    retry.voice = AVSpeechSynthesisVoice(language: "zh-CN")
                }
                self.synthesizer.speak(retry)
            }
        }
    }

    func stopSpeaking() {
        intentionallyStopped = true
        pendingText = nil
        edgeFallbackTimer?.cancel()
        edgeFallbackTimer = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        isPlayingGeminiAudio = false
        stopLivePCM()
    }

    // MARK: - Gemini Live PCM 流式播放（24kHz 16bit mono）

    private var liveAudioEngine: AVAudioEngine?
    private var liveAudioNode: AVAudioPlayerNode?
    private let liveAudioFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    }()
    private var liveAudioEndTimer: DispatchWorkItem?
    private var isPlayingLiveAudio = false

    private func ensureLiveEngineStarted() {
        if liveAudioEngine?.isRunning == true { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
        } catch {
            print("❌ Live audio session 配置失败: \(error.localizedDescription)")
            return
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: liveAudioFormat)

        do {
            try engine.start()
            node.play()
            liveAudioEngine = engine
            liveAudioNode = node
        } catch {
            print("❌ Live audio engine 启动失败: \(error.localizedDescription)")
            liveAudioEngine = nil
            liveAudioNode = nil
        }
    }

    func playLivePCMAudio(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.ensureLiveEngineStarted()
            guard let node = self.liveAudioNode else { return }

            let frameCount = AVAudioFrameCount(pcmData.count / 2) // Int16 mono = 2 bytes/frame
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.liveAudioFormat, frameCapacity: frameCount) else {
                return
            }
            buffer.frameLength = frameCount

            pcmData.withUnsafeBytes { raw in
                guard let src = raw.bindMemory(to: Int16.self).baseAddress,
                      let dst = buffer.int16ChannelData?[0] else { return }
                memcpy(dst, src, pcmData.count)
            }

            node.scheduleBuffer(buffer, completionHandler: nil)

            if !self.isPlayingLiveAudio {
                self.isPlayingLiveAudio = true
                self.onSpeakStart?()
            }

            // 500ms 无新 chunk 视为本轮播放结束，触发 onSpeakEnd
            self.liveAudioEndTimer?.cancel()
            let endTask = DispatchWorkItem { [weak self] in
                guard let self = self, self.isPlayingLiveAudio else { return }
                self.isPlayingLiveAudio = false
                self.onSpeakEnd?()
            }
            self.liveAudioEndTimer = endTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: endTask)
        }
    }

    private func stopLivePCM() {
        liveAudioEndTimer?.cancel()
        liveAudioEndTimer = nil
        liveAudioNode?.stop()
        liveAudioEngine?.stop()
        liveAudioNode = nil
        liveAudioEngine = nil
        if isPlayingLiveAudio {
            isPlayingLiveAudio = false
            DispatchQueue.main.async { self.onSpeakEnd?() }
        }
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || (audioPlayer?.isPlaying ?? false)
    }

    // AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onSpeakStart?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onSpeakEnd?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // 不触发 onSpeakEnd：didCancel 只在主动调用 stopSpeaking 时触发
        // 调用方（speak/stopSpeak/nativeUserInterrupt）已自行处理状态
        // 如果触发 onSpeakEnd 会导致 stale nativeTTSEnded，破坏后续 TTS 状态
    }
}

// MARK: - Speech Recognition Manager

class SpeechManager: NSObject, ObservableObject {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // 追踪最后的 partial 文本，确保识别结束时一定能返回结果
    private var lastPartialText: String = ""
    private var didFireFinalResult = false

    // 静音超时计时器
    private var silenceTimer: Timer?
    // 强制超时计时器（3秒无新内容则强制停止）
    private var forceStopTimer: Timer?

    var onResult: ((String) -> Void)?
    var onPartialResult: ((String) -> Void)?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Whisper STT 配置
    var whisperAPIKey: String = "" {
        didSet { UserDefaults.standard.set(whisperAPIKey, forKey: "whisper_api_key") }
    }
    var whisperAPIURL: String = "https://api.siliconflow.cn/v1/audio/transcriptions" {
        didSet { UserDefaults.standard.set(whisperAPIURL, forKey: "whisper_api_url") }
    }
    var whisperModel: String = "FunAudioLLM/SenseVoiceSmall" {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisper_model") }
    }
    var useWhisperSTT: Bool { !whisperAPIKey.isEmpty }

    // Whisper 录音相关
    private var whisperRecorder: AVAudioRecorder?
    private var whisperFileURL: URL?
    private var whisperLevelTimer: Timer?
    private var whisperMaxTimer: DispatchWorkItem?
    private var whisperHasSound = false
    private var whisperIsTranscribing = false
    // 混合模式：Apple STT 实时显示 + Whisper 最终识别
    private var realtimePartialTask: SFSpeechRecognitionTask?
    private var realtimePartialRequest: SFSpeechAudioBufferRecognitionRequest?
    private var realtimeLastText: String = "" // Apple STT 最新识别文本

    override init() {
        super.init()
        // 从 UserDefaults 恢复配置
        whisperAPIKey = UserDefaults.standard.string(forKey: "whisper_api_key") ?? "sk-nvhyzltqyauqlatvkbgizbvrjgqxsgrqkmtczryqcdulyytt"
        if let url = UserDefaults.standard.string(forKey: "whisper_api_url"), !url.isEmpty {
            whisperAPIURL = url
        }
        if let model = UserDefaults.standard.string(forKey: "whisper_model"), !model.isEmpty {
            whisperModel = model
        }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    // 录音看门狗：检测录音启动后是否收到音频数据
    private var recordingWatchdog: DispatchWorkItem?
    private var hasReceivedAudioData = false

    // MARK: - 录音入口（自动选择 Whisper 或 Apple 原生）

    func startRecording() {
        if useWhisperSTT {
            startWhisperRecording()
        } else {
            startNativeRecording()
        }
    }

    func stopRecording() {
        if useWhisperSTT {
            stopWhisperRecording()
        } else {
            stopNativeRecording()
        }
    }

    // MARK: - Whisper STT 录音

    /// 启动 Apple STT 用于实时显示字幕（不作为最终结果，仅 UI 反馈）
    private func startRealtimePartials() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        // 清理之前的状态
        stopRealtimePartials()
        realtimeLastText = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        realtimePartialRequest = request

        realtimePartialTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result = result else { return }
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                DispatchQueue.main.async {
                    self?.realtimeLastText = text
                    self?.onPartialResult?(text)
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.realtimePartialRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[RealtimePartials] audioEngine 启动失败: \(error)")
        }
    }

    /// 停止实时字幕识别
    private func stopRealtimePartials() {
        realtimePartialTask?.cancel()
        realtimePartialTask = nil
        realtimePartialRequest?.endAudio()
        realtimePartialRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func startWhisperRecording() {
        // 清理之前的状态
        whisperLevelTimer?.invalidate()
        whisperRecorder?.stop()
        whisperRecorder = nil
        whisperHasSound = false
        whisperIsTranscribing = false
        whisperMaxTimer?.cancel()
        whisperMaxTimer = nil
        stopLevelMonitoring()
        stopRealtimePartials()

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("whisper_\(UUID().uuidString).wav")
        whisperFileURL = fileURL

        // 使用 WAV 格式，16kHz 单声道 — Whisper API 兼容性最好
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)

            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true

            // 关键：检查 record() 是否成功
            guard recorder.record() else {
                onError?("录音启动失败")
                onEnd?()
                return
            }
            whisperRecorder = recorder
            onStart?()

            // 启动 Apple STT 实时字幕（边说边出字，Whisper 结果作为最终文本）
            startRealtimePartials()

            // 最大录音超时：15 秒后强制结束并识别
            let maxTimer = DispatchWorkItem { [weak self] in
                guard let self = self, self.whisperRecorder != nil, !self.whisperIsTranscribing else { return }
                self.onPartialResult?("超时，正在识别...")
                self.finishWhisperRecording()
            }
            self.whisperMaxTimer = maxTimer
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: maxTimer)

            // 音量监听 + 静音检测（50ms 间隔，更灵敏更快速）
            var skipInitial = 6  // 跳过前 300ms（TTS 回声消散）
            var silentFrames = 0
            var soundFrames = 0  // 累计有声帧数
            whisperLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, let rec = self.whisperRecorder, rec.isRecording else { return }
                rec.updateMeters()
                let level = rec.averagePower(forChannel: 0)

                // 跳过初始读数（避免 TTS 回声触发）
                if skipInitial > 0 {
                    skipInitial -= 1
                    return
                }

                if level > -45 {
                    // 检测到有声音（阈值 -45dB）
                    if !self.whisperHasSound {
                        self.whisperHasSound = true
                        self.onPartialResult?("正在听...")
                    }
                    soundFrames += 1
                    silentFrames = 0
                } else if self.whisperHasSound && soundFrames >= 4 {
                    // 至少录到 200ms 有效语音后，才开始计算静音
                    silentFrames += 1
                    // 动态静音阈值：短句(< 1s语音)用800ms，长句(>= 1s)用1.2s
                    let silenceThreshold = soundFrames >= 20 ? 24 : 16
                    if silentFrames >= silenceThreshold {
                        maxTimer.cancel()
                        self.onPartialResult?("识别中...")
                        self.finishWhisperRecording()
                    }
                }
            }
        } catch {
            onError?("录音启动失败: \(error.localizedDescription)")
            onEnd?()
        }
    }

    private func stopWhisperRecording() {
        whisperMaxTimer?.cancel()
        whisperMaxTimer = nil
        stopRealtimePartials()
        if !whisperIsTranscribing {
            // 不管有没有检测到声音都尝试识别
            if whisperRecorder != nil {
                finishWhisperRecording()
            } else {
                whisperLevelTimer?.invalidate()
                whisperLevelTimer = nil
                if let url = whisperFileURL { try? FileManager.default.removeItem(at: url) }
                onEnd?()
            }
        }
    }

    private func finishWhisperRecording() {
        guard !whisperIsTranscribing else { return }
        whisperLevelTimer?.invalidate()
        whisperLevelTimer = nil
        whisperMaxTimer?.cancel()
        whisperMaxTimer = nil
        whisperRecorder?.stop()
        whisperRecorder = nil

        // 保存 Apple STT 的实时结果
        let appleSTTText = realtimeLastText.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRealtimePartials()

        let fileURL = whisperFileURL

        // Apple STT 已经有结果 → 直接用，零延迟
        if !appleSTTText.isEmpty {
            onResult?(appleSTTText)
            onEnd?()
            // 清理临时文件
            if let url = fileURL { try? FileManager.default.removeItem(at: url) }
            return
        }

        // Apple STT 没结果 → fallback 到 Whisper API
        whisperIsTranscribing = true

        guard let fileURL = fileURL else {
            whisperIsTranscribing = false
            onEnd?()
            return
        }

        // 通知 JS 正在识别中
        onPartialResult?("识别中...")

        transcribeWithWhisper(fileURL: fileURL) { [weak self] result in
            guard let self = self else { return }
            self.whisperIsTranscribing = false

            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.onResult?(trimmed)
                    }
                case .failure(let error):
                    print("[Whisper] 识别失败: \(error.localizedDescription)")
                    self.onError?("语音识别失败，请重试")
                }
                self.onEnd?()
                // 清理临时文件
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func transcribeWithWhisper(fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: whisperAPIURL) else {
            completion(.failure(NSError(domain: "WhisperSTT", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API URL"])))
            return
        }

        guard let audioData = try? Data(contentsOf: fileURL) else {
            completion(.failure(NSError(domain: "WhisperSTT", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法读取录音文件"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(whisperAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // model 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(whisperModel)\r\n".data(using: .utf8)!)

        // language 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("zh\r\n".data(using: .utf8)!)

        // 音频文件
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // 结束
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "WhisperSTT", code: -3, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                completion(.failure(NSError(domain: "WhisperSTT", code: -4, userInfo: [NSLocalizedDescriptionKey: "解析失败: \(responseStr)"])))
                return
            }
            completion(.success(text))
        }.resume()
    }

    // MARK: - Apple 原生语音识别

    private func startNativeRecording() {
        // Cancel any ongoing task
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        // 重置状态
        lastPartialText = ""
        didFireFinalResult = false
        hasReceivedAudioData = false
        recordingWatchdog?.cancel()

        // 停止音量监听，避免与语音识别冲突
        stopLevelMonitoring()

        // 彻底清理音频引擎状态
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        // 每次开始录音前重新配置音频会话
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 使用 .measurement 模式降低环境噪音敏感度
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
            // 设置输入增益，降低环境噪音影响
            if audioSession.isInputGainSettable {
                try audioSession.setInputGain(0.7) // 降低输入增益
            }
        } catch {
            print("[语音识别] 音频会话配置失败: \(error)")
        }

        startNativeRecordingInternal()
    }

    private func startNativeRecordingInternal(isRetry: Bool = false) {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            onError?("无法创建语音识别请求")
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        recognitionRequest.taskHint = .dictation
        recognitionRequest.contextualStrings = [
            "化妆", "口红", "眼影", "粉底", "腮红", "眉笔", "睫毛膏",
            "遮瑕", "高光", "修容", "定妆", "卸妆", "底妆", "唇彩",
            "唇釉", "眼线", "散粉", "气垫", "妆前乳", "隔离霜",
            "BB霜", "CC霜", "蜜粉", "刷子", "美妆蛋", "卸妆水",
            "小美", "帮我", "教我", "怎么化妆", "完成了", "下一步"
        ]
        if #available(iOS 16, *) {
            recognitionRequest.addsPunctuation = true
        }

        let inputNode = audioEngine.inputNode

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            self.hasReceivedAudioData = true

            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal

                print("[语音识别] 收到结果 - isFinal: \(isFinal), 长度: \(text.count)")

                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.lastPartialText = text

                    // 每次收到新内容，重置强制停止计时器（3秒无新内容则强制停止）
                    DispatchQueue.main.async {
                        self.forceStopTimer?.invalidate()
                        self.forceStopTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                            guard let self = self else { return }
                            print("[语音识别] ⏰ 3秒无新内容，强制停止识别")

                            self.audioEngine.stop()
                            inputNode.removeTap(onBus: 0)
                            self.recognitionRequest = nil
                            self.recognitionTask = nil
                            self.forceStopTimer = nil
                            self.silenceTimer = nil

                            let finalText = self.lastPartialText
                            self.lastPartialText = ""

                            if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.onResult?(finalText)
                            }
                            self.onEnd?()
                        }
                    }
                }

                // 发送部分结果
                DispatchQueue.main.async {
                    self.onPartialResult?(text)
                }

                // 如果是最终结果，立即停止识别
                if isFinal {
                    print("[语音识别] ⚠️ 检测到 isFinal，立即停止")
                    self.didFireFinalResult = true

                    // 立即停止识别，不等待
                    DispatchQueue.main.async {
                        self.silenceTimer?.invalidate()
                        self.silenceTimer = nil
                        self.forceStopTimer?.invalidate()
                        self.forceStopTimer = nil

                        // 停止识别
                        self.audioEngine.stop()
                        inputNode.removeTap(onBus: 0)
                        self.recognitionRequest = nil
                        self.recognitionTask = nil

                        let finalText = self.lastPartialText
                        self.lastPartialText = ""

                        print("[语音识别] 最终文本: \(finalText)")

                        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.onResult?(finalText)
                        }
                        self.onEnd?()
                    }
                    return
                }
            }

            // 只在错误时立即停止
            if let error = error {
                print("[语音识别] ❌ 错误: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = nil
                    self.forceStopTimer?.invalidate()
                    self.forceStopTimer = nil
                }
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil

                let pendingPartial = self.lastPartialText
                self.lastPartialText = ""

                DispatchQueue.main.async {
                    if !pendingPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.onResult?(pendingPartial)
                    }
                    self.onEnd?()
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            onStart?()

            if !isRetry {
                let watchdog = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.hasReceivedAudioData else { return }
                    self.audioEngine.stop()
                    self.audioEngine.inputNode.removeTap(onBus: 0)
                    self.audioEngine.reset()
                    self.recognitionTask?.cancel()
                    self.recognitionTask = nil
                    self.recognitionRequest = nil

                    do {
                        let audioSession = AVAudioSession.sharedInstance()
                        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                        try audioSession.setActive(true)
                    } catch {}

                    self.startNativeRecordingInternal(isRetry: true)
                }
                self.recordingWatchdog = watchdog
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: watchdog)
            }
        } catch {
            if !isRetry {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.reset()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.startNativeRecordingInternal(isRetry: true)
                }
            } else {
                onError?("音频引擎启动失败")
            }
        }
    }

    private func stopNativeRecording() {
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        forceStopTimer?.invalidate()
        forceStopTimer = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let finalText = lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPartialText = ""

        print("[语音识别] 手动停止识别，最终文本: \(finalText)")

        if !finalText.isEmpty {
            DispatchQueue.main.async {
                self.onResult?(finalText)
                self.onEnd?()
            }
        } else {
            DispatchQueue.main.async {
                self.onEnd?()
            }
        }
    }

    // MARK: - Audio Level Monitoring (TTS播放期间检测用户说话，实现语音打断)
    private var levelRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    var onLoudAudioDetected: (() -> Void)?

    func startLevelMonitoring() {
        stopLevelMonitoring()

        let url = URL(fileURLWithPath: "/dev/null")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            levelRecorder = recorder

            // 校准机制：先采样 TTS 回声的音量基线，再检测用户说话
            var calibrationReadings: [Float] = []
            let calibrationCount = 10 // 500ms 校准期
            var baselineLevel: Float = -40 // 默认基线
            var isCalibrated = false
            var consecutiveLoud = 0

            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, let rec = self.levelRecorder else { return }
                rec.updateMeters()
                let level = rec.averagePower(forChannel: 0) // dB: -160 to 0

                if !isCalibrated {
                    // 校准阶段：收集 TTS 回声音量
                    calibrationReadings.append(level)
                    if calibrationReadings.count >= calibrationCount {
                        // 取最大值作为 TTS 回声基线
                        baselineLevel = calibrationReadings.max() ?? -40
                        isCalibrated = true
                    }
                } else {
                    // 检测阶段：用户说话必须比 TTS 回声高 20dB 以上（提高阈值减少误触发）
                    let threshold = baselineLevel + 20
                    // 同时要求绝对值至少 -15dB，必须是明确的人声才触发
                    if level > threshold && level > -15 {
                        consecutiveLoud += 1
                        if consecutiveLoud >= 5 { // 250ms 持续大音量即触发（增加持续时间）
                            self.onLoudAudioDetected?()
                            self.stopLevelMonitoring()
                        }
                    } else {
                        consecutiveLoud = 0
                    }
                }
            }
        } catch {
            // 音量监听启动失败，忽略
        }
    }

    func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        levelRecorder?.stop()
        levelRecorder = nil
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    @Published var userLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var onLocationUpdate: ((Double, Double) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 50
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        locationManager.startUpdatingLocation()
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        userLocation = location
        onLocationUpdate?(location.coordinate.latitude, location.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onError?("定位失败：\(error.localizedDescription)")
    }

    func distanceTo(lat: Double, lng: Double) -> Double? {
        guard let userLocation = userLocation else { return nil }
        let target = CLLocation(latitude: lat, longitude: lng)
        return userLocation.distance(from: target)
    }
}

// MARK: - WebView Container

struct WebViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        if #available(iOS 14.5, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        // Register message handlers for native bridge
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "startVoice")
        contentController.add(context.coordinator, name: "stopVoice")
        contentController.add(context.coordinator, name: "startLevelMonitor")
        contentController.add(context.coordinator, name: "stopLevelMonitor")
        contentController.add(context.coordinator, name: "requestLocation")
        contentController.add(context.coordinator, name: "getDistance")
        contentController.add(context.coordinator, name: "callAI")
        contentController.add(context.coordinator, name: "nativeSpeak")
        contentController.add(context.coordinator, name: "stopSpeak")
        contentController.add(context.coordinator, name: "getVoices")
        contentController.add(context.coordinator, name: "setVoice")
        contentController.add(context.coordinator, name: "setCloudVoice")
        contentController.add(context.coordinator, name: "setUseCloudTTS")
        contentController.add(context.coordinator, name: "getCloudTTSStatus")
        contentController.add(context.coordinator, name: "setVolcVoice")
        contentController.add(context.coordinator, name: "getVolcVoice")
        contentController.add(context.coordinator, name: "setWhisperKey")
        contentController.add(context.coordinator, name: "getWhisperKey")
        contentController.add(context.coordinator, name: "detectFace")
        contentController.add(context.coordinator, name: "startGeminiLive")
        contentController.add(context.coordinator, name: "stopGeminiLive")
        contentController.add(context.coordinator, name: "sendGeminiLiveImage")
        contentController.add(context.coordinator, name: "sendGeminiLiveText")
        contentController.add(context.coordinator, name: "interruptGeminiLive")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        context.coordinator.webView = webView

        // Load local HTML file
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlURL = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            print("Bundle path: \(Bundle.main.bundlePath)")
            print("Bundle resources: \(Bundle.main.paths(forResourcesOfType: "html", inDirectory: nil))")
        }

        // Setup native speech recognition bridge
        context.coordinator.setupAudioSession()
        context.coordinator.setupSpeechBridge()
        context.coordinator.setupLocationBridge()
        context.coordinator.setupTTSBridge()

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let speechManager = SpeechManager()
        let locationManager = LocationManager()
        let aiService = AIService()
        let ttsManager = TTSManager()

        override init() {
            super.init()
            // 设置 AIService 的 TTSManager 引用
            aiService.ttsManager = ttsManager
        }

        // 全局音频会话配置：初始使用 .default 模式（音量大），录音时切换到 .voiceChat（AEC）
        func setupAudioSession() {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try audioSession.setActive(true)
            } catch {
                // 静默处理
            }
        }

        func setupSpeechBridge() {
            speechManager.requestAuthorization { authorized in
                if !authorized {
                    self.callJS("window.nativeSpeechError('语音识别权限未授权，请在设置中开启')")
                }
            }

            speechManager.onStart = { [weak self] in
                self?.callJS("window.nativeSpeechStarted()")
            }

            speechManager.onResult = { [weak self] text in
                let escaped = text.replacingOccurrences(of: "'", with: "\\'")
                self?.callJS("window.nativeSpeechResult('\(escaped)')")
            }

            speechManager.onPartialResult = { [weak self] text in
                let escaped = text.replacingOccurrences(of: "'", with: "\\'")
                self?.callJS("window.nativeSpeechPartial('\(escaped)')")
            }

            speechManager.onEnd = { [weak self] in
                self?.callJS("window.nativeSpeechEnded()")
            }

            speechManager.onError = { [weak self] error in
                let escaped = error.replacingOccurrences(of: "'", with: "\\'")
                self?.callJS("window.nativeSpeechError('\(escaped)')")
            }

            // 语音打断：TTS播放期间检测到用户说话，停止TTS并通知JS
            speechManager.onLoudAudioDetected = { [weak self] in
                self?.ttsManager.stopSpeaking()
                self?.callJS("window.nativeUserInterrupt()")
            }
        }

        func setupLocationBridge() {
            locationManager.requestPermission()

            locationManager.onLocationUpdate = { [weak self] lat, lng in
                self?.callJS("window.nativeLocationUpdate(\(lat), \(lng))")
            }

            locationManager.onError = { [weak self] error in
                let escaped = error.replacingOccurrences(of: "'", with: "\\'")
                self?.callJS("window.nativeLocationError('\(escaped)')")
            }
        }

        func setupTTSBridge() {
            ttsManager.onSpeakStart = { [weak self] in
                self?.callJS("window.nativeTTSStarted()")
            }
            ttsManager.onSpeakEnd = { [weak self] in
                self?.callJS("window.nativeTTSEnded()")
            }
            ttsManager.onCloudTTSError = { [weak self] error in
                let escaped = error.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")
                self?.callJS("window.nativeCloudTTSError && window.nativeCloudTTSError('\(escaped)')")
            }
        }

        func callJS(_ code: String) {
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript(code, completionHandler: nil)
            }
        }

        // WKScriptMessageHandler
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "startVoice":
                speechManager.startRecording()
            case "stopVoice":
                speechManager.stopRecording()
            case "startLevelMonitor":
                speechManager.startLevelMonitoring()
            case "stopLevelMonitor":
                speechManager.stopLevelMonitoring()
            case "requestLocation":
                locationManager.requestPermission()
                locationManager.startUpdating()
            case "getDistance":
                if let body = message.body as? [String: Any],
                   let lat = body["lat"] as? Double,
                   let lng = body["lng"] as? Double,
                   let id = body["id"] as? String {
                    if let distance = locationManager.distanceTo(lat: lat, lng: lng) {
                        let escaped = id.replacingOccurrences(of: "'", with: "\\'")
                        callJS("window.nativeDistanceResult('\(escaped)', \(distance))")
                    }
                }
            case "callAI":
                if let body = message.body as? [String: Any],
                   let messages = body["messages"] as? [[String: Any]] {
                    let callId = body["callId"] as? String ?? ""
                    let temperature = body["temperature"] as? Double ?? 0.8
                    let isCallMode = body["callMode"] as? Bool ?? false
                    var images: [String] = []
                    if let imagesArray = body["images"] as? [String] {
                        images = imagesArray
                    } else if let singleImage = body["image"] as? String, !singleImage.isEmpty {
                        images = [singleImage]
                    }

                    if images.isEmpty {
                        let maxTokens = isCallMode ? 800 : 2000
                        print("🤖 开始流式请求，callId: \(callId), maxTokens: \(maxTokens), isCallMode: \(isCallMode)")
                        aiService.chatStream(messages: messages, maxTokens: maxTokens, onChunk: { [weak self] chunk in
                            let escaped = chunk
                                .replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "'", with: "\\'")
                                .replacingOccurrences(of: "\n", with: "\\n")
                                .replacingOccurrences(of: "\r", with: "")
                            self?.callJS("window.nativeAIChunk('\(escaped)', '\(callId)')")
                        }, completion: { [weak self] result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success(let text):
                                    print("✅ 流式响应完成，callId: \(callId), 总长度: \(text.count)")
                                    let escaped = text
                                        .replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "'", with: "\\'")
                                        .replacingOccurrences(of: "\n", with: "\\n")
                                        .replacingOccurrences(of: "\r", with: "")
                                    self?.callJS("window.nativeAIResponse('\(escaped)', '\(callId)')")
                                case .failure(let error):
                                    print("❌ 流式响应失败，callId: \(callId), 错误: \(error.localizedDescription)")
                                    let escaped = error.localizedDescription
                                        .replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "'", with: "\\'")
                                        .replacingOccurrences(of: "\n", with: "\\n")
                                        .replacingOccurrences(of: "\r", with: "")
                                    self?.callJS("window.nativeAIError('\(escaped)', '\(callId)')")
                                }
                            }
                        })
                    } else {
                        aiService.chat(messages: messages, images: images, temperature: temperature) { [weak self] result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success(let text):
                                    let escaped = text
                                        .replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "'", with: "\\'")
                                        .replacingOccurrences(of: "\n", with: "\\n")
                                        .replacingOccurrences(of: "\r", with: "")
                                    self?.callJS("window.nativeAIResponse('\(escaped)', '\(callId)')")
                                case .failure(let error):
                                    let escaped = error.localizedDescription
                                        .replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "'", with: "\\'")
                                        .replacingOccurrences(of: "\n", with: "\\n")
                                        .replacingOccurrences(of: "\r", with: "")
                                    self?.callJS("window.nativeAIError('\(escaped)', '\(callId)')")
                                }
                            }
                        }
                    }
                }
            case "nativeSpeak":
                if let body = message.body as? [String: Any],
                   let text = body["text"] as? String {
                    let rate = Float(body["rate"] as? Double ?? 0.52)
                    let pitch = Float(body["pitch"] as? Double ?? 1.1)
                    ttsManager.speak(text, rate: rate, pitch: pitch)
                }
            case "stopSpeak":
                ttsManager.stopSpeaking()
            case "getVoices":
                let voices = ttsManager.getChineseVoices()
                if let jsonData = try? JSONSerialization.data(withJSONObject: voices),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    let escaped = jsonStr.replacingOccurrences(of: "'", with: "\\'")
                    callJS("window.nativeVoicesList('\(escaped)')")
                }
            case "setVoice":
                if let voiceId = message.body as? String {
                    ttsManager.setVoice(voiceId)
                    callJS("window.nativeVoiceSet(true)")
                }
            case "setCloudVoice":
                if let voiceId = message.body as? String {
                    ttsManager.setCloudVoice(voiceId)
                    callJS("window.nativeCloudVoiceSet(true)")
                }
            case "setUseCloudTTS":
                if let enabled = message.body as? Bool {
                    ttsManager.setUseCloudTTS(enabled)
                } else if let enabledStr = message.body as? String {
                    ttsManager.setUseCloudTTS(enabledStr == "true")
                }
            case "getCloudTTSStatus":
                let isCloud = ttsManager.getUseCloudTTS()
                let cloudVoice = ttsManager.getCloudVoiceId().replacingOccurrences(of: "'", with: "\\'")
                callJS("window.nativeCloudTTSStatus(\(isCloud), '\(cloudVoice)')")
            case "setVolcVoice":
                if let voiceId = message.body as? String {
                    ttsManager.setVolcVoice(voiceId)
                    callJS("window.nativeVolcVoiceSet(true)")
                }
            case "getVolcVoice":
                let id = ttsManager.getVolcVoiceId().replacingOccurrences(of: "'", with: "\\'")
                callJS("window.nativeVolcVoiceCurrent('\(id)')")
            case "setWhisperKey":
                if let key = message.body as? String {
                    speechManager.whisperAPIKey = key
                    let enabled = speechManager.useWhisperSTT
                    callJS("window.nativeWhisperKeySet(\(enabled))")
                }
            case "getWhisperKey":
                let hasKey = speechManager.useWhisperSTT
                let maskedKey = speechManager.whisperAPIKey.isEmpty ? "" : String(speechManager.whisperAPIKey.prefix(6)) + "****"
                let escaped = maskedKey.replacingOccurrences(of: "'", with: "\\'")
                callJS("window.nativeWhisperKeyStatus(\(hasKey), '\(escaped)')")
            case "detectFace":
                if let body = message.body as? [String: Any],
                   let base64String = body["image"] as? String,
                   let imageData = Data(base64Encoded: base64String),
                   let uiImage = UIImage(data: imageData),
                   let cgImage = uiImage.cgImage {

                    let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
                        guard let results = request.results as? [VNFaceObservation],
                              let face = results.first,
                              let landmarks = face.landmarks else {
                            self?.callJS("window.nativeFaceLandmarks(null)")
                            return
                        }

                        let faceBox = face.boundingBox
                        var result: [String: Any] = [:]

                        // Outer lip bounds → 4 key points (matching MediaPipe indices 13,14,61,291)
                        if let outerLips = landmarks.outerLips {
                            let points = outerLips.normalizedPoints
                            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
                            var minY = CGFloat.infinity, maxY = -CGFloat.infinity

                            for point in points {
                                let imgX = faceBox.origin.x + CGFloat(point.x) * faceBox.width
                                let imgY = 1.0 - (faceBox.origin.y + CGFloat(point.y) * faceBox.height)
                                minX = min(minX, imgX)
                                maxX = max(maxX, imgX)
                                minY = min(minY, imgY)
                                maxY = max(maxY, imgY)
                            }

                            result["lipTop"] = ["x": Double((minX + maxX) / 2), "y": Double(minY)]
                            result["lipBottom"] = ["x": Double((minX + maxX) / 2), "y": Double(maxY)]
                            result["lipLeft"] = ["x": Double(minX), "y": Double((minY + maxY) / 2)]
                            result["lipRight"] = ["x": Double(maxX), "y": Double((minY + maxY) / 2)]
                        }

                        // Left eyebrow bounds
                        if let leftBrow = landmarks.leftEyebrow {
                            let points = leftBrow.normalizedPoints
                            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
                            var minY = CGFloat.infinity, maxY = -CGFloat.infinity
                            for point in points {
                                let imgX = faceBox.origin.x + CGFloat(point.x) * faceBox.width
                                let imgY = 1.0 - (faceBox.origin.y + CGFloat(point.y) * faceBox.height)
                                minX = min(minX, imgX); maxX = max(maxX, imgX)
                                minY = min(minY, imgY); maxY = max(maxY, imgY)
                            }
                            result["leftEyebrow"] = ["x": Double(minX), "y": Double(minY), "w": Double(maxX - minX), "h": Double(maxY - minY)]
                        }

                        // Right eyebrow bounds
                        if let rightBrow = landmarks.rightEyebrow {
                            let points = rightBrow.normalizedPoints
                            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
                            var minY = CGFloat.infinity, maxY = -CGFloat.infinity
                            for point in points {
                                let imgX = faceBox.origin.x + CGFloat(point.x) * faceBox.width
                                let imgY = 1.0 - (faceBox.origin.y + CGFloat(point.y) * faceBox.height)
                                minX = min(minX, imgX); maxX = max(maxX, imgX)
                                minY = min(minY, imgY); maxY = max(maxY, imgY)
                            }
                            result["rightEyebrow"] = ["x": Double(minX), "y": Double(minY), "w": Double(maxX - minX), "h": Double(maxY - minY)]
                        }

                        // Face bounding box (y flipped to top-left origin)
                        result["faceBox"] = [
                            "x": Double(faceBox.origin.x),
                            "y": Double(1.0 - faceBox.origin.y - faceBox.height),
                            "w": Double(faceBox.width),
                            "h": Double(faceBox.height)
                        ]

                        if let jsonData = try? JSONSerialization.data(withJSONObject: result),
                           let jsonStr = String(data: jsonData, encoding: .utf8) {
                            self?.callJS("window.nativeFaceLandmarks(\(jsonStr))")
                        }
                    }

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? handler.perform([request])
                    }
                }

            case "startGeminiLive":
                aiService.onGeminiLiveResponse = { [weak self] text in
                    self?.callJS("window.nativeGeminiLiveResponse('\(text.replacingOccurrences(of: "'", with: "\\'"))')")
                }
                aiService.onGeminiLiveAudio = { [weak self] in
                    self?.callJS("window.nativeGeminiLiveAudio()")
                }
                aiService.startGeminiLive()

            case "stopGeminiLive":
                aiService.stopGeminiLive()

            case "sendGeminiLiveImage":
                if let body = message.body as? [String: Any],
                   let base64Image = body["image"] as? String,
                   let text = body["text"] as? String {
                    aiService.sendImageToGeminiLive(base64Image: base64Image, withText: text)
                }

            case "sendGeminiLiveText":
                if let body = message.body as? [String: Any],
                   let text = body["text"] as? String {
                    aiService.sendTextToGeminiLive(text: text)
                }

            case "interruptGeminiLive":
                aiService.interruptGeminiLive()

            default:
                break
            }
        }

        // Handle camera/mic permission requests from web
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }

        // Handle JavaScript alerts
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        // Handle JavaScript confirms
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        // WebView navigation delegate methods for debugging
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // WebView loaded successfully
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        }
    }
}


// MARK: - Gemini TTS Manager (专用于语音合成)

class GeminiTTSManager: NSObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let apiKey: String
    private let model = "gemini-2.0-flash-exp"

    var onAudioReady: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var onComplete: (() -> Void)?

    private var audioBuffer = Data()
    private var isConnected = false

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func speak(_ text: String) {
        // 每次朗读都重新连接，确保干净的状态
        disconnect()
        audioBuffer = Data()
        connect(text: text)
    }

    func stop() {
        disconnect()
        audioBuffer = Data()
    }

    private func connect(text: String) {
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            onError?("Invalid URL")
            return
        }

        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        // 等待连接建立
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendSetup(text: text)
            self?.receiveMessage()
        }
    }

    private func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    private func sendSetup(text: String) {
        // 专门用于 TTS 的 system instruction
        let systemInstruction = """
        你是一个语音朗读助手。你的唯一任务是：用自然、流畅的中文语音朗读用户发送的文本。

        重要规则：
        1. 不要回答问题，不要对话，不要添加任何额外内容
        2. 只朗读用户发送的原文，一字不差
        3. 用自然的语气和节奏朗读
        4. 保持语调平稳、清晰

        示例：
        用户：你好
        你：（直接朗读"你好"，不要说"你好！有什么可以帮你的？"）

        用户：今天天气真好
        你：（直接朗读"今天天气真好"，不要添加任何评论）
        """

        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "system_instruction": [
                    "parts": [
                        ["text": systemInstruction]
                    ]
                ],
                "generation_config": [
                    "response_modalities": ["AUDIO"],  // 只要音频，不要文本
                    "speech_config": [
                        "voice_config": [
                            "prebuilt_voice_config": [
                                "voice_name": "Puck"  // 使用 Puck 声音（中文女声）
                            ]
                        ]
                    ]
                ]
            ]
        ]

        sendMessage(setup)

        // 发送完 setup 后立即发送要朗读的文本
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.sendText(text)
        }
    }

    private func sendText(_ text: String) {
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
        print("📤 Gemini TTS: 发送文本 \(text.prefix(30))...")
    }

    private func sendMessage(_ message: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { [weak self] error in
            if let error = error {
                self?.onError?("发送失败: \(error.localizedDescription)")
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
                self.receiveMessage()

            case .failure(let error):
                self.onError?("接收失败: \(error.localizedDescription)")
            }
        }
    }

    private func handleResponse(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // 检查是否是 setup 完成的响应
        if json["setupComplete"] is [String: Any] {
            print("✓ Gemini TTS: 连接建立")
            isConnected = true
            return
        }

        // 处理音频数据
        if let serverContent = json["serverContent"] as? [String: Any],
           let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType == "audio/pcm",
                   let base64Audio = inlineData["data"] as? String,
                   let pcmData = Data(base64Encoded: base64Audio) {

                    print("📥 Gemini TTS: 收到音频 \(pcmData.count) bytes")

                    // 将 PCM 转换为 WAV
                    let wavData = createWAVFromPCM(pcmData, sampleRate: 24000, channels: 1, bitsPerSample: 16)

                    DispatchQueue.main.async {
                        self.onAudioReady?(wavData)
                    }
                }
            }

        }

        // 检查是否完成 (turnComplete 在 serverContent 层级)
        if let serverContent = json["serverContent"] as? [String: Any],
           let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
            print("✓ Gemini TTS: 朗读完成")
            DispatchQueue.main.async {
                self.onComplete?()
            }
            disconnect()
        }
    }

    private func createWAVFromPCM(_ pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize

        var header = Data()
        // RIFF header
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        // fmt sub-chunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // sub-chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM format
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        // data sub-chunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        header.append(pcmData)
        return header
    }
}

extension GeminiTTSManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✓ Gemini TTS WebSocket 已连接")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("✓ Gemini TTS WebSocket 已断开")
    }
}

// MARK: - Gemini Live Manager (保留作为备用)

class GeminiLiveManager: NSObject {
    var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let proxyURL: String
    // 当前唯一支持 bidiGenerateContent 的稳定别名（截至 2026-05）
    private let model = "gemini-2.5-flash-native-audio-latest"

    var onTextResponse: ((String) -> Void)?
    var onAudioResponse: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    init(proxyURL: String) {
        self.proxyURL = proxyURL
        super.init()
    }

    func connect() {
        // 走 Mac 代理（ws://host:port/api/live），API key 在代理的 .env 里
        guard let url = URL(string: proxyURL) else {
            onError?(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        sendSetup()
        receiveMessage()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func interrupt() {
        let interruptMessage: [String: Any] = [
            "client_content": [
                "turn_complete": true
            ]
        ]
        sendMessage(interruptMessage)
    }

    private func sendSetup() {
        let systemInstruction = """
        你是"小美"，一个专业又亲切的AI美妆助手。你正在和用户进行实时语音通话。

        【对话风格 - 极其重要！】
        - 用自然的口语表达，像朋友聊天一样轻松随意
        - 回复要简短（1-2句话），不要长篇大论
        - 多用语气词："嗯"、"哦"、"呀"、"啦"、"呢"、"~"
        - 避免书面语，用口语化表达：
          ✓ "你可以试试这个"（不说"您可以尝试"）
          ✓ "挺好看的呀"（不说"效果很不错"）
          ✓ "对对对"（不说"是的，您说得对"）
        - 表达要有情感和共鸣：
          ✓ "哇，你皮肤真好！"
          ✓ "嗯嗯，我懂你的意思"
          ✓ "这个颜色超适合你的！"

        【回复原则】
        - 每次只说1-2句话，让对话自然流畅
        - 不要一次性说太多，给用户回应的机会
        - 听到用户说话后，先简短回应表示理解，再给建议
        - 避免机械式的"好的，我来帮你..."开头

        【示例对话】
        用户："我想化个淡妆"
        你："嗯嗯，淡妆很适合日常！你想要自然一点的还是稍微精致一些的？"

        用户："自然一点"
        你："好的！那我们就简单几步，先涂个防晒和粉底就行~"

        用户："好"
        你："嗯，开始吧！先把脸洗干净，然后涂防晒霜~"

        记住：你是在和朋友聊天，不是在做客服！要自然、亲切、有人情味！
        """

        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "system_instruction": [
                    "parts": [
                        ["text": systemInstruction]
                    ]
                ],
                "generation_config": [
                    // native-audio 模型只支持 AUDIO 输出（无 TEXT）
                    "response_modalities": ["AUDIO"],
                    "speech_config": [
                        "voice_config": [
                            "prebuilt_voice_config": [
                                "voice_name": "Puck"
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

    func sendAudio(_ base64Audio: String) {
        let message: [String: Any] = [
            "client_content": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            [
                                "inline_data": [
                                    "mime_type": "audio/pcm",
                                    "data": base64Audio
                                ]
                            ]
                        ]
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

        if let serverContent = json["serverContent"] as? [String: Any],
           let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                if let text = part["text"] as? String {
                    DispatchQueue.main.async {
                        self.onTextResponse?(text)
                    }
                }

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

#Preview {
    ContentView()
}
