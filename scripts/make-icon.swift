// 生成 MailMind 的 Logo 与 App 图标。
// 用法：swift scripts/make-icon.swift <输出目录>
// 输出：logo-1024.png（无边距的方形原图）和 AppIcon.iconset/（含各尺寸，供 iconutil 生成 .icns）
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// 四角星（AI 的「灵感」符号），四条边向内弯曲。
struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let tips = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                    CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        var p = Path()
        p.move(to: tips[0])
        for i in 1...4 {
            let next = tips[i % 4]
            // 控制点靠近中心，形成内凹的弧线
            let ctrl = CGPoint(x: c.x + (tips[i - 1].x + next.x - 2 * c.x) * 0.12,
                               y: c.y + (tips[i - 1].y + next.y - 2 * c.y) * 0.12)
            p.addQuadCurve(to: next, control: ctrl)
        }
        p.closeSubpath()
        return p
    }
}

/// 信封封口的 V 形折线。
struct Flap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.2))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.58))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.minY + r.height * 0.2))
        return p
    }
}

/// 图标主体。canvas 为整张画布边长；macOS 图标的圆角方块约占 80%。
struct MailMindIcon: View {
    var canvas: CGFloat = 1024
    var plate: CGFloat = 824

    var body: some View {
        let s = plate / 824 // 以 824 为设计基准缩放
        ZStack {
            RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x3D8BFF), Color(hex: 0x6E56F8), Color(hex: 0x9B4DF0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)],
                                             startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 4 * s)
                )
                .frame(width: plate, height: plate)
                .shadow(color: .black.opacity(0.28), radius: 22 * s, y: 14 * s)

            // 信封
            ZStack {
                RoundedRectangle(cornerRadius: 58 * s, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(hex: 0xEEF2FF)], startPoint: .top, endPoint: .bottom))
                Flap()
                    .stroke(LinearGradient(colors: [Color(hex: 0x6E8BFF), Color(hex: 0x8F6BFF)], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 30 * s, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 520 * s, height: 372 * s)
            .shadow(color: Color(hex: 0x1B1464).opacity(0.35), radius: 18 * s, y: 10 * s)
            .offset(y: 46 * s)

            // AI 星芒
            Sparkle()
                .fill(LinearGradient(colors: [Color(hex: 0xFFF3B0), Color(hex: 0xFFC83D), Color(hex: 0xFF9F1C)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 236 * s, height: 236 * s)
                .shadow(color: Color(hex: 0x7A3A00).opacity(0.35), radius: 12 * s, y: 6 * s)
                .offset(x: 238 * s, y: -196 * s)
            Sparkle()
                .fill(.white.opacity(0.95))
                .frame(width: 84 * s, height: 84 * s)
                .offset(x: 92 * s, y: -268 * s)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func png(_ view: some View, size: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: view.frame(width: 1024, height: 1024))
    renderer.scale = size / 1024
    guard let cg = renderer.cgImage else { fatalError("渲染失败") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    // App 图标：带 macOS 标准边距
    for base in [16, 32, 128, 256, 512] {
        png(MailMindIcon(), size: CGFloat(base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        png(MailMindIcon(), size: CGFloat(base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    // Logo：铺满画布，用于 README 等
    png(MailMindIcon(canvas: 1024, plate: 960), size: 1024, to: out.appendingPathComponent("logo-1024.png"))
    png(MailMindIcon(), size: 1024, to: out.appendingPathComponent("icon-1024.png"))
}
print("✓ 已输出到 \(out.path)")
