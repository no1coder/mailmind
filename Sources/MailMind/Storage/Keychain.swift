import Foundation
import Security

/// 邮箱密码和 AI API Key 都保存在 macOS 钥匙串中，不写入配置文件。
enum Keychain {
    private static let service = "app.mailmind.MailMind"

    /// 截图模式下禁用，避免未签名的开发版本访问钥匙串时弹出授权框。
    nonisolated(unsafe) static var disabled = false

    static let aiKey = "ai-api-key"
    static func accountKey(_ id: UUID) -> String { "imap:\(id.uuidString)" }

    static func set(_ value: String, for key: String) {
        guard !disabled else { return }
        delete(key)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        guard !disabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        guard !disabled else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
