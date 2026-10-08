import SwiftUI

/// 首次启动向导：添加邮箱 → 连接 AI → 提醒方式。
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var step = 0

    private let titles = ["添加邮箱", "连接 AI", "提醒方式"]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 18)
            Divider()
            Group {
                switch step {
                case 0: AccountsStep()
                case 1: AIStep()
                default: NotifyStep()
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .frame(width: 780, height: 620)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppLogo(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("欢迎使用 MailMind").font(.title3.bold())
                Text("三步完成设置，让 AI 帮你管邮件").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        ZStack {
                            Circle().fill(i < step ? Color.green : (i == step ? Color.accentColor : Color.secondary.opacity(0.2)))
                            if i < step {
                                Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                            } else {
                                Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(i == step ? .white : .secondary)
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(titles[i]).font(.caption).foregroundStyle(i == step ? .primary : .secondary)
                    }
                    if i < titles.count - 1 {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 16, height: 1)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step == 0 {
                Button("跳过，稍后设置") { finish() }
                    .buttonStyle(.borderless)
            } else {
                Button("上一步") { step -= 1 }
            }
            Spacer()
            if step == 0 && state.settings.accounts.isEmpty {
                Text("至少添加一个邮箱后继续").font(.caption).foregroundStyle(.secondary)
            }
            if step < titles.count - 1 {
                Button("下一步") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 0 && state.settings.accounts.isEmpty)
            } else {
                Button("开始使用") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    private func finish() {
        state.settings.hasCompletedOnboarding = true
        state.refreshRealtime()
        dismiss()
    }
}

private struct AccountsStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.settings.accounts.isEmpty {
                HStack(spacing: 8) {
                    Text("已添加").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.settings.accounts) { a in
                        HStack(spacing: 4) {
                            (MailProviderPreset.forAccount(a) ?? MailProviderPresets.all.last!).icon(size: 16)
                            Text(a.email).font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }
            }
            AddAccountFlow()
        }
    }
}

private struct AIStep: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择一个 AI 服务").font(.title2.bold())
                    Text("AI 会给每封邮件写一句话总结、自动分类、翻译外文邮件，并判断哪些值得提醒你。")
                        .foregroundStyle(.secondary)
                }
                AIProviderForm()
            }
        }
    }
}

private struct NotifyStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("什么时候提醒你？").font(.title2.bold())
                Text("MailMind 只在真正需要你马上知道时才会打扰你。").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                levelCard("bell.badge.fill", .red, "响铃提醒", "需要你回复的真人邮件、快到期的事、账号安全、付款异常、验证码")
                levelCard("bell.fill", .blue, "安静通知", "其他重要邮件，只出现在通知中心，不响铃")
                levelCard("tray.full.fill", .gray, "定期汇总", "营销、资讯、社交动态，每天汇总成一份摘要")
            }
            VStack(spacing: 0) {
                toggleRow("新邮件实时推送", "支持的邮箱几秒内就能收到", $settings.realtimeEnabled)
                Divider()
                toggleRow("夜间勿扰", "22:00–08:00 只提醒 VIP 和验证码", $settings.quietHoursEnabled)
                Divider()
                toggleRow("每天汇总非重点邮件", "每天 \(String(format: "%02d:%02d", settings.digestHour, settings.digestMinute)) 生成", $settings.digestEnabled)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func levelCard(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            Text(title).font(.headline)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
