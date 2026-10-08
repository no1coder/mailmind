import SwiftUI

/// 添加邮箱的引导流程：选择邮箱 → 按步骤开启 IMAP 并填写授权码 → 连接成功。
/// 面向不懂 IMAP / 授权码的普通用户。
struct AddAccountFlow: View {
    @Environment(AppState.self) private var state

    enum Stage: Equatable {
        case pick
        case login(MailProviderPreset)
        case success(MailAccount, inboxCount: Int)
        case batch
    }

    @State var stage: Stage = .pick
    /// 「完成」按钮的回调；为 nil 时不显示完成按钮（例如嵌入向导中）。
    var onDone: (() -> Void)?

    var body: some View {
        Group {
            switch stage {
            case .pick:
                ProviderPicker { stage = .login($0) } onBatch: { stage = .batch }
            case .login(let provider):
                LoginStage(provider: provider) {
                    stage = .pick
                } onSuccess: { account, count in
                    stage = .success(account, inboxCount: count)
                }
            case .success(let account, let count):
                SuccessStage(account: account, inboxCount: count, onAddAnother: { stage = .pick }, onDone: onDone)
            case .batch:
                VStack(alignment: .leading, spacing: 12) {
                    BackButton { stage = .pick }
                    Text("批量添加邮箱").font(.title2.bold())
                    Text("适合有很多邮箱的用户。每个邮箱都需要先在网页版开启 IMAP 并获取授权码。")
                        .foregroundStyle(.secondary)
                    BatchImportView { if let onDone { onDone() } else { stage = .pick } }
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: stage)
    }
}

private struct BackButton: View {
    var title = "选择其他邮箱"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - 第一步：选择邮箱

private struct ProviderPicker: View {
    var onPick: (MailProviderPreset) -> Void
    var onBatch: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("你用的是哪种邮箱？").font(.title2.bold())
                Text("选择后会一步一步教你连接，大约需要 1 分钟。")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(MailProviderPresets.all) { p in
                    SelectableCard(action: { onPick(p) }) {
                        VStack(spacing: 8) {
                            p.icon(size: 44)
                            Text(p.name).font(.callout.weight(.medium))
                            Text(p.appleMail ? "Exchange 等" : p.supported ? (p.domains.first.map { "@\($0)" } ?? (p.isCustom ? "公司或其他邮箱" : "企业邮箱")) : "暂不支持")
                                .font(.caption2)
                                .foregroundStyle(p.supported ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("MailMind 只读取邮件，不会删除或修改任何内容；密码保存在系统钥匙串中。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("邮箱很多？批量添加", action: onBatch)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

// MARK: - 第二步：登录

private struct LoginStage: View {
    @Environment(AppState.self) private var state
    let provider: MailProviderPreset
    var onBack: () -> Void
    var onSuccess: (MailAccount, Int) -> Void

    @State private var emailInput = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = 993
    @State private var showServer = false
    @State private var working = false
    @State private var progress = ""
    @State private var error: FriendlyError.Message?
    @State private var showExplain = false

    private var email: String { FriendlyError.completeEmail(emailInput, domain: provider.domains.first) }
    private var canConnect: Bool { email.contains("@") && email.contains(".") && !password.isEmpty && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackButton(action: onBack)
            if provider.oauth != nil {
                OutlookMethodsView(provider: provider, onSuccess: onSuccess)
            } else if provider.appleMail {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        provider.icon(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("从 Mac 邮件 App 接入").font(.title2.bold())
                            Text("适合 Outlook、公司 Exchange 等需要授权登录的邮箱").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    AppleMailPanel(accountKind: "邮箱", onSuccess: onSuccess)
                }
            } else {
                HStack(alignment: .top, spacing: 24) {
                    guide
                        .frame(width: 290)
                    form
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            host = provider.host
            port = provider.port
        }
    }

    // 左侧：图文步骤
    private var guide: some View {
        VStack(alignment: .leading, spacing: 14) {
            if provider.supported {
                Text(provider.oauth != nil ? "怎么连接" : (provider.isCustom ? "怎么连接" : "第一次使用，先做这几步"))
                    .font(.headline)
                if !provider.isCustom && provider.oauth == nil {
                    Text("只需要做一次，之后不用再操作。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                StepList(steps: provider.steps, color: provider.color)
                if !provider.note.isEmpty {
                    Text(provider.note).font(.caption).foregroundStyle(.secondary)
                }
                if let url = provider.helpURL.flatMap(URL.init) {
                    Link(destination: url) {
                        Label(provider.helpButtonTitle, systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
                NoticeCard(style: .warning, title: "暂时无法连接 \(provider.name)", message: provider.note)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 右侧：表单
    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                provider.icon(size: 44)
                VStack(alignment: .leading) {
                    Text("登录 \(provider.name)").font(.title2.bold())
                    Text("填写下面两项即可").font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("邮箱地址").font(.callout.weight(.medium))
                HStack(spacing: 0) {
                    TextField(provider.domains.first.map { "例如 zhangsan，会自动补全 @\($0)" } ?? "例如 name@company.com", text: $emailInput)
                        .textFieldStyle(.plain)
                    if let domain = provider.domains.first, !emailInput.contains("@"), !emailInput.isEmpty {
                        Text("@\(domain)").foregroundStyle(.secondary)
                    }
                }
                .fieldBox()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(provider.passwordLabel).font(.callout.weight(.medium))
                    if !provider.passwordExplain.isEmpty {
                        Button {
                            showExplain.toggle()
                        } label: {
                            Label("这是什么？", systemImage: "questionmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showExplain, arrowEdge: .trailing) {
                            Text(provider.passwordExplain)
                                .font(.callout)
                                .padding()
                                .frame(width: 280)
                        }
                    }
                }
                RevealableSecureField(title: provider.passwordLabel == "密码" ? "邮箱密码" : "粘贴\(provider.passwordLabel)", text: $password)
                    .onSubmit { if canConnect { connect() } }
            }

            if showServer {
                DisclosureGroup("服务器设置", isExpanded: $showServer) {
                    HStack {
                        TextField("IMAP 服务器", text: $host).fieldBox()
                        TextField("端口", value: $port, format: .number.grouping(.never))
                            .frame(width: 70)
                            .fieldBox()
                    }
                    .padding(.top, 6)
                }
            }

            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    NoticeCard(style: .error, title: error.title, message: error.detail)
                    if !error.raw.isEmpty {
                        Text("服务器返回：\(error.raw)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            if error == nil {
                Label("只读取邮件，不会删除或修改；\(provider.passwordLabel)只保存在这台 Mac 的钥匙串中。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                if !showServer {
                    Button("手动设置服务器") { showServer = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                Button(action: connect) {
                    Text("连接").frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
    }

    private func connect() {
        let address = email
        let pwd = FriendlyError.cleanPassword(password, label: provider.passwordLabel)
        if state.settings.accounts.contains(where: { $0.email.lowercased() == address.lowercased() }) {
            error = .init(title: "这个邮箱已经添加过了", detail: "可以在账户列表中找到它。")
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            var server = (host: host, port: port, tls: true)
            if server.host.trimmed.isEmpty {
                progress = "正在查找邮箱服务器…"
                guard let found = await AccountDiscovery.discover(email: address) else {
                    error = .init(title: "没找到这个邮箱的服务器",
                                  detail: "请在邮箱服务商的帮助页面查找「IMAP 服务器地址」，然后点「手动设置服务器」填写。")
                    showServer = true
                    return
                }
                server = (found.host, found.port, found.useTLS)
                host = found.host
                port = found.port
            }
            progress = "正在登录…"
            let account = MailAccount(displayName: address, email: address, username: address,
                                      host: server.host.trimmed, port: server.port, useTLS: server.tls)
            do {
                let count = try await SyncEngine.test(account: account, password: pwd)
                state.saveAccount(account, password: pwd)
                onSuccess(account, count)
            } catch {
                self.error = FriendlyError.connection(error, passwordLabel: provider.passwordLabel)
            }
        }
    }
}

// MARK: - OAuth 登录（Outlook）

struct OAuthPanel: View {
    @Environment(AppState.self) private var state
    let provider: MailProviderPreset
    var onSuccess: (MailAccount, Int) -> Void

    @State private var emailHint = ""
    @State private var clientID = ""
    @State private var working = false
    @State private var error: FriendlyError.Message?
    @State private var showHowTo = false

    private var configured: Bool { !state.settings.microsoftOAuth.clientID.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                provider.icon(size: 44)
                VStack(alignment: .leading) {
                    Text("登录 \(provider.name)").font(.title2.bold())
                    Text("通过微软官方页面授权，无需授权码").font(.callout).foregroundStyle(.secondary)
                }
            }

            if !configured {
                VStack(alignment: .leading, spacing: 8) {
                    NoticeCard(style: .warning, title: "这个版本还没有配置微软应用 ID",
                               message: "开发者在微软免费注册一次即可，所有用户共用。如果你是开发者，把应用 ID 粘贴到下面。")
                    HStack {
                        TextField("应用（客户端）ID，例如 1a2b3c4d-…", text: $clientID)
                            .textFieldStyle(.plain)
                            .fieldBox()
                        Button("保存") { state.settings.microsoftClientID = clientID.trimmed }
                            .disabled(clientID.trimmed.count < 30)
                    }
                    Button("如何获取应用 ID？") { showHowTo.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .popover(isPresented: $showHowTo) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("注册微软应用（约 5 分钟，免费）").font(.headline)
                                StepList(steps: [
                                    "打开 portal.azure.com，进入「Microsoft Entra ID」→「应用注册」→「新注册」",
                                    "账户类型选「任何组织目录中的帐户和个人 Microsoft 帐户」",
                                    "重定向 URI 选「公共客户端/本机」，填写 mailmind://oauth",
                                    "在「API 权限」中添加 Microsoft Graph 的 IMAP.AccessAsUser.All、offline_access、openid、email",
                                    "复制概览页的「应用程序(客户端) ID」，粘贴到这里",
                                ], color: provider.color)
                            }
                            .padding()
                            .frame(width: 400)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("邮箱地址（可选）").font(.callout.weight(.medium))
                TextField("例如 name@outlook.com，方便自动选中账号", text: $emailHint)
                    .textFieldStyle(.plain)
                    .fieldBox()
            }

            if let error {
                NoticeCard(style: .error, title: error.title, message: error.detail)
            } else {
                Label("MailMind 只获得读取邮件的权限，看不到你的密码；随时可以在微软账户中撤销授权。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                    Text("请在弹出的页面中完成登录…").font(.callout).foregroundStyle(.secondary)
                }
                Button(action: signIn) {
                    HStack(spacing: 8) {
                        MicrosoftLogo().frame(width: 14, height: 14)
                        Text("使用微软账号登录")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(working || !configured)
            }
        }
    }

    private func signIn() {
        let hint = emailHint.trimmed
        if !hint.isEmpty, state.settings.accounts.contains(where: { $0.email.lowercased() == hint.lowercased() }) {
            error = .init(title: "这个邮箱已经添加过了", detail: "可以在账户列表中找到它；授权过期时可在那里「重新登录」。")
            return
        }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let (account, count) = try await state.signInWithMicrosoft(loginHint: hint.isEmpty ? nil : hint)
                onSuccess(account, count)
            } catch OAuthError.cancelled {
                // 用户关闭了登录页，不提示
            } catch {
                self.error = FriendlyError.oauth(error)
            }
        }
    }
}

/// 微软四色方块标志。
struct MicrosoftLogo: View {
    var body: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                Rectangle().fill(Color(hex: 0xF25022))
                Rectangle().fill(Color(hex: 0x7FBA00))
            }
            GridRow {
                Rectangle().fill(Color(hex: 0x00A4EF))
                Rectangle().fill(Color(hex: 0xFFB900))
            }
        }
    }
}

// MARK: - 第三步：成功

private struct SuccessStage: View {
    @Environment(AppState.self) private var state
    let account: MailAccount
    let inboxCount: Int
    var onAddAnother: () -> Void
    var onDone: (() -> Void)?

    @State private var name = ""
    private let suggestions = ["工作", "个人", "购物", "订阅", "家庭"]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.bounce, value: account.id)
            VStack(spacing: 6) {
                Text("连接成功！").font(.title.bold())
                Text("\(account.email) · 收件箱共 \(inboxCount) 封邮件")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("给它起个名字（可选）").font(.callout.weight(.medium))
                TextField(account.email, text: $name)
                    .textFieldStyle(.plain)
                    .fieldBox()
                    .onChange(of: name) { state.renameAccount(account.id, name.trimmed.isEmpty ? account.email : name.trimmed) }
                HStack {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { name = s }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            .frame(width: 360)
            Text("MailMind 正在后台整理最近几天的邮件，重要的会第一时间提醒你。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("再添加一个邮箱", action: onAddAnother)
                    .controlSize(.large)
                if let onDone {
                    Button("完成", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
