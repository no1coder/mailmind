import AppKit
import SwiftUI

/// 设置 →「转发」：把重要邮件发到 Telegram、微信（OpenClaw）或 Webhook。
struct ForwardSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var editing: ForwardChannel?

    var body: some View {
        @Bindable var settings = state.settings
        SnapshotSafeScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("转发重要邮件").font(.headline)
                        Text("不在电脑前时，把重要邮件的一句话总结发到手机上。只发送 AI 提炼的标题、摘要和发件人，不发送邮件正文。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Menu {
                        ForEach(ForwardChannel.Kind.allCases) { k in
                            Button {
                                editing = ForwardChannel.new(k)
                            } label: {
                                Label(k.label, systemImage: k.symbol)
                            }
                        }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .fixedSize()
                }

                if settings.forwardChannels.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(ForwardChannel.Kind.allCases) { k in
                            SelectableCard(action: { editing = ForwardChannel.new(k) }) {
                                VStack(spacing: 8) {
                                    BrandIcon(badge: "", symbol: k.symbol, color: Color(hex: k.colorHex), size: 40)
                                    Text(k.label).font(.callout.weight(.medium))
                                    Text(kindHint(k)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(settings.forwardChannels) { c in
                            ChannelRow(channel: c, onEdit: { editing = c })
                            Divider()
                        }
                    }
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("转发不受「重要邮件通知」开关和勿扰时段影响。每次同步超过 3 封时合并成一条发送。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .sheet(item: $editing) { c in
            ForwardEditor(channel: c, isNew: !state.settings.forwardChannels.contains { $0.id == c.id })
                .environment(state)
        }
    }

    private func kindHint(_ k: ForwardChannel.Kind) -> String {
        switch k {
        case .telegram: return "通过你自己的机器人发给你"
        case .openclaw: return "通过 OpenClaw 发到微信"
        case .webhook: return "企业微信、飞书、钉钉群机器人等"
        }
    }
}

private struct ChannelRow: View {
    @Environment(AppState.self) private var state
    let channel: ForwardChannel
    var onEdit: () -> Void
    @State private var testing = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 10) {
            BrandIcon(badge: "", symbol: channel.kind.symbol, color: Color(hex: channel.kind.colorHex), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.callout.weight(.medium))
                Text(result ?? summary)
                    .font(.caption)
                    .foregroundStyle(result == nil ? Color.secondary : (failed ? Color.red : Color.green))
                    .lineLimit(2)
            }
            Spacer()
            Button(testing ? "发送中…" : "测试") { test() }
                .disabled(testing)
            Button("编辑", action: onEdit)
            Toggle("", isOn: Binding(get: { channel.enabled }, set: { v in
                if let i = state.settings.forwardChannels.firstIndex(where: { $0.id == channel.id }) {
                    state.settings.forwardChannels[i].enabled = v
                }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: String {
        let scope = channel.accountIDs.isEmpty ? "所有邮箱" : channel.accountIDs.compactMap { state.account(id: $0)?.displayName }.joined(separator: "、")
        return "\(channel.trigger.label) · \(scope)" + (channel.includeCodes ? " · 含验证码" : "")
    }

    private func test() {
        testing = true
        result = nil
        Task {
            do {
                try await state.testForward(channel)
                failed = false
                result = channel.kind == .openclaw ? "已提交给 OpenClaw，稍后在微信中查看" : "已发送，请在手机上查看"
            } catch {
                failed = true
                result = error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - 编辑

struct ForwardEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var channel: ForwardChannel
    let isNew: Bool

    @State private var secret = ""
    @State private var chats: [Forwarder.TelegramChat] = []
    @State private var finding = false
    @State private var message: (String, Bool)?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandIcon(badge: "", symbol: channel.kind.symbol, color: Color(hex: channel.kind.colorHex), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "添加 \(channel.kind.label) 转发" : "编辑转发").font(.title3.bold())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                switch channel.kind {
                case .telegram: telegramSection
                case .openclaw: openClawSection
                case .webhook: webhookSection
                }
                Section("转发哪些邮件") {
                    Picker("内容", selection: $channel.trigger) {
                        ForEach(ForwardChannel.Trigger.allCases) { t in
                            VStack(alignment: .leading) {
                                Text(t.label)
                                Text(t.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(t)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Toggle("包含验证码", isOn: $channel.includeCodes)
                    if state.settings.accounts.count > 1 {
                        accountPicker
                    }
                }
                Section {
                    TextField("名称", text: $channel.name)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let (text, ok) = message {
                    Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ok ? .green : .red)
                        .lineLimit(2)
                }
                Spacer()
                Button(testing ? "发送中…" : "发送测试") { test() }
                    .disabled(testing)
                if !isNew {
                    Button("删除", role: .destructive) {
                        state.settings.forwardChannels.removeAll { $0.id == channel.id }
                        Keychain.delete(channel.secretKey)
                        dismiss()
                    }
                }
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 600, height: 640)
        .onAppear { secret = Keychain.get(channel.secretKey) ?? "" }
    }

    private var subtitle: String {
        switch channel.kind {
        case .telegram: return "通过你自己创建的 Telegram 机器人，把重要邮件发给你"
        case .openclaw: return "通过本机或服务器上的 OpenClaw，把重要邮件发到微信"
        case .webhook: return "向任意地址发送 POST 请求"
        }
    }

    // MARK: Telegram

    @ViewBuilder
    private var telegramSection: some View {
        Section {
            StepList(steps: [
                "在 Telegram 中搜索 @BotFather，发送 /newbot，按提示起名，拿到机器人令牌（Token）",
                "把令牌填到下面",
                "在 Telegram 里找到你的机器人，给它发任意一条消息（例如 hi）",
                "点「获取 Chat ID」，选择你自己",
            ], color: Color(hex: 0x229ED9))
            HStack {
                Link(destination: URL(string: "https://t.me/BotFather")!) {
                    Label("打开 BotFather", systemImage: "arrow.up.forward.app")
                }
                Spacer()
            }
        } header: {
            Text("设置步骤")
        }
        Section("机器人") {
            SecureField("令牌", text: $secret, prompt: Text("例如 123456789:AAH…"))
            HStack {
                TextField("Chat ID", text: $channel.chatID, prompt: Text("点右侧按钮自动获取"))
                Button(finding ? "获取中…" : "获取 Chat ID") { findChats() }
                    .disabled(secret.trimmed.isEmpty || finding)
            }
            if chats.count > 1 {
                Picker("选择会话", selection: $channel.chatID) {
                    ForEach(chats, id: \.id) { Text("\($0.title)（\($0.id)）").tag($0.id) }
                }
            }
        }
    }

    private func findChats() {
        finding = true
        message = nil
        Task {
            do {
                chats = try await Forwarder.telegramChats(token: secret)
                if let first = chats.first {
                    channel.chatID = first.id
                    message = ("已找到：\(first.title)", true)
                } else {
                    message = ("没有找到消息。请先在 Telegram 里给机器人发一条消息，再点获取", false)
                }
            } catch {
                message = (error.localizedDescription, false)
            }
            finding = false
        }
    }

    // MARK: OpenClaw

    private var hooksConfig: String {
        """
        hooks: {
          enabled: true,
          token: "\(secret.isEmpty ? "<令牌>" : secret)",
          path: "/hooks",
        },
        """
    }

    @ViewBuilder
    private var openClawSection: some View {
        Section {
            StepList(steps: [
                "安装 OpenClaw，并安装微信插件：npx -y @tencent-weixin/openclaw-weixin-cli install",
                "在运行 OpenClaw 的电脑上执行 openclaw channels login --channel openclaw-weixin，用微信扫码登录",
                "点下面「生成令牌」，把配置片段复制到 OpenClaw 配置文件（~/.openclaw/openclaw.json）中，然后重启 OpenClaw",
                "填写接收人的微信 ID，点「发送测试」",
            ], color: Color(hex: 0x07C160))
            HStack {
                Link(destination: URL(string: "https://docs.openclaw.ai/channels/wechat")!) {
                    Label("微信接入文档", systemImage: "book")
                }
                Link(destination: URL(string: "https://docs.openclaw.ai/automation/cron-jobs/webhooks")!) {
                    Label("Webhook 文档", systemImage: "book")
                }
                Spacer()
            }
        } header: {
            Text("设置步骤")
        }
        Section {
            TextField("地址", text: $channel.url, prompt: Text("http://127.0.0.1:18789/hooks/agent"))
            HStack {
                SecureField("令牌", text: $secret, prompt: Text("与 OpenClaw 配置中的 hooks.token 一致"))
                Button("生成令牌") { secret = Forwarder.randomToken() }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("OpenClaw 配置片段").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hooksConfig, forType: .string)
                    }
                    .controlSize(.small)
                }
                Text(hooksConfig)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        } header: {
            Text("OpenClaw")
        }
        Section {
            TextField("频道", text: $channel.channel, prompt: Text("openclaw-weixin"))
            TextField("接收人", text: $channel.to, prompt: Text("微信用户 ID"))
            TextField("智能体", text: $channel.agentID, prompt: Text("可选，默认使用主智能体"))
        } header: {
            Text("发给谁")
        } footer: {
            Text("接收人 ID 可在 OpenClaw 的会话列表或日志中查看。频道和接收人都留空时，消息会发到 OpenClaw 主会话。频道填 telegram、whatsapp 等也可以发到 OpenClaw 支持的其他聊天软件。邮件来自外部、内容不可信，建议给它配置一个没有工具权限的智能体。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Webhook

    @ViewBuilder
    private var webhookSection: some View {
        Section {
            Picker("格式", selection: $channel.webhookFormat) {
                ForEach(ForwardChannel.WebhookFormat.allCases) { Text($0.label).tag($0) }
            }
            TextField("地址", text: $channel.url, prompt: Text("https://…"))
            SecureField("Bearer 令牌", text: $secret, prompt: Text("可选"))
        } header: {
            Text("Webhook")
        } footer: {
            Text(channel.webhookFormat == .json
                 ? "POST JSON：{ event, text, mail: { from, subject, headline, summary, action, deadline, code, … } }"
                 : "在群设置中添加自定义机器人，复制它的 Webhook 地址填到这里。钉钉机器人如果开启了「自定义关键词」，请把关键词设为「邮件」或「发件人」。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 账户

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("所有邮箱", isOn: Binding(get: { channel.accountIDs.isEmpty }, set: { all in
                channel.accountIDs = all ? [] : state.settings.accounts.map(\.id)
            }))
            if !channel.accountIDs.isEmpty {
                ForEach(state.settings.accounts) { a in
                    Toggle(a.displayName, isOn: Binding(get: { channel.accountIDs.contains(a.id) }, set: { on in
                        if on { channel.accountIDs.append(a.id) } else { channel.accountIDs.removeAll { $0 == a.id } }
                    }))
                    .padding(.leading, 18)
                }
            }
        }
    }

    // MARK: 操作

    private func save() {
        if channel.name.trimmed.isEmpty { channel.name = channel.kind.label }
        Keychain.set(secret.trimmed, for: channel.secretKey)
        if let i = state.settings.forwardChannels.firstIndex(where: { $0.id == channel.id }) {
            state.settings.forwardChannels[i] = channel
        } else {
            state.settings.forwardChannels.append(channel)
        }
    }

    private func test() {
        testing = true
        message = nil
        Task {
            do {
                try await state.testForward(channel, secret: secret.trimmed)
                message = (channel.kind == .openclaw ? "已提交给 OpenClaw，稍后在微信中查看" : "已发送，请查看", true)
            } catch {
                message = (error.localizedDescription, false)
            }
            testing = false
        }
    }
}
