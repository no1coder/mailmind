import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// MailMind 在微软注册的应用 ID（公共客户端，无密钥，可以公开）。
/// 注册方法见 docs/microsoft-oauth.md；为空时用户可在登录页填写自己的应用 ID。
enum MicrosoftOAuth {
    static let builtInClientID = ""
    static let redirectURI = "mailmind://oauth"
    static let callbackScheme = "mailmind"
}

enum OAuthError: LocalizedError {
    case notConfigured
    case cancelled
    case invalidCallback
    case token(String)
    case reauthRequired

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置微软应用 ID"
        case .cancelled: return "已取消登录"
        case .invalidCallback: return "登录返回的数据不完整，请重试"
        case .token(let s): return "获取授权失败：\(s)"
        case .reauthRequired: return "授权已过期，请重新登录"
        }
    }
}

struct OAuthConfig: Equatable {
    var provider: String
    var clientID: String
    var authorizeURL: URL
    var tokenURL: URL
    var scopes: [String]
    var redirectURI: String
    var callbackScheme: String

    static func microsoft(clientID: String) -> OAuthConfig {
        OAuthConfig(
            provider: "microsoft",
            clientID: clientID,
            authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["https://outlook.office.com/IMAP.AccessAsUser.All", "offline_access", "openid", "email", "profile"],
            redirectURI: MicrosoftOAuth.redirectURI,
            callbackScheme: MicrosoftOAuth.callbackScheme
        )
    }
}

struct OAuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var email: String = ""

    var isFresh: Bool { expiry.timeIntervalSinceNow > 60 }
}

/// PKCE（RFC 7636）：桌面应用不能保存密钥，用一次性的 verifier / challenge 防止授权码被截获。
struct PKCE {
    let verifier: String
    let challenge: String

    init(verifier: String? = nil) {
        let v = verifier ?? Self.randomURLSafe(byteCount: 48)
        self.verifier = v
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(v.utf8))))
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthClient {
    static func authorizeURL(_ c: OAuthConfig, pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var comps = URLComponents(url: c.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: c.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: c.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: c.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        comps.queryItems = items
        return comps.url!
    }

    /// 完整的交互式登录：打开微软登录页 → 用户授权 → 用授权码换取令牌。
    @MainActor
    static func signIn(_ c: OAuthConfig, loginHint: String? = nil) async throws -> OAuthTokens {
        guard !c.clientID.isEmpty else { throw OAuthError.notConfigured }
        let pkce = PKCE()
        let state = PKCE.randomURLSafe(byteCount: 16)
        let callback = try await WebAuthenticator().authenticate(
            url: authorizeURL(c, pkce: pkce, state: state, loginHint: loginHint),
            callbackScheme: c.callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let err = item("error") {
            throw OAuthError.token(item("error_description") ?? err)
        }
        guard item("state") == state, let code = item("code") else { throw OAuthError.invalidCallback }
        return try await requestToken(c, form: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": pkce.verifier,
            "redirect_uri": c.redirectURI,
        ], previousRefreshToken: nil)
    }

    static func refresh(_ tokens: OAuthTokens, config c: OAuthConfig) async throws -> OAuthTokens {
        var t = try await requestToken(c, form: [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ], previousRefreshToken: tokens.refreshToken)
        if t.email.isEmpty { t.email = tokens.email }
        return t
    }

    private static func requestToken(_ c: OAuthConfig, form: [String: String], previousRefreshToken: String?) async throws -> OAuthTokens {
        var all = form
        all["client_id"] = c.clientID
        all["scope"] = c.scopes.joined(separator: " ")
        var request = URLRequest(url: c.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(all).data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseTokenResponse(data, previousRefreshToken: previousRefreshToken)
    }

    static func parseTokenResponse(_ data: Data, previousRefreshToken: String?, now: Date = Date()) throws -> OAuthTokens {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.token(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let err = json["error"] as? String {
            if err == "invalid_grant" && previousRefreshToken != nil { throw OAuthError.reauthRequired }
            throw OAuthError.token((json["error_description"] as? String)?.components(separatedBy: "\r\n").first ?? err)
        }
        guard let access = json["access_token"] as? String else { throw OAuthError.token("响应中没有 access_token") }
        let refresh = (json["refresh_token"] as? String) ?? previousRefreshToken ?? ""
        let expiresIn = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? String ?? "") ?? 3600
        let email = (json["id_token"] as? String).flatMap(emailFromIDToken) ?? ""
        return OAuthTokens(accessToken: access, refreshToken: refresh, expiry: now.addingTimeInterval(expiresIn), email: email)
    }

    /// 从 OpenID id_token（JWT）中读取邮箱地址。只用于显示和预填，不做签名校验。
    static func emailFromIDToken(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (claims["email"] as? String) ?? (claims["preferred_username"] as? String)
    }

    /// IMAP AUTHENTICATE XOAUTH2 的初始响应。
    static func xoauth2(user: String, accessToken: String) -> String {
        Data("user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }
}

/// 用系统的 ASWebAuthenticationSession 打开登录页（与 Safari 共享登录状态）。
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { url, error in
                if let url {
                    cont.resume(returning: url)
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: OAuthError.cancelled)
                } else {
                    cont.resume(throwing: error ?? OAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                cont.resume(throwing: OAuthError.invalidCallback)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}

/// 令牌存取：缓存在内存，持久化到钥匙串；过期前自动刷新，并保证同一账户同时只刷新一次。
actor OAuthTokenStore {
    static let shared = OAuthTokenStore()

    private var cache: [UUID: OAuthTokens] = [:]
    private var refreshing: [UUID: Task<OAuthTokens, Error>] = [:]

    static func key(_ id: UUID) -> String { "oauth:\(id.uuidString)" }

    func save(_ tokens: OAuthTokens, for id: UUID) {
        cache[id] = tokens
        if let data = try? JSONEncoder().encode(tokens) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: Self.key(id))
        }
    }

    func delete(_ id: UUID) {
        cache[id] = nil
        Keychain.delete(Self.key(id))
    }

    func load(_ id: UUID) -> OAuthTokens? {
        if let t = cache[id] { return t }
        guard let s = Keychain.get(Self.key(id)), let t = try? JSONDecoder().decode(OAuthTokens.self, from: Data(s.utf8)) else { return nil }
        cache[id] = t
        return t
    }

    func accessToken(for id: UUID, config: OAuthConfig) async throws -> String {
        guard let tokens = load(id) else { throw OAuthError.reauthRequired }
        if tokens.isFresh { return tokens.accessToken }
        if let running = refreshing[id] { return try await running.value.accessToken }
        let task = Task { try await OAuthClient.refresh(tokens, config: config) }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        let fresh = try await task.value
        save(fresh, for: id)
        return fresh.accessToken
    }
}
