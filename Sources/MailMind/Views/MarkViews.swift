import SwiftUI

/// 打开「标记」面板的请求。
struct MarkRequest: Identifiable {
    var id = UUID()
    var ids: [String]
    var category: MailCategory
}

/// 邮件右键菜单 / 详情页「标记」菜单里的条目。
struct MarkMenuItems: View {
    @Environment(AppState.self) private var state
    let ids: [String]
    let message: MailMessage

    var body: some View {
        Button("标记为垃圾邮件…") { state.markRequest = MarkRequest(ids: ids, category: .spam) }
        Menu("标记为…") {
            ForEach(MailCategory.allCases) { c in
                Button {
                    state.markRequest = MarkRequest(ids: ids, category: c)
                } label: {
                    if message.category == c.rawValue && ids.count == 1 {
                        Label(c.rawValue, systemImage: "checkmark")
                    } else {
                        Label(c.rawValue, systemImage: c.symbol)
                    }
                }
            }
        }
        let notify = state.senderOnlyRule(message.fromEmail)?.notify ?? .auto
        Menu("\(message.fromEmail) 的提醒") {
            ForEach(RuleNotify.allCases) { n in
                Button {
                    state.setSenderNotify(message.fromEmail, n)
                } label: {
                    if notify == n { Label(n.label, systemImage: "checkmark") } else { Text(n.label) }
                }
            }
        }
        Divider()
        Button(ids.count > 1 ? "删除 \(ids.count) 封邮件…" : "删除…", role: .destructive) {
            state.deleteRequest = ids
        }
    }
}

// MARK: - 标记面板

struct MarkSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: MarkRequest

    enum Scope: Hashable {
        case once, sender, domain
    }

    @State private var category: MailCategory = .spam
    @State private var scope: Scope = .sender
    @State private var keywords = ""
    @State private var allAccounts = true
    @State private var exceptCodes = true
    @State private var notify: RuleNotify = .auto
    @State private var applyExisting = true
    @State private var deleteNow = false
    @State private var affected = 0

    private var messages: [MailMessage] { request.ids.compactMap { state.message(id: $0) } }
    private var senders: [String] { Array(Set(messages.map { $0.fromEmail.lowercased() })).filter { !$0.isEmpty }.sorted() }
    private var domains: [String] {
        Array(Set(senders.compactMap { $0.split(separator: "@").last.map { "@" + $0 } })).sorted()
    }
    private var accountIDs: Set<UUID> { Set(messages.map(\.accountID)) }
    private var singleAccount: MailAccount? { accountIDs.count == 1 ? accountIDs.first.flatMap(state.account(id:)) : nil }
    private var isLowValue: Bool { [.spam, .marketing, .social, .notification].contains(category) }

    /// 按当前选项生成的规则（只改这一封时为空）。
    private var rules: [MailRule] {
        let conditions: [String]
        switch scope {
        case .once: return []
        case .sender: conditions = senders
        case .domain: conditions = domains
        }
        return conditions.map {
            MailRule(accountID: allAccounts ? nil : singleAccount?.id, sender: $0, keywords: keywords,
                     category: category.rawValue, notify: notify, exceptCodes: exceptCodes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("归为").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(MailCategory.allCases) { c in
                        Button {
                            category = c
                        } label: {
                            Label(c.rawValue, systemImage: c.symbol)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(category == c ? c.color.opacity(0.18) : Color.primary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(category == c ? c.color : .clear, lineWidth: 1.5))
                                .foregroundStyle(category == c ? c.color : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("以后遇到这样的邮件").font(.headline)
                Picker("", selection: $scope) {
                    Text(state.settings.learnFromCorrections ? "只改这次（AI 会参考这次纠正，自动处理相似邮件）" : "只改这次").tag(Scope.once)
                    Text(senders.count == 1 ? "来自 \(senders[0]) 的都这样处理" : "来自这 \(senders.count) 个发件人的都这样处理").tag(Scope.sender)
                    Text(domains.count == 1 ? "来自 \(domains[0]) 域名的都这样处理" : "来自这些域名的都这样处理").tag(Scope.domain)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if scope != .once {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("且主题或正文包含")
                            TextField("可选，多个关键词用逗号分隔，如：促销, 优惠券", text: $keywords)
                                .textFieldStyle(.roundedBorder)
                        }
                        if let account = singleAccount, state.settings.accounts.count > 1 {
                            Picker("适用于", selection: $allAccounts) {
                                Text("所有邮箱").tag(true)
                                Text("仅 \(account.displayName)").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        Picker("提醒", selection: $notify) {
                            ForEach(RuleNotify.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Toggle(isOn: $exceptCodes) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("验证码邮件除外")
                                Text("同一发件人发来的验证码仍然正常归类和提醒").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if affected > 0 {
                            Toggle("同时修改已有的 \(affected) 封同类邮件", isOn: $applyExisting)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            if category == .spam || category == .marketing {
                Toggle("标记后删除\(request.ids.count > 1 ? "这 \(request.ids.count) 封" : "这封")邮件", isOn: $deleteNow)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            category = request.category
            scope = request.category == .spam ? .sender : .once
            exceptCodes = isLowValue
            if request.category == .spam { notify = .never }
            refreshAffected()
        }
        .onChange(of: category) { _, c in
            exceptCodes = [.spam, .marketing, .social, .notification].contains(c)
            if c == .spam { notify = .never } else if notify == .never && c == .important { notify = .auto }
            refreshAffected()
        }
        .onChange(of: scope) { refreshAffected() }
        .onChange(of: keywords) { refreshAffected() }
        .onChange(of: allAccounts) { refreshAffected() }
        .onChange(of: exceptCodes) { refreshAffected() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let m = messages.first, messages.count == 1 {
                AvatarView(name: m.fromName, email: m.fromEmail, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("标记邮件").font(.title3.bold())
                    Text("\(m.sender) · \(m.subject)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Image(systemName: "tag.fill").font(.title).foregroundStyle(Color.accentColor).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("标记 \(request.ids.count) 封邮件").font(.title3.bold())
                    Text("来自 \(senders.count) 个发件人").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshAffected() {
        guard !Snapshot.isActive else { affected = scope == .once ? 0 : 6; return } // 截图时不读取真实数据
        // 不算当前选中的这几封（无论如何都会修改）
        affected = max(0, state.countAffected(by: rules, excluding: Set(request.ids)))
    }

    private func save() {
        state.setCategory(request.ids, category)
        for rule in rules {
            state.saveRule(rule, applyToExisting: applyExisting)
        }
        if deleteNow {
            let ids = request.ids
            Task { await state.deleteMessages(ids) }
        }
        dismiss()
    }
}

// MARK: - 批量清理

/// 一次清理 AI 识别出的垃圾 / 营销邮件：按发件人分组，勾选后删除。
struct CleanupView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State var category: MailCategory = .spam
    @State private var groups: [SenderGroup] = []
    @State private var unchecked: Set<String> = []
    @State private var confirm = false
    @State private var counts: [MailCategory: Int] = [:]

    struct SenderGroup: Identifiable {
        var id: String { email }
        var email: String
        var name: String
        var messages: [MailMessage]
    }

    private var selectedIDs: [String] {
        groups.filter { !unchecked.contains($0.email) }.flatMap { $0.messages.map(\.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.system(size: 36)).foregroundStyle(.red.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理邮件").font(.title3.bold())
                    Text("AI 已识别出以下邮件，按发件人分组。取消勾选要保留的，其余一次删除。").font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $category) {
                ForEach([MailCategory.spam, .marketing, .social, .notification]) { c in
                    Text("\(c.rawValue)（\(counts[c] ?? 0)）").tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if groups.isEmpty {
                ContentUnavailableView("没有\(category.rawValue)邮件", systemImage: "checkmark.circle",
                                       description: Text("AI 分析后归为「\(category.rawValue)」的邮件会出现在这里"))
                    .frame(height: 300)
            } else {
                HStack {
                    Button("全选") { unchecked = [] }
                    Button("全不选") { unchecked = Set(groups.map(\.email)) }
                    Spacer()
                    Text("\(groups.count) 个发件人").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.link)
                List {
                    ForEach(groups) { g in
                        row(g)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 300)
            }

            Text("删除后邮件会移到各邮箱的「已删除」文件夹，在邮箱网页版或手机上仍可找回；通过「邮件」App 读取的账户只从 MailMind 中移除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("删除 \(selectedIDs.count) 封", role: .destructive) { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear(perform: load)
        .onChange(of: category) { load() }
        .confirmationDialog("删除 \(selectedIDs.count) 封\(category.rawValue)邮件？", isPresented: $confirm) {
            Button("删除", role: .destructive) {
                let ids = selectedIDs
                Task { await state.deleteMessages(ids) }
                dismiss()
            }
        } message: {
            Text("邮件会移到邮箱的「已删除」文件夹。")
        }
    }

    private func row(_ g: SenderGroup) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { !unchecked.contains(g.email) }, set: { on in
                if on { unchecked.remove(g.email) } else { unchecked.insert(g.email) }
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            AvatarView(name: g.name, email: g.email, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(g.name.isEmpty ? g.email : g.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(g.messages.count) 封").font(.caption).foregroundStyle(.secondary)
                }
                Text(g.messages.first.map { $0.headline.isEmpty ? $0.subject : $0.headline } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let reason = g.messages.first?.reason, !reason.isEmpty {
                    Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() {
        if Snapshot.isActive { return loadDemo() }
        for c in [MailCategory.spam, .marketing, .social, .notification] {
            counts[c] = ((try? state.db.messages(filter: .category(c.rawValue), limit: 2000)) ?? []).count
        }
        let list = ((try? state.db.messages(filter: .category(category.rawValue), limit: 2000)) ?? [])
            .filter { $0.code.isEmpty } // 不清理验证码
        groups = Dictionary(grouping: list, by: { $0.fromEmail.lowercased() })
            .map { SenderGroup(email: $0.key, name: $0.value.first?.fromName ?? "", messages: $0.value) }
            .sorted { $0.messages.count > $1.messages.count }
        unchecked = []
    }

    private func loadDemo() {
        counts = [.spam: 23, .marketing: 41, .social: 8, .notification: 15]
        groups = Demo.spam.map { SenderGroup(email: $0.0, name: $0.1, messages: $0.2) }
        unchecked = [Demo.spam.last?.0 ?? ""]
    }
}
