import SwiftUI

/// 批量添加邮箱：每行「邮箱 授权码 [名称]」，自动识别服务器并逐个测试连接。
struct BatchImportView: View {
    @Environment(AppState.self) private var state
    /// 添加完成后的回调（例如关闭弹窗、进入下一步）。
    var onFinished: (() -> Void)?

    struct Item: Identifiable {
        let id = UUID()
        var email: String
        var password: String
        var name: String
        var server: DiscoveredServer?
        var state: ItemState = .waiting
    }

    enum ItemState: Equatable {
        case waiting, checking
        case ok(Int)
        case failed(String)
    }

    @State private var text = ""
    @State private var items: [Item] = []
    @State private var running = false

    private let placeholder = """
    每行一个邮箱：邮箱地址 授权码 [显示名称]
    例如：
    zhangsan@qq.com abcdefghijklmnop 个人QQ
    work@company.com,Passw0rd,工作邮箱
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 150)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .border(Color.secondary.opacity(0.2))
                Text("QQ、163、126 需要先在网页版开启 IMAP 并生成授权码；Gmail、iCloud 需要应用专用密码。服务器会自动识别。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("识别并测试") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(AccountDiscovery.parseBatch(text).isEmpty)
                }
            } else {
                List(items) { item in
                    HStack {
                        icon(item.state)
                        VStack(alignment: .leading) {
                            Text(item.email).font(.callout)
                            Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if case .failed = item.state, let url = item.server?.helpURL.flatMap(URL.init) {
                            Link("去开启 IMAP", destination: url).font(.caption)
                        }
                    }
                }
                .frame(minHeight: 180)
                HStack {
                    Button("返回修改") { items = [] }
                        .disabled(running)
                    Spacer()
                    let okCount = items.filter { if case .ok = $0.state { return true } else { return false } }.count
                    Button("添加 \(okCount) 个账户") { add() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || okCount == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ s: ItemState) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func detail(_ item: Item) -> String {
        switch item.state {
        case .waiting: return "等待中"
        case .checking: return item.server.map { "正在连接 \($0.host)…" } ?? "正在识别服务器…"
        case .ok(let n): return "\(item.server?.providerName ?? "") · 收件箱 \(n) 封"
        case .failed(let e): return e
        }
    }

    private func start() {
        let existing = Set(state.settings.accounts.map { $0.email.lowercased() })
        items = AccountDiscovery.parseBatch(text)
            .filter { !existing.contains($0.email.lowercased()) }
            .map { Item(email: $0.email, password: $0.password, name: $0.name) }
        guard !items.isEmpty else { return }
        running = true
        Task {
            // 每次并发 4 个，避免同一服务商限流。
            for chunk in items.indices.map({ $0 }).chunked(4) {
                await withTaskGroup(of: (Int, DiscoveredServer?, ItemState).self) { group in
                    for i in chunk {
                        items[i].state = .checking
                        let item = items[i]
                        group.addTask { await Self.check(index: i, item: item) }
                    }
                    for await (i, server, result) in group {
                        items[i].server = server
                        items[i].state = result
                    }
                }
            }
            running = false
        }
    }

    private static func check(index: Int, item: Item) async -> (Int, DiscoveredServer?, ItemState) {
        guard let server = await AccountDiscovery.discover(email: item.email) else {
            return (index, nil, .failed("无法自动识别服务器，请用「添加单个账户」手动填写"))
        }
        let account = makeAccount(item, server)
        do {
            let n = try await SyncEngine.test(account: account, password: item.password)
            return (index, server, .ok(n))
        } catch {
            return (index, server, .failed(error.localizedDescription))
        }
    }

    private static func makeAccount(_ item: Item, _ s: DiscoveredServer) -> MailAccount {
        MailAccount(displayName: item.name.isEmpty ? item.email : item.name, email: item.email,
                    username: item.email, host: s.host, port: s.port, useTLS: s.useTLS)
    }

    private func add() {
        let ok = items.compactMap { item -> (MailAccount, String?)? in
            guard case .ok = item.state, let s = item.server else { return nil }
            return (Self.makeAccount(item, s), item.password)
        }
        state.addAccounts(ok)
        items.removeAll { if case .ok = $0.state { return true } else { return false } }
        if items.isEmpty {
            text = ""
            onFinished?()
        }
    }
}
