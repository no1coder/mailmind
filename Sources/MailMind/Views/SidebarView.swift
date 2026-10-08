import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let selection = Binding<SidebarItem?>(
            get: { state.filter },
            set: { if let v = $0 { state.filter = v } }
        )
        List(selection: selection) {
            Section("智能视图") {
                row(.important, "重要", "star.fill", .yellow, count: state.unreadCounts["@important"])
                row(.action, "待处理", "checklist", .orange, count: state.unreadCounts["@action"])
                row(.inbox, "全部邮件", "tray.full", .accentColor, count: state.unreadCounts["@all"])
                row(.digest, "定期汇总", "doc.text.magnifyingglass", .teal, count: nil)
            }
            Section("AI 分类") {
                ForEach(MailCategory.allCases) { c in
                    row(.category(c), c.rawValue, c.symbol, c.color, count: state.unreadCounts[c.rawValue])
                }
            }
            if !state.settings.accounts.isEmpty {
                Section("账户") {
                    ForEach(state.settings.accounts) { a in
                        AccountRow(account: a, status: state.accountStatus[a.id])
                            .tag(SidebarItem.account(a.id))
                            .contextMenu {
                                Button("立即同步") { state.syncAccount(a.id) }
                                Button(a.enabled ? "停用" : "启用") { state.setAccountEnabled(a.id, !a.enabled) }
                                SettingsLink { Text("管理账户…") }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(Snapshot.isActive ? .hidden : .automatic)
        .background(Snapshot.isActive ? Color(nsColor: .underPageBackgroundColor) : .clear)
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, _ color: Color, count: Int?) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .badge(count ?? 0)
        .tag(item)
    }
}

/// 账户行：状态点（绿 = 实时推送中，蓝 = 正常轮询，红 = 出错，灰 = 停用）。
struct AccountRow: View {
    let account: MailAccount
    let status: AccountStatus?

    var body: some View {
        HStack(spacing: 6) {
            Label(account.displayName, systemImage: "at")
            Spacer()
            if status?.syncing == true {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
        }
        .opacity(account.enabled ? 1 : 0.5)
        .help(help)
    }

    private var color: Color {
        guard account.enabled else { return .gray }
        if status?.error != nil { return .red }
        if status?.realtime == true { return .green }
        return .blue
    }

    private var help: String {
        guard account.enabled else { return "已停用" }
        if let e = status?.error { return "同步出错：\(e)" }
        var parts: [String] = [status?.realtime == true ? "实时推送已连接" : "定时轮询"]
        if let t = status?.lastSync { parts.append("上次同步 \(t.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }
}
