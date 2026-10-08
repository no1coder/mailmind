import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    private var importantUnread: [MailMessage] {
        ((try? state.db.messages(filter: .important, limit: 30)) ?? []).filter { !$0.isRead }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MailMind").font(.headline)
                Spacer()
                if state.isSyncing { ProgressView().controlSize(.small) }
                Text(state.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            let list = importantUnread
            if list.isEmpty {
                Text("没有未读的重要邮件 🎉")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                Text("\(list.count) 封未读重要邮件")
                    .font(.subheadline.bold())
                ForEach(list.prefix(6)) { m in
                    Button {
                        open { state.open(messageID: m.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.headline.isEmpty ? "\(m.sender) · \(m.subject)" : m.headline)
                                .lineLimit(1).font(.callout.weight(.medium))
                            Text("\(m.sender) · \(m.subject)")
                                .lineLimit(2)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }

            HStack {
                Button("立即同步") { state.syncNow() }
                    .disabled(state.isSyncing)
                Button("查看汇总") {
                    open { state.filter = .digest }
                }
                Button("问 AI") {
                    open { state.showAskAI = true }
                }
                .disabled(state.makeAIClient() == nil)
                Spacer()
                Button("打开主窗口") { open {} }
            }
            HStack {
                SettingsLink { Text("设置…") }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func open(_ then: () -> Void) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        then()
    }
}
