import Foundation

enum AIError: LocalizedError {
    case notConfigured
    case invalidURL
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置 AI 服务"
        case .invalidURL: return "AI 接口地址无效"
        case .http(let code, let msg): return "AI 接口错误 \(code)：\(msg)"
        case .badResponse(let s): return "AI 返回内容无法解析：\(s)"
        }
    }

    var isRateLimited: Bool {
        if case .http(429, _) = self { return true }
        return false
    }
}

/// 记住哪些「接口地址 + 模型」不支持 response_format，避免每次都先失败一次。
actor JSONModeSupport {
    static let shared = JSONModeSupport()
    private var unsupported: Set<String> = []

    func isUnsupported(_ key: String) -> Bool { unsupported.contains(key) }
    func markUnsupported(_ key: String) { unsupported.insert(key) }
}

/// OpenAI 兼容的 Chat Completions 客户端。
/// 适用于 DeepSeek、通义千问、Kimi、OpenRouter、Ollama、LM Studio 等。
struct AIClient: Sendable {
    var baseURL: String
    var model: String
    var apiKey: String

    static let maxAttempts = 3

    /// 发送一次对话。限流（429）、服务端错误和网络超时会自动退避重试。
    /// `json` 为 true 时请求 JSON 模式；服务商不支持该参数（返回 400）时自动去掉重试，并记住这个模型。
    func chat(system: String, user: String, json: Bool = false) async throws -> String {
        guard let base = URL(string: baseURL.trimmed), base.scheme != nil else { throw AIError.invalidURL }
        let key = "\(baseURL.trimmed)|\(model)"
        var useJSON = json
        if json, await JSONModeSupport.shared.isUnsupported(key) { useJSON = false }

        var attempt = 1
        while true {
            do {
                return try await send(base: base, system: system, user: user, json: useJSON)
            } catch AIError.http(400, _) where useJSON {
                await JSONModeSupport.shared.markUnsupported(key)
                useJSON = false
            } catch let error as RetryableError {
                guard attempt < Self.maxAttempts else { throw error.underlying }
                try await Task.sleep(nanoseconds: UInt64(Self.backoff(attempt: attempt, retryAfter: error.retryAfter) * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func send(base: URL, system: String, user: String, json: Bool) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("MailMind", forHTTPHeaderField: "X-Title")
        // 不传 temperature / max_tokens：部分新模型只接受默认值，省略兼容性最好。
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where Self.retryableURLErrors.contains(error.code) {
            throw RetryableError(underlying: error, retryAfter: nil)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            let error = AIError.http(status, message)
            if Self.retryableStatus.contains(status) {
                let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                throw RetryableError(underlying: error, retryAfter: retryAfter)
            }
            throw error
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return Self.stripThinking(content)
    }

    static let retryableStatus: Set<Int> = [408, 429, 500, 502, 503, 504, 529]
    static let retryableURLErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet]

    /// 第 n 次失败后的等待秒数：优先遵守 Retry-After（最多 60 秒），否则 2、4、8… 秒加随机抖动。
    static func backoff(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, 60) }
        return pow(2, Double(attempt)) + Double.random(in: 0...1)
    }

    private struct RetryableError: Error {
        var underlying: Error
        var retryAfter: TimeInterval?
    }

    /// 获取可用模型列表（OpenAI 兼容的 GET /models）。
    func listModels() async throws -> [String] {
        guard let base = URL(string: baseURL.trimmed), base.scheme != nil else { throw AIError.invalidURL }
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 20)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError.http(status, message)
        }
        return Self.parseModels(json)
    }

    /// 兼容 {"data":[{"id":…}]}（OpenAI 规范）与 {"models":[{"name":…}]} 两种格式。
    static func parseModels(_ json: [String: Any]?) -> [String] {
        let list = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        let ids = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 去掉推理模型（如 deepseek-r1、qwen3）输出中的 <think>…</think>。
    static func stripThinking(_ s: String) -> String {
        guard let end = s.range(of: "</think>") else { return s.trimmed }
        return String(s[end.upperBound...]).trimmed
    }
}
