import AppKit
import SwiftUI

/// Outlook 的三种接入方式：通过 Mac 邮件 App（推荐）/ 转发到其他邮箱 / 微软账号直连。
struct OutlookMethodsView: View {
    let provider: MailProviderPreset
    var onSuccess: (MailAccount, Int) -> Void

    enum Method: String, CaseIterable, Identifiable {
        case appleMail = "通过 Mac 邮件 App（推荐）"
        case forward = "转发到其他邮箱"
        case oauth = "微软账号直连"
        var id: String { rawValue }
    }

    @State var method: Method = .appleMail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                provider.icon(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接 \(provider.name)").font(.title2.bold())
                    Text("微软不再允许第三方软件用密码登录，请选择一种方式").font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch method {
            case .appleMail:
                AppleMailPanel(accountKind: "Outlook.com", onSuccess: onSuccess)
            case .forward:
                ForwardPanel()
            case .oauth:
                OAuthPanel(provider: provider, onSuccess: onSuccess)
            }
        }
    }
}

// MARK: - 通过 Mac 邮件 App

struct AppleMailPanel: View {
    @Environment(AppState.self) private var state
    /// 第一步中提示用户在「互联网账户」里添加的账户类型
    var accountKind: String
    var onSuccess: (MailAccount, Int) -> Void

    @State private var access: AppleMailReader.Access = .notFound
    @State private var found: [AppleMailReader.Account] = []
    @State private var scanning = false
    @State private var scanned = false

    private var granted: Bool { if case .granted = access { return true } else { return false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("macOS 自带的「邮件」App 已经支持微软账号授权登录。让它负责登录和收信，MailMind 从本机读取邮件后再交给 AI 整理。不需要授权码，MailMind 也接触不到你的密码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                step(1, "在系统设置的「互联网账户」中添加 \(accountKind) 账户，并勾选「邮件」") {
                    Button("打开互联网账户") {
                        open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
                    }
                }
                step(2, "打开「邮件」App，确认能收到这个账户的邮件；之后让它保持运行（可以最小化）") {
                    Button("打开邮件 App") {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mail.app"),
                                                           configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                step(3, "允许 MailMind 读取「邮件」App 的数据：在「完全磁盘访问权限」中打开 MailMind 的开关，然后重新打开 MailMind", done: granted) {
                    if granted {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("打开隐私设置") {
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                        }
                    }
                }
                step(4, "选择要接入的账户", done: false) {
                    Button(scanning ? "检测中…" : "检测账户") { scan() }
                        .disabled(scanning)
                }

                if scanned {
                    accountList
                }
            }
            .padding(.trailing, 4)
        }
        .onAppear {
            guard !Snapshot.isActive else { return } // 截图时不读取真实数据
            access = AppleMailReader.access()
            if granted { scan() }
        }
    }

    @ViewBuilder
    private var accountList: some View {
        switch access {
        case .denied:
            NoticeCard(style: .warning, title: "还没有读取权限",
                       message: "请完成第 3 步。开启权限后需要退出并重新打开 MailMind 才会生效。")
        case .notFound:
            NoticeCard(style: .warning, title: "没有找到「邮件」App 的数据",
                       message: "请先完成第 1、2 步，在「邮件」App 中收到邮件后再检测。")
        case .granted:
            if found.isEmpty {
                NoticeCard(style: .info, title: "「邮件」App 中还没有可用的账户",
                           message: "请确认账户已添加，且收件箱里已经有邮件。")
            } else {
                VStack(spacing: 0) {
                    ForEach(found) { a in
                        let added = state.settings.accounts.contains { $0.appleMailInbox == a.inbox.path }
                        HStack {
                            Image(systemName: "tray.full.fill").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.email.isEmpty ? "未识别的账户" : a.email).font(.callout.weight(.medium))
                                Text("收件箱 \(a.messageCount) 封").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if added {
                                Text("已接入").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("接入") { add(a) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(10)
                        Divider()
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func step<Accessory: View>(_ n: Int, _ text: String, done: Bool = false, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor)
                if done {
                    Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                }
            }
            .frame(width: 20, height: 20)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory()
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    private func scan() {
        scanning = true
        access = AppleMailReader.access()
        guard case .granted(let root) = access else {
            scanning = false
            scanned = true
            return
        }
        Task.detached(priority: .userInitiated) {
            let result = AppleMailReader.accounts(root: root)
            await MainActor.run {
                found = result
                scanning = false
                scanned = true
            }
        }
    }

    private func add(_ a: AppleMailReader.Account) {
        let name = a.email.isEmpty ? "邮件 App 账户" : a.email
        let account = MailAccount(displayName: name, email: a.email, username: "", host: "applemail",
                                  appleMailInbox: a.inbox.path)
        state.addAccounts([(account, nil)])
        onSuccess(account, a.messageCount)
    }
}

// MARK: - 转发到其他邮箱

struct ForwardPanel: View {
    @Environment(AppState.self) private var state
    @State private var address = ""
    @State private var name = "Outlook"
    @State private var saved = false

    private var targets: [MailAccount] { state.settings.accounts.filter { !$0.isAppleMail && $0.oauthProvider == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在 Outlook 网页版设置自动转发，把邮件转到一个已经接入 MailMind 的邮箱（如 QQ、163、Gmail）。MailMind 会按原收件人把它们单独归到「\(name)」视图里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if targets.isEmpty {
                NoticeCard(style: .warning, title: "请先添加一个接收邮箱",
                           message: "返回上一页添加 QQ、163 或 Gmail 等邮箱，再回来设置转发。")
            }

            StepList(steps: [
                "打开 Outlook 网页版：设置 → 邮件 → 转发",
                "打开「启用转发」，填写下面任意一个接收邮箱，并勾选「保留转发邮件的副本」，保存",
                "在下面填写你的 Outlook 邮箱地址，点「完成」",
            ], color: Color(hex: 0x0078D4))

            HStack {
                Link(destination: URL(string: "https://outlook.live.com/mail/0/options/mail/forwarding")!) {
                    Label("打开 Outlook 转发设置", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            if !targets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("可用的接收邮箱（点击复制）").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(targets) { t in
                            Button(t.email) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(t.email, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                TextField("你的 Outlook 地址，例如 name@outlook.com", text: $address)
                    .textFieldStyle(.plain)
                    .fieldBox()
                TextField("视图名称", text: $name)
                    .textFieldStyle(.plain)
                    .fieldBox()
                    .frame(width: 130)
            }

            if saved {
                NoticeCard(style: .success, title: "已设置",
                           message: "转发来的邮件会出现在侧边栏「账户」下的「\(name)」中。如果一段时间后仍然是空的，请检查 Outlook 的转发是否已生效。")
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("完成") {
                    state.addForwardAlias(address, name: name)
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!address.contains("@") || targets.isEmpty)
            }
        }
    }
}
