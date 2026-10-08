import Foundation
import Network

/// 把技术性的连接错误翻译成普通用户看得懂的话。
enum FriendlyError {
    struct Message: Equatable {
        var title: String
        var detail: String
        /// 服务器原始返回，供高级用户排查
        var raw: String = ""
    }

    static func connection(_ error: Error, passwordLabel: String = "密码") -> Message {
        switch error {
        case IMAPError.loginFailed(let raw):
            let lower = raw.lowercased()
            if lower.contains("unsafe login") {
                return Message(title: "被邮箱安全策略拦截了",
                               detail: "请先在网页版开启 IMAP 服务，并使用授权码登录（不是登录密码）。",
                               raw: raw)
            }
            if lower.contains("frequency") || lower.contains("too many") || lower.contains("limit") {
                return Message(title: "登录太频繁，被暂时限制了",
                               detail: "请等几分钟再试。如果仍然失败，请确认已开启 IMAP 并使用\(passwordLabel)。",
                               raw: raw)
            }
            return Message(title: "\(passwordLabel)不正确，或者还没有开启 IMAP",
                           detail: "请按照左侧步骤在网页版开启 IMAP 服务，并确认粘贴的是\(passwordLabel)，而不是平时的登录密码。",
                           raw: raw)
        case IMAPError.timeout:
            return Message(title: "连接超时",
                           detail: "邮箱服务器长时间没有响应。请检查网络；如果开着代理或 VPN，可以试试关掉后重试。")
        case IMAPError.badGreeting(let raw), IMAPError.commandFailed(let raw):
            return Message(title: "邮箱服务器拒绝了连接",
                           detail: "可能是服务器地址不对，或服务暂时不可用，请稍后再试。",
                           raw: raw)
        case IMAPError.closed:
            return Message(title: "连接被服务器断开",
                           detail: "请稍后再试。如果一直这样，请确认已在网页版开启 IMAP 服务。")
        case is NWError, is URLError:
            return Message(title: "连不上邮箱服务器",
                           detail: "请检查网络连接，以及服务器地址是否正确。如果开着代理或 VPN，可以试试关掉。",
                           raw: error.localizedDescription)
        default:
            return Message(title: "连接失败", detail: error.localizedDescription)
        }
    }

    static func oauth(_ error: Error) -> Message {
        switch error {
        case OAuthError.notConfigured:
            return Message(title: "还没有配置微软应用 ID", detail: "请先填写应用 ID。")
        case OAuthError.reauthRequired:
            return Message(title: "授权已过期", detail: "请重新用微软账号登录。")
        case OAuthError.token(let raw):
            if raw.contains("AADSTS50020") || raw.contains("AADSTS65001") || raw.lowercased().contains("admin") {
                return Message(title: "需要公司管理员同意授权", detail: "你的公司邮箱限制了第三方应用，请联系 IT 管理员允许 MailMind 访问。", raw: raw)
            }
            if raw.contains("AADSTS700016") {
                return Message(title: "微软应用 ID 不正确", detail: "请检查应用 ID 是否复制完整，以及应用是否支持个人微软账户。", raw: raw)
            }
            return Message(title: "微软登录失败", detail: "请重试；如果一直失败，请检查网络。", raw: raw)
        case IMAPError.loginFailed(let raw):
            return Message(title: "授权成功，但邮箱拒绝了 IMAP 登录",
                           detail: "请到 outlook.live.com →「设置」→「邮件」→「转发和 IMAP」中确认已开启 IMAP；公司邮箱需管理员允许 IMAP。",
                           raw: raw)
        default:
            return connection(error)
        }
    }

    /// 补全邮箱地址：只输入「12345」时自动加上服务商默认后缀。
    static func completeEmail(_ input: String, domain: String?) -> String {
        let t = input.trimmed.replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return "" }
        if t.contains("@") { return t.hasSuffix("@") ? t + (domain ?? "") : t }
        guard let domain else { return t }
        return "\(t)@\(domain)"
    }

    /// 授权码 / 应用专用密码中的空格是复制时带进来的，去掉；普通密码只去掉首尾空白。
    static func cleanPassword(_ input: String, label: String) -> String {
        label == "密码" ? input.trimmingCharacters(in: .newlines) : input.replacingOccurrences(of: " ", with: "").trimmed
    }
}
