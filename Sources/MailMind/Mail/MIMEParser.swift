import Foundation

struct ParsedMail {
    var subject = ""
    var fromName = ""
    var fromEmail = ""
    var to = ""
    var date: Date?
    var messageID = ""
    var listUnsubscribe = ""
    var textBody = ""
    var htmlBody = ""
    var attachments: [String] = []

    /// 优先纯文本正文，没有时从 HTML 中提取文字。
    var bestText: String {
        textBody.trimmed.isEmpty ? MIMEParser.htmlToText(htmlBody) : textBody
    }
}

/// 一个容错的 RFC 5322 / MIME 解析器。
/// 输入可能被截断（同步时只取邮件前 512KB），所以所有步骤都不能假设数据完整。
enum MIMEParser {
    typealias Headers = [(name: String, value: String)]

    static func parse(_ data: Data) -> ParsedMail {
        let (headerData, body) = splitHeaderAndBody(data)
        let headers = parseHeaders(headerData)
        var mail = ParsedMail()
        mail.subject = decodeEncodedWords(header("subject", in: headers) ?? "").trimmed
        let from = parseAddress(decodeEncodedWords(header("from", in: headers) ?? ""))
        mail.fromName = from.name
        mail.fromEmail = from.email
        mail.to = decodeEncodedWords(header("to", in: headers) ?? "").trimmed
        mail.date = parseDate(header("date", in: headers) ?? "")
        mail.messageID = header("message-id", in: headers)?.trimmed ?? ""
        mail.listUnsubscribe = header("list-unsubscribe", in: headers)?.trimmed ?? ""
        walk(headers: headers, body: body, into: &mail, depth: 0)
        return mail
    }

    // MARK: - 结构

    static func splitHeaderAndBody(_ input: Data) -> (Data, Data) {
        let data = Data(input)
        if data.starts(with: [13, 10]) { return (Data(), Data(data.dropFirst(2))) }
        if data.starts(with: [10]) { return (Data(), Data(data.dropFirst(1))) }
        let crlf = data.range(of: Data([13, 10, 13, 10]))
        let lf = data.range(of: Data([10, 10]))
        let sep: Range<Data.Index>?
        switch (crlf, lf) {
        case let (a?, b?): sep = a.lowerBound <= b.lowerBound ? a : b
        case let (a?, nil): sep = a
        case let (nil, b?): sep = b
        default: sep = nil
        }
        guard let sep else { return (data, Data()) }
        return (Data(data[..<sep.lowerBound]), Data(data[sep.upperBound...]))
    }

    static func parseHeaders(_ data: Data) -> Headers {
        let text = decodeBytes(data, charset: nil).replacingOccurrences(of: "\r\n", with: "\n")
        var result: Headers = []
        var name: String?
        var value = ""
        for line in text.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t" {
                if name != nil { value += " " + line.trimmed }
                continue
            }
            if let n = name { result.append((n, value)) }
            name = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            name = line[..<colon].trimmed.lowercased()
            value = line[line.index(after: colon)...].trimmed
        }
        if let n = name { result.append((n, value)) }
        return result
    }

    static func header(_ name: String, in headers: Headers) -> String? {
        headers.first { $0.name == name }?.value
    }

    private static func walk(headers: Headers, body: Data, into mail: inout ParsedMail, depth: Int) {
        guard depth < 12 else { return }
        let (type, params) = parseHeaderParams(header("content-type", in: headers) ?? "text/plain")
        let encoding = (header("content-transfer-encoding", in: headers) ?? "7bit").trimmed.lowercased()
        let (disposition, dparams) = parseHeaderParams(header("content-disposition", in: headers) ?? "")

        if type.hasPrefix("multipart/"), let boundary = params["boundary"], !boundary.isEmpty {
            for part in splitMultipart(body, boundary: boundary) {
                let (h, b) = splitHeaderAndBody(part)
                walk(headers: parseHeaders(h), body: b, into: &mail, depth: depth + 1)
            }
            return
        }
        if type == "message/rfc822" {
            let (h, b) = splitHeaderAndBody(decodeTransfer(body, encoding: encoding))
            walk(headers: parseHeaders(h), body: b, into: &mail, depth: depth + 1)
            return
        }

        let filename = decodeEncodedWords(dparams["filename"] ?? params["name"] ?? "").trimmed
        let isText = type.isEmpty || type.hasPrefix("text/")
        if disposition == "attachment" || (!filename.isEmpty && !isText) {
            mail.attachments.append(filename.isEmpty ? "未命名附件" : filename)
            return
        }

        if type == "text/plain" || type.isEmpty {
            if mail.textBody.isEmpty {
                mail.textBody = decodeBytes(decodeTransfer(body, encoding: encoding), charset: params["charset"])
            }
        } else if type == "text/html" {
            if mail.htmlBody.isEmpty {
                mail.htmlBody = decodeBytes(decodeTransfer(body, encoding: encoding), charset: params["charset"])
            }
        }
    }

    static func splitMultipart(_ input: Data, boundary: String) -> [Data] {
        let body = Data(input)
        let delimiter = Data("--\(boundary)".utf8)
        var positions: [Range<Data.Index>] = []
        var searchStart = body.startIndex
        while searchStart < body.endIndex,
              let r = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            if r.lowerBound == body.startIndex || body[r.lowerBound - 1] == 10 {
                positions.append(r)
            }
            searchStart = r.upperBound
        }

        var parts: [Data] = []
        for (i, r) in positions.enumerated() {
            if body[r.upperBound...].starts(with: [45, 45]) { break } // "--" 结束标记
            guard let newline = body[r.upperBound...].firstIndex(of: 10) else { break }
            let start = newline + 1
            var end = i + 1 < positions.count ? positions[i + 1].lowerBound : body.endIndex
            if end > start, body[end - 1] == 10 { end -= 1 }
            if end > start, body[end - 1] == 13 { end -= 1 }
            if end > start { parts.append(Data(body[start..<end])) }
        }
        return parts
    }

    // MARK: - 头部参数（含 RFC 2231）

    static func parseHeaderParams(_ value: String) -> (String, [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuote = false
        for ch in value {
            if ch == "\"" { inQuote.toggle(); current.append(ch) }
            else if ch == ";" && !inQuote { segments.append(current); current = "" }
            else { current.append(ch) }
        }
        segments.append(current)

        let main = segments.first?.trimmed.lowercased() ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(index: Int, value: String, extended: Bool)]] = [:]

        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<eq].trimmed.lowercased()
            var val = segment[segment.index(after: eq)...].trimmed
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
            }
            let extended = key.hasSuffix("*")
            if extended { key.removeLast() }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continuations[String(key[..<star]), default: []].append((n, val, extended))
                continue
            }
            if extended {
                var charset: String?
                let bytes = rfc2231Bytes(val, first: true, charset: &charset)
                params[key] = decodeBytes(bytes, charset: charset)
            } else {
                params[key] = val
            }
        }

        for (key, segs) in continuations where params[key] == nil {
            var charset: String?
            var bytes = Data()
            for (i, seg) in segs.sorted(by: { $0.index < $1.index }).enumerated() {
                bytes.append(seg.extended ? rfc2231Bytes(seg.value, first: i == 0, charset: &charset) : Data(seg.value.utf8))
            }
            params[key] = decodeBytes(bytes, charset: charset)
        }
        return (main, params)
    }

    private static func rfc2231Bytes(_ raw: String, first: Bool, charset: inout String?) -> Data {
        var value = raw
        if first {
            let comps = value.components(separatedBy: "'")
            if comps.count >= 3 {
                charset = comps[0].isEmpty ? nil : comps[0]
                value = comps[2...].joined(separator: "'")
            }
        }
        return percentDecode(value)
    }

    private static func percentDecode(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 37, i + 2 < bytes.count, let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - 编码

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func encoding(for charset: String) -> String.Encoding? {
        let name = charset.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        switch name {
        case "utf-8", "utf8", "us-ascii", "ascii": return .utf8
        case "gb2312", "gbk", "x-gbk", "gb18030", "cp936", "euc-cn", "936": return gb18030
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// 按声明的字符集解码，失败时依次尝试 UTF-8（容忍末尾被截断的多字节字符）、GB18030、Latin-1。
    static func decodeBytes(_ data: Data, charset: String?) -> String {
        if let charset, let enc = encoding(for: charset), enc != .utf8, let s = String(data: data, encoding: enc) {
            return s
        }
        for cut in 0...3 where data.count >= cut {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
        }
        if let s = String(data: data, encoding: gb18030) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64": return base64Decode(data)
        case "quoted-printable": return quotedPrintableDecode(data)
        default: return data
        }
    }

    static func base64Decode(_ data: Data) -> Data {
        var clean = data.filter { b in
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47
        }
        switch clean.count % 4 {
        case 1: clean.removeLast()
        case 2: clean.append(contentsOf: [61, 61])
        case 3: clean.append(61)
        default: break
        }
        return Data(base64Encoded: clean) ?? Data()
    }

    static func base64Decode(_ s: String) -> Data { base64Decode(Data(s.utf8)) }

    static func quotedPrintableDecode(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 { // "="
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hexValue(bytes[i + 1]), let l = hexValue(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }

    private static let encodedWordRegex = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?=")

    /// 解码 RFC 2047 编码词（=?gb2312?B?...?=）。同字符集的相邻编码词先拼接字节再解码，
    /// 避免一个汉字被拆在两个编码词之间时出现乱码。
    static func decodeEncodedWords(_ input: String) -> String {
        let ns = input as NSString
        let matches = encodedWordRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = ""
        var cursor = 0
        var pendingCharset: String?
        var pendingBytes = Data()

        func flush() {
            if let cs = pendingCharset { out += decodeBytes(pendingBytes, charset: cs) }
            pendingCharset = nil
            pendingBytes = Data()
        }

        for m in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let charset = ns.substring(with: m.range(at: 1)).components(separatedBy: "*")[0]
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let bytes = mode == "B" ? base64Decode(text) : qDecode(text)

            if let cs = pendingCharset, gap.trimmed.isEmpty {
                if cs.lowercased() == charset.lowercased() {
                    pendingBytes.append(bytes)
                } else {
                    flush()
                    pendingCharset = charset
                    pendingBytes = bytes
                }
            } else {
                flush()
                out += gap
                pendingCharset = charset
                pendingBytes = bytes
            }
            cursor = m.range.location + m.range.length
        }
        flush()
        out += ns.substring(from: cursor)
        return out
    }

    private static func qDecode(_ s: String) -> Data {
        quotedPrintableDecode(Data(s.replacingOccurrences(of: "_", with: " ").utf8))
    }

    // MARK: - 地址与日期

    static func parseAddress(_ s: String) -> (name: String, email: String) {
        let t = s.trimmed
        if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
            let email = t[t.index(after: lt)..<gt].trimmed
            let name = t[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines))
            return (name, email)
        }
        return ("", t)
    }

    private static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yy HH:mm:ss Z",
        "dd-MMM-yyyy HH:mm:ss Z", // IMAP INTERNALDATE
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    static func parseDate(_ raw: String) -> Date? {
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !s.isEmpty else { return nil }
        for f in dateFormatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - HTML 转纯文本

    private static func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    static func htmlToText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var s = html
        s = regexReplace(s, "<!--.*?-->", "")
        s = regexReplace(s, "<(head|style|script|title)[^>]*>.*?</\\1>", "")
        s = regexReplace(s, "<br\\s*/?>", "\n")
        s = regexReplace(s, "<li[^>]*>", "\n• ")
        s = regexReplace(s, "</(p|div|tr|h[1-6]|table|ul|ol|blockquote)>", "\n")
        s = regexReplace(s, "<[^>]+>", "")
        s = decodeEntities(s)
        let lines = s.components(separatedBy: .newlines).map { $0.trimmed }
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmed
    }

    private static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "copy": "©", "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "middot": "·", "yen": "¥", "zwnj": "",
    ]

    private static let entityRegex = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")

    static func decodeEntities(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in entityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let body = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[body.lowercased()]
            }
            out += replacement ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
