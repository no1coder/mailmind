import Foundation

struct DiscoveredServer: Equatable {
    var host: String
    var port: Int
    var useTLS: Bool
    var providerName: String
    var hint: String?
    var helpURL: String?
}

/// 只输入邮箱地址即可找到 IMAP 服务器：
/// 1. 内置服务商预设（QQ、163、Gmail……）
/// 2. Mozilla Thunderbird 的公开配置库 ISPDB（覆盖数千个服务商）
/// 3. 依次尝试 imap.域名、mail.域名 的 993 端口
enum AccountDiscovery {
    static func discover(email: String) async -> DiscoveredServer? {
        if let p = MailProviderPresets.guess(email: email) {
            return DiscoveredServer(host: p.host, port: p.port, useTLS: true, providerName: p.name, hint: p.hint, helpURL: p.helpURL)
        }
        guard let domain = email.split(separator: "@").last.map({ String($0).lowercased() }), domain.contains(".") else {
            return nil
        }
        if let s = await lookupISPDB(domain: domain) {
            return s
        }
        for host in ["imap.\(domain)", "mail.\(domain)", "imap.mail.\(domain)"] {
            if await canConnect(host: host, port: 993) {
                return DiscoveredServer(host: host, port: 993, useTLS: true, providerName: domain, hint: nil, helpURL: nil)
            }
        }
        return nil
    }

    static func lookupISPDB(domain: String) async -> DiscoveredServer? {
        guard let url = URL(string: "https://autoconfig.thunderbird.net/v1.1/\(domain)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("MailMind", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseISPDB(String(decoding: data, as: UTF8.self), domain: domain)
    }

    static func parseISPDB(_ xml: String, domain: String) -> DiscoveredServer? {
        guard let block = firstMatch("<incomingServer type=\"imap\">(.*?)</incomingServer>", in: xml),
              let host = firstMatch("<hostname>([^<]+)</hostname>", in: block) else { return nil }
        let port = firstMatch("<port>(\\d+)</port>", in: block).flatMap(Int.init) ?? 993
        let socket = firstMatch("<socketType>([^<]+)</socketType>", in: block) ?? "SSL"
        let name = firstMatch("<shortDisplayName>([^<]+)</shortDisplayName>", in: xml) ?? domain
        return DiscoveredServer(host: host.replacingOccurrences(of: "%EMAILDOMAIN%", with: domain),
                                port: port, useTLS: socket.uppercased() == "SSL", providerName: name,
                                hint: "已从 Thunderbird 配置库自动识别。如登录失败，请确认已开启 IMAP 并使用授权码。",
                                helpURL: nil)
    }

    static func canConnect(host: String, port: Int) async -> Bool {
        let conn = IMAPConnection(host: host, port: port, useTLS: true)
        defer { conn.cancel() }
        do {
            try await conn.open(timeout: 5)
            return true
        } catch {
            return false
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (text as NSString).substring(with: m.range(at: 1)).trimmed
    }

    /// 解析批量导入文本。每行：邮箱 授权码 [显示名称]，分隔符可以是空格、Tab、逗号。
    static func parseBatch(_ text: String) -> [(email: String, password: String, name: String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmed
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            // 有 Tab 或逗号时只按它们分隔，这样密码和名称里可以带空格。
            let hasStrongSeparator = t.contains("\t") || t.contains(",") || t.contains("，")
            let parts = t.split(whereSeparator: { hasStrongSeparator ? ($0 == "\t" || $0 == "," || $0 == "，") : $0 == " " })
                .map { $0.trimmed }
                .filter { !$0.isEmpty }
            guard parts.count >= 2, parts[0].contains("@") else { return nil }
            // Google 应用专用密码常被复制成 "abcd efgh ijkl mnop"
            if !hasStrongSeparator, parts.count >= 5, parts[1...4].allSatisfy({ $0.count == 4 }) {
                return (parts[0], parts[1...4].joined(), parts.dropFirst(5).joined(separator: " "))
            }
            let name = parts.count > 2 ? parts[2...].joined(separator: " ") : ""
            return (parts[0], parts[1], name)
        }
    }
}
