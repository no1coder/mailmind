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
}

/// OpenAI 兼容的 Chat Completions 客户端。
/// 适用于 DeepSeek、通义千问、Kimi、OpenRouter、Ollama、LM Studio 等。
struct AIClient: Sendable {
    var baseURL: String
    var model: String
    var apiKey: String

    func chat(system: String, user: String) async throws -> String {
        guard let base = URL(string: baseURL.trimmed), base.scheme != nil else { throw AIError.invalidURL }
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("MailMind", forHTTPHeaderField: "X-Title")
        // 不传 temperature / max_tokens：部分新模型只接受默认值，省略兼容性最好。
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError.http(status, message)
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return Self.stripThinking(content)
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
