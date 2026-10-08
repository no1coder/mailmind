import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettingsView()
                .tabItem { Label("账户", systemImage: "at") }
            AISettingsView()
                .tabItem { Label("AI 服务", systemImage: "sparkles") }
            RulesSettingsView()
                .tabItem { Label("分类规则", systemImage: "list.bullet.rectangle") }
            NotificationSettingsView()
                .tabItem { Label("同步与通知", systemImage: "bell.badge") }
            SenderRulesView()
                .tabItem { Label("发件人", systemImage: "person.2") }
        }
        .frame(width: 660, height: 560)
    }
}

// MARK: - AI

struct AISettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $settings.aiEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 AI").font(.headline)
                        Text("一句话总结、自动分类、翻译、智能提醒").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                if settings.aiEnabled {
                    AIProviderForm()
                }
                Text("邮件内容会发送给所选 AI 服务处理；如注重隐私，可选择 Ollama 在本机运行。API Key 保存在系统钥匙串中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

// MARK: - 规则

struct RulesSettingsView: View {
    @Environment(AppState.self) private var state

    private static let example = """
    例如：
    - 来自 boss@company.com 的邮件一律为重要
    - GitHub 的 PR review 请求归为工作，重要性 high
    - 招聘网站的职位推荐归为营销
    - 银行的月度账单归为账单，重要性 normal
    """

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section("翻译") {
                Toggle("自动翻译外语邮件", isOn: $settings.autoTranslate)
                TextField("目标语言", text: $settings.targetLanguage)
            }
            Section {
                TextEditor(text: $settings.customRules)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if settings.customRules.isEmpty {
                            Text(Self.example)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("自定义分类规则")
            } footer: {
                Text("用自然语言描述你的规则，会追加到 AI 提示词中，优先级高于默认规则。修改后对新邮件生效，可在邮件上点「重新分析」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("重新分析所有失败的邮件") { state.retryFailed() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 同步与通知

struct NotificationSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError = ""

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                Toggle("实时推送（IMAP IDLE）", isOn: $settings.realtimeEnabled)
                    .onChange(of: settings.realtimeEnabled) { state.refreshRealtime() }
                Stepper("每 \(settings.syncIntervalMinutes) 分钟全量检查所有邮箱", value: $settings.syncIntervalMinutes, in: 1...120)
                Stepper("首次同步最近 \(settings.initialSyncDays) 天的邮件", value: $settings.initialSyncDays, in: 1...60)
                Stepper("每次最多同步 \(settings.maxMessagesPerSync) 封", value: $settings.maxMessagesPerSync, in: 20...2000, step: 20)
            } header: {
                Text("拉取频率")
            } footer: {
                Text("支持实时推送的邮箱（如 QQ、Gmail）新邮件到达几秒内就会拉取，账户旁显示绿点；不支持的邮箱自动改为每 5 分钟检查一次。全量检查作为兜底，Mac 从睡眠中唤醒时也会立即同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("重要邮件通知", isOn: $settings.notifyImportant)
                Toggle("勿扰时段", isOn: $settings.quietHoursEnabled)
                if settings.quietHoursEnabled {
                    HStack {
                        DatePicker("从", selection: minuteBinding($settings.quietStart), displayedComponents: .hourAndMinute)
                        DatePicker("到", selection: minuteBinding($settings.quietEnd), displayedComponents: .hourAndMinute)
                    }
                }
                Button("发送测试通知") { Notifier.shared.notifyTest() }
                if !Notifier.shared.isAvailable {
                    Text("当前以开发模式运行，系统通知不可用。请用 make run 打包成 .app 后运行。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("通知")
            } footer: {
                Text("""
                🔔 响铃：真人发来需尽快回复、48 小时内截止、账号安全异常、付款异常、验证码、VIP 发件人
                🔕 静默：其他重要邮件，只进入通知中心
                ✖︎ 不通知：营销、资讯、社交、垃圾、已在其他设备读过、静音的发件人
                勿扰时段内只有 VIP 和验证码会响铃；一次超过 3 封会合并为一条通知。
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("定期汇总") {
                Toggle("定期生成非重点邮件汇总", isOn: $settings.digestEnabled)
                Picker("频率", selection: $settings.digestFrequency) {
                    ForEach(DigestFrequency.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("时间", selection: Binding<Date>(
                    get: {
                        Calendar.current.date(bySettingHour: settings.digestHour, minute: settings.digestMinute, second: 0, of: Date()) ?? Date()
                    },
                    set: { date in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                        settings.digestHour = c.hour ?? 20
                        settings.digestMinute = c.minute ?? 0
                    }
                ), displayedComponents: .hourAndMinute)
            }

            Section("启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError = ""
                        } catch {
                            launchError = error.localizedDescription
                        }
                    }
                if !launchError.isEmpty {
                    Text(launchError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 把「一天中的分钟数」绑定成 DatePicker 能用的 Date。
    private func minuteBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}

// MARK: - 发件人规则

struct SenderRulesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let rules = state.senderRules.values.sorted { $0.email < $1.email }
        VStack(alignment: .leading) {
            Table(rules) {
                TableColumn("发件人", value: \.email)
                TableColumn("VIP") { r in
                    Toggle("", isOn: Binding(get: { r.vip }, set: { v in
                        state.updateSenderRule(r.email) { $0.vip = v; if v { $0.muted = false } }
                    })).labelsHidden()
                }
                .width(40)
                TableColumn("静音") { r in
                    Toggle("", isOn: Binding(get: { r.muted }, set: { v in
                        state.updateSenderRule(r.email) { $0.muted = v; if v { $0.vip = false } }
                    })).labelsHidden()
                }
                .width(40)
                TableColumn("固定分类") { r in
                    Picker("", selection: Binding(get: { r.category }, set: { v in
                        state.setSenderCategory(r.email, MailCategory(rawValue: v))
                    })) {
                        Text("交给 AI").tag("")
                        ForEach(MailCategory.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                .width(110)
            }
            .overlay {
                if rules.isEmpty {
                    ContentUnavailableView("还没有发件人规则", systemImage: "person.2",
                                           description: Text("在邮件上右键 →「设为 VIP」「静音此发件人」「以后都归为…」即可添加"))
                }
            }
            Text("VIP：总是响铃提醒（包括勿扰时段）。静音：永不提醒。固定分类为营销 / 垃圾 / 社交 / 通知时不再调用 AI，节省费用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
