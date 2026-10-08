import Foundation

struct IMAPResponse {
    /// 响应文本，字面量（literal）位置保留 `{n}` 标记。
    var text: String
    var literals: [Data]
}

struct IMAPFetchedMessage {
    var uid: UInt32
    var flags: [String]
    var internalDate: Date?
    var raw: Data
}

struct IMAPFolderInfo {
    var uidValidity: UInt32
    var uidNext: UInt32?
    var exists: Int
}

enum IMAPCredential {
    case password(String)
    /// OAuth 访问令牌（XOAUTH2）
    case oauth(String)
}

/// 保证 IDLE 的 DONE 只发送一次（定时器与新邮件可能同时触发）。
private final class DoneOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false
    private let connection: IMAPConnection

    init(_ connection: IMAPConnection) { self.connection = connection }

    func send() {
        lock.lock()
        defer { lock.unlock() }
        guard !sent else { return }
        sent = true
        connection.sendDetached("DONE\r\n")
    }
}

/// 极简、只读的 IMAP4rev1 客户端：登录、EXAMINE、UID SEARCH、UID FETCH。
/// 使用 EXAMINE 和 BODY.PEEK，不会改变服务器上邮件的已读状态。
final class IMAPClient {
    private let connection: IMAPConnection
    private var tagCounter = 0

    init(host: String, port: Int, useTLS: Bool) {
        connection = IMAPConnection(host: host, port: port, useTLS: useTLS)
    }

    /// 仅建立连接并读取问候语（用于探测服务器能力）。
    func connectWithoutLogin() async throws {
        try await connection.open()
        let greeting = String(decoding: try await connection.readLine(), as: UTF8.self)
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw IMAPError.badGreeting(greeting)
        }
    }

    func connect(username: String, password: String) async throws {
        try await connect(username: username, credential: .password(password))
    }

    func connect(username: String, credential: IMAPCredential) async throws {
        try await connection.open()
        let greeting = String(decoding: try await connection.readLine(), as: UTF8.self)
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw IMAPError.badGreeting(greeting)
        }
        do {
            switch credential {
            case .password(let password):
                try await command("LOGIN \(quote(username)) \(quote(password))")
            case .oauth(let token):
                try await command("AUTHENTICATE XOAUTH2 \(OAuthClient.xoauth2(user: username, accessToken: token))")
            }
        } catch IMAPError.commandFailed(let msg) {
            throw IMAPError.loginFailed(msg)
        }
        // 网易系邮箱（163/126）要求客户端在 SELECT 前发送 ID，否则报 "Unsafe Login"。
        _ = try? await command("ID (\"name\" \"MailMind\" \"version\" \"0.1.0\" \"vendor\" \"MailMind\")")
    }

    func logout() async {
        _ = try? await command("LOGOUT", timeout: 5)
        connection.cancel()
    }

    /// 立即断开（用于取消 IDLE 等长时间等待）。
    func cancel() {
        connection.cancel()
    }

    func capabilities() async throws -> Set<String> {
        var caps = Set<String>()
        for r in try await command("CAPABILITY") where r.text.hasPrefix("* CAPABILITY") {
            caps.formUnion(r.text.dropFirst("* CAPABILITY".count).split(separator: " ").map { $0.uppercased() })
        }
        return caps
    }

    /// IMAP IDLE（RFC 2177）：挂起等待服务器推送，有新邮件或到达 maxDuration 时返回。
    /// 返回 true 表示收到了新邮件通知。调用前需要先 EXAMINE / SELECT 文件夹。
    func idle(maxDuration: TimeInterval) async throws -> Bool {
        tagCounter += 1
        let tag = String(format: "A%04d", tagCounter)
        try await connection.send(Data("\(tag) IDLE\r\n".utf8))

        let done = DoneOnce(connection)
        let timer = DispatchWorkItem { done.send() }
        DispatchQueue.global().asyncAfter(deadline: .now() + maxDuration, execute: timer)
        // 服务器无响应时的兜底：DONE 发出 60 秒后仍未结束就断开。
        let watchdog = DispatchWorkItem { [connection] in connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + maxDuration + 60, execute: watchdog)
        defer {
            timer.cancel()
            watchdog.cancel()
        }

        var newMail = false
        while true {
            let r = try await readResponse()
            if r.text.hasPrefix("+") { continue }
            if r.text.hasPrefix(tag + " ") {
                let status = r.text.dropFirst(tag.count + 1)
                if status.hasPrefix("OK") { return newMail }
                throw IMAPError.commandFailed(String(status))
            }
            if r.text.hasPrefix("* BYE") { throw IMAPError.closed }
            if r.text.hasSuffix(" EXISTS") || r.text.hasSuffix(" RECENT") {
                newMail = true
                done.send()
            }
        }
    }

    func examine(_ folder: String) async throws -> IMAPFolderInfo {
        let responses = try await command("EXAMINE \(quote(folder))")
        var info = IMAPFolderInfo(uidValidity: 0, uidNext: nil, exists: 0)
        for r in responses {
            if let v = Self.firstMatch("UIDVALIDITY (\\d+)", in: r.text) { info.uidValidity = UInt32(v) ?? 0 }
            if let v = Self.firstMatch("UIDNEXT (\\d+)", in: r.text) { info.uidNext = UInt32(v) }
            if let v = Self.firstMatch("^\\* (\\d+) EXISTS", in: r.text) { info.exists = Int(v) ?? 0 }
        }
        return info
    }

    func searchUIDs(since date: Date) async throws -> [UInt32] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy"
        return try await search("UID SEARCH SINCE \(f.string(from: date))")
    }

    func searchUIDs(after uid: UInt32) async throws -> [UInt32] {
        // "n:*" 在没有新邮件时也会返回当前最大 UID，需要过滤。
        try await search("UID SEARCH UID \(uid + 1):*").filter { $0 > uid }
    }

    private func search(_ cmd: String) async throws -> [UInt32] {
        var uids: [UInt32] = []
        for r in try await command(cmd) where r.text.hasPrefix("* SEARCH") {
            uids += r.text.dropFirst("* SEARCH".count).split(separator: " ").compactMap { UInt32($0) }
        }
        return uids
    }

    func fetch(uids: [UInt32], maxBytes: Int) async throws -> [IMAPFetchedMessage] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let responses = try await command("UID FETCH \(set) (UID FLAGS INTERNALDATE BODY.PEEK[]<0.\(maxBytes)>)", timeout: 180)
        var out: [IMAPFetchedMessage] = []
        for r in responses where r.text.contains(" FETCH (") {
            guard let raw = r.literals.first,
                  let uidStr = Self.firstMatch("UID (\\d+)", in: r.text),
                  let uid = UInt32(uidStr) else { continue }
            let flags = Self.firstMatch("FLAGS \\(([^)]*)\\)", in: r.text)?
                .split(separator: " ").map(String.init) ?? []
            let date = Self.firstMatch("INTERNALDATE \"([^\"]+)\"", in: r.text).flatMap(MIMEParser.parseDate)
            out.append(IMAPFetchedMessage(uid: uid, flags: flags, internalDate: date, raw: raw))
        }
        return out
    }

    // MARK: - 命令与响应

    @discardableResult
    func command(_ cmd: String, timeout: TimeInterval = 60) async throws -> [IMAPResponse] {
        tagCounter += 1
        let tag = String(format: "A%04d", tagCounter)

        var timedOut = false
        let watchdog = DispatchWorkItem { [connection] in
            timedOut = true
            connection.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        do {
            try await connection.send(Data("\(tag) \(cmd)\r\n".utf8))
            var responses: [IMAPResponse] = []
            while true {
                let r = try await readResponse()
                if r.text.hasPrefix(tag + " ") {
                    let status = r.text.dropFirst(tag.count + 1)
                    if status.hasPrefix("OK") { return responses }
                    throw IMAPError.commandFailed(String(status))
                }
                // XOAUTH2 失败时服务器先发 "+ <错误详情>"，需回一个空行才会返回 NO。
                if r.text.hasPrefix("+") && cmd.hasPrefix("AUTHENTICATE") {
                    try await connection.send(Data("\r\n".utf8))
                    continue
                }
                if r.text.hasPrefix("* BYE") && !cmd.hasPrefix("LOGOUT") {
                    throw IMAPError.closed
                }
                responses.append(r)
            }
        } catch let e as IMAPError {
            throw e
        } catch {
            throw timedOut ? IMAPError.timeout : error
        }
    }

    private func readResponse() async throws -> IMAPResponse {
        var text = ""
        var literals: [Data] = []
        while true {
            let line = String(decoding: try await connection.readLine(), as: UTF8.self)
            text += line
            if let n = Self.literalLength(line) {
                literals.append(try await connection.readBytes(n))
                continue
            }
            return IMAPResponse(text: text, literals: literals)
        }
    }

    static func literalLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(inner.hasSuffix("+") ? inner.dropLast() : inner)
    }

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }
}
