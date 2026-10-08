import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } content: {
            Group {
                if state.filter == .digest {
                    DigestListView()
                } else {
                    MessageListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 400)
        } detail: {
            detail
        }
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "搜索主题、发件人、摘要")
        .onChange(of: state.searchText) { state.reload() }
        .toolbar {
            ToolbarItem(placement: .status) {
                StatusIndicator()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.showAskAI = true
                } label: {
                    Label("问 AI", systemImage: "sparkles")
                }
                .help("用自然语言查询邮件（⌘K）")
                .disabled(state.makeAIClient() == nil)

                Button {
                    state.syncNow()
                } label: {
                    Label("同步", systemImage: "arrow.clockwise")
                }
                .disabled(state.isSyncing)
                .help("立即同步所有邮箱（⌘R）")
            }
        }
        .sheet(isPresented: $state.showAskAI) {
            AskAIView()
                .environment(state)
        }
        .sheet(isPresented: $state.showOnboarding) {
            OnboardingView()
                .environment(state)
                .interactiveDismissDisabled()
        }
        .onAppear {
            state.openMainWindow = { openWindow(id: "main") }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if state.filter == .digest {
            DigestDetailView()
        } else if state.selectedIDs.count > 1 {
            BulkActionView(ids: Array(state.selectedIDs))
        } else if let id = state.selectedMessageID, let message = state.message(id: id) {
            MessageDetailView(message: message)
                .id(message.id)
        } else if state.settings.accounts.isEmpty {
            WelcomeView()
        } else {
            ContentUnavailableView {
                Label("选择一封邮件", systemImage: "envelope.open")
            } description: {
                Text("↑↓ 切换邮件　⇧⌘U 标为已读/未读　⌘K 问 AI　⌘R 同步")
            }
        }
    }
}

private struct StatusIndicator: View {
    @Environment(AppState.self) private var state
    @State private var showErrors = false

    var body: some View {
        HStack(spacing: 6) {
            if state.isSyncing || state.isGeneratingDigest {
                ProgressView().controlSize(.small)
            }
            if !state.lastErrors.isEmpty {
                Button {
                    showErrors.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showErrors) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.lastErrors, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                    .padding()
                    .frame(maxWidth: 420)
                }
            }
            Text(state.isGeneratingDigest ? "正在生成汇总…" : state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ContentUnavailableView {
            Label("欢迎使用 MailMind", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("添加邮箱、连接 AI，三步完成设置。\nMailMind 会自动分类、翻译邮件，重要邮件即时通知，其余邮件定期汇总。")
        } actions: {
            Button("开始设置") { state.showOnboarding = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// 多选时的批量操作面板。
struct BulkActionView: View {
    @Environment(AppState.self) private var state
    let ids: [String]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("已选择 \(ids.count) 封邮件").font(.title3.bold())
            HStack {
                Button("标为已读") { state.setRead(ids, read: true) }
                Button("标为未读") { state.setRead(ids, read: false) }
            }
            Menu("修改分类") {
                ForEach(MailCategory.allCases) { c in
                    Button(c.rawValue) { state.setCategory(ids, c) }
                }
            }
            .fixedSize()
            Button("取消选择") { state.selectedIDs = [] }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
