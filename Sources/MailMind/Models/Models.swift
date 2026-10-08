import Foundation
import SwiftUI

/// 一个 IMAP 邮箱账户。密码 / 授权码不在这里，保存在钥匙串中。
struct MailAccount: Identifiable, Codable, Hashable {
    var id = UUID()
    var displayName: String
    var email: String
    var username: String
    var host: String
    var port: Int = 993
    var useTLS = true
    var enabled = true
    var folders: [String] = ["INBOX"]
    /// OAuth 登录的服务商（例如 "microsoft"）；为 nil 表示用密码 / 授权码登录。
    var oauthProvider: String?
    /// 从「邮件」App 本地读取时，收件箱目录的路径；为 nil 表示通过 IMAP 连接。
    var appleMailInbox: String?

    var isAppleMail: Bool { appleMailInbox != nil }
}

/// 转发来源：例如 Outlook 邮件自动转发到某个已接入的邮箱，
/// 按原收件人地址把这些邮件单独归为一个视图。
struct ForwardAlias: Identifiable, Codable, Hashable {
    var address: String
    var name: String
    var id: String { address.lowercased() }
}

/// AI 给出的邮件分类。rawValue 直接用中文，便于提示词和数据库共用。
enum MailCategory: String, CaseIterable, Codable, Identifiable {
    case important = "重要"
    case work = "工作"
    case personal = "个人"
    case finance = "账单"
    case notification = "通知"
    case marketing = "营销"
    case social = "社交"
    case spam = "垃圾"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .important: return "exclamationmark.circle"
        case .work: return "briefcase"
        case .personal: return "person"
        case .finance: return "creditcard"
        case .notification: return "bell"
        case .marketing: return "megaphone"
        case .social: return "bubble.left.and.bubble.right"
        case .spam: return "xmark.bin"
        }
    }

    var color: Color {
        switch self {
        case .important: return .red
        case .work: return .blue
        case .personal: return .green
        case .finance: return .orange
        case .notification: return .gray
        case .marketing: return .purple
        case .social: return .pink
        case .spam: return .brown
        }
    }
}

enum Importance: String, Codable, CaseIterable {
    case high, normal, low

    var label: String {
        switch self {
        case .high: return "重点"
        case .normal: return "普通"
        case .low: return "次要"
        }
    }
}

enum AIStatus: Int {
    case pending = 0
    case done = 1
    case failed = 2
}

struct MailMessage: Identifiable, Hashable {
    var id: String
    var accountID: UUID
    var folder: String
    var uid: UInt32
    var messageID = ""
    var fromName = ""
    var fromEmail = ""
    var to = ""
    var subject = ""
    var date = Date()
    var snippet = ""
    /// 列表查询不加载正文，详情页再按需读取。
    var bodyText = ""
    var bodyHTML = ""
    var attachments: [String] = []
    var listUnsubscribe = ""
    var isRead = false

    var aiStatus: AIStatus = .pending
    var category = ""
    var importance: Importance?
    var summary = ""
    var translation = ""
    var action = ""
    var reason = ""
    var language = ""
    var aiError = ""
    var notified = false
    /// 一句话通知标题：「谁 + 要你做什么 + 截止时间」。
    var headline = ""
    /// AI 建议的提醒级别：urgent / normal / none。
    var notifyLevel = ""
    /// 截止日期（YYYY-MM-DD），没有为空。
    var deadline = ""
    /// 验证码，没有为空。
    var code = ""

    var sender: String { fromName.isEmpty ? fromEmail : fromName }
    var mailCategory: MailCategory? { MailCategory(rawValue: category) }
    var senderKey: String { fromEmail.lowercased() }

    var deadlineDate: Date? {
        guard !deadline.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: deadline)
    }
}

/// 按发件人的规则：固定分类、VIP、静音。
struct SenderRule: Identifiable, Hashable {
    var email: String
    var category = ""
    var vip = false
    var muted = false
    var id: String { email }
}

/// 账户运行时状态（不持久化）。
struct AccountStatus: Equatable {
    var lastSync: Date?
    var error: String?
    var realtime = false
    var syncing = false
}

struct Digest: Identifiable, Hashable {
    var id: Int64
    var createdAt: Date
    var periodStart: Date
    var periodEnd: Date
    var messageCount: Int
    var content: String
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - 规则

/// 规则命中后的提醒方式。
enum RuleNotify: String, Codable, CaseIterable, Identifiable {
    /// 交给 AI 和通知策略判断
    case auto
    /// 总是响铃（VIP）
    case always
    /// 永不提醒
    case never

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "按 AI 判断"
        case .always: return "总是提醒"
        case .never: return "不提醒"
        }
    }
}

/// 用户的分类 / 提醒规则。可针对所有邮箱，也可只针对某一个邮箱。
struct MailRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    /// 只对这个邮箱生效；nil 表示所有邮箱
    var accountID: UUID?
    /// 发件人：完整地址（a@b.com）或域名（@b.com）；为空表示不限
    var sender = ""
    /// 主题或正文包含任意一个关键词（用逗号、顿号或空格分隔）；为空表示不限
    var keywords = ""
    /// 归为此分类；为空表示不改分类
    var category = ""
    var notify: RuleNotify = .auto
    /// 验证码邮件不受此规则影响（仍正常分类和提醒）
    var exceptCodes = false
    var createdAt = Date()

    var keywordList: [String] {
        keywords.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；\n "))
            .map(\.trimmed)
            .filter { !$0.isEmpty }
    }

    var isValid: Bool {
        !(sender.trimmed.isEmpty && keywordList.isEmpty) && !(category.isEmpty && notify == .auto)
    }

    /// 是否匹配。text 为主题之外用于关键词匹配的内容（正文或摘要）。
    func matches(_ m: MailMessage, text: String? = nil) -> Bool {
        guard enabled, isValid else { return false }
        if let accountID, accountID != m.accountID { return false }
        let s = sender.trimmed.lowercased()
        if !s.isEmpty {
            let from = m.fromEmail.lowercased()
            if s.hasPrefix("@") {
                let domain = String(s.dropFirst())
                guard let at = from.lastIndex(of: "@") else { return false }
                let fromDomain = String(from[from.index(after: at)...])
                // @example.com 同时匹配子域名 mail.example.com
                guard fromDomain == domain || fromDomain.hasSuffix("." + domain) else { return false }
            } else if s != from {
                return false
            }
        }
        let words = keywordList
        if !words.isEmpty {
            let haystack = (m.subject + "\n" + (text ?? (m.snippet + "\n" + m.summary))).lowercased()
            guard words.contains(where: { haystack.contains($0) }) else { return false }
        }
        return true
    }

    /// 越具体的规则优先：指定邮箱 > 完整地址 > 域名，带关键词的更优先。
    var specificity: Int {
        var n = 0
        if accountID != nil { n += 4 }
        let s = sender.trimmed
        if !s.isEmpty { n += s.hasPrefix("@") ? 1 : 2 }
        if !keywordList.isEmpty { n += 2 }
        return n
    }

    /// 返回命中的最具体的规则（相同时取最新创建的）。
    static func firstMatch(_ rules: [MailRule], for m: MailMessage, text: String? = nil) -> MailRule? {
        rules.filter { $0.matches(m, text: text) }
            .max { ($0.specificity, $0.createdAt) < ($1.specificity, $1.createdAt) }
    }

    /// 人类可读的条件描述。
    var conditionText: String {
        var parts: [String] = []
        let s = sender.trimmed
        if !s.isEmpty { parts.append(s.hasPrefix("@") ? "来自 \(s) 域名" : "来自 \(s)") }
        if !keywordList.isEmpty { parts.append("包含「\(keywordList.joined(separator: "」或「"))」") }
        return parts.joined(separator: "，且")
    }

    var actionText: String {
        var parts: [String] = []
        if !category.isEmpty { parts.append("归为\(category)") }
        if notify != .auto { parts.append(notify.label) }
        return parts.joined(separator: "，")
    }
}

/// 用户手动纠正过的分类，作为示例交给 AI 学习。
struct ClassificationExample: Identifiable, Hashable {
    var id: Int64
    var accountID: UUID?
    var fromEmail: String
    var subject: String
    var category: String
    var createdAt: Date

    /// 写进提示词的一行
    var promptLine: String { "发件人 \(fromEmail) ｜ 主题「\(subject.prefix(60))」 → \(category)" }
}

// MARK: - 转发

/// 把重要邮件转发到 Telegram、微信（经 OpenClaw）或任意 Webhook。
struct ForwardChannel: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case telegram, openclaw, webhook
        var id: String { rawValue }
        var label: String {
            switch self {
            case .telegram: return "Telegram"
            case .openclaw: return "微信（OpenClaw）"
            case .webhook: return "Webhook"
            }
        }
        var symbol: String {
            switch self {
            case .telegram: return "paperplane.fill"
            case .openclaw: return "message.fill"
            case .webhook: return "link"
            }
        }
        var colorHex: UInt32 {
            switch self {
            case .telegram: return 0x229ED9
            case .openclaw: return 0x07C160
            case .webhook: return 0x6E6E73
            }
        }
    }

    /// 哪些邮件需要转发
    enum Trigger: String, Codable, CaseIterable, Identifiable {
        /// 会响铃提醒的：紧急邮件、VIP、验证码
        case urgent
        /// 所有会提醒的（含静默提醒）
        case important
        var id: String { rawValue }
        var label: String { self == .urgent ? "仅紧急邮件" : "所有重要邮件" }
        var detail: String {
            self == .urgent
                ? "需要尽快处理的邮件、设为「总是提醒」的发件人、验证码"
                : "以上之外，还包括重要但不紧急的邮件"
        }
    }

    /// Webhook 的请求格式
    enum WebhookFormat: String, Codable, CaseIterable, Identifiable {
        case json, wecom, feishu, dingtalk
        var id: String { rawValue }
        var label: String {
            switch self {
            case .json: return "通用 JSON"
            case .wecom: return "企业微信群机器人"
            case .feishu: return "飞书群机器人"
            case .dingtalk: return "钉钉群机器人"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var name: String
    var enabled = true
    var trigger: Trigger = .urgent
    /// 只转发这些邮箱的邮件；为空表示所有邮箱
    var accountIDs: [UUID] = []
    var includeCodes = true

    /// Telegram：接收消息的 chat id
    var chatID = ""
    /// OpenClaw / Webhook 地址
    var url = ""
    /// OpenClaw：投递频道（如 openclaw-weixin、telegram）与接收人
    var channel = "openclaw-weixin"
    var to = ""
    var agentID = ""
    var webhookFormat: WebhookFormat = .json

    /// 令牌保存在钥匙串中的键
    var secretKey: String { "forward:\(id.uuidString)" }

    static func new(_ kind: Kind) -> ForwardChannel {
        var c = ForwardChannel(kind: kind, name: kind == .openclaw ? "微信" : kind.label)
        if kind == .openclaw { c.url = "http://127.0.0.1:18789/hooks/agent" }
        return c
    }

    func accepts(_ m: MailMessage) -> Bool {
        guard enabled else { return false }
        if !accountIDs.isEmpty && !accountIDs.contains(m.accountID) { return false }
        if !includeCodes && !m.code.isEmpty { return false }
        return true
    }
}
