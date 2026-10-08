import SwiftUI

struct MessageDetailView: View {
    @Environment(AppState.self) private var state
    let message: MailMessage

    enum Tab: String, CaseIterable, Identifiable {
        case translation = "译文"
        case original = "原文"
        case html = "网页版"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .original
    @State private var bodyText = ""
    @State private var bodyHTML = ""
    @State private var allowRemoteContent = false
    @State private var showReply = false

    private var availableTabs: [Tab] {
        var tabs: [Tab] = []
        if !message.translation.isEmpty { tabs.append(.translation) }
        tabs.append(.original)
        if !bodyHTML.isEmpty { tabs.append(.html) }
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top])
                .padding(.bottom, 10)
            AICard(message: message)
                .padding(.horizontal)
                .padding(.bottom, 10)
            Divider()
            HStack {
                if availableTabs.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                } else {
                    Text("正文").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                if tab == .html {
                    Toggle("加载远程图片", isOn: $allowRemoteContent)
                        .toggleStyle(.checkbox)
                        .help("远程图片可能被用于追踪你是否打开了邮件")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            content
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showReply = true
                } label: {
                    Label("AI 回复", systemImage: "arrowshape.turn.up.left")
                }
                .help("让 AI 起草回复")
                .disabled(state.makeAIClient() == nil)

                Menu {
                    SenderMenuItems(message: message)
                } label: {
                    Label("发件人", systemImage: "person.crop.circle")
                }
                .help("VIP、静音、固定分类")
            }
        }
        .sheet(isPresented: $showReply) {
            ReplyDraftView(message: message)
                .environment(state)
        }
        .task(id: message.id) {
            let body = (try? state.db.body(id: message.id)) ?? (text: "", html: "")
            bodyText = body.text
            bodyHTML = body.html
            tab = message.translation.isEmpty ? .original : .translation
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.subject)
                .font(.title2.bold())
                .textSelection(.enabled)
            HStack(alignment: .center, spacing: 10) {
                AvatarView(name: message.fromName, email: message.fromEmail, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.sender).font(.callout.weight(.semibold))
                    Text(message.fromEmail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if state.senderRules[message.senderKey]?.vip == true {
                    Text("VIP").font(.caption.bold()).foregroundStyle(.orange)
                }
                if state.senderRules[message.senderKey]?.muted == true {
                    Image(systemName: "bell.slash").foregroundStyle(.secondary).help("已静音")
                }
                Spacer()
                Text(message.date, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack {
                if !message.to.isEmpty {
                    Text("收件人：\(message.to)")
                        .lineLimit(1)
                }
                if let account = state.account(id: message.accountID) {
                    Text(message.to.isEmpty ? "收件账户：\(account.displayName)" : "· \(account.displayName)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !message.attachments.isEmpty {
                Label(message.attachments.joined(separator: "、"), systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .translation:
            TextBody(text: message.translation)
        case .original:
            TextBody(text: bodyText.isEmpty ? message.snippet : bodyText)
        case .html:
            HTMLView(html: bodyHTML, allowRemoteContent: allowRemoteContent)
        }
    }
}

private struct TextBody: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

private struct AICard: View {
    @Environment(AppState.self) private var state
    let message: MailMessage
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                if let c = message.mailCategory {
                    CategoryBadge(category: c)
                }
                if let imp = message.importance, message.mailCategory != .important {
                    Text(imp.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((imp == .high ? Color.red : Color.secondary).opacity(0.15), in: Capsule())
                        .foregroundStyle(imp == .high ? .red : .secondary)
                }
                if let due = message.deadlineDate {
                    DeadlineBadge(date: due)
                }
                Spacer()
                Menu {
                    ForEach(MailCategory.allCases) { c in
                        Button(c.rawValue) { state.setCategory([message.id], c) }
                    }
                } label: {
                    Text("改分类")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("重新分析") { state.reanalyze(message.id) }
                    .buttonStyle(.borderless)
            }

            switch message.aiStatus {
            case .pending:
                Text(state.makeAIClient() == nil ? "未配置 AI 服务，可在设置中开启。" : "AI 正在分析…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("AI 分析失败：\(message.aiError)")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            case .done:
                if !message.headline.isEmpty {
                    Text(message.headline)
                        .font(.headline)
                        .textSelection(.enabled)
                }
                if !message.code.isEmpty {
                    HStack {
                        Text(message.code)
                            .font(.title2.monospaced().bold())
                            .textSelection(.enabled)
                        Button(copied ? "已复制 ✓" : "复制验证码") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.code, forType: .string)
                            copied = true
                        }
                    }
                }
                if !message.summary.isEmpty {
                    Text(message.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if !message.action.isEmpty {
                    Label(message.action, systemImage: "checklist")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                if !message.reason.isEmpty {
                    Text(message.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.15)))
    }
}

/// AI 起草回复：可以给出要求，生成后可编辑、复制，或在系统邮件 App 中打开发送。
struct ReplyDraftView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let message: MailMessage

    @State private var instruction = ""
    @State private var draft = ""
    @State private var working = false
    @State private var error = ""

    private let quickIdeas = ["同意，并表示感谢", "礼貌拒绝", "请对方提供更多细节", "确认收到，稍后回复"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("回复：\(message.subject)").font(.headline).lineLimit(1)
            HStack {
                TextField("告诉 AI 你想怎么回复（可留空）", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(generate)
                Button(working ? "生成中…" : (draft.isEmpty ? "生成" : "重新生成"), action: generate)
                    .disabled(working)
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                ForEach(quickIdeas, id: \.self) { idea in
                    Button(idea) {
                        instruction = idea
                        generate()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 260)
                .overlay {
                    if working { ProgressView() }
                }
                .border(Color.secondary.opacity(0.2))
            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft, forType: .string)
                }
                .disabled(draft.isEmpty)
                Button("在邮件 App 中打开") {
                    openInMailApp()
                    dismiss()
                }
                .disabled(draft.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func generate() {
        working = true
        error = ""
        Task {
            do {
                draft = try await state.draftReply(to: message, instruction: instruction)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func openInMailApp() {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = message.fromEmail
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        comps.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: draft)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}
