import AppKit
import Foundation
import UserNotifications

/// 系统通知。只有打包成 .app 运行时才可用（`swift run` 没有 bundle identifier）。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let mailCategory = "MAIL"
    private static let codeCategory = "MAIL_CODE"
    private static let markReadAction = "MARK_READ"
    private static let copyCodeAction = "COPY_CODE"

    /// 用户点击通知时回调，参数为邮件 id；汇总通知为 "digest"，合并通知为 "important"。
    var onOpen: ((String) -> Void)?
    /// 用户点击「标为已读」。
    var onMarkRead: (([String]) -> Void)?

    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let markRead = UNNotificationAction(identifier: Self.markReadAction, title: "标为已读")
        let copyCode = UNNotificationAction(identifier: Self.copyCodeAction, title: "复制验证码")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.mailCategory, actions: [markRead], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.codeCategory, actions: [copyCode, markRead], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 单封邮件通知：标题是 AI 的一句话总结，副标题是发件人与主题。
    func notify(_ m: MailMessage, decision: NotifyDecision, accountName: String?) {
        let content = UNMutableNotificationContent()
        content.title = m.headline.isEmpty ? "\(m.sender)：\(m.subject)" : m.headline
        content.subtitle = [m.sender, accountName].compactMap { $0 }.joined(separator: " · ")
        var body = m.subject
        if !m.action.isEmpty { body += "\n👉 \(m.action)" }
        content.body = body
        content.threadIdentifier = m.accountID.uuidString
        content.userInfo = ["messageID": m.id, "ids": [m.id], "code": m.code]
        content.categoryIdentifier = m.code.isEmpty ? Self.mailCategory : Self.codeCategory
        if decision == .alert {
            content.sound = .default
            content.interruptionLevel = .active
        } else {
            content.interruptionLevel = .passive
        }
        post(id: m.id, content)
    }

    /// 一次来了多封时合并成一条，避免通知轰炸。
    func notifyBatch(_ list: [MailMessage], withSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "\(list.count) 封新的重要邮件"
        content.body = list.prefix(4).map { "• " + ($0.headline.isEmpty ? "\($0.sender)：\($0.subject)" : $0.headline) }
            .joined(separator: "\n") + (list.count > 4 ? "\n…" : "")
        content.userInfo = ["messageID": "important", "ids": list.map(\.id)]
        content.categoryIdentifier = Self.mailCategory
        content.interruptionLevel = withSound ? .active : .passive
        if withSound { content.sound = .default }
        post(id: "batch-\(Date().timeIntervalSince1970)", content)
    }

    func notifyDigest(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "邮件汇总已生成"
        content.body = "共整理 \(count) 封非重点邮件，点击查看。"
        content.userInfo = ["messageID": "digest"]
        content.interruptionLevel = .passive
        post(id: "digest-\(Date().timeIntervalSince1970)", content)
    }

    func notifyTest() {
        let content = UNMutableNotificationContent()
        content.title = "王经理：周五前确认 Q4 预算表"
        content.subtitle = "王经理 · 工作邮箱"
        content.body = "Q4 预算调整\n👉 回复确认或提出修改意见"
        content.sound = .default
        content.categoryIdentifier = Self.mailCategory
        post(id: "test", content)
    }

    private func post(id: String, _ content: UNMutableNotificationContent) {
        guard isAvailable else {
            print("[通知] \(content.title) — \(content.subtitle) \(content.body)")
            return
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let ids = info["ids"] as? [String] ?? []
        switch response.actionIdentifier {
        case Self.copyCodeAction:
            if let code = info["code"] as? String, !code.isEmpty {
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            }
        case Self.markReadAction:
            let handler = onMarkRead
            DispatchQueue.main.async { handler?(ids) }
        default:
            if let id = info["messageID"] as? String {
                let handler = onOpen
                DispatchQueue.main.async { handler?(id) }
            }
        }
        completionHandler()
    }
}
