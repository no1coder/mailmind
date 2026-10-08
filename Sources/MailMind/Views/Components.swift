import SwiftUI

/// 服务商图标：彩色圆角方块 + 文字或 SF Symbol。
struct BrandIcon: View {
    var badge: String
    var symbol: String = "envelope.fill"
    var color: Color
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                if badge.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(badge)
                        .font(.system(size: size * (badge.count > 2 ? 0.32 : 0.42), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                }
            }
            .shadow(color: color.opacity(0.3), radius: 3, y: 1)
    }
}

extension MailProviderPreset {
    func icon(size: CGFloat = 40) -> BrandIcon {
        BrandIcon(badge: badge, symbol: symbol, color: color, size: size)
    }

    /// 根据账户的服务器地址或邮箱后缀找到对应服务商。
    static func forAccount(_ a: MailAccount) -> MailProviderPreset? {
        MailProviderPresets.all.first { !$0.host.isEmpty && $0.host == a.host } ?? MailProviderPresets.guess(email: a.email)
    }
}

/// 发件人头像：取名字首字，颜色由邮箱地址决定（同一发件人颜色固定）。
struct AvatarView: View {
    var name: String
    var email: String
    var size: CGFloat = 34

    private static let palette: [UInt32] = [0x5B8DEF, 0xE5735A, 0x4CB782, 0xB46CDB, 0xE0A23B, 0x3FB3C6, 0xD9628E, 0x7D8CA3]

    var body: some View {
        Circle()
            .fill(Color(hex: Self.palette[Self.hash(email) % Self.palette.count]).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }

    private var initial: String {
        let source = name.trimmed.isEmpty ? email : name.trimmed
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }

    /// 稳定的哈希（String.hashValue 每次启动都会变）。
    static func hash(_ s: String) -> Int {
        Int(s.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value } % 10_000)
    }
}

/// 带序号的步骤列表。
struct StepList: View {
    var steps: [String]
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(color, in: Circle())
                    Text(step)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 彩色提示卡片。
struct NoticeCard: View {
    enum Style { case info, warning, error, success }
    var style: Style
    var title: String
    var message: String = ""

    private var color: Color {
        switch style {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.25)))
    }
}

/// 可选中的卡片按钮（用于服务商网格）。
struct SelectableCard<Content: View>: View {
    var selected = false
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(hovering ? 0.08 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 可切换明文显示的密码框。
struct RevealableSecureField: View {
    var title: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.plain)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "隐藏" : "显示")
        }
        .modifier(FieldBox())
    }
}

/// 大号输入框外观。
struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
    }
}

extension View {
    func fieldBox() -> some View { modifier(FieldBox()) }
}
