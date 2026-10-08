import SwiftUI

struct MessageListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedIDs) {
            ForEach(Self.group(state.messages), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.messages) { m in
                        MessageRow(message: m,
                                   accountName: state.settings.accounts.count > 1 ? state.account(id: m.accountID)?.displayName : nil,
                                   isVIP: state.rule(for: m)?.notify == .always)
                            .tag(m.id)
                            .contextMenu { contextMenu(for: m) }
                    }
                }
            }
        }
        .overlay {
            if state.messages.isEmpty {
                ContentUnavailableView(state.searchText.isEmpty ? emptyTitle : "没有匹配的邮件",
                                       systemImage: state.searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
            }
        }
        .onChange(of: state.selectedIDs) { _, ids in
            if ids.count == 1, let id = ids.first { state.markRead(id) }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    state.showCleanup = true
                } label: {
                    Label("清理", systemImage: "trash.circle")
                }
                .help("批量删除 AI 识别出的垃圾、营销邮件")
            }
            ToolbarItem {
                Button {
                    state.markAllReadInCurrentView()
                } label: {
                    Label("全部标为已读", systemImage: "envelope.open")
                }
                .help("将当前列表全部标为已读")
                .disabled(!state.messages.contains { !$0.isRead })
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for m: MailMessage) -> some View {
        let ids = state.selectedIDs.contains(m.id) ? Array(state.selectedIDs) : [m.id]
        Button(m.isRead ? "标为未读" : "标为已读") { state.setRead(ids, read: !m.isRead) }
        Divider()
        Button("重新 AI 分析") { state.reanalyze(m.id) }
        Divider()
        MarkMenuItems(ids: ids, message: m)
    }

    private var emptyTitle: String {
        state.filter == .important ? "没有重要邮件，一切顺利 🎉" : "没有邮件"
    }

    private var title: String {
        switch state.filter {
        case .important: return "重要"
        case .action: return "待处理"
        case .inbox, .digest: return "全部邮件"
        case .category(let c): return c.rawValue
        case .account(let id): return state.account(id: id)?.displayName ?? "账户"
        case .alias(let address): return state.settings.forwardAliases.first { $0.address == address }?.name ?? address
        }
    }

    private var subtitle: String {
        let unread = state.messages.filter { !$0.isRead }.count
        return unread > 0 ? "\(unread) 封未读" : "\(state.messages.count) 封"
    }

    struct DateSection {
        var title: String
        var messages: [MailMessage]
    }

    /// 按「今天 / 昨天 / 本周 / 更早」分组（输入已按时间倒序）。
    static func group(_ messages: [MailMessage], now: Date = Date()) -> [DateSection] {
        let cal = Calendar.current
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "今天" }
            if cal.isDateInYesterday(d) { return "昨天" }
            if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7 {
                return "本周"
            }
            return "更早"
        }
        var sections: [DateSection] = []
        for m in messages {
            let t = bucket(m.date)
            if sections.last?.title == t {
                sections[sections.count - 1].messages.append(m)
            } else {
                sections.append(DateSection(title: t, messages: [m]))
            }
        }
        return sections
    }
}

struct MessageRow: View {
    let message: MailMessage
    let accountName: String?
    var isVIP = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: message.fromName, email: message.fromEmail, size: 34)
                .overlay(alignment: .topLeading) {
                    if !message.isRead {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .offset(x: -3, y: -3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(message.sender)
                        .font(.callout.weight(message.isRead ? .medium : .bold))
                        .lineLimit(1)
                    if isVIP {
                        Text("VIP")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if message.importance == .high {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Spacer()
                    Text(message.date, format: Self.dateStyle(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(message.isRead ? .secondary : .primary)
                    .lineLimit(2)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                tags
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var tags: some View {
        let hasTags = message.mailCategory != nil || message.aiStatus != .done || message.deadlineDate != nil
            || !message.code.isEmpty || !message.attachments.isEmpty || accountName != nil
        if hasTags {
            HStack(spacing: 6) {
                if let c = message.mailCategory {
                    CategoryBadge(category: c)
                } else if message.aiStatus == .pending {
                    Label("分析中", systemImage: "sparkles").font(.caption2).foregroundStyle(.tertiary)
                } else if message.aiStatus == .failed {
                    Label("分析失败", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let due = message.deadlineDate {
                    DeadlineBadge(date: due)
                }
                if !message.code.isEmpty {
                    Label(message.code, systemImage: "key.fill").font(.caption2.monospaced()).foregroundStyle(.blue)
                }
                if !message.attachments.isEmpty {
                    Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let accountName {
                    Text(accountName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.top, 1)
        }
    }

    /// 第一行优先显示 AI 的一句话总结，没有时显示主题。
    private var preview: String {
        message.headline.isEmpty ? message.subject : message.headline
    }

    private var secondaryLine: String {
        message.headline.isEmpty ? (message.summary.isEmpty ? message.snippet : message.summary) : message.subject
    }

    static func dateStyle(_ date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.month().day()
    }
}

struct CategoryBadge: View {
    let category: MailCategory

    var body: some View {
        Label(category.rawValue, systemImage: category.symbol)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(category.color.opacity(0.15), in: Capsule())
            .foregroundStyle(category.color)
    }
}

struct DeadlineBadge: View {
    let date: Date

    var body: some View {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 0
        let text: String = days < 0 ? "已过期" : days == 0 ? "今天截止" : days == 1 ? "明天截止" : "\(date.formatted(.dateTime.month().day())) 截止"
        Label(text, systemImage: "calendar.badge.clock")
            .font(.caption2)
            .foregroundStyle(days <= 1 ? .red : .orange)
    }
}
