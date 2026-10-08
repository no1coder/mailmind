import SwiftUI

/// ⌘K：用自然语言查询最近 30 天的邮件。
struct AskAIView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var answer = ""
    @State private var cited: [MailMessage] = []
    @State private var working = false
    @State private var error = ""
    @FocusState private var focused: Bool

    private let examples = [
        "这周有哪些需要我回复的邮件？",
        "最近有哪些账单要付？金额多少？",
        "有没有快到截止日期的事情？",
        "今天收到了哪些重要通知？",
        "哪些营销邮件可以退订？",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple).font(.title2)
                TextField("问问你的邮箱……", text: $question)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(ask)
                if working { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if answer.isEmpty && !working {
                VStack(alignment: .leading, spacing: 6) {
                    Text("试试这样问").font(.caption).foregroundStyle(.secondary)
                    ForEach(examples, id: \.self) { e in
                        Button(e) {
                            question = e
                            ask()
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if !error.isEmpty {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            if !answer.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(DigestDetailView.render(answer))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !cited.isEmpty {
                            Divider()
                            Text("相关邮件").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(cited.enumerated()), id: \.element.id) { _, m in
                                Button {
                                    dismiss()
                                    state.open(messageID: m.id)
                                } label: {
                                    HStack {
                                        Image(systemName: "envelope")
                                        VStack(alignment: .leading) {
                                            Text(m.subject).lineLimit(1)
                                            Text("\(m.sender) · \(m.date.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
            }

            HStack {
                Text("基于最近 30 天的邮件").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { focused = true }
    }

    private func ask() {
        let q = question.trimmed
        guard !q.isEmpty, !working else { return }
        working = true
        error = ""
        answer = ""
        cited = []
        Task {
            do {
                let result = try await state.ask(q)
                answer = result.answer
                cited = result.cited
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
