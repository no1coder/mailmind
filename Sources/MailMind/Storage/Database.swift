import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

struct DatabaseError: LocalizedError {
    var message: String
    var errorDescription: String? { "数据库错误：\(message)" }
}

struct SQLRow {
    fileprivate let stmt: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
}

/// 本地邮件库。SQLite 句柄以 FULLMUTEX 打开，并额外加锁，可在任意线程调用。
final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    static let shared: Database = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            return try Database(path: dir.appendingPathComponent("mailmind.sqlite").path)
        } catch {
            fatalError("无法打开数据库：\(error)")
        }
    }()

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw DatabaseError(message: "无法打开 \(path)")
        }
        try run("PRAGMA journal_mode=WAL")
        try migrate()
    }

    deinit { sqlite3_close(handle) }

    private func migrate() throws {
        try run("""
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid INTEGER NOT NULL,
            message_id TEXT DEFAULT '',
            from_name TEXT DEFAULT '',
            from_email TEXT DEFAULT '',
            to_text TEXT DEFAULT '',
            subject TEXT DEFAULT '',
            date REAL NOT NULL,
            snippet TEXT DEFAULT '',
            body_text TEXT DEFAULT '',
            body_html TEXT DEFAULT '',
            attachments TEXT DEFAULT '',
            list_unsubscribe TEXT DEFAULT '',
            is_read INTEGER DEFAULT 0,
            ai_status INTEGER DEFAULT 0,
            category TEXT DEFAULT '',
            importance TEXT DEFAULT '',
            summary TEXT DEFAULT '',
            translation TEXT DEFAULT '',
            action TEXT DEFAULT '',
            reason TEXT DEFAULT '',
            language TEXT DEFAULT '',
            ai_error TEXT DEFAULT '',
            notified INTEGER DEFAULT 0,
            created_at REAL NOT NULL
        )
        """)
        // v0.2：一句话标题、提醒级别、截止日期、验证码
        let columns = Set(try query("PRAGMA table_info(messages)") { $0.text(1) })
        for name in ["headline", "notify_level", "deadline", "code"] where !columns.contains(name) {
            try run("ALTER TABLE messages ADD COLUMN \(name) TEXT DEFAULT ''")
        }
        try run("""
        CREATE TABLE IF NOT EXISTS senders (
            email TEXT PRIMARY KEY,
            category TEXT DEFAULT '',
            vip INTEGER DEFAULT 0,
            muted INTEGER DEFAULT 0
        )
        """)
        try run("CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(date DESC)")
        try run("CREATE INDEX IF NOT EXISTS idx_messages_account ON messages(account_id)")
        try run("CREATE INDEX IF NOT EXISTS idx_messages_ai ON messages(ai_status)")
        try run("""
        CREATE TABLE IF NOT EXISTS sync_state (
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid_validity INTEGER NOT NULL,
            last_uid INTEGER NOT NULL,
            PRIMARY KEY (account_id, folder)
        )
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS digests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            period_start REAL NOT NULL,
            period_end REAL NOT NULL,
            message_count INTEGER NOT NULL,
            content TEXT NOT NULL
        )
        """)
    }

    // MARK: - 底层

    func run(_ sql: String, _ args: [SQLValue] = []) throws {
        try withStatement(sql, args) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
        }
    }

    func query<T>(_ sql: String, _ args: [SQLValue] = [], map: (SQLRow) -> T) throws -> [T] {
        try withStatement(sql, args) { stmt in
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { out.append(map(SQLRow(stmt: stmt))) }
                else if rc == SQLITE_DONE { return out }
                else { throw lastError() }
            }
        }
    }

    private func withStatement<T>(_ sql: String, _ args: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return try body(stmt)
    }

    private func lastError() -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
    }

    // MARK: - 邮件

    private static let listColumns = """
    id, account_id, folder, uid, message_id, from_name, from_email, to_text, subject, date, snippet,
    attachments, list_unsubscribe, is_read, ai_status, category, importance, summary, translation,
    action, reason, language, ai_error, notified, headline, notify_level, deadline, code
    """
    private static let listColumnCount: Int32 = 28

    private static func mapMessage(_ r: SQLRow) -> MailMessage {
        var m = MailMessage(
            id: r.text(0),
            accountID: UUID(uuidString: r.text(1)) ?? UUID(),
            folder: r.text(2),
            uid: UInt32(truncatingIfNeeded: r.int(3))
        )
        m.messageID = r.text(4)
        m.fromName = r.text(5)
        m.fromEmail = r.text(6)
        m.to = r.text(7)
        m.subject = r.text(8)
        m.date = Date(timeIntervalSince1970: r.double(9))
        m.snippet = r.text(10)
        let att = r.text(11)
        m.attachments = att.isEmpty ? [] : att.components(separatedBy: "\n")
        m.listUnsubscribe = r.text(12)
        m.isRead = r.int(13) != 0
        m.aiStatus = AIStatus(rawValue: Int(r.int(14))) ?? .pending
        m.category = r.text(15)
        m.importance = Importance(rawValue: r.text(16))
        m.summary = r.text(17)
        m.translation = r.text(18)
        m.action = r.text(19)
        m.reason = r.text(20)
        m.language = r.text(21)
        m.aiError = r.text(22)
        m.notified = r.int(23) != 0
        m.headline = r.text(24)
        m.notifyLevel = r.text(25)
        m.deadline = r.text(26)
        m.code = r.text(27)
        return m
    }

    func insert(_ m: MailMessage) throws {
        try run("""
        INSERT OR IGNORE INTO messages (id, account_id, folder, uid, message_id, from_name, from_email, to_text,
            subject, date, snippet, body_text, body_html, attachments, list_unsubscribe, is_read, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(m.id), .text(m.accountID.uuidString), .text(m.folder), .int(Int64(m.uid)),
            .text(m.messageID), .text(m.fromName), .text(m.fromEmail), .text(m.to),
            .text(m.subject), .double(m.date.timeIntervalSince1970), .text(m.snippet),
            .text(m.bodyText), .text(m.bodyHTML), .text(m.attachments.joined(separator: "\n")),
            .text(m.listUnsubscribe), .int(m.isRead ? 1 : 0), .double(Date().timeIntervalSince1970),
        ])
    }

    enum Filter: Equatable {
        case all
        case important
        case actionNeeded
        case category(String)
        case account(UUID)
        /// 原收件人包含该地址（用于转发来源）
        case recipient(String)
    }

    func messages(filter: Filter, search: String = "", limit: Int = 500) throws -> [MailMessage] {
        let (whereClause, args) = Self.whereClause(filter: filter, search: search)
        return try query("SELECT \(Self.listColumns) FROM messages \(whereClause) ORDER BY date DESC LIMIT \(limit)", args, map: Self.mapMessage)
    }

    func markAllRead(filter: Filter, search: String = "") throws {
        let (whereClause, args) = Self.whereClause(filter: filter, search: search)
        try run("UPDATE messages SET is_read = 1 \(whereClause)", args)
    }

    private static func whereClause(filter: Filter, search: String) -> (String, [SQLValue]) {
        var conditions: [String] = []
        var args: [SQLValue] = []
        switch filter {
        case .all:
            conditions.append("category != '垃圾'")
        case .important:
            conditions.append("importance = 'high' AND category != '垃圾'")
        case .actionNeeded:
            conditions.append("action != '' AND category != '垃圾'")
        case .category(let c):
            conditions.append("category = ?")
            args.append(.text(c))
        case .account(let id):
            conditions.append("account_id = ?")
            args.append(.text(id.uuidString))
        case .recipient(let address):
            conditions.append("lower(to_text) LIKE ?")
            args.append(.text("%\(address.lowercased())%"))
        }
        let q = search.trimmed
        if !q.isEmpty {
            conditions.append("(subject LIKE ? OR from_name LIKE ? OR from_email LIKE ? OR summary LIKE ? OR snippet LIKE ?)")
            args += Array(repeating: .text("%\(q)%"), count: 5)
        }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), args)
    }

    /// 「问 AI」用的近期邮件索引（不含垃圾邮件）。
    func recentMessages(since: Date, limit: Int) throws -> [MailMessage] {
        try query("SELECT \(Self.listColumns) FROM messages WHERE date >= ? AND category != '垃圾' ORDER BY date DESC LIMIT \(limit)",
                  [.double(since.timeIntervalSince1970)], map: Self.mapMessage)
    }

    func message(id: String) throws -> MailMessage? {
        try query("SELECT \(Self.listColumns) FROM messages WHERE id = ?", [.text(id)], map: Self.mapMessage).first
    }

    func body(id: String) throws -> (text: String, html: String) {
        try query("SELECT body_text, body_html FROM messages WHERE id = ?", [.text(id)]) { ($0.text(0), $0.text(1)) }.first ?? ("", "")
    }

    func pendingAIMessages(limit: Int) throws -> [MailMessage] {
        let rows = try query("SELECT \(Self.listColumns), body_text FROM messages WHERE ai_status = 0 ORDER BY date DESC LIMIT \(limit)") { r -> MailMessage in
            var m = Self.mapMessage(r)
            m.bodyText = r.text(Self.listColumnCount)
            return m
        }
        return rows
    }

    func pendingAICount() -> Int {
        (try? query("SELECT COUNT(*) FROM messages WHERE ai_status = 0") { Int($0.int(0)) }.first) ?? 0
    }

    func saveAnalysis(id: String, _ a: AIAnalysis) throws {
        try run("""
        UPDATE messages SET ai_status = 1, category = ?, importance = ?, summary = ?, translation = ?,
            action = ?, reason = ?, language = ?, headline = ?, notify_level = ?, deadline = ?, code = ?,
            ai_error = '' WHERE id = ?
        """, [.text(a.category), .text(a.importance.rawValue), .text(a.summary), .text(a.translation),
              .text(a.action), .text(a.reason), .text(a.language), .text(a.headline), .text(a.notify.rawValue),
              .text(a.deadline), .text(a.code), .text(id)])
    }

    func markAIFailed(id: String, error: String) throws {
        try run("UPDATE messages SET ai_status = 2, ai_error = ? WHERE id = ?", [.text(error), .text(id)])
    }

    func resetAI(id: String) throws {
        try run("UPDATE messages SET ai_status = 0 WHERE id = ?", [.text(id)])
    }

    func retryFailedAI() throws {
        try run("UPDATE messages SET ai_status = 0 WHERE ai_status = 2")
    }

    func setCategory(id: String, category: MailCategory) throws {
        let importance: Importance = category == .important ? .high : (category == .spam || category == .marketing ? .low : .normal)
        try run("UPDATE messages SET category = ?, importance = ?, ai_status = 1 WHERE id = ?",
                [.text(category.rawValue), .text(importance.rawValue), .text(id)])
    }

    func setRead(ids: [String], read: Bool) throws {
        for id in ids {
            try run("UPDATE messages SET is_read = ? WHERE id = ?", [.int(read ? 1 : 0), .text(id)])
        }
    }

    func markRead(id: String) throws {
        try setRead(ids: [id], read: true)
    }

    /// 已完成 AI 分析、尚未经过通知策略判断的邮件。
    func notificationCandidates() throws -> [MailMessage] {
        try query("SELECT \(Self.listColumns) FROM messages WHERE notified = 0 AND ai_status = 1 ORDER BY date ASC",
                  map: Self.mapMessage)
    }

    func markNotified(ids: [String]) throws {
        for id in ids {
            try run("UPDATE messages SET notified = 1 WHERE id = ?", [.text(id)])
        }
    }

    // MARK: - 发件人规则

    func senderRules() throws -> [SenderRule] {
        try query("SELECT email, category, vip, muted FROM senders ORDER BY email") {
            SenderRule(email: $0.text(0), category: $0.text(1), vip: $0.int(2) != 0, muted: $0.int(3) != 0)
        }
    }

    func saveSenderRule(_ rule: SenderRule) throws {
        let email = rule.email.lowercased().trimmed
        guard !email.isEmpty else { return }
        if rule.category.isEmpty && !rule.vip && !rule.muted {
            try run("DELETE FROM senders WHERE email = ?", [.text(email)])
        } else {
            try run("INSERT OR REPLACE INTO senders (email, category, vip, muted) VALUES (?,?,?,?)",
                    [.text(email), .text(rule.category), .int(rule.vip ? 1 : 0), .int(rule.muted ? 1 : 0)])
        }
    }

    /// 把发件人规则的分类应用到该发件人已有的邮件上。
    func applyCategory(_ category: MailCategory, toSender email: String) throws {
        let importance: Importance = category == .important ? .high : (category == .spam || category == .marketing ? .low : .normal)
        try run("UPDATE messages SET category = ?, importance = ?, ai_status = 1 WHERE lower(from_email) = ?",
                [.text(category.rawValue), .text(importance.rawValue), .text(email.lowercased())])
    }

    /// 侧边栏各项的未读数量。
    func unreadCounts() throws -> [String: Int] {
        var result: [String: Int] = [:]
        for (key, n) in try query("SELECT category, COUNT(*) FROM messages WHERE is_read = 0 GROUP BY category", map: { ($0.text(0), Int($0.int(1))) }) {
            result[key] = n
        }
        result["@important"] = try query("SELECT COUNT(*) FROM messages WHERE is_read = 0 AND importance = 'high' AND category != '垃圾'") { Int($0.int(0)) }.first ?? 0
        result["@action"] = try query("SELECT COUNT(*) FROM messages WHERE is_read = 0 AND action != '' AND category != '垃圾'") { Int($0.int(0)) }.first ?? 0
        result["@all"] = try query("SELECT COUNT(*) FROM messages WHERE is_read = 0 AND category != '垃圾'") { Int($0.int(0)) }.first ?? 0
        return result
    }

    func deleteAccountData(_ accountID: UUID) throws {
        try run("DELETE FROM messages WHERE account_id = ?", [.text(accountID.uuidString)])
        try run("DELETE FROM sync_state WHERE account_id = ?", [.text(accountID.uuidString)])
    }

    // MARK: - 同步状态

    func syncState(accountID: UUID, folder: String) throws -> (uidValidity: UInt32, lastUID: UInt32)? {
        try query("SELECT uid_validity, last_uid FROM sync_state WHERE account_id = ? AND folder = ?",
                  [.text(accountID.uuidString), .text(folder)]) {
            (UInt32(truncatingIfNeeded: $0.int(0)), UInt32(truncatingIfNeeded: $0.int(1)))
        }.first
    }

    func setSyncState(accountID: UUID, folder: String, uidValidity: UInt32, lastUID: UInt32) throws {
        try run("INSERT OR REPLACE INTO sync_state (account_id, folder, uid_validity, last_uid) VALUES (?,?,?,?)",
                [.text(accountID.uuidString), .text(folder), .int(Int64(uidValidity)), .int(Int64(lastUID))])
    }

    // MARK: - 汇总

    func digestMessages(from: Date, to: Date) throws -> [MailMessage] {
        try query("""
        SELECT \(Self.listColumns) FROM messages
        WHERE date >= ? AND date < ? AND ai_status = 1 AND importance != 'high'
        ORDER BY category, date DESC LIMIT 400
        """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)], map: Self.mapMessage)
    }

    @discardableResult
    func insertDigest(start: Date, end: Date, count: Int, content: String) throws -> Int64 {
        try run("INSERT INTO digests (created_at, period_start, period_end, message_count, content) VALUES (?,?,?,?,?)",
                [.double(Date().timeIntervalSince1970), .double(start.timeIntervalSince1970),
                 .double(end.timeIntervalSince1970), .int(Int64(count)), .text(content)])
        return sqlite3_last_insert_rowid(handle)
    }

    func digests(limit: Int = 100) throws -> [Digest] {
        try query("SELECT id, created_at, period_start, period_end, message_count, content FROM digests ORDER BY created_at DESC LIMIT \(limit)") {
            Digest(id: $0.int(0),
                   createdAt: Date(timeIntervalSince1970: $0.double(1)),
                   periodStart: Date(timeIntervalSince1970: $0.double(2)),
                   periodEnd: Date(timeIntervalSince1970: $0.double(3)),
                   messageCount: Int($0.int(4)),
                   content: $0.text(5))
        }
    }

    func deleteDigest(id: Int64) throws {
        try run("DELETE FROM digests WHERE id = ?", [.int(id)])
    }
}
