import AppKit
import SwiftUI

@main
struct MailMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    var body: some Scene {
        Window("MailMind", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 980, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("立即同步") { state.syncNow() }
                    .keyboardShortcut("r")
                Button("生成邮件汇总") { Task { await state.generateDigest() } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("邮件") {
                Button("问 AI…") { state.showAskAI = true }
                    .keyboardShortcut("k")
                    .disabled(state.makeAIClient() == nil)
                Button("标为已读 / 未读") { state.toggleReadForSelection() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(state.selectedIDs.isEmpty)
                Button("全部标为已读") { state.markAllReadInCurrentView() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Divider()
                Button("重要") { state.filter = .important }.keyboardShortcut("1")
                Button("待处理") { state.filter = .action }.keyboardShortcut("2")
                Button("全部邮件") { state.filter = .inbox }.keyboardShortcut("3")
                Button("定期汇总") { state.filter = .digest }.keyboardShortcut("4")
            }
        }

        Settings {
            SettingsView()
                .environment(state)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(state)
        } label: {
            Image(systemName: state.importantUnread > 0 ? "envelope.badge.fill" : "envelope")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Task { @MainActor in
                Snapshot.run(to: URL(fileURLWithPath: args[i + 1]), dark: !args.contains("--light"))
                NSApp.terminate(nil)
            }
            return
        }
        // 通过 `swift run` 启动时没有 Info.plist，需要手动设为常规应用才会出现 Dock 图标和窗口。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in AppState.shared.start() }
    }

    /// 关闭主窗口后继续在菜单栏运行，以便后台同步和通知。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
