import SwiftUI

struct AccountsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var editing: MailAccount?
    @State private var showAdd = false
    @State private var deleting: MailAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("邮箱账户").font(.title3.bold())
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.syncNow()
                } label: {
                    Label("全部同步", systemImage: "arrow.clockwise")
                }
                .disabled(state.isSyncing || state.settings.accounts.isEmpty)
                Button {
                    showAdd = true
                } label: {
                    Label("添加邮箱", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if state.settings.accounts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("还没有添加邮箱").font(.headline)
                    Button("添加第一个邮箱") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.settings.accounts) { a in
                        AccountSettingsRow(account: a, status: state.accountStatus[a.id],
                                           onEdit: { editing = a }, onDelete: { deleting = a })
                    }
                    .onMove { state.moveAccounts(from: $0, to: $1) }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                Text("拖动可以调整顺序。绿点 = 实时推送，蓝点 = 定时检查，红点 = 连接出错。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .sheet(item: $editing) { account in
            AccountEditor(account: account, isNew: false) { saved, password in
                state.saveAccount(saved, password: password)
            }
        }
        .sheet(isPresented: $showAdd) {
            VStack(spacing: 0) {
                AddAccountFlow { showAdd = false }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                HStack {
                    Spacer()
                    Button("关闭") { showAdd = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .frame(width: 760, height: 560)
        }
        .confirmationDialog("删除「\(deleting?.displayName ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let id = deleting?.id { state.deleteAccount(id) }
                deleting = nil
            }
        } message: {
            Text("只会删除 MailMind 本地保存的数据，不影响邮箱服务器上的邮件。")
        }
    }

    private var summary: String {
        let all = state.settings.accounts
        let live = all.filter { state.accountStatus[$0.id]?.realtime == true }.count
        let errors = all.filter { state.accountStatus[$0.id]?.error != nil }.count
        var parts = ["共 \(all.count) 个"]
        if live > 0 { parts.append("\(live) 个实时推送") }
        if errors > 0 { parts.append("\(errors) 个出错") }
        return parts.joined(separator: " · ")
    }
}

private struct AccountSettingsRow: View {
    @Environment(AppState.self) private var state
    let account: MailAccount
    let status: AccountStatus?
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            (MailProviderPreset.forAccount(account) ?? MailProviderPresets.all.last!).icon(size: 34)
                .opacity(account.enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.headline)
                if account.displayName != account.email {
                    Text(account.email).font(.caption).foregroundStyle(.secondary)
                }
                statusLine
            }
            Spacer()
            Toggle("", isOn: Binding(get: { account.enabled }, set: { state.setAccountEnabled(account.id, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(account.enabled ? "停用" : "启用")
            Menu {
                Button("立即同步") { state.syncAccount(account.id) }
                if account.oauthProvider == "microsoft" {
                    Button("重新登录微软账号") { reauthorize() }
                }
                Button("编辑…", action: onEdit)
                Divider()
                Button("删除…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    @ViewBuilder
    private var statusLine: some View {
        if !account.enabled {
            Text("已停用").font(.caption).foregroundStyle(.secondary)
        } else if let error = status?.error {
            let friendly = FriendlyError.connection(IMAPError.loginFailed(error), passwordLabel: MailProviderPreset.forAccount(account)?.passwordLabel ?? "密码")
            Label(error.contains("登录失败") ? friendly.title : error, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else {
            HStack(spacing: 4) {
                Circle().fill(status?.realtime == true || account.isAppleMail ? Color.green : Color.blue).frame(width: 6, height: 6)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reauthorize() {
        Task {
            do {
                _ = try await state.signInWithMicrosoft(existing: account)
            } catch OAuthError.cancelled {
            } catch {
                state.accountStatus[account.id, default: AccountStatus()].error = FriendlyError.oauth(error).title
            }
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if status?.syncing == true { parts.append("同步中…") }
        parts.append(account.isAppleMail ? "从「邮件」App 读取" : (status?.realtime == true ? "实时推送" : "定时检查"))
        if let t = status?.lastSync { parts.append("\(t.formatted(date: .omitted, time: .shortened)) 已同步") }
        return parts.joined(separator: " · ")
    }
}

/// 单个账户编辑：只需邮箱和授权码，服务器自动识别；高级设置默认折叠。
struct AccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var account: MailAccount
    let isNew: Bool
    let onSave: (MailAccount, String?) -> Void

    @State private var password = ""
    @State private var discovered: DiscoveredServer?
    @State private var discovering = false
    @State private var showAdvanced = false
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("邮箱地址", text: $account.email, prompt: Text("name@example.com"))
                        .onSubmit { discover() }
                        .onChange(of: account.email) { old, new in
                            if account.username.isEmpty || account.username == old { account.username = new }
                        }
                    if account.oauthProvider == nil {
                        SecureField(isNew ? "授权码 / 密码" : "授权码 / 密码（留空则不修改）", text: $password)
                    } else {
                        Label("通过微软账号授权登录", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                    }
                    TextField("显示名称", text: $account.displayName, prompt: Text("例如：工作邮箱"))
                }
                Section {
                    HStack {
                        if discovering {
                            ProgressView().controlSize(.small)
                            Text("正在识别服务器…").foregroundStyle(.secondary)
                        } else if !account.host.isEmpty {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("\(discovered?.providerName ?? "服务器") · \(account.host):\(String(account.port))")
                        } else {
                            Text("输入邮箱后自动识别服务器").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重新识别") { discover() }
                            .disabled(account.email.isEmpty || discovering)
                    }
                    if let hint = discovered?.hint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                    if let url = discovered?.helpURL.flatMap(URL.init) {
                        Link("打开邮箱设置页面，开启 IMAP / 获取授权码 ↗", destination: url)
                            .font(.caption)
                    }
                }
                Section(isExpanded: $showAdvanced) {
                    TextField("用户名", text: $account.username)
                    TextField("IMAP 服务器", text: $account.host)
                    TextField("端口", value: $account.port, format: .number.grouping(.never))
                    Toggle("使用 SSL/TLS", isOn: $account.useTLS)
                } header: {
                    Text("高级设置")
                }
                if !testResult.isEmpty {
                    Section {
                        Text(testResult).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(testing ? "测试中…" : "测试连接") { test() }
                    .disabled(testing || !isValid)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    if account.displayName.trimmed.isEmpty { account.displayName = account.email }
                    onSave(account, password.isEmpty ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || (isNew && password.isEmpty && account.oauthProvider == nil))
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onChange(of: account.email) {
            // 输入停顿后自动识别
            let email = account.email
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if email == account.email, email.contains("@"), email.contains(".") { discover() }
            }
        }
        .onAppear {
            if !isNew, let p = MailProviderPresets.all.first(where: { $0.host == account.host && !$0.host.isEmpty }) {
                discovered = DiscoveredServer(host: p.host, port: p.port, useTLS: true, providerName: p.name, hint: p.hint, helpURL: p.helpURL)
            }
        }
    }

    private var isValid: Bool {
        !account.email.trimmed.isEmpty && !account.host.trimmed.isEmpty && !account.username.trimmed.isEmpty
    }

    private func discover() {
        let email = account.email.trimmed
        guard email.contains("@") else { return }
        discovering = true
        Task {
            let found = await AccountDiscovery.discover(email: email)
            discovering = false
            guard email == account.email.trimmed else { return }
            discovered = found
            if let found {
                account.host = found.host
                account.port = found.port
                account.useTLS = found.useTLS
            } else {
                showAdvanced = true
                testResult = "未能自动识别服务器，请在高级设置中手动填写 IMAP 服务器。"
            }
        }
    }

    private func test() {
        let pwd = password.isEmpty ? (Keychain.get(Keychain.accountKey(account.id)) ?? "") : password
        testing = true
        testResult = ""
        Task {
            do {
                let credential: IMAPCredential = account.oauthProvider != nil
                    ? try await AppState.shared.credential(for: account)
                    : .password(pwd)
                let n = try await SyncEngine.test(account: account, credential: credential)
                testResult = "✅ 连接成功，收件箱共 \(n) 封邮件"
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
