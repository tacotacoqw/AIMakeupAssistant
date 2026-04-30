import Foundation

// 简单测试 Gemini API
let apiKey = "AIzaSyAbBeRmDER_9sFhUvLYy1P5WsYj8QOE6yw"
let model = "gemini-2.5-flash"

let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
guard let url = URL(string: urlString) else {
    print("❌ URL 无效")
    exit(1)
}

let body: [String: Any] = [
    "contents": [
        [
            "role": "user",
            "parts": [["text": "你好，请回复'测试成功'"]]
        ]
    ]
]

guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
    print("❌ JSON 序列化失败")
    exit(1)
}

var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = jsonData

print("🔵 发送请求到 Gemini API...")

let semaphore = DispatchSemaphore(value: 0)

URLSession.shared.dataTask(with: request) { data, response, error in
    defer { semaphore.signal() }

    if let error = error {
        print("❌ 网络错误: \(error.localizedDescription)")
        return
    }

    guard let data = data else {
        print("❌ 没有收到数据")
        return
    }

    if let responseString = String(data: data, encoding: .utf8) {
        print("✅ 收到响应:")
        print(responseString)
    }
}.resume()

semaphore.wait()
print("\n测试完成")
