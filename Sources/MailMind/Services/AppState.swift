import AppKit
import Observation
import SwiftUI

enum AccountCredentialError: LocalizedError {
    case missing
    var errorDescription: String? { "未保存密码，请在账户设置中重新填写" }
}

enum SidebarItem: Hashable {
    case important
    case action
    case inbox
    case digest
    case category(MailCategory)
    case account(UUID)
    /// 转发来源视图（按原收件人地址）
    case alias(String)
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let settings = AppSettings()
    @ObservationIgnored let db = Database.shared

    var filter: SidebarItem = .important {
        didSet {
            guard oldValue != filter else { return }
            selectedIDs = []
            reload()
        }
    }
    var searchText = ""
    var messages: [MailMessage] = []
    /// 列表多选；恰好选中一封时显示详情。
    var selectedIDs: Set<String> = []
    var unreadCounts: [String: Int] = [:]
    var digests: [Digest] = []
    var selectedDigestID: Int64?
    var senderRules: [String: SenderRule] = [:]
    var accountStatus: [UUID: AccountStatus] = [:]

    var isSyncing = false
    var isGeneratingDigest = false
    var statusText = ""
    var lastErrors: [String] = []
    var showAskAI = false
    var showOnboarding = false

    /// 由视图注入，用于从菜单栏或通知中重新打开主窗口。
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var lastFullSync: Date?
    @ObservationIgnored private var lastQuickSync: Date?
    @ObservationIgnored private var lastDigestAttempt: Date?
    @ObservationIgnored private var pendingSync: Set<UUID> = []
    @ObservationIgnored private var isRunningAI = false
    @ObservationIgnored private var realtimeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var realtimeAccounts: [UUID: MailAccount] = [:]
    @ObservationIgnored private var realtimeClients: [UUID: IMAPClient] = [:]

    var selectedMessageID: String? { selectedIDs.count == 1 ? selectedIDs.first : nil }
    var importantUnread: Int { unreadCounts["@important"] ?? 0 }

    // MARK: - 生命周期

    func start() {
        guard loopTask == nil else { return }
        Notifier.shared.onOpen = { [weak self] id in
            Task { @MainActor in self?.handleNotificationOpen(id) }
        }
        Notifier.shared.onMarkRead = { [weak self] ids in
            Task { @MainActor in self?.setRead(ids, read: true) }
        }
        Notifier.shared.requestAuthorization()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }

        if !settings.hasCompletedOnboarding && settings.accounts.isEmpty {
            showOnboarding = true
        }

        reload()
        reloadDigests()
        reloadSenderRules()
        refreshRealtime()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// 不支持实时推送的邮箱的轮询间隔。
    static let pollIntervalWithoutPush: TimeInterval = 5 * 60

    /// 每分钟执行一次：
    /// - 全量：每 syncIntervalMinutes 分钟同步所有账户（兜底）
    /// - 没有实时推送的 IMAP 账户：每 5 分钟
    /// - 「邮件」App 本地账户：每分钟（只读本地文件，开销很小）
    private func tick() async {
        let now = Date()
        let interval = TimeInterval(max(1, settings.syncIntervalMinutes) * 60)
        if lastFullSync.map({ now.timeIntervalSince($0) >= interval - 5 }) ?? true {
            lastQuickSync = now
            await sync()
        } else {
            var due = Set(settings.accounts.filter { $0.enabled && $0.isAppleMail }.map(\.id))
            if lastQuickSync.map({ now.timeIntervalSince($0) >= Self.pollIntervalWithoutPush - 5 }) ?? true {
                lastQuickSync = now
                due.formUnion(settings.accounts.filter { $0.enabled && !$0.isAppleMail && accountStatus[$0.id]?.realtime != true }.map(\.id))
            }
            if !due.isEmpty { await sync(accounts: due) }
        }
        await generateDigestIfDue()
    }

    /// 睡眠唤醒后旧连接都已失效：重建实时连接并立即补拉一次。
    private func handleWake() {
        restartRealtime()
        Task {
            try? await Task.sleep(for: .seconds(5)) // 等网络恢复
            await sync()
        }
    }

    // MARK: - 数据

    var currentDBFilter: Database.Filter {
        switch filter {
        case .important: return .important
        case .action: return .actionNeeded
        case .inbox, .digest: return .all
        case .category(let c): return .category(c.rawValue)
        case .account(let id): return .account(id)
        case .alias(let address): return .recipient(address)
        }
    }

    func reload() {
        messages = (try? db.messages(filter: currentDBFilter, search: searchText)) ?? []
        refreshCounts()
    }

    private func refreshCounts() {
        unreadCounts = (try? db.unreadCounts()) ?? [:]
        NSApp?.dockTile.badgeLabel = importantUnread > 0 ? "\(importantUnread)" : nil
    }

    func reloadDigests() {
        digests = (try? db.digests()) ?? []
        if selectedDigestID == nil { selectedDigestID = digests.first?.id }
    }

    func reloadSenderRules() {
        senderRules = Dictionary(((try? db.senderRules()) ?? []).map { ($0.email, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func message(id: String) -> MailMessage? {
        messages.first { $0.id == id } ?? (try? db.message(id: id)) ?? nil
    }

    func account(id: UUID) -> MailAccount? {
        settings.accounts.first { $0.id == id }
    }

    // MARK: - 已读状态

    func markRead(_ id: String) {
        guard let m = message(id: id), !m.isRead else { return }
        setRead([id], read: true)
    }

    func setRead(_ ids: [String], read: Bool) {
        try? db.setRead(ids: ids, read: read)
        for id in ids {
            if let idx = messages.firstIndex(where: { $0.id == id }) { messages[idx].isRead = read }
        }
        refreshCounts()
    }

    func toggleReadForSelection() {
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else { return }
        let anyUnread = messages.contains { ids.contains($0.id) && !$0.isRead }
        setRead(ids, read: anyUnread)
    }

    func markAllReadInCurrentView() {
        try? db.markAllRead(filter: currentDBFilter, search: searchText)
        reload()
    }

    // MARK: - 分类与发件人规则

    func setCategory(_ ids: [String], _ category: MailCategory) {
        for id in ids { try? db.setCategory(id: id, category: category) }
        reload()
    }

    func reanalyze(_ id: String) {
        try? db.resetAI(id: id)
        reload()
        Task { await runAI() }
    }

    func retryFailed() {
        try? db.retryFailedAI()
        Task { await runAI() }
    }

    func senderRule(for email: String) -> SenderRule {
        senderRules[email.lowercased()] ?? SenderRule(email: email.lowercased())
    }

    func updateSenderRule(_ email: String, _ change: (inout SenderRule) -> Void) {
        var rule = senderRule(for: email)
        change(&rule)
        try? db.saveSenderRule(rule)
        reloadSenderRules()
    }

    /// 以后该发件人的邮件都归为某个分类（同时修正已有邮件）。
    func setSenderCategory(_ email: String, _ category: MailCategory?) {
        updateSenderRule(email) { $0.category = category?.rawValue ?? "" }
        if let category { try? db.applyCategory(category, toSender: email) }
        reload()
    }

    // MARK: - 打开

    func open(messageID: String) {
        if message(id: messageID) != nil {
            if !messages.contains(where: { $0.id == messageID }) { filter = .inbox }
            selectedIDs = [messageID]
        }
        showMainWindow()
    }

    func showMainWindow() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleNotificationOpen(_ id: String) {
        switch id {
        case "digest":
            filter = .digest
            reloadDigests()
            selectedDigestID = digests.first?.id
            showMainWindow()
        case "important":
            filter = .important
            showMainWindow()
        default:
            open(messageID: id)
        }
    }

    // MARK: - 同步

    func syncNow() {
        Task { await sync() }
    }

    func syncAccount(_ id: UUID) {
        Task { await sync(accounts: [id]) }
    }

    /// 同步指定账户；为 nil 时同步全部启用的账户。正在同步时会排队，结束后再执行。
    func sync(accounts ids: Set<UUID>? = nil) async {
        let targets = settings.accounts.filter { $0.enabled && (ids?.contains($0.id) ?? true) }
        guard !isSyncing else {
            pendingSync.formUnion(targets.map(\.id))
            return
        }
        isSyncing = true
        if ids == nil {
            lastFullSync = Date()
            lastErrors = []
        }

        await withTaskGroup(of: Void.self) { group in
            for account in targets {
                accountStatus[account.id, default: AccountStatus()].syncing = true
                group.addTask { await self.syncOne(account) }
            }
        }
        reload()
        await runAI()
        notifyNewMail()

        let failed = settings.accounts.filter { accountStatus[$0.id]?.error != nil }.count
        let time = Date().formatted(date: .omitted, time: .shortened)
        statusText = failed == 0 ? "\(time) 已同步" : "\(time) 已同步，\(failed) 个账户异常"
        isSyncing = false

        if !pendingSync.isEmpty {
            let next = pendingSync
            pendingSync = []
            await sync(accounts: next)
        }
    }

    private func syncOne(_ account: MailAccount) async {
        statusText = "正在同步 \(account.displayName)…"
        var status = accountStatus[account.id] ?? AccountStatus()
        defer {
            status.syncing = false
            accountStatus[account.id] = status
        }
        do {
            if account.isAppleMail {
                let n = try SyncEngine.syncAppleMail(account: account, initialDays: settings.initialSyncDays,
                                                     maxMessages: settings.maxMessagesPerSync, db: db)
                status.error = nil
                status.lastSync = Date()
                if n > 0 { reload() }
                return
            }
            let credential = try await credential(for: account)
            let n = try await SyncEngine.sync(account: account, credential: credential,
                                              initialDays: settings.initialSyncDays,
                                              maxMessages: settings.maxMessagesPerSync, db: db)
            status.error = nil
            status.lastSync = Date()
            if n > 0 { reload() }
        } catch {
            status.error = error.localizedDescription
            lastErrors.append("\(account.displayName)：\(error.localizedDescription)")
        }
    }

    // MARK: - 实时推送（IMAP IDLE）

    /// 按当前设置启动 / 停止各账户的实时连接。账户配置变化时调用。
    func refreshRealtime() {
        let wanted = settings.realtimeEnabled ? settings.accounts.filter { $0.enabled && !$0.isAppleMail } : []
        let wantedIDs = Set(wanted.map(\.id))
        for id in realtimeTasks.keys where !wantedIDs.contains(id) {
            stopRealtime(id)
        }
        for account in wanted where realtimeAccounts[account.id] != account {
            stopRealtime(account.id)
            realtimeAccounts[account.id] = account
            realtimeTasks[account.id] = Task { [weak self] in await self?.runRealtime(account) }
        }
    }

    private func restartRealtime() {
        for id in Array(realtimeTasks.keys) { stopRealtime(id) }
        refreshRealtime()
    }

    private func stopRealtime(_ id: UUID) {
        realtimeTasks[id]?.cancel()
        realtimeClients[id]?.cancel()
        realtimeTasks[id] = nil
        realtimeClients[id] = nil
        realtimeAccounts[id] = nil
        accountStatus[id]?.realtime = false
    }

    private func runRealtime(_ account: MailAccount) async {
        var backoff: Double = 30
        while !Task.isCancelled {
            let client = IMAPClient(host: account.host, port: account.port, useTLS: account.useTLS)
            realtimeClients[account.id] = client
            do {
                let credential = try await credential(for: account)
                try await client.connect(username: account.username, credential: credential)
                guard try await client.capabilities().contains("IDLE") else {
                    await client.logout()
                    return // 服务器不支持 IDLE，只靠定时轮询
                }
                _ = try await client.examine(account.folders.first ?? "INBOX")
                accountStatus[account.id, default: AccountStatus()].realtime = true
                backoff = 30
                while !Task.isCancelled {
                    // 服务器通常 30 分钟断开空闲连接，25 分钟重新发起一次 IDLE。
                    if try await client.idle(maxDuration: 25 * 60) {
                        await sync(accounts: [account.id])
                    }
                }
                await client.logout()
            } catch {
                client.cancel()
                accountStatus[account.id]?.realtime = false
                if Task.isCancelled { break }
                if case OAuthError.reauthRequired = error { return }
                if case AccountCredentialError.missing = error { return }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 600)
            }
        }
    }

    // MARK: - AI

    func makeAIClient() -> AIClient? {
        let base = settings.aiBaseURL.trimmed
        let model = settings.aiModel.trimmed
        guard settings.aiEnabled, !base.isEmpty, !model.isEmpty else { return nil }
        return AIClient(baseURL: base, model: model, apiKey: Keychain.get(Keychain.aiKey) ?? "")
    }

    func runAI() async {
        guard !isRunningAI, let client = makeAIClient() else { return }
        isRunningAI = true
        defer { isRunningAI = false }

        let options = settings.analysisOptions
        let rules = senderRules
        let db = self.db
        var attempted = Set<String>()
        while true {
            let batch = ((try? db.pendingAIMessages(limit: 6)) ?? []).filter { !attempted.contains($0.id) }
            if batch.isEmpty { break }
            attempted.formUnion(batch.map(\.id))
            statusText = "AI 正在分析，剩余 \(db.pendingAICount()) 封…"
            await withTaskGroup(of: Void.self) { group in
                for m in batch {
                    group.addTask {
                        let rule = rules[m.senderKey]
                        let ruleCategory = rule.flatMap { MailCategory(rawValue: $0.category) }
                        // 发件人规则命中低价值分类：本地直接归类，不花 AI 的钱。
                        if let c = ruleCategory, [.marketing, .spam, .social, .notification].contains(c) {
                            try? db.saveAnalysis(id: m.id, Classifier.localAnalysis(for: m, category: c))
                            return
                        }
                        do {
                            var result = try await Classifier.analyze(m, client: client, options: options)
                            if let c = ruleCategory {
                                result.category = c.rawValue
                                if c == .important { result.importance = .high }
                            }
                            try db.saveAnalysis(id: m.id, result)
                        } catch {
                            try? db.markAIFailed(id: m.id, error: error.localizedDescription)
                        }
                    }
                }
            }
            reload()
        }
    }

    private func notificationPolicy() -> NotificationPolicy {
        NotificationPolicy(
            enabled: settings.notifyImportant,
            quietHoursEnabled: settings.quietHoursEnabled,
            quietStart: settings.quietStart,
            quietEnd: settings.quietEnd,
            vipSenders: Set(senderRules.values.filter(\.vip).map(\.email)),
            mutedSenders: Set(senderRules.values.filter(\.muted).map(\.email))
        )
    }

    private func notifyNewMail() {
        let candidates = (try? db.notificationCandidates()) ?? []
        guard !candidates.isEmpty else { return }
        try? db.markNotified(ids: candidates.map(\.id))

        let policy = notificationPolicy()
        let decided = candidates.map { ($0, policy.decide($0)) }.filter { $0.1 != .none }
        guard !decided.isEmpty else { return }
        if decided.count > 3 {
            Notifier.shared.notifyBatch(decided.map(\.0), withSound: decided.contains { $0.1 == .alert })
        } else {
            for (m, d) in decided {
                Notifier.shared.notify(m, decision: d, accountName: account(id: m.accountID)?.displayName)
            }
        }
    }

    /// 在近 30 天的邮件里回答问题，返回回答与被引用的邮件。
    func ask(_ question: String) async throws -> (answer: String, cited: [MailMessage]) {
        guard let client = makeAIClient() else { throw AIError.notConfigured }
        let since = Date().addingTimeInterval(-30 * 86_400)
        let list = try db.recentMessages(since: since, limit: 300)
        let answer = try await Classifier.ask(question, messages: list, client: client, targetLanguage: settings.targetLanguage)
        let cited = Classifier.citations(in: answer).compactMap { $0 >= 1 && $0 <= list.count ? list[$0 - 1] : nil }
        return (answer, cited)
    }

    func draftReply(to m: MailMessage, instruction: String) async throws -> String {
        guard let client = makeAIClient() else { throw AIError.notConfigured }
        var full = m
        full.bodyText = (try? db.body(id: m.id).text) ?? m.snippet
        return try await Classifier.draftReply(to: full, instruction: instruction, client: client)
    }

    // MARK: - 汇总

    private func generateDigestIfDue() async {
        guard settings.digestEnabled, makeAIClient() != nil else { return }
        let due = settings.lastScheduledDigestTime()
        let last = digests.first?.createdAt ?? .distantPast
        guard last < due else { return }
        if let attempt = lastDigestAttempt, Date().timeIntervalSince(attempt) < 1800 { return }
        await generateDigest()
    }

    func generateDigest() async {
        guard !isGeneratingDigest, let client = makeAIClient() else { return }
        isGeneratingDigest = true
        lastDigestAttempt = Date()
        defer { isGeneratingDigest = false }

        let end = Date()
        let fallback: TimeInterval = settings.digestFrequency == .weekly ? 7 * 86_400 : 86_400
        let start = digests.first?.periodEnd ?? end.addingTimeInterval(-fallback)
        let messages = (try? db.digestMessages(from: start, to: end)) ?? []
        do {
            let content = try await Classifier.digest(messages, client: client, targetLanguage: settings.targetLanguage)
            let id = try db.insertDigest(start: start, end: end, count: messages.count, content: content)
            reloadDigests()
            selectedDigestID = id
            Notifier.shared.notifyDigest(count: messages.count)
        } catch {
            lastErrors.append("生成汇总失败：\(error.localizedDescription)")
        }
    }

    func deleteDigest(_ id: Int64) {
        try? db.deleteDigest(id: id)
        if selectedDigestID == id { selectedDigestID = nil }
        reloadDigests()
    }

    // MARK: - 账户

    func saveAccount(_ account: MailAccount, password: String?) {
        addAccounts([(account, password)])
    }

    func addAccounts(_ items: [(MailAccount, String?)]) {
        for (account, password) in items {
            if let password { Keychain.set(password, for: Keychain.accountKey(account.id)) }
            if let idx = settings.accounts.firstIndex(where: { $0.id == account.id }) {
                settings.accounts[idx] = account
            } else {
                settings.accounts.append(account)
            }
        }
        refreshRealtime()
        Task { await sync(accounts: Set(items.map(\.0.id))) }
    }

    /// 取得登录凭证：密码账户读钥匙串；OAuth 账户返回（必要时自动刷新的）访问令牌。
    func credential(for account: MailAccount) async throws -> IMAPCredential {
        if account.oauthProvider == "microsoft" {
            return .oauth(try await OAuthTokenStore.shared.accessToken(for: account.id, config: settings.microsoftOAuth))
        }
        guard let password = Keychain.get(Keychain.accountKey(account.id)) else { throw AccountCredentialError.missing }
        return .password(password)
    }

    /// 用微软账号登录：弹出授权页，成功后测试连接并保存账户。返回账户和收件箱邮件数。
    func signInWithMicrosoft(loginHint: String? = nil, existing: MailAccount? = nil) async throws -> (MailAccount, Int) {
        let config = settings.microsoftOAuth
        let tokens = try await OAuthClient.signIn(config, loginHint: loginHint ?? existing?.email)
        let email = tokens.email.isEmpty ? (loginHint ?? existing?.email ?? "") : tokens.email
        var account = existing ?? MailAccount(displayName: email, email: email, username: email, host: "outlook.office365.com")
        account.oauthProvider = "microsoft"
        account.username = email
        let count = try await SyncEngine.test(account: account, credential: .oauth(tokens.accessToken))
        await OAuthTokenStore.shared.save(tokens, for: account.id)
        accountStatus[account.id]?.error = nil
        addAccounts([(account, nil)])
        return (account, count)
    }

    func renameAccount(_ id: UUID, _ name: String) {
        guard let idx = settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        settings.accounts[idx].displayName = name
    }

    func setAccountEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        settings.accounts[idx].enabled = enabled
        refreshRealtime()
    }

    func deleteAccount(_ id: UUID) {
        stopRealtime(id)
        Task { await OAuthTokenStore.shared.delete(id) }
        settings.accounts.removeAll { $0.id == id }
        Keychain.delete(Keychain.accountKey(id))
        try? db.deleteAccountData(id)
        accountStatus[id] = nil
        if filter == .account(id) { filter = .important }
        reload()
    }

    // MARK: - 转发来源

    func addForwardAlias(_ address: String, name: String) {
        let a = ForwardAlias(address: address.trimmed.lowercased(), name: name.trimmed.isEmpty ? address.trimmed : name.trimmed)
        guard !a.address.isEmpty, !settings.forwardAliases.contains(where: { $0.id == a.id }) else { return }
        settings.forwardAliases.append(a)
    }

    func removeForwardAlias(_ alias: ForwardAlias) {
        settings.forwardAliases.removeAll { $0.id == alias.id }
        if filter == .alias(alias.address) { filter = .important }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        settings.accounts.move(fromOffsets: source, toOffset: destination)
    }
}
