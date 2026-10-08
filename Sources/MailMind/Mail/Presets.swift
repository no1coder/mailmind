import Foundation
import SwiftUI

/// 邮箱服务商：服务器配置 + 面向普通用户的图文引导。
struct MailProviderPreset: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var host: String
    var port: Int = 993
    /// 一句话提示（高级模式 / 自动识别时显示）
    var hint: String
    /// 获取授权码 / 应用专用密码的页面
    var helpURL: String? = nil

    // 引导界面
    /// 图标上的文字，为空时使用 symbol
    var badge = ""
    var symbol = "envelope.fill"
    var colorHex: UInt32 = 0x8E8E93
    /// 该服务商的邮箱后缀，用于自动补全和识别（第一个为默认后缀）
    var domains: [String] = []
    /// 密码输入框的叫法：授权码 / 应用专用密码 / 密码
    var passwordLabel = "密码"
    /// 一句话解释这个密码是什么
    var passwordExplain = ""
    /// 开启 IMAP、获取授权码的步骤（大白话）
    var steps: [String] = []
    var helpButtonTitle = "打开网页版设置"
    /// 目前能否用密码方式连接
    var supported = true
    var note = ""
    /// 使用 OAuth 登录的服务商标识（例如 "microsoft"）
    var oauth: String? = nil
    /// 通过 Mac 自带「邮件」App 的本地数据接入
    var appleMail = false

    var color: Color { Color(hex: colorHex) }
    var isCustom: Bool { host.isEmpty && !appleMail }
}

enum MailProviderPresets {
    private static let authCodeExplain = "授权码是邮箱专门给第三方软件用的一串密码，不是你的登录密码。用它登录更安全，随时可以在网页版里作废。"

    static let all: [MailProviderPreset] = [
        .init(name: "QQ 邮箱", host: "imap.qq.com",
              hint: "网页版 设置 → 账号 → 开启 IMAP/SMTP 服务，生成授权码，用授权码代替密码。",
              helpURL: "https://mail.qq.com",
              badge: "QQ", colorHex: 0x12B7F5, domains: ["qq.com", "foxmail.com", "vip.qq.com"],
              passwordLabel: "授权码", passwordExplain: authCodeExplain,
              steps: [
                  "点击下方按钮，在浏览器中登录 QQ 邮箱网页版",
                  "点击页面上方的「设置」，进入「账号」（新版叫「账号与安全」）",
                  "找到「IMAP/SMTP 服务」，点击「开启」，按提示用手机发送短信验证",
                  "页面会显示一串 16 位字母，这就是授权码，复制后粘贴到右边",
              ]),
        .init(name: "163 邮箱", host: "imap.163.com",
              hint: "网页版 设置 → POP3/SMTP/IMAP → 开启 IMAP，使用授权码登录。",
              helpURL: "https://mail.163.com",
              badge: "163", colorHex: 0xD7000F, domains: ["163.com"],
              passwordLabel: "授权码", passwordExplain: authCodeExplain,
              steps: [
                  "点击下方按钮，在浏览器中登录 163 邮箱网页版",
                  "点击页面上方的「设置」，选择「POP3/SMTP/IMAP」",
                  "开启「IMAP/SMTP 服务」，按提示完成手机验证",
                  "页面会显示授权码（只显示一次），复制后粘贴到右边",
              ]),
        .init(name: "126 邮箱", host: "imap.126.com",
              hint: "网页版 设置 → POP3/SMTP/IMAP → 开启 IMAP，使用授权码登录。",
              helpURL: "https://mail.126.com",
              badge: "126", colorHex: 0x1AAD19, domains: ["126.com"],
              passwordLabel: "授权码", passwordExplain: authCodeExplain,
              steps: [
                  "点击下方按钮，在浏览器中登录 126 邮箱网页版",
                  "点击页面上方的「设置」，选择「POP3/SMTP/IMAP」",
                  "开启「IMAP/SMTP 服务」，按提示完成手机验证",
                  "页面会显示授权码（只显示一次），复制后粘贴到右边",
              ]),
        .init(name: "腾讯企业邮", host: "imap.exmail.qq.com",
              hint: "需管理员开启 IMAP；开启安全登录时使用客户端专用密码。",
              helpURL: "https://exmail.qq.com",
              badge: "企", colorHex: 0x2D6CDF, domains: [],
              passwordLabel: "密码", passwordExplain: "通常就是你的企业邮箱密码。如果开启了微信安全登录，需要使用「客户端专用密码」。",
              steps: [
                  "点击下方按钮，登录腾讯企业邮网页版",
                  "进入「设置」→「客户端设置」，勾选开启 IMAP/SMTP 服务",
                  "如果你开启了微信安全登录：在「设置」→「账户」中生成「客户端专用密码」",
                  "回到这里填写邮箱地址和密码（或客户端专用密码）",
              ]),
        .init(name: "Gmail", host: "imap.gmail.com",
              hint: "需开启两步验证，在 Google 账号 → 安全性 → 应用专用密码 中生成密码。",
              helpURL: "https://myaccount.google.com/apppasswords",
              badge: "G", colorHex: 0xEA4335, domains: ["gmail.com", "googlemail.com"],
              passwordLabel: "应用专用密码", passwordExplain: "应用专用密码是 Google 给第三方软件用的 16 位密码，不是你的 Google 登录密码。",
              steps: [
                  "确认你的 Google 账号已开启「两步验证」",
                  "点击下方按钮，打开「应用专用密码」页面",
                  "随便输入一个名字（例如 MailMind），点击「创建」",
                  "复制弹出的 16 位密码，粘贴到右边（空格可以保留）",
              ],
              helpButtonTitle: "打开应用专用密码页面"),
        .init(name: "iCloud", host: "imap.mail.me.com",
              hint: "在 account.apple.com 生成 App 专用密码，用户名填写 @icloud.com 地址。",
              helpURL: "https://account.apple.com",
              symbol: "icloud.fill", colorHex: 0x3693F3, domains: ["icloud.com", "me.com", "mac.com"],
              passwordLabel: "App 专用密码", passwordExplain: "App 专用密码是 Apple 给第三方软件用的密码，不是你的 Apple ID 密码。",
              steps: [
                  "点击下方按钮，登录 Apple 账户网页",
                  "进入「登录与安全」→「App 专用密码」",
                  "点击「生成 App 专用密码」，名字填 MailMind",
                  "复制生成的密码，粘贴到右边；邮箱地址填写 @icloud.com 地址",
              ],
              helpButtonTitle: "打开 Apple 账户"),
        .init(name: "Outlook", host: "outlook.office365.com",
              hint: "微软个人账户已停用密码方式的 IMAP 登录，需要 OAuth（计划中）。企业账户视管理员设置而定。",
              badge: "O", colorHex: 0x0078D4, domains: ["outlook.com", "hotmail.com", "live.com", "msn.com"],
              passwordLabel: "密码",
              steps: [
                  "点击「使用微软账号登录」",
                  "在弹出的微软官方页面登录你的 Outlook / Hotmail 账号",
                  "确认授权 MailMind 读取邮件",
                  "完成！不需要授权码，MailMind 也看不到你的密码",
              ],
              note: "公司的 Microsoft 365 邮箱可能需要管理员先同意授权。",
              oauth: "microsoft"),
        .init(name: "阿里邮箱", host: "imap.aliyun.com",
              hint: "网页版 设置 → 账户 → 开启 IMAP。",
              helpURL: "https://mail.aliyun.com",
              badge: "阿", colorHex: 0xFF6A00, domains: ["aliyun.com"],
              passwordLabel: "密码", passwordExplain: "通常就是你的邮箱登录密码。",
              steps: [
                  "点击下方按钮，登录阿里邮箱网页版",
                  "进入「设置」→「账户」→「POP3/SMTP 和 IMAP/SMTP」",
                  "勾选开启 IMAP/SMTP 服务并保存",
                  "回到这里填写邮箱地址和密码",
              ]),
        .init(name: "Yahoo", host: "imap.mail.yahoo.com",
              hint: "在账户安全设置中生成应用密码。",
              helpURL: "https://login.yahoo.com/account/security",
              badge: "Y!", colorHex: 0x6001D2, domains: ["yahoo.com"],
              passwordLabel: "应用密码", passwordExplain: "应用密码是 Yahoo 给第三方软件用的密码，不是你的登录密码。",
              steps: [
                  "点击下方按钮，打开 Yahoo 账户安全页面",
                  "找到「生成应用密码」，名字填 MailMind",
                  "复制生成的密码，粘贴到右边",
              ]),
        .init(name: "Mac 邮件 App", host: "",
              hint: "读取 macOS「邮件」App 已收取的邮件。",
              symbol: "envelope.open.fill", colorHex: 0x1A8CFF,
              passwordLabel: "密码", appleMail: true),
        .init(name: "其他邮箱", host: "",
              hint: "填写邮箱服务商提供的 IMAP 服务器地址，通常端口为 993（SSL）。",
              symbol: "envelope.fill", colorHex: 0x8E8E93,
              passwordLabel: "密码", passwordExplain: "一般是邮箱密码；部分邮箱需要在网页版开启 IMAP 并使用授权码。",
              steps: [
                  "填写邮箱地址和密码，MailMind 会自动查找服务器",
                  "如果连接失败，请到邮箱网页版的设置里开启 IMAP 服务",
                  "部分邮箱需要使用「授权码」或「客户端专用密码」代替登录密码",
              ]),
    ]

    /// 根据邮箱地址的域名识别服务商。
    static func guess(email: String) -> MailProviderPreset? {
        let domain = email.split(separator: "@").last?.lowercased() ?? ""
        return all.first { $0.domains.contains(domain) }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct AIProviderPreset: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var baseURL: String
    var model: String
    var needsKey = true
    /// 获取 API Key 的页面
    var keyURL: String? = nil
    var tagline = ""
    var badge = ""
    var colorHex: UInt32 = 0x8E8E93
}

enum AIProviderPresets {
    static let all: [AIProviderPreset] = [
        .init(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
              keyURL: "https://platform.deepseek.com/api_keys", tagline: "便宜好用，推荐", badge: "D", colorHex: 0x4D6BFE),
        .init(name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",
              keyURL: "https://bailian.console.aliyun.com", tagline: "阿里云", badge: "通", colorHex: 0x615CED),
        .init(name: "小米 MiMo", baseURL: "https://api.xiaomimimo.com/v1", model: "mimo-v2.6-flash",
              tagline: "小米", badge: "Mi", colorHex: 0xFF6900),
        .init(name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-32k",
              keyURL: "https://platform.moonshot.cn/console/api-keys", tagline: "月之暗面", badge: "K", colorHex: 0x16191E),
        .init(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-32B-Instruct",
              keyURL: "https://cloud.siliconflow.cn/account/ak", tagline: "多种开源模型", badge: "硅", colorHex: 0x7C3AED),
        .init(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
              keyURL: "https://platform.openai.com/api-keys", tagline: "需海外网络", badge: "AI", colorHex: 0x10A37F),
        .init(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5",
              keyURL: "https://openrouter.ai/keys", tagline: "聚合多家模型", badge: "OR", colorHex: 0x6467F2),
        .init(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b", needsKey: false,
              keyURL: "https://ollama.com", tagline: "离线最私密", badge: "🦙", colorHex: 0x333333),
        .init(name: "LM Studio", baseURL: "http://localhost:1234/v1", model: "local-model", needsKey: false,
              tagline: "本机运行", badge: "LM", colorHex: 0x4B5563),
    ]

    static func matching(baseURL: String) -> AIProviderPreset? {
        all.first { $0.baseURL == baseURL.trimmed }
    }
}
