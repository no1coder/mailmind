import Foundation

/// 把 IMAP 服务器上的新邮件拉到本地数据库。
enum SyncEngine {
    static let maxFetchBytes = 512 * 1024

    /// 同步一个账户，返回新增邮件数。
    static func sync(account: MailAccount, credential: IMAPCredential, initialDays: Int, maxMessages: Int, db: Database) async throws -> Int {
        let client = IMAPClient(host: account.host, port: account.port, useTLS: account.useTLS)
        do {
            try await client.connect(username: account.username, credential: credential)
            var total = 0
            for folder in account.folders {
                total += try await syncFolder(folder, account: account, client: client, initialDays: initialDays, maxMessages: maxMessages, db: db)
            }
            await client.logout()
            return total
        } catch {
            await client.logout()
            throw error
        }
    }

    private static func syncFolder(_ folder: String, account: MailAccount, client: IMAPClient, initialDays: Int, maxMessages: Int, db: Database) async throws -> Int {
        let info = try await client.examine(folder)
        let state = try db.syncState(accountID: account.id, folder: folder)

        var uids: [UInt32]
        var lastUID: UInt32
        if let state, state.uidValidity == info.uidValidity {
            uids = try await client.searchUIDs(after: state.lastUID)
            lastUID = state.lastUID
        } else {
            // 首次同步（或文件夹被重建）：只取最近几天的邮件，避免把整个历史邮箱交给 AI。
            let since = Calendar.current.date(byAdding: .day, value: -max(1, initialDays), to: Date()) ?? Date()
            uids = try await client.searchUIDs(since: since)
            lastUID = (info.uidNext ?? 1) - 1
        }
        uids.sort()
        if uids.count > maxMessages { uids = Array(uids.suffix(maxMessages)) }

        var inserted = 0
        for chunk in uids.chunked(20) {
            for fetched in try await client.fetch(uids: chunk, maxBytes: maxFetchBytes) {
                let message = makeMessage(fetched, account: account, folder: folder, uidValidity: info.uidValidity)
                try db.insert(message)
                inserted += 1
            }
            lastUID = max(lastUID, chunk.max() ?? 0)
            try db.setSyncState(accountID: account.id, folder: folder, uidValidity: info.uidValidity, lastUID: lastUID)
        }
        try db.setSyncState(accountID: account.id, folder: folder, uidValidity: info.uidValidity, lastUID: lastUID)
        return inserted
    }

    static func makeMessage(_ fetched: IMAPFetchedMessage, account: MailAccount, folder: String, uidValidity: UInt32) -> MailMessage {
        let parsed = MIMEParser.parse(fetched.raw)
        let text = parsed.bestText
        var m = MailMessage(
            id: "\(account.id.uuidString):\(folder):\(uidValidity):\(fetched.uid)",
            accountID: account.id,
            folder: folder,
            uid: fetched.uid
        )
        m.messageID = parsed.messageID
        m.fromName = parsed.fromName
        m.fromEmail = parsed.fromEmail
        m.to = parsed.to
        m.subject = parsed.subject.isEmpty ? "（无主题）" : parsed.subject
        m.date = parsed.date ?? fetched.internalDate ?? Date()
        m.bodyText = String(text.prefix(100_000))
        m.bodyHTML = String(parsed.htmlBody.prefix(500_000))
        m.snippet = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
        m.attachments = parsed.attachments
        m.listUnsubscribe = parsed.listUnsubscribe
        m.isRead = fetched.flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
        return m
    }

    /// 从「邮件」App 的本地文件同步。sync_state 的 last_uid 记录已读取到的最新修改时间（秒）。
    static func syncAppleMail(account: MailAccount, initialDays: Int, maxMessages: Int, db: Database) throws -> Int {
        guard let path = account.appleMailInbox else { return 0 }
        let inbox = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: inbox.path) else { throw AppleMailReader.ReadError.inboxMissing(path) }
        // 没有「完全磁盘访问权限」时目录存在但无法列出内容
        guard (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) != nil else { throw AppleMailReader.ReadError.accessDenied }

        let folder = "applemail"
        let state = try db.syncState(accountID: account.id, folder: folder)
        // 留 2 分钟余量，避免和「邮件」App 同时写入时漏掉；重复的会被 INSERT OR IGNORE 忽略
        let since = state.map { Date(timeIntervalSince1970: TimeInterval($0.lastUID) - 120) }
            ?? Calendar.current.date(byAdding: .day, value: -max(1, initialDays), to: Date())!
        var files = AppleMailReader.messageFiles(in: inbox, modifiedAfter: since)
        if files.count > maxMessages { files = Array(files.suffix(maxMessages)) }

        var latest = state?.lastUID ?? UInt32(since.timeIntervalSince1970)
        for f in files {
            guard let data = try? Data(contentsOf: f.url, options: .mappedIfSafe) else { continue }
            let (raw, isRead) = AppleMailReader.parseEMLX(data)
            let fetched = IMAPFetchedMessage(uid: f.number, flags: isRead ? ["\\Seen"] : [], internalDate: f.modified, raw: raw)
            try db.insert(makeMessage(fetched, account: account, folder: folder, uidValidity: 0))
            latest = max(latest, UInt32(clamping: Int(f.modified.timeIntervalSince1970)))
        }
        try db.setSyncState(accountID: account.id, folder: folder, uidValidity: 0, lastUID: latest)
        return files.count
    }

    /// 测试账户能否连接，返回收件箱邮件数。
    static func test(account: MailAccount, password: String) async throws -> Int {
        try await test(account: account, credential: .password(password))
    }

    static func test(account: MailAccount, credential: IMAPCredential) async throws -> Int {
        let client = IMAPClient(host: account.host, port: account.port, useTLS: account.useTLS)
        do {
            try await client.connect(username: account.username, credential: credential)
            let info = try await client.examine(account.folders.first ?? "INBOX")
            await client.logout()
            return info.exists
        } catch {
            await client.logout()
            throw error
        }
    }
}
