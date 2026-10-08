import XCTest
@testable import MailMind

final class NotificationPolicyTests: XCTestCase {
    private let now = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
    private let night = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!

    private func mail(_ level: NotifyLevel = .none, importance: Importance = .normal, category: MailCategory = .work,
                      from: String = "boss@corp.com", code: String = "", read: Bool = false, age: TimeInterval = 60,
                      relativeTo base: Date? = nil) -> MailMessage {
        var m = MailMessage(id: UUID().uuidString, accountID: UUID(), folder: "INBOX", uid: 1)
        m.fromEmail = from
        m.notifyLevel = level.rawValue
        m.importance = importance
        m.category = category.rawValue
        m.code = code
        m.isRead = read
        m.date = (base ?? now).addingTimeInterval(-age)
        return m
    }

    func testUrgentAlertsAndNormalIsSilent() {
        let p = NotificationPolicy()
        XCTAssertEqual(p.decide(mail(.urgent), now: now), .alert)
        XCTAssertEqual(p.decide(mail(.normal), now: now), .silent)
        XCTAssertEqual(p.decide(mail(.none), now: now), .none)
        XCTAssertEqual(p.decide(mail(.none, importance: .high), now: now), .silent)
    }

    func testSuppressions() {
        var p = NotificationPolicy()
        XCTAssertEqual(p.decide(mail(.urgent, read: true), now: now), .none, "其他设备已读")
        XCTAssertEqual(p.decide(mail(.urgent, age: 2 * 86_400), now: now), .none, "旧邮件")
        XCTAssertEqual(p.decide(mail(.urgent, category: .spam), now: now), .none)
        p.rules = [MailRule(sender: "boss@corp.com", notify: .never)]
        XCTAssertEqual(p.decide(mail(.urgent, from: "Boss@Corp.com"), now: now), .none, "静音（大小写不敏感）")
        p.enabled = false
        XCTAssertEqual(p.decide(mail(.urgent, from: "x@y.com"), now: now), .none)
    }

    func testQuietHoursDowngradeButVIPAndCodesStillRing() {
        var p = NotificationPolicy(quietHoursEnabled: true, quietStart: 22 * 60, quietEnd: 8 * 60)
        XCTAssertEqual(p.decide(mail(.urgent, relativeTo: night), now: night), .silent)
        XCTAssertEqual(p.decide(mail(.none, code: "123456", relativeTo: night), now: night), .alert)
        XCTAssertEqual(p.decide(mail(.none, code: "123456", age: 3600, relativeTo: night), now: night), .none, "过期验证码")
        p.rules = [MailRule(sender: "boss@corp.com", notify: .always)]
        XCTAssertEqual(p.decide(mail(.none, relativeTo: night), now: night), .alert)
    }

    /// 不想看某个发件人的其他邮件，但验证码还要收
    func testMutedSenderStillDeliversCodes() {
        var p = NotificationPolicy()
        p.rules = [MailRule(sender: "@shop.com", notify: .never, exceptCodes: true)]
        XCTAssertEqual(p.decide(mail(.normal, from: "promo@shop.com"), now: now), .none)
        XCTAssertEqual(p.decide(mail(.none, from: "noreply@login.shop.com", code: "8812"), now: now), .alert, "子域名的验证码仍提醒")
        p.rules[0].exceptCodes = false
        XCTAssertEqual(p.decide(mail(.none, from: "noreply@shop.com", code: "8812"), now: now), .none)
    }

    func testQuietHoursWindow() {
        let p = NotificationPolicy(quietHoursEnabled: true, quietStart: 22 * 60, quietEnd: 8 * 60)
        func at(_ h: Int, _ m: Int = 0) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        XCTAssertTrue(p.isQuietTime(at(23)))
        XCTAssertTrue(p.isQuietTime(at(3)))
        XCTAssertFalse(p.isQuietTime(at(8)))
        XCTAssertFalse(p.isQuietTime(at(21, 59)))
        let day = NotificationPolicy(quietHoursEnabled: true, quietStart: 12 * 60, quietEnd: 13 * 60)
        XCTAssertTrue(day.isQuietTime(at(12, 30)))
        XCTAssertFalse(day.isQuietTime(at(13, 30)))
    }
}

final class AccountDiscoveryTests: XCTestCase {
    func testBatchParsing() {
        let text = """
        # 注释
        a@qq.com  abcdefgh  个人 QQ
        b@gmail.com abcd efgh ijkl mnop
        c@company.com,Pass word 1,工作邮箱
        not-an-email foo
        d@163.com\tsecret
        """
        let r = AccountDiscovery.parseBatch(text)
        XCTAssertEqual(r.count, 4)
        XCTAssertEqual(r[0].email, "a@qq.com")
        XCTAssertEqual(r[0].password, "abcdefgh")
        XCTAssertEqual(r[0].name, "个人 QQ")
        XCTAssertEqual(r[1].password, "abcdefghijklmnop", "Gmail 应用专用密码中的空格应被去掉")
        XCTAssertEqual(r[2].password, "Pass word 1")
        XCTAssertEqual(r[2].name, "工作邮箱")
        XCTAssertEqual(r[3].password, "secret")
    }

    func testISPDBParsing() {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="example.org">
          <shortDisplayName>Example</shortDisplayName>
          <incomingServer type="pop3"><hostname>pop.example.org</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
          <incomingServer type="imap"><hostname>imap.%EMAILDOMAIN%</hostname><port>993</port><socketType>SSL</socketType></incomingServer>
        </emailProvider></clientConfig>
        """
        let s = AccountDiscovery.parseISPDB(xml, domain: "example.org")
        XCTAssertEqual(s?.host, "imap.example.org")
        XCTAssertEqual(s?.port, 993)
        XCTAssertEqual(s?.useTLS, true)
        XCTAssertEqual(s?.providerName, "Example")
    }

    func testPresetDiscoveryIsInstant() async {
        let s = await AccountDiscovery.discover(email: "someone@foxmail.com")
        XCTAssertEqual(s?.host, "imap.qq.com")
    }
}

final class AIFeatureTests: XCTestCase {
    func testParseNewFields() throws {
        let a = try Classifier.parse("""
        {"category":"账单","importance":"high","notify":"urgent","headline":"招行信用卡 ¥3,280 将于 10/15 扣款",
         "deadline":"2026-10-15","code":"","summary":"s","action":"还款","reason":"r","language":"zh","translation":""}
        """)
        XCTAssertEqual(a.notify, .urgent)
        XCTAssertEqual(a.headline, "招行信用卡 ¥3,280 将于 10/15 扣款")
        XCTAssertEqual(a.deadline, "2026-10-15")
    }

    func testInvalidDeadlineAndNumericCode() throws {
        let a = try Classifier.parse(#"{"category":"通知","deadline":"下周五","code":482913}"#)
        XCTAssertEqual(a.deadline, "")
        XCTAssertEqual(a.code, "482913")
        XCTAssertEqual(a.notify, .none)
    }

    func testCitations() {
        XCTAssertEqual(Classifier.citations(in: "你需要回复王经理 [3]，还有账单 [12][3]。"), [3, 12])
    }

    func testLocalAnalysisSkipsNotification() {
        var m = MailMessage(id: "x", accountID: UUID(), folder: "INBOX", uid: 1)
        m.subject = "双十一大促"
        let a = Classifier.localAnalysis(for: m, category: .marketing)
        XCTAssertEqual(a.importance, .low)
        XCTAssertEqual(a.notify, .none)
    }
}

final class ListGroupingTests: XCTestCase {
    func testDateSections() {
        let now = Date()
        func m(_ daysAgo: Int) -> MailMessage {
            var x = MailMessage(id: UUID().uuidString, accountID: UUID(), folder: "INBOX", uid: 1)
            x.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            return x
        }
        let sections = MessageListView.group([m(0), m(0), m(1), m(3), m(30)], now: now)
        XCTAssertEqual(sections.map(\.title), ["今天", "昨天", "本周", "更早"])
        XCTAssertEqual(sections[0].messages.count, 2)
    }
}

final class MigrationTests: XCTestCase {
    func testOldDatabaseGetsNewColumnsAndRules() throws {
        let path = NSTemporaryDirectory() + "mailmind-migration-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // 用 v0.1 的表结构建库
        do {
            let db = try Database(path: path)
            try db.run("DROP TABLE messages")
            try db.run("""
            CREATE TABLE messages (id TEXT PRIMARY KEY, account_id TEXT NOT NULL, folder TEXT NOT NULL, uid INTEGER NOT NULL,
            message_id TEXT DEFAULT '', from_name TEXT DEFAULT '', from_email TEXT DEFAULT '', to_text TEXT DEFAULT '',
            subject TEXT DEFAULT '', date REAL NOT NULL, snippet TEXT DEFAULT '', body_text TEXT DEFAULT '', body_html TEXT DEFAULT '',
            attachments TEXT DEFAULT '', list_unsubscribe TEXT DEFAULT '', is_read INTEGER DEFAULT 0, ai_status INTEGER DEFAULT 0,
            category TEXT DEFAULT '', importance TEXT DEFAULT '', summary TEXT DEFAULT '', translation TEXT DEFAULT '',
            action TEXT DEFAULT '', reason TEXT DEFAULT '', language TEXT DEFAULT '', ai_error TEXT DEFAULT '',
            notified INTEGER DEFAULT 0, created_at REAL NOT NULL)
            """)
            try db.run("INSERT INTO messages (id, account_id, folder, uid, date, created_at, from_email) VALUES ('old', ?, 'INBOX', 1, 0, 0, 'Shop@Example.com')",
                       [.text(UUID().uuidString)])
        }
        let db = try Database(path: path)
        let m = try XCTUnwrap(db.message(id: "old"))
        XCTAssertEqual(m.headline, "")

        try db.saveSenderRule(SenderRule(email: "Shop@Example.com", category: "营销"))
        try db.applyCategory(.marketing, toSender: "shop@example.com")
        XCTAssertEqual(try db.senderRules().first?.email, "shop@example.com")
        XCTAssertEqual(try db.message(id: "old")?.category, "营销")

        try db.saveSenderRule(SenderRule(email: "shop@example.com"))
        XCTAssertTrue(try db.senderRules().isEmpty, "空规则应被删除")
    }
}

final class ModelListTests: XCTestCase {
    func testParseModelFormats() {
        XCTAssertEqual(AIClient.parseModels(["data": [["id": "b-model"], ["id": "a-model"], ["id": "a-model"]]]), ["a-model", "b-model"])
        XCTAssertEqual(AIClient.parseModels(["models": [["name": "qwen2.5:7b"]]]), ["qwen2.5:7b"])
        XCTAssertEqual(AIClient.parseModels(nil), [])
    }

    func testLiveModelList() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILMIND_NETWORK_TESTS"] == "1")
        let models = try await AIClient(baseURL: "https://openrouter.ai/api/v1", model: "", apiKey: "").listModels()
        print("OpenRouter: \(models.count) 个模型，例如 \(models.prefix(3).joined(separator: ", "))")
        XCTAssertGreaterThan(models.count, 10)
        do {
            _ = try await AIClient(baseURL: "https://api.xiaomimimo.com/v1", model: "", apiKey: "").listModels()
            print("MiMo: 无 Key 也返回了列表")
        } catch {
            print("MiMo 无 Key：\(error.localizedDescription)")
        }
    }
}

final class OAuthTests: XCTestCase {
    func testPKCEMatchesRFC7636Vector() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertGreaterThanOrEqual(PKCE().verifier.count, 43)
    }

    func testXOAUTH2Encoding() {
        let s = OAuthClient.xoauth2(user: "a@outlook.com", accessToken: "tok")
        XCTAssertEqual(String(decoding: Data(base64Encoded: s)!, as: UTF8.self), "user=a@outlook.com\u{01}auth=Bearer tok\u{01}\u{01}")
    }

    func testAuthorizeURL() {
        let c = OAuthConfig.microsoft(clientID: "cid")
        let url = OAuthClient.authorizeURL(c, pkce: PKCE(verifier: "v"), state: "s", loginHint: "a@outlook.com").absoluteString
        XCTAssertTrue(url.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"))
        for part in ["client_id=cid", "code_challenge_method=S256", "redirect_uri=mailmind://oauth", "login_hint=a@outlook.com", "IMAP.AccessAsUser.All"] {
            XCTAssertTrue(url.contains(part), part)
        }
    }

    func testTokenResponseParsing() throws {
        let claims = PKCE.base64URL(Data(#"{"preferred_username":"me@outlook.com"}"#.utf8))
        let body = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"id_token":"x.\#(claims).y"}"#
        let now = Date()
        let t = try OAuthClient.parseTokenResponse(Data(body.utf8), previousRefreshToken: nil, now: now)
        XCTAssertEqual(t.accessToken, "AT")
        XCTAssertEqual(t.refreshToken, "RT")
        XCTAssertEqual(t.email, "me@outlook.com")
        XCTAssertEqual(t.expiry.timeIntervalSince(now), 3600, accuracy: 1)

        // 刷新时服务器没返回新 refresh_token：沿用旧的
        let r = try OAuthClient.parseTokenResponse(Data(#"{"access_token":"AT2","expires_in":"60"}"#.utf8), previousRefreshToken: "OLD")
        XCTAssertEqual(r.refreshToken, "OLD")
        XCTAssertFalse(r.isFresh)

        XCTAssertThrowsError(try OAuthClient.parseTokenResponse(Data(#"{"error":"invalid_grant"}"#.utf8), previousRefreshToken: "OLD")) {
            guard case OAuthError.reauthRequired = $0 else { return XCTFail("应要求重新登录") }
        }
    }

    func testOldAccountJSONStillDecodes() throws {
        let old = #"[{"id":"7C9A6B0E-0000-4000-8000-000000000001","displayName":"a","email":"a@qq.com","username":"a@qq.com","host":"imap.qq.com","port":993,"useTLS":true,"enabled":true,"folders":["INBOX"]}]"#
        let accounts = try JSONDecoder().decode([MailAccount].self, from: Data(old.utf8))
        XCTAssertNil(accounts.first?.oauthProvider)
    }

    func testLiveMicrosoftRejectsUnknownClient() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILMIND_NETWORK_TESTS"] == "1")
        let c = OAuthConfig.microsoft(clientID: "00000000-0000-0000-0000-000000000000")
        do {
            _ = try await OAuthClient.refresh(OAuthTokens(accessToken: "", refreshToken: "bogus", expiry: .distantPast), config: c)
            XCTFail("不应成功")
        } catch {
            print("Microsoft 返回：\(error.localizedDescription.prefix(160))")
        }
    }
}

/// 用临时目录模拟「邮件」App 的数据结构（不读取任何真实邮件）。
final class AppleMailTests: XCTestCase {
    private var home: URL!
    private var inbox: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mailmind-applemail-\(UUID().uuidString)")
        let account = home.appendingPathComponent("Library/Mail/V10/0A1B2C3D-0000-4000-8000-00000000AAAA")
        inbox = account.appendingPathComponent("Inbox.mbox")
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("1F2E3D4C/Data/2/1/Messages"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mail/V9"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: account.appendingPathComponent("Sent Messages.mbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mail/V10/MailData"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func emlx(subject: String, read: Bool, to: String = "me@outlook.com") -> Data {
        let raw = Data("From: Boss <boss@corp.com>\r\nTo: \(to)\r\nSubject: \(subject)\r\nDate: Wed, 8 Oct 2026 10:00:00 +0800\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n你好，正文。\r\n".utf8)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>flags</key><integer>\(read ? 8590195713 : 8590195712)</integer></dict></plist>
        """
        var d = Data("\(raw.count)        \n".utf8)
        d.append(raw)
        d.append(Data(plist.utf8))
        return d
    }

    private func write(_ name: String, _ data: Data) throws {
        try data.write(to: inbox.appendingPathComponent("1F2E3D4C/Data/2/1/Messages/\(name)"))
    }

    func testParseEMLX() {
        let (raw, read) = AppleMailReader.parseEMLX(emlx(subject: "Hi", read: true))
        XCTAssertEqual(MIMEParser.parse(raw).subject, "Hi")
        XCTAssertTrue(read)
        XCTAssertFalse(AppleMailReader.parseEMLX(emlx(subject: "Hi", read: false)).isRead)
    }

    func testDiscoverAccountsAndDedupePartial() throws {
        try write("101.emlx", emlx(subject: "A", read: true))
        try write("102.partial.emlx", emlx(subject: "B", read: false))
        try write("103.partial.emlx", emlx(subject: "C-partial", read: false))
        try write("103.emlx", emlx(subject: "C-full", read: false))

        guard case .granted(let root) = AppleMailReader.access(home: home) else { return XCTFail("应能访问") }
        XCTAssertEqual(root.lastPathComponent, "V10", "应选择最新版本目录")

        let accounts = AppleMailReader.accounts(root: root)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.email, "me@outlook.com")
        XCTAssertEqual(accounts.first?.messageCount, 3)

        let files = AppleMailReader.messageFiles(in: inbox)
        let c = try XCTUnwrap(files.first { $0.number == 103 })
        XCTAssertFalse(c.url.lastPathComponent.contains("partial"), "同一封邮件应优先使用完整版")
    }

    func testAccessNotFound() {
        XCTAssertEqual(AppleMailReader.access(home: home.appendingPathComponent("nope")), .notFound)
    }

    func testIncrementalSyncIntoDatabase() throws {
        try write("201.emlx", emlx(subject: "第一封", read: true))
        let db = try Database(path: ":memory:")
        let account = MailAccount(displayName: "o", email: "me@outlook.com", username: "", host: "applemail", appleMailInbox: inbox.path)

        XCTAssertEqual(try SyncEngine.syncAppleMail(account: account, initialDays: 3, maxMessages: 100, db: db), 1)
        var list = try db.messages(filter: .account(account.id))
        XCTAssertEqual(list.map(\.subject), ["第一封"])
        XCTAssertTrue(list[0].isRead)

        // 新邮件到达：再次同步只会新增它（旧的即使重读也会被忽略）
        try write("202.emlx", emlx(subject: "第二封", read: false))
        _ = try SyncEngine.syncAppleMail(account: account, initialDays: 3, maxMessages: 100, db: db)
        list = try db.messages(filter: .account(account.id))
        XCTAssertEqual(Set(list.map(\.subject)), ["第一封", "第二封"])
    }

    func testForwardAliasFilter() throws {
        let db = try Database(path: ":memory:")
        var m = MailMessage(id: "x", accountID: UUID(), folder: "INBOX", uid: 1)
        m.to = "Me <Me@Outlook.com>"
        try db.insert(m)
        XCTAssertEqual(try db.messages(filter: .recipient("me@outlook.com")).count, 1)
        XCTAssertEqual(try db.messages(filter: .recipient("other@outlook.com")).count, 0)
    }
}


final class MailRuleTests: XCTestCase {
    private let qq = UUID(), work = UUID()

    private func mail(from: String, subject: String = "", account: UUID? = nil, code: String = "") -> MailMessage {
        var m = MailMessage(id: UUID().uuidString, accountID: account ?? qq, folder: "INBOX", uid: 1)
        m.fromEmail = from
        m.subject = subject
        m.code = code
        return m
    }

    func testMatching() {
        let exact = MailRule(sender: "News@Shop.com", category: "营销")
        XCTAssertTrue(exact.matches(mail(from: "news@shop.com")))
        XCTAssertFalse(exact.matches(mail(from: "other@shop.com")))

        let domain = MailRule(sender: "@shop.com", category: "垃圾")
        XCTAssertTrue(domain.matches(mail(from: "a@shop.com")))
        XCTAssertTrue(domain.matches(mail(from: "a@mail.shop.com")))
        XCTAssertFalse(domain.matches(mail(from: "a@myshop.com")), "不能误匹配相似域名")

        let keyword = MailRule(sender: "@shop.com", keywords: "促销，优惠券", category: "垃圾")
        XCTAssertTrue(keyword.matches(mail(from: "a@shop.com", subject: "双十一优惠券来了")))
        XCTAssertFalse(keyword.matches(mail(from: "a@shop.com", subject: "订单已发货")))
        XCTAssertTrue(keyword.matches(mail(from: "a@shop.com", subject: "通知"), text: "限时促销"))

        let scoped = MailRule(accountID: work, sender: "@shop.com", category: "垃圾")
        XCTAssertFalse(scoped.matches(mail(from: "a@shop.com", account: qq)), "只对指定邮箱生效")
        XCTAssertTrue(scoped.matches(mail(from: "a@shop.com", account: work)))

        var disabled = exact
        disabled.enabled = false
        XCTAssertFalse(disabled.matches(mail(from: "news@shop.com")))
        XCTAssertFalse(MailRule(category: "垃圾").isValid, "没有条件的规则无效")
        XCTAssertFalse(MailRule(sender: "a@b.com").isValid, "没有动作的规则无效")
    }

    func testMostSpecificRuleWins() {
        let older = Date(timeIntervalSince1970: 0)
        let rules = [
            MailRule(sender: "@shop.com", category: "垃圾", createdAt: older),
            MailRule(sender: "orders@shop.com", category: "通知", createdAt: older),
            MailRule(accountID: work, sender: "@shop.com", category: "工作", createdAt: older),
        ]
        XCTAssertEqual(MailRule.firstMatch(rules, for: mail(from: "promo@shop.com"))?.category, "垃圾")
        XCTAssertEqual(MailRule.firstMatch(rules, for: mail(from: "orders@shop.com"))?.category, "通知")
        XCTAssertEqual(MailRule.firstMatch(rules, for: mail(from: "orders@shop.com", account: work))?.category, "工作")
    }

    func testApplyCategoryAdjustsImportance() {
        var a = AIAnalysis(category: "工作", importance: .high, language: "zh", summary: "", translation: "", action: "", reason: "",
                           notify: .urgent)
        a.apply(category: .spam)
        XCTAssertEqual(a.importance, .low)
        XCTAssertEqual(a.notify, .none)
        a.apply(category: .important)
        XCTAssertEqual(a.importance, .high)
        XCTAssertEqual(a.notify, .normal)
    }

    func testExamplesInPrompt() throws {
        var o = AnalysisOptions(translate: false, targetLanguage: "简体中文", customRules: "")
        XCTAssertFalse(Classifier.systemPrompt(o).contains("手动纠正"))
        let db = try Database(path: ":memory:")
        try db.addExample(accountID: nil, fromEmail: "Promo@Shop.com", subject: "会员日", category: "垃圾")
        try db.addExample(accountID: nil, fromEmail: "promo@shop.com", subject: "会员日", category: "营销")
        let examples = try db.examples()
        XCTAssertEqual(examples.count, 1, "同一发件人 + 主题只保留最新一条")
        XCTAssertEqual(examples[0].category, "营销")
        o.examples = examples.map(\.promptLine)
        let prompt = Classifier.systemPrompt(o)
        XCTAssertTrue(prompt.contains("promo@shop.com"))
        XCTAssertTrue(prompt.contains("→ 营销"))
    }
}

final class DeletionTests: XCTestCase {
    func testDeletedMessagesAreHiddenAndNotResynced() throws {
        let db = try Database(path: ":memory:")
        let account = UUID()
        var m = MailMessage(id: "\(account.uuidString):INBOX:777:42", accountID: account, folder: "INBOX", uid: 42)
        m.category = ""
        m.bodyText = "正文"
        try db.insert(m)
        try db.setCategory(id: m.id, category: .spam)
        XCTAssertEqual(try db.messages(filter: .category("垃圾")).count, 1)

        let targets = try db.deletionTargets(ids: [m.id])
        XCTAssertEqual(targets, [Database.DeletionTarget(id: m.id, accountID: account, folder: "INBOX", uid: 42, uidValidity: 777)])

        try db.markDeleted(ids: [m.id])
        XCTAssertTrue(try db.messages(filter: .category("垃圾")).isEmpty)
        XCTAssertTrue(try db.messages(filter: .account(account)).isEmpty)
        XCTAssertEqual(try db.body(id: m.id).text, "", "正文应被清空")
        XCTAssertNil(try db.unreadCounts()["垃圾"])

        // 再次同步到同一封邮件时不应重新出现
        try db.insert(m)
        XCTAssertTrue(try db.messages(filter: .account(account)).isEmpty)
    }

    func testParseListAndFindTrash() {
        func list(_ line: String, literal: String? = nil) -> IMAPClient.FolderEntry? {
            IMAPClient.parseList(IMAPResponse(text: line, literals: literal.map { [Data($0.utf8)] } ?? []))
        }
        XCTAssertEqual(list(#"* LIST (\HasNoChildren \Trash) "/" "Deleted Messages""#),
                       IMAPClient.FolderEntry(name: "Deleted Messages", attributes: ["\\HasNoChildren", "\\Trash"]))
        XCTAssertEqual(list(#"* LIST (\HasNoChildren) "/" INBOX"#)?.name, "INBOX")
        XCTAssertEqual(list(#"* LIST () NIL "&XfJSIJZk-""#)?.name, "&XfJSIJZk-")
        XCTAssertEqual(list(#"* LIST () "/" {9}"#, literal: "Junk Mail")?.name, "Junk Mail")
        XCTAssertNil(list("* OK done"))

        // 有 \Trash 标记时优先
        XCTAssertEqual(IMAPClient.trashFolder(in: [
            .init(name: "Trash", attributes: []),
            .init(name: "[Gmail]/Bin", attributes: ["\\HasNoChildren", "\\Trash"]),
        ]), "[Gmail]/Bin")
        // 163：没有 SPECIAL-USE，按中文名（修改版 UTF-7）识别
        XCTAssertEqual(IMAPClient.trashFolder(in: [.init(name: "INBOX", attributes: []), .init(name: "&XfJSIJZk-", attributes: [])]), "&XfJSIJZk-")
        XCTAssertNil(IMAPClient.trashFolder(in: [.init(name: "INBOX", attributes: [])]))
    }

    func testTrashCommands() {
        XCTAssertEqual(IMAPClient.trashCommands(uids: [9, 3], trash: "Trash", capabilities: ["MOVE"]),
                       [#"UID MOVE 3,9 "Trash""#])
        XCTAssertEqual(IMAPClient.trashCommands(uids: [3], trash: "Trash", capabilities: ["UIDPLUS"]),
                       [#"UID COPY 3 "Trash""#, #"UID STORE 3 +FLAGS.SILENT (\Deleted)"#, "UID EXPUNGE 3"])
        XCTAssertEqual(IMAPClient.trashCommands(uids: [3], trash: "Trash", capabilities: []),
                       [#"UID COPY 3 "Trash""#, #"UID STORE 3 +FLAGS.SILENT (\Deleted)"#], "不支持 UIDPLUS 时不执行 EXPUNGE")
        XCTAssertEqual(IMAPClient.trashCommands(uids: [3], trash: nil, capabilities: ["MOVE"]),
                       [#"UID STORE 3 +FLAGS.SILENT (\Deleted)"#])
    }
}

final class ForwarderTests: XCTestCase {
    private var sample: MailMessage {
        var m = MailMessage(id: "acc:INBOX:1:5", accountID: UUID(), folder: "INBOX", uid: 5)
        m.fromName = "王经理"
        m.fromEmail = "wang@corp.com"
        m.subject = "Q4 预算"
        m.headline = "王经理：周五前确认 Q4 预算表"
        m.summary = "需要确认预算。"
        m.action = "确认预算表"
        m.deadline = "2026-10-16"
        return m
    }

    private func json(_ r: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
    }

    func testText() {
        let t = Forwarder.text(for: sample, accountName: "工作邮箱")
        XCTAssertTrue(t.hasPrefix("📬 王经理：周五前确认 Q4 预算表"))
        XCTAssertTrue(t.contains("王经理 <wang@corp.com>"))
        XCTAssertTrue(t.contains("待办：确认预算表（2026-10-16 前）"))
        XCTAssertTrue(t.contains("工作邮箱"))
        var code = sample
        code.code = "482913"
        XCTAssertTrue(Forwarder.text(for: code, accountName: nil).contains("验证码：482913"))
    }

    func testTelegramRequest() throws {
        var c = ForwardChannel.new(.telegram)
        XCTAssertThrowsError(try Forwarder.request(for: c, secret: "", text: "x", message: nil, idempotencyKey: "k"))
        c.chatID = "12345"
        let r = try Forwarder.request(for: c, secret: "123:ABC", text: "hello", message: nil, idempotencyKey: "k")
        XCTAssertEqual(r.url?.absoluteString, "https://api.telegram.org/bot123:ABC/sendMessage")
        XCTAssertEqual(try json(r)["chat_id"] as? String, "12345")
        XCTAssertEqual(try json(r)["text"] as? String, "hello")
        XCTAssertThrowsError(try Forwarder.telegramURL(token: "../x", method: "getMe"))
    }

    func testOpenClawRequest() throws {
        var c = ForwardChannel.new(.openclaw)
        c.to = "wxid_abc"
        let r = try Forwarder.request(for: c, secret: "tok", text: "hello", message: nil, idempotencyKey: "acc:INBOX:1:5")
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:18789/hooks/agent")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Idempotency-Key"), "acc:INBOX:1:5")
        let body = try json(r)
        XCTAssertEqual(body["channel"] as? String, "openclaw-weixin")
        XCTAssertEqual(body["to"] as? String, "wxid_abc")
        XCTAssertEqual(body["deliver"] as? Bool, true)
        XCTAssertTrue((body["message"] as? String)?.contains("hello") == true)
        XCTAssertNil(body["agentId"])

        // 只填频道不填接收人：两者都不发送（OpenClaw 要求同时提供）
        c.to = ""
        XCTAssertNil(try json(Forwarder.request(for: c, secret: "tok", text: "x", message: nil, idempotencyKey: "k"))["channel"])
    }

    func testWebhookFormats() throws {
        var c = ForwardChannel.new(.webhook)
        c.url = "https://example.com/hook"
        let generic = try json(Forwarder.request(for: c, secret: "", text: "hi", message: sample, idempotencyKey: "k"))
        XCTAssertEqual(generic["event"] as? String, "mail.important")
        XCTAssertEqual((generic["mail"] as? [String: Any])?["headline"] as? String, sample.headline)

        c.webhookFormat = .wecom
        XCTAssertEqual(try json(Forwarder.request(for: c, secret: "", text: "hi", message: nil, idempotencyKey: "k"))["msgtype"] as? String, "text")
        c.webhookFormat = .feishu
        XCTAssertEqual(try json(Forwarder.request(for: c, secret: "", text: "hi", message: nil, idempotencyKey: "k"))["msg_type"] as? String, "text")
        c.url = "not a url"
        XCTAssertThrowsError(try Forwarder.request(for: c, secret: "", text: "hi", message: nil, idempotencyKey: "k"))
    }

    func testBodyErrors() {
        var c = ForwardChannel.new(.webhook)
        c.webhookFormat = .wecom
        XCTAssertThrowsError(try Forwarder.checkBody(c, data: Data(#"{"errcode":93000,"errmsg":"invalid webhook url"}"#.utf8)))
        XCTAssertNoThrow(try Forwarder.checkBody(c, data: Data(#"{"errcode":0,"errmsg":"ok"}"#.utf8)))
        XCTAssertThrowsError(try Forwarder.checkBody(.new(.telegram), data: Data(#"{"ok":false,"description":"chat not found"}"#.utf8)))
    }

    func testParseTelegramChats() {
        let data = Data("""
        {"ok":true,"result":[
          {"update_id":1,"message":{"chat":{"id":111,"first_name":"Lu","type":"private"},"text":"hi"}},
          {"update_id":2,"message":{"chat":{"id":-100222,"title":"家庭群","type":"supergroup"},"text":"x"}},
          {"update_id":3,"message":{"chat":{"id":111,"first_name":"Lu","type":"private"},"text":"again"}}
        ]}
        """.utf8)
        XCTAssertEqual(Forwarder.parseTelegramChats(data), [
            .init(id: "111", title: "Lu"),
            .init(id: "-100222", title: "家庭群"),
        ])
    }

    func testChannelFilter() {
        var c = ForwardChannel.new(.telegram)
        var m = sample
        XCTAssertTrue(c.accepts(m))
        c.accountIDs = [UUID()]
        XCTAssertFalse(c.accepts(m), "不在所选邮箱中")
        c.accountIDs = [m.accountID]
        c.includeCodes = false
        m.code = "1234"
        XCTAssertFalse(c.accepts(m))
        c.enabled = false
        m.code = ""
        XCTAssertFalse(c.accepts(m))
    }
}
