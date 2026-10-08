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
