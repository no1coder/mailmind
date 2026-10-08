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
        p.mutedSenders = ["boss@corp.com"]
        XCTAssertEqual(p.decide(mail(.urgent, from: "Boss@Corp.com"), now: now), .none, "静音（大小写不敏感）")
        p.enabled = false
        XCTAssertEqual(p.decide(mail(.urgent, from: "x@y.com"), now: now), .none)
    }

    func testQuietHoursDowngradeButVIPAndCodesStillRing() {
        var p = NotificationPolicy(quietHoursEnabled: true, quietStart: 22 * 60, quietEnd: 8 * 60)
        XCTAssertEqual(p.decide(mail(.urgent, relativeTo: night), now: night), .silent)
        XCTAssertEqual(p.decide(mail(.none, code: "123456", relativeTo: night), now: night), .alert)
        XCTAssertEqual(p.decide(mail(.none, code: "123456", age: 3600, relativeTo: night), now: night), .none, "过期验证码")
        p.vipSenders = ["boss@corp.com"]
        XCTAssertEqual(p.decide(mail(.none, relativeTo: night), now: night), .alert)
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
