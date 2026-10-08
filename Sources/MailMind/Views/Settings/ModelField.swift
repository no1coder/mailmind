import SwiftUI

/// 模型输入框：可手动输入，也可从服务商获取模型列表后搜索选择。
struct ModelField: View {
    @Binding var model: String
    let baseURL: String
    let apiKey: String

    @State private var models: [String] = []
    @State private var loading = false
    @State private var error = ""
    @State private var showList = false
    @State private var query = ""
    /// 记录上次获取时的接口与 Key，二者变化后需要重新获取。
    @State private var fetchedFor = ""

    private var filtered: [String] {
        let q = query.trimmed.lowercased()
        return q.isEmpty ? models : models.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("模型", text: $model, prompt: Text("例如 deepseek-chat"))
                Button {
                    if models.isEmpty || fetchedFor != baseURL + apiKey { fetch() }
                    showList = true
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("获取模型", systemImage: "list.bullet")
                    }
                }
                .disabled(baseURL.trimmed.isEmpty || loading)
                .help("从服务商获取可用模型列表")
                .popover(isPresented: $showList, arrowEdge: .bottom) {
                    list
                }
            }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索模型", text: $query)
                .textFieldStyle(.roundedBorder)
            if loading {
                ProgressView("正在获取…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if models.isEmpty {
                Text(error.isEmpty ? "没有获取到模型" : error)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(filtered, id: \.self) { id in
                    Button {
                        model = id
                        showList = false
                    } label: {
                        HStack {
                            Text(id).lineLimit(1)
                            Spacer()
                            if id == model { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(height: 280)
            }
            HStack {
                Text("共 \(models.count) 个模型").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { fetch() }
                    .buttonStyle(.link)
                    .disabled(loading)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func fetch() {
        loading = true
        error = ""
        let key = baseURL + apiKey
        Task {
            do {
                models = try await AIClient(baseURL: baseURL, model: "", apiKey: apiKey).listModels()
                fetchedFor = key
                if models.isEmpty { error = "服务商没有返回任何模型，请手动输入模型名称" }
            } catch {
                models = []
                self.error = "获取失败：\(error.localizedDescription)。可直接手动输入模型名称。"
            }
            loading = false
        }
    }
}
