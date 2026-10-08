import Foundation

enum NotifyDecision: Equatable {
    /// 横幅 + 声音
    case alert
    /// 静默送达通知中心，不响铃
    case silent
    case none
}

/// 决定一封邮件是否通知、以什么方式通知。纯函数，便于测试。
///
/// 规则（按优先级）：
/// 1. 总开关关闭、已读（在其他设备上看过）、超过 24 小时、垃圾邮件 → 不通知
/// 2. 命中规则「不提醒」→ 不通知；「总是提醒」→ 响铃（勿扰时段也响）。
///    规则勾选了「验证码除外」时，验证码邮件不受规则影响
/// 3. 15 分钟内的验证码 → 响铃（用户正在等它，勿扰时段也响）
/// 4. AI 判定 urgent → 响铃；勿扰时段降级为静默
/// 5. AI 判定 normal，或重要性为 high → 静默
/// 6. 其他 → 不通知，留给定期汇总
struct NotificationPolicy {
    var enabled = true
    var quietHoursEnabled = false
    /// 一天中的分钟数，例如 22:00 = 1320
    var quietStart = 22 * 60
    var quietEnd = 8 * 60
    var rules: [MailRule] = []
    var maxAge: TimeInterval = 24 * 3600

    func decide(_ m: MailMessage, now: Date = Date()) -> NotifyDecision {
        guard enabled, !m.isRead else { return .none }
        let age = now.timeIntervalSince(m.date)
        guard age < maxAge else { return .none }
        if m.category == MailCategory.spam.rawValue { return .none }

        if let rule = MailRule.firstMatch(rules, for: m), !(rule.exceptCodes && !m.code.isEmpty) {
            switch rule.notify {
            case .never: return .none
            case .always: return .alert
            case .auto: break
            }
        }
        if !m.code.isEmpty { return age < 15 * 60 ? .alert : .none }

        switch NotifyLevel(rawValue: m.notifyLevel) {
        case .urgent:
            return isQuietTime(now) ? .silent : .alert
        case .normal:
            return .silent
        default:
            return m.importance == .high ? .silent : .none
        }
    }

    func isQuietTime(_ date: Date) -> Bool {
        guard quietHoursEnabled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if quietStart == quietEnd { return false }
        return quietStart < quietEnd
            ? (minute >= quietStart && minute < quietEnd)
            : (minute >= quietStart || minute < quietEnd)
    }
}
