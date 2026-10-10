import XCTest
@testable import MailMind

final class MIMEParserTests: XCTestCase {
    func testEncodedWordUTF8Base64() {
        XCTAssertEqual(MIMEParser.decodeEncodedWords("=?UTF-8?B?5L2g5aW95LiW55WM?="), "你好世界")
    }

    func testEncodedWordGBKSplitAcrossWords() {
        // "会议通知" 的 GBK 字节被拆成两个编码词，且第二个字被拆在边界上。
        let gbk = "会议通知".data(using: MIMEParser.gb18030)!
        let a = gbk.prefix(3).base64EncodedString()
        let b = gbk.dropFirst(3).base64EncodedString()
        let header = "=?gb2312?B?\(a)?=\r\n =?gb2312?B?\(b)?="
        XCTAssertEqual(MIMEParser.decodeEncodedWords(header), "会议通知")
    }

    func testEncodedWordQuotedPrintableAndPlainText() {
        XCTAssertEqual(MIMEParser.decodeEncodedWords("Re: =?utf-8?Q?caf=C3=A9_time?= today"), "Re: café time today")
    }

    func testAddressParsing() {
        let a = MIMEParser.parseAddress("\"张三\" <zhangsan@example.com>")
        XCTAssertEqual(a.name, "张三")
        XCTAssertEqual(a.email, "zhangsan@example.com")
        XCTAssertEqual(MIMEParser.parseAddress("bob@example.com").email, "bob@example.com")
    }

    func testDateParsing() {
        XCTAssertNotNil(MIMEParser.parseDate("Wed, 8 Oct 2026 10:30:00 +0800"))
        XCTAssertNotNil(MIMEParser.parseDate("Wed, 08 Oct 2026 10:30:00 +0800 (CST)"))
        XCTAssertNotNil(MIMEParser.parseDate("08-Oct-2026 10:30:00 +0800"))
    }

    func testMultipartAlternativeWithBase64HTMLAndAttachment() {
        let html = "<html><body><p>Hello <b>World</b></p><p>A &amp; B</p></body></html>"
        let raw = """
        From: =?UTF-8?B?5byg5LiJ?= <zs@example.com>\r
        To: me@example.com\r
        Subject: =?UTF-8?B?5rWL6K+V?=\r
        Date: Wed, 8 Oct 2026 10:30:00 +0800\r
        List-Unsubscribe: <https://example.com/unsub>\r
        Content-Type: multipart/mixed; boundary="OUTER"\r
        \r
        --OUTER\r
        Content-Type: multipart/alternative; boundary=INNER\r
        \r
        --INNER\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(Data(html.utf8).base64EncodedString(options: .lineLength76Characters))\r
        --INNER--\r
        --OUTER\r
        Content-Type: application/pdf; name="=?UTF-8?B?5oql5Lu3LnBkZg==?="\r
        Content-Disposition: attachment; filename*=UTF-8''%E6%8A%A5%E4%BB%B7.pdf\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0=\r
        --OUTER--\r

        """
        let mail = MIMEParser.parse(Data(raw.utf8))
        XCTAssertEqual(mail.subject, "测试")
        XCTAssertEqual(mail.fromName, "张三")
        XCTAssertEqual(mail.fromEmail, "zs@example.com")
        XCTAssertNotNil(mail.date)
        XCTAssertEqual(mail.listUnsubscribe, "<https://example.com/unsub>")
        XCTAssertTrue(mail.htmlBody.contains("<b>World</b>"))
        XCTAssertEqual(mail.bestText, "Hello World\nA & B")
        XCTAssertEqual(mail.attachments, ["报价.pdf"])
    }

    func testGBKQuotedPrintableBody() {
        let body = "你好，请查收附件。".data(using: MIMEParser.gb18030)!
        let qp = body.map { String(format: "=%02X", $0) }.joined()
        let raw = "Subject: hi\r\nContent-Type: text/plain; charset=GBK\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n\(qp)\r\n"
        XCTAssertEqual(MIMEParser.parse(Data(raw.utf8)).textBody.trimmed, "你好，请查收附件。")
    }

    func testTruncatedMessageDoesNotCrash() {
        let raw = "Subject: x\r\nContent-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\nContent-Type: text/plain\r\n\r\n截断的正文"
        let data = Data(raw.utf8).dropLast(2) // 切断最后一个汉字的 UTF-8 字节
        let mail = MIMEParser.parse(Data(data))
        XCTAssertTrue(mail.textBody.hasPrefix("截断的正"))
    }

    func testHTMLToTextStripsStyleAndScript() {
        let html = "<style>p{color:red}</style><script>alert(1)</script><div>第一行</div><br>第二行&nbsp;&#x4E09;"
        XCTAssertEqual(MIMEParser.htmlToText(html), "第一行\n\n第二行 三")
    }
}

final class IMAPParsingTests: XCTestCase {
    func testLiteralLength() {
        XCTAssertEqual(IMAPClient.literalLength("* 1 FETCH (UID 5 BODY[]<0> {1234}"), 1234)
        XCTAssertEqual(IMAPClient.literalLength("A001 LOGIN {5+}"), 5)
        XCTAssertNil(IMAPClient.literalLength("* OK [UIDVALIDITY 3]"))
    }
}

final class ClassifierTests: XCTestCase {
    func testParseTolerantJSON() throws {
        let reply = """
        ```json
        {"category": "账单", "importance": "HIGH", "language": "en", "summary": "信用卡账单到期", "translation": "译文", "action": "10 月 15 日前还款", "reason": "账单到期"}
        ```
        """
        let a = try Classifier.parse(reply)
        XCTAssertEqual(a.category, "账单")
        XCTAssertEqual(a.importance, .high)
        XCTAssertEqual(a.action, "10 月 15 日前还款")
    }

    func testUnknownCategoryFallsBack() throws {
        let a = try Classifier.parse(#"{"category": "Shopping", "importance": "low"}"#)
        XCTAssertEqual(a.category, MailCategory.notification.rawValue)
        XCTAssertEqual(a.importance, .low)
    }

    func testThinkingIsStripped() {
        XCTAssertEqual(AIClient.stripThinking("<think>hmm</think>\n{\"a\":1}"), "{\"a\":1}")
    }

    func testCustomRulesInPrompt() {
        let p = Classifier.systemPrompt(AnalysisOptions(targetLanguage: "简体中文", customRules: "老板的邮件都重要"))
        XCTAssertTrue(p.contains("老板的邮件都重要"))
    }
}

final class DatabaseTests: XCTestCase {
    func testInsertFilterAndAnalysis() throws {
        let db = try Database(path: ":memory:")
        let account = UUID()
        var m = MailMessage(id: "a:INBOX:1:1", accountID: account, folder: "INBOX", uid: 1)
        m.subject = "Invoice"
        m.bodyText = "Please pay"
        try db.insert(m)
        try db.insert(m) // 重复插入被忽略

        XCTAssertEqual(try db.pendingAIMessages(limit: 10).first?.bodyText, "Please pay")
        try db.saveAnalysis(id: m.id, AIAnalysis(category: "账单", importance: .high, language: "en",
                                                  summary: "发票", action: "付款", reason: ""))
        XCTAssertEqual(try db.messages(filter: .important).count, 1)
        XCTAssertEqual(try db.messages(filter: .actionNeeded).count, 1)
        XCTAssertEqual(try db.messages(filter: .all, search: "Invoice").count, 1)
        XCTAssertEqual(try db.unreadCounts()["@important"], 1)

        try db.setCategory(id: m.id, category: .spam)
        XCTAssertEqual(try db.messages(filter: .all).count, 0)
        XCTAssertEqual(try db.messages(filter: .category("垃圾")).count, 1)
    }
}

/// 真实网络测试，默认跳过：MAILMIND_NETWORK_TESTS=1 swift test
final class IMAPNetworkTests: XCTestCase {
    func testBadCredentialsYieldLoginFailed() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILMIND_NETWORK_TESTS"] == "1")
        for host in ["imap.qq.com", "imap.163.com", "imap.gmail.com"] {
            let client = IMAPClient(host: host, port: 993, useTLS: true)
            do {
                try await client.connect(username: "mailmind-test-nobody@example.com", password: "wrong")
                XCTFail("\(host): 不应登录成功")
            } catch IMAPError.loginFailed(let msg) {
                print("✓ \(host): \(msg)")
            } catch {
                print("? \(host): \(error.localizedDescription)")
            }
            await client.logout()
        }
    }
}

extension IMAPNetworkTests {
    func testISPDBAndCapabilities() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILMIND_NETWORK_TESTS"] == "1")
        for domain in ["gmx.com", "yandex.com", "zoho.com"] {
            let s = await AccountDiscovery.lookupISPDB(domain: domain)
            print("ISPDB \(domain): \(s.map { "\($0.host):\($0.port) tls=\($0.useTLS)" } ?? "未找到")")
        }
        for host in ["imap.qq.com", "imap.163.com", "imap.gmail.com", "imap.mail.me.com"] {
            let c = IMAPClient(host: host, port: 993, useTLS: true)
            let conn = try? await { () async throws -> Set<String> in
                try await c.connectWithoutLogin()
                return try await c.capabilities()
            }()
            print("CAP \(host): IDLE=\(conn?.contains("IDLE") ?? false) \(conn.map { Array($0).sorted().prefix(8).joined(separator: " ") } ?? "连接失败")")
            await c.logout()
        }
    }
}
