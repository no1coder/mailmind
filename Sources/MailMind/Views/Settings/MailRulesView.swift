import SwiftUI

/// 设置 →「规则」：按发件人 / 域名 / 关键词归类、提醒，可针对所有邮箱或单个邮箱；以及 AI 学到的偏好。
struct MailRulesView: View {
    @Environment(AppState.self) private var state
    @State private var editing: MailRule?
    @State private var isNew = false

    var body: some View {
        @Bindable var settings = state.settings
        SnapshotSafeScroll {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("规则").font(.headline)
                            Text("命中规则的邮件直接归类，归为垃圾、营销等时不再调用 AI，节省费用。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            isNew = true
                            editing = MailRule(exceptCodes: true)
                        } label: {
                            Label("添加规则", systemImage: "plus")
                        }
                    }
                    if settings.mailRules.isEmpty {
                        NoticeCard(style: .info, title: "还没有规则",
                                   message: "在邮件上右键 →「标记为垃圾邮件…」或「标记为…」，选择「来自 xx 的都这样处理」即可创建；也可以点右上角手动添加。")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(settings.mailRules.sorted { $0.createdAt > $1.createdAt }) { rule in
                                row(rule)
                                Divider()
                            }
                        }
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $settings.learnFromCorrections) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("让 AI 学习我的纠正").font(.headline)
                            Text("你手动改过分类的邮件会作为例子交给 AI，以后遇到相似的邮件（同一发件人、相似主题）自动按你的习惯归类。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    if settings.learnFromCorrections && !state.examples.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(state.examples.prefix(40)) { e in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.subject).font(.callout).lineLimit(1)
                                        Text(e.fromEmail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let c = MailCategory(rawValue: e.category) { CategoryBadge(category: c) }
                                    Button {
                                        state.deleteExample(e.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("忘掉这条")
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        HStack {
                            Text("AI 每次参考最近 40 条").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("全部清空") { state.clearExamples() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: isNew)
                .environment(state)
        }
    }

    private func row(_ rule: MailRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in
                var r = rule
                r.enabled = v
                state.saveRule(r, applyToExisting: false)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.conditionText).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("→ \(rule.actionText)")
                    Text("·")
                    Text(rule.accountID.flatMap { state.account(id: $0)?.displayName }.map { "仅 \($0)" } ?? "所有邮箱")
                    if rule.exceptCodes {
                        Text("验证码除外")
                            .padding(.horizontal, 5)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer()
            Button("编辑") {
                isNew = false
                editing = rule
            }
            .buttonStyle(.link)
            Button {
                state.deleteRule(rule.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除规则")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct RuleEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var rule: MailRule
    let isNew: Bool
    @State private var applyExisting = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "添加规则" : "编辑规则").font(.title3.bold()).padding([.horizontal, .top], 20)
            Form {
                Section("当邮件") {
                    TextField("发件人", text: $rule.sender, prompt: Text("完整地址如 news@shop.com，或域名如 @shop.com"))
                    TextField("且包含关键词", text: $rule.keywords, prompt: Text("可选，主题或正文包含任意一个，用逗号分隔"))
                    Picker("适用于", selection: $rule.accountID) {
                        Text("所有邮箱").tag(UUID?.none)
                        ForEach(state.settings.accounts) { a in
                            Text("仅 \(a.displayName)").tag(UUID?.some(a.id))
                        }
                    }
                }
                Section("就") {
                    Picker("归为", selection: $rule.category) {
                        Text("不改变（交给 AI）").tag("")
                        ForEach(MailCategory.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Picker("提醒", selection: $rule.notify) {
                        ForEach(RuleNotify.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("验证码邮件除外（验证码照常归类和提醒）", isOn: $rule.exceptCodes)
                }
                if !rule.category.isEmpty {
                    Section {
                        Toggle("同时修改已有的同类邮件", isOn: $applyExisting)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !rule.isValid {
                    Text(rule.sender.trimmed.isEmpty && rule.keywordList.isEmpty ? "请填写发件人或关键词" : "请选择分类或提醒方式")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    rule.sender = rule.sender.trimmed.lowercased()
                    state.saveRule(rule, applyToExisting: applyExisting)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!rule.isValid)
            }
            .padding(20)
        }
        .frame(width: 520, height: 470)
    }
}
