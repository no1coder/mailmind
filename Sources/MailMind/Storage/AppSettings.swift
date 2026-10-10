import Foundation
import Observation

enum DigestFrequency: String, CaseIterable, Identifiable {
    case daily, weekly
    var id: String { rawValue }
    var label: String { self == .daily ? "每天" : "每周一" }
}

/// 应用设置，持久化在 UserDefaults 中（密钥除外）。
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var accounts: [MailAccount] {
        didSet { defaults.set(try? JSONEncoder().encode(accounts), forKey: "accounts") }
    }
    var forwardAliases: [ForwardAlias] {
        didSet { defaults.set(try? JSONEncoder().encode(forwardAliases), forKey: "forwardAliases") }
    }
    /// 分类 / 提醒规则
    var mailRules: [MailRule] {
        didSet { defaults.set(try? JSONEncoder().encode(mailRules), forKey: "mailRules") }
    }
    /// 重要邮件转发渠道（Telegram、微信等）；令牌在钥匙串中
    var forwardChannels: [ForwardChannel] {
        didSet { defaults.set(try? JSONEncoder().encode(forwardChannels), forKey: "forwardChannels") }
    }
    /// 是否已把旧版「发件人规则」迁移为 mailRules
    var senderRulesMigrated: Bool { didSet { defaults.set(senderRulesMigrated, forKey: "senderRulesMigrated") } }
    /// 是否把手动纠正的分类作为示例交给 AI 学习
    var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: "learnFromCorrections") } }

    // AI
    var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }
    var aiBaseURL: String { didSet { defaults.set(aiBaseURL, forKey: "aiBaseURL") } }
    var aiModel: String { didSet { defaults.set(aiModel, forKey: "aiModel") } }
    var autoTranslate: Bool { didSet { defaults.set(autoTranslate, forKey: "autoTranslate") } }
    var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: "targetLanguage") } }
    var customRules: String { didSet { defaults.set(customRules, forKey: "customRules") } }

    // 同步与通知
    var syncIntervalMinutes: Int { didSet { defaults.set(syncIntervalMinutes, forKey: "syncIntervalMinutes") } }
    var initialSyncDays: Int { didSet { defaults.set(initialSyncDays, forKey: "initialSyncDays") } }
    var maxMessagesPerSync: Int { didSet { defaults.set(maxMessagesPerSync, forKey: "maxMessagesPerSync") } }
    var notifyImportant: Bool { didSet { defaults.set(notifyImportant, forKey: "notifyImportant") } }
    /// IMAP IDLE 实时推送；关闭后仅靠定时轮询。
    var realtimeEnabled: Bool { didSet { defaults.set(realtimeEnabled, forKey: "realtimeEnabled") } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") } }
    /// 勿扰开始 / 结束，单位：一天中的分钟数
    var quietStart: Int { didSet { defaults.set(quietStart, forKey: "quietStart") } }
    var quietEnd: Int { didSet { defaults.set(quietEnd, forKey: "quietEnd") } }
    /// 自定义微软应用 ID（为空时使用内置的）。
    var microsoftClientID: String { didSet { defaults.set(microsoftClientID, forKey: "microsoftClientID") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    // 定期汇总
    var digestEnabled: Bool { didSet { defaults.set(digestEnabled, forKey: "digestEnabled") } }
    var digestFrequency: DigestFrequency { didSet { defaults.set(digestFrequency.rawValue, forKey: "digestFrequency") } }
    var digestHour: Int { didSet { defaults.set(digestHour, forKey: "digestHour") } }
    var digestMinute: Int { didSet { defaults.set(digestMinute, forKey: "digestMinute") } }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "aiEnabled": true,
            "aiBaseURL": "https://api.deepseek.com/v1",
            "aiModel": "deepseek-chat",
            "autoTranslate": true,
            "targetLanguage": "简体中文",
            "customRules": "",
            "syncIntervalMinutes": 15,
            "initialSyncDays": 3,
            "maxMessagesPerSync": 200,
            "notifyImportant": true,
            "realtimeEnabled": true,
            "quietHoursEnabled": true,
            "quietStart": 22 * 60,
            "quietEnd": 8 * 60,
            "hasCompletedOnboarding": false,
            "digestEnabled": true,
            "digestFrequency": DigestFrequency.daily.rawValue,
            "digestHour": 20,
            "digestMinute": 0,
            "senderRulesMigrated": false,
            "learnFromCorrections": true,
        ])
        accounts = (d.data(forKey: "accounts")).flatMap { try? JSONDecoder().decode([MailAccount].self, from: $0) } ?? []
        forwardAliases = (d.data(forKey: "forwardAliases")).flatMap { try? JSONDecoder().decode([ForwardAlias].self, from: $0) } ?? []
        mailRules = (d.data(forKey: "mailRules")).flatMap { try? JSONDecoder().decode([MailRule].self, from: $0) } ?? []
        forwardChannels = (d.data(forKey: "forwardChannels")).flatMap { try? JSONDecoder().decode([ForwardChannel].self, from: $0) } ?? []
        senderRulesMigrated = d.bool(forKey: "senderRulesMigrated")
        learnFromCorrections = d.bool(forKey: "learnFromCorrections")
        aiEnabled = d.bool(forKey: "aiEnabled")
        aiBaseURL = d.string(forKey: "aiBaseURL") ?? ""
        aiModel = d.string(forKey: "aiModel") ?? ""
        autoTranslate = d.bool(forKey: "autoTranslate")
        targetLanguage = d.string(forKey: "targetLanguage") ?? "简体中文"
        customRules = d.string(forKey: "customRules") ?? ""
        syncIntervalMinutes = d.integer(forKey: "syncIntervalMinutes")
        initialSyncDays = d.integer(forKey: "initialSyncDays")
        maxMessagesPerSync = d.integer(forKey: "maxMessagesPerSync")
        notifyImportant = d.bool(forKey: "notifyImportant")
        realtimeEnabled = d.bool(forKey: "realtimeEnabled")
        quietHoursEnabled = d.bool(forKey: "quietHoursEnabled")
        quietStart = d.integer(forKey: "quietStart")
        quietEnd = d.integer(forKey: "quietEnd")
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
        microsoftClientID = d.string(forKey: "microsoftClientID") ?? ""
        digestEnabled = d.bool(forKey: "digestEnabled")
        digestFrequency = DigestFrequency(rawValue: d.string(forKey: "digestFrequency") ?? "") ?? .daily
        digestHour = d.integer(forKey: "digestHour")
        digestMinute = d.integer(forKey: "digestMinute")
    }

    var microsoftOAuth: OAuthConfig {
        let custom = microsoftClientID.trimmed
        return .microsoft(clientID: custom.isEmpty ? MicrosoftOAuth.builtInClientID : custom)
    }

    var analysisOptions: AnalysisOptions {
        AnalysisOptions(targetLanguage: targetLanguage, customRules: customRules)
    }

    /// 最近一次（不晚于 now）应当生成汇总的时间点。
    func lastScheduledDigestTime(before now: Date = Date()) -> Date {
        var comps = DateComponents()
        comps.hour = digestHour
        comps.minute = digestMinute
        if digestFrequency == .weekly { comps.weekday = 2 }
        return Calendar.current.nextDate(after: now, matching: comps, matchingPolicy: .nextTime, direction: .backward) ?? now
    }
}
