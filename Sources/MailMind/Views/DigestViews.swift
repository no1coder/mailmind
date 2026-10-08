import SwiftUI

struct DigestListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedDigestID) {
            ForEach(state.digests) { d in
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.createdAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.headline)
                    Text("\(d.periodStart.formatted(date: .abbreviated, time: .shortened)) 起 · \(d.messageCount) 封邮件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(d.id)
                .contextMenu {
                    Button("删除", role: .destructive) { state.deleteDigest(d.id) }
                }
            }
        }
        .overlay {
            if state.digests.isEmpty {
                ContentUnavailableView("还没有汇总", systemImage: "doc.text.magnifyingglass",
                                       description: Text("汇总会按设置的时间自动生成，也可以手动生成。"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await state.generateDigest() }
            } label: {
                Label(state.isGeneratingDigest ? "正在生成…" : "立即生成汇总", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(state.isGeneratingDigest || state.makeAIClient() == nil)
            .padding()
        }
        .navigationTitle("定期汇总")
    }
}

struct DigestDetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let id = state.selectedDigestID, let digest = state.digests.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("邮件汇总")
                        .font(.title2.bold())
                    Text("\(digest.periodStart.formatted(date: .abbreviated, time: .shortened)) — \(digest.periodEnd.formatted(date: .abbreviated, time: .shortened)) · 共 \(digest.messageCount) 封")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text(Self.render(digest.content))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        } else {
            ContentUnavailableView("选择一份汇总", systemImage: "doc.text")
        }
    }

    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
