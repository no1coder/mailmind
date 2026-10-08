import SwiftUI

/// 选择 AI 服务商 + 填写 API Key + 测试，供设置向导和设置页共用。
struct AIProviderForm: View {
    @Environment(AppState.self) private var state
    @State private var apiKey = Keychain.get(Keychain.aiKey) ?? ""
    @State private var custom = false
    @State private var showAdvanced = false
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    private let columns = [GridItem(.adaptive(minimum: 136), spacing: 10)]

    private var selected: AIProviderPreset? {
        custom ? nil : AIProviderPresets.matching(baseURL: state.settings.aiBaseURL)
    }

    var body: some View {
        @Bindable var settings = state.settings
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AIProviderPresets.all) { p in
                    SelectableCard(selected: selected == p, action: { choose(p) }) {
                        HStack(spacing: 8) {
                            BrandIcon(badge: p.badge, color: Color(hex: p.colorHex), size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(p.tagline).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                SelectableCard(selected: selected == nil, action: {
                    custom = true
                    showAdvanced = true
                }) {
                    HStack(spacing: 8) {
                        BrandIcon(badge: "", symbol: "slider.horizontal.3", color: .gray, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("自定义").font(.callout.weight(.medium))
                            Text("其他接口").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if selected?.needsKey ?? true {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("API Key").font(.callout.weight(.medium))
                        Spacer()
                        if let url = selected?.keyURL.flatMap(URL.init) {
                            Link(destination: url) {
                                Label("还没有？去 \(selected?.name ?? "") 官网获取", systemImage: "arrow.up.forward")
                                    .font(.caption)
                            }
                        }
                    }
                    RevealableSecureField(title: "粘贴 API Key（通常以 sk- 开头）", text: $apiKey)
                        .onChange(of: apiKey) { Keychain.set(apiKey.trimmed, for: Keychain.aiKey) }
                    Text("API Key 相当于 AI 服务的账号凭证，用于计费。新用户通常有免费额度，处理一封邮件的花费不到 1 分钱。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let p = selected {
                NoticeCard(style: .info, title: "\(p.name) 在你的电脑上运行，无需 API Key",
                           message: p.name.hasPrefix("Ollama") ? "需要先安装 Ollama 并下载模型，例如在终端运行：ollama pull \(p.model)" : "请先在 LM Studio 中加载模型并启动本地服务器。")
            }

            DisclosureGroup("高级设置（接口地址、模型）", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("接口地址（Base URL）", text: $settings.aiBaseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                    ModelField(model: $settings.aiModel, baseURL: settings.aiBaseURL, apiKey: apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button {
                    test()
                } label: {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(testing || settings.aiBaseURL.trimmed.isEmpty || settings.aiModel.trimmed.isEmpty)
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                        .font(.callout)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear {
            custom = AIProviderPresets.matching(baseURL: state.settings.aiBaseURL) == nil
        }
    }

    private func choose(_ p: AIProviderPreset) {
        custom = false
        state.settings.aiBaseURL = p.baseURL
        state.settings.aiModel = p.model
        result = nil
    }

    private func test() {
        testing = true
        result = nil
        Task {
            do {
                let client = AIClient(baseURL: state.settings.aiBaseURL, model: state.settings.aiModel, apiKey: apiKey.trimmed)
                _ = try await client.chat(system: "你是测试助手。", user: "只回复：OK")
                result = (true, "连接成功，模型 \(state.settings.aiModel) 可以使用")
            } catch {
                result = (false, Self.friendly(error))
            }
            testing = false
        }
    }

    static func friendly(_ error: Error) -> String {
        if case AIError.http(let code, let msg) = error {
            switch code {
            case 401, 403: return "API Key 不正确或已失效"
            case 402: return "账户余额不足，请到服务商官网充值"
            case 404: return "找不到这个模型或接口地址，请检查高级设置"
            case 429: return "请求太频繁或额度用完了，请稍后再试"
            default: return "服务商返回错误 \(code)：\(msg.prefix(80))"
            }
        }
        if error is URLError { return "连不上 AI 服务，请检查网络或接口地址" }
        return error.localizedDescription
    }
}
