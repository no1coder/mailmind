import Foundation
import Network

enum IMAPError: LocalizedError {
    case timeout
    case closed
    case badGreeting(String)
    case loginFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "连接超时"
        case .closed: return "连接被服务器关闭"
        case .badGreeting(let s): return "服务器拒绝连接：\(s)"
        case .loginFailed(let s): return "登录失败：\(s)。请确认已在邮箱网页版开启 IMAP，并使用授权码 / 应用专用密码登录。"
        case .commandFailed(let s): return "服务器返回错误：\(s)"
        }
    }
}

/// 保证 continuation 只被恢复一次（连接就绪、失败、超时可能先后触发）。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// 基于 Network.framework 的带缓冲 TCP/TLS 连接，提供按行读取和按字节数读取。
final class IMAPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mailmind.imap")
    private var buffer = Data()

    init(host: String, port: Int, useTLS: Bool) {
        let params: NWParameters = useTLS ? .tls : .tcp
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 993
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    func open(timeout: TimeInterval = 20) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(cont)
            let finish: @Sendable (Result<Void, Error>) -> Void = { once.resume($0) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e), .waiting(let e): finish(.failure(e))
                case .cancelled: finish(.failure(IMAPError.closed))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(IMAPError.timeout)) }
        }
    }

    func cancel() { connection.cancel() }

    /// 不等待完成的发送，用于在读取进行中时从定时器发送 IDLE 的 DONE。
    func sendDetached(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: IMAPError.closed) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    /// 读取一行（不含 CRLF）。
    func readLine() async throws -> Data {
        while true {
            if let r = buffer.range(of: Data([13, 10])) {
                let line = Data(buffer[buffer.startIndex..<r.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            buffer.append(try await receiveChunk())
        }
    }

    func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await receiveChunk())
        }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }
}
