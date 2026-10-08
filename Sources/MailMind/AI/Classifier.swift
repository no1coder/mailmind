import Foundation

struct AnalysisOptions: Sendable {
    var translate: Bool
    var targetLanguage: String
    var customRules: String
}

enum NotifyLevel: String {
    case urgent, normal, none
}

struct AIAnalysis: Equatable {
    var category: String
    var importance: Importance
    var language: String
    var summary: String
    var translation: String
    var action: String
    var reason: String
    var headline = ""
    var notify: NotifyLevel = .none
    var deadline = ""
    var code = ""
}

enum Classifier {
    static let maxBodyCharacters = 8000

    static func systemPrompt(_ o: AnalysisOptions, today: Date = Date()) -> String {
        let categories = MailCategory.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        let translationRule = o.translate
            ? "如果邮件正文不是\(o.targetLanguage)，给出完整、通顺的\(o.targetLanguage)翻译，保留段落结构，可省略签名档和法律免责声明；如果已经是\(o.targetLanguage)则为空字符串"
            : "固定为空字符串"
        let todayString = today.formatted(.iso8601.year().month().day())
        var prompt = """
        你是一个专业的邮件助理，负责分类、提炼和翻译。今天是 \(todayString)。
        阅读用户收到的一封邮件，只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。

        JSON 字段：
        - category：从 [\(categories)] 中选择一个
        - importance："high"（需要用户关注或处理）、"normal" 或 "low"（广告、群发、订阅资讯、可忽略）
        - notify：是否值得打断用户
            · "urgent"：需要立刻知道——真人发来且需要尽快回复或决策；24～48 小时内截止的事项；账号安全异常（异地登录、密码被改）；付款失败、异常扣款、欠费停机；验证码 / 一次性登录链接
            · "normal"：重要但不紧急，用户今天内看到即可
            · "none"：其他所有情况（营销、通知、资讯、社交动态、已完成事项的回执等）
        - headline：一句话通知标题，不超过 30 个字，格式为「谁/什么：要用户做什么 + 截止时间」，不要复述主题。例如：
            「王经理：周五前确认 Q4 预算表」「招行信用卡 ¥3,280 将于 10/15 自动扣款」「GitHub 验证码 482913，10 分钟内有效」「京东：订单已发货，预计明天送达」
        - summary：用\(o.targetLanguage)写 1～2 句话的摘要
        - action：用户需要做的事（回复、付款、确认、提交……），一句话；不需要则为空字符串
        - deadline：如果有明确截止日期，输出 "YYYY-MM-DD"；否则为空字符串
        - code：如果是验证码邮件，输出验证码本身；否则为空字符串
        - language：正文主要语言的 ISO 639-1 代码，如 "zh"、"en"、"ja"
        - reason：用一句\(o.targetLanguage)说明分类与提醒级别的理由
        - translation：\(translationRule)

        判断规则：
        1. 钓鱼、诈骗、中奖、可疑链接、冒充银行或平台的邮件归为 "垃圾"，importance 为 "low"，notify 为 "none"。
        2. 带退订链接的群发推广归为 "营销"，importance 为 "low"，notify 为 "none"。
        3. 验证码、登录提醒、物流、系统自动通知归为 "通知"。
        4. 社交网络、论坛、群组的动态提醒归为 "社交"。
        5. 对 notify 要克制：宁可少打扰，只有真的需要用户马上知道时才用 "urgent"。
        """
        let rules = o.customRules.trimmed
        if !rules.isEmpty {
            prompt += "\n\n用户自定义规则（优先级最高，与上面冲突时以此为准）：\n\(rules)"
        }
        return prompt
    }

    static func userPrompt(_ m: MailMessage) -> String {
        var body = m.bodyText.trimmed
        if body.count > maxBodyCharacters {
            body = String(body.prefix(maxBodyCharacters)) + "\n…（正文过长，已截断）"
        }
        let formatter = ISO8601DateFormatter()
        return """
        发件人：\(m.fromName) <\(m.fromEmail)>
        收件人：\(m.to)
        主题：\(m.subject)
        时间：\(formatter.string(from: m.date))
        包含退订链接：\(m.listUnsubscribe.isEmpty ? "否" : "是")
        附件：\(m.attachments.isEmpty ? "无" : m.attachments.joined(separator: "、"))

        正文：
        \(body.isEmpty ? "（无正文）" : body)
        """
    }

    static func analyze(_ message: MailMessage, client: AIClient, options: AnalysisOptions) async throws -> AIAnalysis {
        let reply = try await client.chat(system: systemPrompt(options), user: userPrompt(message))
        return try parse(reply)
    }

    /// 宽松解析：截取第一个 { 到最后一个 } 之间的内容，字段缺失时使用默认值。
    static func parse(_ reply: String) throws -> AIAnalysis {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] else {
            throw AIError.badResponse(String(reply.prefix(200)))
        }
        func str(_ key: String) -> String {
            if let s = obj[key] as? String { return s.trimmed }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            return ""
        }

        var category = str("category")
        if MailCategory(rawValue: category) == nil {
            category = MailCategory.notification.rawValue
        }
        let importance = Importance(rawValue: str("importance").lowercased())
            ?? (category == MailCategory.important.rawValue ? .high : .normal)
        var deadline = str("deadline")
        if deadline.count != 10 || deadline.dropFirst(4).first != "-" { deadline = "" }
        return AIAnalysis(
            category: category,
            importance: importance,
            language: str("language"),
            summary: str("summary"),
            translation: str("translation"),
            action: str("action"),
            reason: str("reason"),
            headline: str("headline"),
            notify: NotifyLevel(rawValue: str("notify").lowercased()) ?? (importance == .high ? .normal : .none),
            deadline: deadline,
            code: str("code")
        )
    }

    /// 发件人规则命中「低价值」分类时，不调用 AI，直接本地归类以节省费用。
    static func localAnalysis(for m: MailMessage, category: MailCategory) -> AIAnalysis {
        AIAnalysis(
            category: category.rawValue,
            importance: category == .important ? .high : (category == .spam || category == .marketing ? .low : .normal),
            language: "",
            summary: String(m.snippet.prefix(80)),
            translation: "",
            action: "",
            reason: "按发件人规则自动归类为「\(category.rawValue)」",
            headline: "\(m.sender)：\(m.subject)",
            notify: category == .important ? .normal : .none
        )
    }

    // MARK: - 定期汇总

    static func digestPrompt(targetLanguage: String) -> String {
        """
        你是用户的邮件助理。下面是一段时间内用户收到的「非重点」邮件列表（重点邮件已单独通知过用户）。
        请用\(targetLanguage)写一份简洁的汇总，要求：
        - 使用 Markdown 列表，不要使用 # 标题
        - 按分类分组，每组用 **分类名（数量）** 开头，先用一句话概括
        - 列出其中仍值得一看的条目（发件人 + 一句话），可以忽略的内容合并成一句带过
        - 如果有可能被误判、其实需要处理的邮件，单独放在最前面的 **可能需要留意** 分组
        - 最后一行给出建议，例如哪些发件人可以考虑退订
        """
    }

    static func digestInput(_ messages: [MailMessage]) -> String {
        messages.map { m in
            let summary = m.headline.isEmpty ? (m.summary.isEmpty ? m.snippet : m.summary) : m.headline
            return "[\(m.category.isEmpty ? "未分类" : m.category)] \(m.sender) | \(m.subject) | \(summary.prefix(120))"
        }.joined(separator: "\n")
    }

    static func digest(_ messages: [MailMessage], client: AIClient, targetLanguage: String) async throws -> String {
        guard !messages.isEmpty else { return "这段时间没有新的非重点邮件。" }
        return try await client.chat(system: digestPrompt(targetLanguage: targetLanguage), user: digestInput(messages))
    }

    // MARK: - 问 AI

    static func askPrompt(targetLanguage: String, today: Date = Date()) -> String {
        """
        你是用户的邮件助理。今天是 \(today.formatted(.iso8601.year().month().day()))。
        下面是用户邮箱中最近的邮件索引，每行格式为：[编号] 日期 | 分类 | 发件人 | 主题 | 一句话 | 待办 | 截止日期。
        请根据这些邮件回答用户的问题，要求：
        - 用\(targetLanguage)回答，简洁、直接，优先给出结论
        - 引用具体邮件时，在句末标注编号，如 [3] 或 [3][12]
        - 如果邮件里找不到答案，直接说明，不要编造
        - 可以使用 Markdown 列表，不要使用 # 标题
        """
    }

    static func askIndex(_ messages: [MailMessage]) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return messages.enumerated().map { i, m in
            let line = m.headline.isEmpty ? (m.summary.isEmpty ? String(m.snippet.prefix(60)) : m.summary) : m.headline
            return "[\(i + 1)] \(f.string(from: m.date)) | \(m.category) | \(m.sender) | \(m.subject) | \(line) | \(m.action) | \(m.deadline)"
        }.joined(separator: "\n")
    }

    static func ask(_ question: String, messages: [MailMessage], client: AIClient, targetLanguage: String) async throws -> String {
        try await client.chat(system: askPrompt(targetLanguage: targetLanguage),
                              user: "邮件索引：\n\(askIndex(messages))\n\n问题：\(question)")
    }

    /// 从回答中提取被引用的编号（从 1 开始）。
    static func citations(in answer: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: "\\[(\\d{1,4})\\]") else { return [] }
        var seen: [Int] = []
        for m in re.matches(in: answer, range: NSRange(location: 0, length: (answer as NSString).length)) {
            if let n = Int((answer as NSString).substring(with: m.range(at: 1))), !seen.contains(n) { seen.append(n) }
        }
        return seen
    }

    // MARK: - 起草回复

    static func replyPrompt() -> String {
        """
        你是用户的邮件写作助理。根据收到的邮件和用户的要求，起草一封回复。
        - 使用与原邮件相同的语言（原邮件是英文就用英文回复）
        - 语气专业、礼貌、简洁，符合商务邮件习惯
        - 只输出回复正文（含称呼和落款占位），不要输出主题行、解释或代码块
        - 不确定的信息用【】标出让用户补充，不要编造
        """
    }

    static func draftReply(to m: MailMessage, instruction: String, client: AIClient) async throws -> String {
        let req = instruction.trimmed.isEmpty ? "请给出一个得体的回复。" : instruction
        return try await client.chat(system: replyPrompt(), user: "\(userPrompt(m))\n\n——\n我的要求：\(req)")
    }
}
