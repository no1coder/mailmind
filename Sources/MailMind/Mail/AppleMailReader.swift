import Foundation

/// 读取 macOS「邮件」App 已下载到本机的邮件（.emlx 文件）。
///
/// 用途：Outlook 等需要 OAuth 的邮箱，可以先在「邮件」App 中用微软账号登录，
/// MailMind 再从本地读取，无需注册应用 ID，也拿不到用户密码。
///
/// 目录结构（macOS 10.13 起）：
///   ~/Library/Mail/V<n>/<账户UUID>/<邮箱名>.mbox/<UUID>/Data/<数字>/.../Messages/<编号>.emlx
/// 只有附件未下载的邮件为 <编号>.partial.emlx。
/// 读取该目录需要「完全磁盘访问权限」。
enum AppleMailReader {
    enum Access: Equatable {
        case granted(URL)
        case denied
        case notFound
    }

    struct Account: Identifiable, Equatable {
        var id: String { uuid }
        var uuid: String
        var inbox: URL
        var email: String
        var messageCount: Int
    }

    enum ReadError: LocalizedError {
        case accessDenied
        case inboxMissing(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "没有读取「邮件」App 数据的权限，请在系统设置中给 MailMind 开启「完全磁盘访问权限」"
            case .inboxMissing(let p): return "找不到「邮件」App 中的收件箱：\(p)"
            }
        }
    }

    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 找到最新版本的数据目录（例如 V10），并检查是否有读取权限。
    static func access(home: URL = defaultHome) -> Access {
        let mail = home.appendingPathComponent("Library/Mail", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: mail.path) else { return .notFound }
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: mail.path)
        } catch {
            return .denied
        }
        let versions = entries.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
            return (n, name)
        }
        guard let latest = versions.max(by: { $0.0 < $1.0 }) else { return .notFound }
        let root = mail.appendingPathComponent(latest.1, isDirectory: true)
        guard (try? fm.contentsOfDirectory(atPath: root.path)) != nil else { return .denied }
        return .granted(root)
    }

    private static let inboxNames = ["inbox.mbox", "收件箱.mbox"]
    private static let uuidPattern = try! NSRegularExpression(pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

    /// 列出「邮件」App 中的账户（每个账户目录下有一个收件箱）。
    static func accounts(root: URL) -> [Account] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return dirs.sorted().compactMap { name in
            guard uuidPattern.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil else { return nil }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let boxes = try? fm.contentsOfDirectory(atPath: folder.path),
                  let inboxName = boxes.first(where: { inboxNames.contains($0.lowercased()) }) else { return nil }
            let inbox = folder.appendingPathComponent(inboxName, isDirectory: true)
            let files = messageFiles(in: inbox)
            guard !files.isEmpty else { return nil }
            return Account(uuid: name, inbox: inbox, email: guessEmail(files), messageCount: files.count)
        }
    }

    struct MessageFile {
        var url: URL
        var modified: Date
        /// 「邮件」App 内部的邮件编号（文件名中的数字）
        var number: UInt32
    }

    /// 递归列出收件箱中的 .emlx 文件，可只取某个时间之后修改的。
    static func messageFiles(in inbox: URL, modifiedAfter: Date? = nil) -> [MessageFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [MessageFile] = []
        for case let url as URL in e where url.pathExtension == "emlx" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let modified = v.contentModificationDate ?? .distantPast
            if let after = modifiedAfter, modified <= after { continue }
            let base = url.lastPathComponent.components(separatedBy: ".").first ?? ""
            guard let number = UInt32(base) else { continue }
            out.append(MessageFile(url: url, modified: modified, number: number))
        }
        // 同一封邮件可能同时存在 .emlx 与 .partial.emlx，保留完整版
        var byNumber: [UInt32: MessageFile] = [:]
        for f in out {
            if let existing = byNumber[f.number], !existing.url.lastPathComponent.contains(".partial.") { continue }
            byNumber[f.number] = f
        }
        return byNumber.values.sorted { $0.modified < $1.modified }
    }

    /// 解析 .emlx：第一行是邮件字节数，随后是原始邮件，最后是包含 flags 的 plist。
    static func parseEMLX(_ data: Data) -> (raw: Data, isRead: Bool) {
        guard let newline = data.firstIndex(of: 10),
              let length = Int(String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmed) else {
            return (data, false)
        }
        let start = newline + 1
        let end = min(data.endIndex, start + length)
        let raw = Data(data[start..<end])
        var isRead = false
        if end < data.endIndex,
           let plist = try? PropertyListSerialization.propertyList(from: Data(data[end...]), format: nil) as? [String: Any],
           let flags = (plist["flags"] as? NSNumber)?.int64Value {
            isRead = flags & 1 == 1 // 第 0 位：已读
        }
        return (raw, isRead)
    }

    /// 根据最近邮件的收件人推测该账户的邮箱地址。
    static func guessEmail(_ files: [MessageFile]) -> String {
        var counts: [String: Int] = [:]
        for f in files.suffix(40) {
            guard let data = try? Data(contentsOf: f.url, options: .mappedIfSafe) else { continue }
            let (raw, _) = parseEMLX(data.prefix(64 * 1024))
            let (headerData, _) = MIMEParser.splitHeaderAndBody(raw)
            let headers = MIMEParser.parseHeaders(headerData)
            for name in ["delivered-to", "x-original-to", "to"] {
                guard let v = MIMEParser.header(name, in: headers) else { continue }
                for part in MIMEParser.decodeEncodedWords(v).components(separatedBy: ",") {
                    let email = MIMEParser.parseAddress(part).email.lowercased()
                    if email.contains("@") { counts[email, default: 0] += name == "to" ? 1 : 3 }
                }
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? ""
    }
}
