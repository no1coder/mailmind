import AppKit
import SwiftUI

/// 界面截图工具（开发用）：离屏渲染主要界面为 PNG，不需要屏幕录制权限。
/// 用法：swift run MailMind --snapshot <输出目录> [--light]
@MainActor
enum Snapshot {
    /// 截图模式：侧边栏的毛玻璃材质无法离屏渲染，改用纯色背景。
    static var isActive = false

    static func run(to dir: URL, dark: Bool) {
        isActive = true
        Keychain.disabled = true // 不读取真实钥匙串，避免弹出授权框
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = MailProviderPresets.all
        let qq = p.first { $0.host == "imap.qq.com" }!
        let gmail = p.first { $0.host == "imap.gmail.com" }!
        let outlook = p.first { $0.oauth != nil }!

        func shot<V: View>(_ name: String, _ w: CGFloat, _ h: CGFloat, _ view: V) {
            render(view, width: w, height: h, to: dir.appendingPathComponent("\(name).png"), dark: dark)
        }

        shot("add-1-pick", 760, 500, AddAccountFlow().padding(24))
        shot("add-2-qq", 760, 500, AddAccountFlow(stage: .login(qq)).padding(24))
        shot("add-3-gmail", 760, 500, AddAccountFlow(stage: .login(gmail)).padding(24))
        shot("add-4-outlook", 760, 560, AddAccountFlow(stage: .login(outlook)).padding(24))
        shot("add-4b-outlook-forward", 760, 560, OutlookMethodsView(provider: outlook, onSuccess: { _, _ in }, method: .forward).padding(24))
        shot("add-5-success", 760, 500, AddAccountFlow(stage: .success(Demo.account, inboxCount: 1284), onDone: {}).padding(24))
        shot("onboarding-1", 780, 620, OnboardingView(step: 0))
        shot("onboarding-2-ai", 780, 620, OnboardingView(step: 1))
        shot("onboarding-3-notify", 780, 620, OnboardingView(step: 2))
        shot("settings-ai", 660, 560, AISettingsView())

        let state = AppState.shared
        state.settings.accounts = Demo.accounts
        for (i, a) in Demo.accounts.enumerated() {
            state.accountStatus[a.id] = AccountStatus(lastSync: Date(), error: nil, realtime: i != 1)
        }
        state.filter = .inbox
        state.messages = Demo.messages
        state.unreadCounts = ["@important": 2, "@action": 2, "@all": 3, "重要": 1, "工作": 1, "通知": 1]
        state.selectedIDs = [Demo.messages[0].id]
        // NavigationSplitView 的侧边栏无法离屏渲染，截图时手动排出三栏
        shot("main", 1280, 780, HStack(spacing: 0) {
            SidebarView().frame(width: 220)
            Divider()
            MessageListView().frame(width: 400)
            Divider()
            MessageDetailView(message: Demo.messages[0])
        })
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL, dark: Bool) {
        let root = view
            .environment(AppState.shared)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("✓ \(url.lastPathComponent)")
        }
        window.orderOut(nil)
    }
}

/// 截图用的示例数据。
enum Demo {
    static let account = MailAccount(displayName: "zhangsan@qq.com", email: "zhangsan@qq.com",
                                     username: "zhangsan@qq.com", host: "imap.qq.com")

    static let accounts: [MailAccount] = [
        account,
        MailAccount(displayName: "工作邮箱", email: "zhang@company.com", username: "zhang@company.com", host: "imap.exmail.qq.com"),
        MailAccount(displayName: "Gmail", email: "zhangsan@gmail.com", username: "zhangsan@gmail.com", host: "imap.gmail.com"),
    ]

    static let messages: [MailMessage] = {
        func m(_ i: Int, _ name: String, _ email: String, _ subject: String, _ headline: String, _ summary: String,
               _ cat: MailCategory, _ imp: Importance, minutesAgo: Double, read: Bool = false,
               action: String = "", deadline: String = "", code: String = "", attachments: [String] = []) -> MailMessage {
            var x = MailMessage(id: "demo-\(i)", accountID: account.id, folder: "INBOX", uid: UInt32(i))
            x.fromName = name
            x.fromEmail = email
            x.subject = subject
            x.headline = headline
            x.summary = summary
            x.snippet = summary
            x.category = cat.rawValue
            x.importance = imp
            x.aiStatus = .done
            x.date = Date().addingTimeInterval(-minutesAgo * 60)
            x.isRead = read
            x.action = action
            x.deadline = deadline
            x.code = code
            x.attachments = attachments
            x.reason = "真人发件人，要求在截止日期前确认，判定为重要。"
            x.language = "zh"
            return x
        }
        let due = Calendar.current.date(byAdding: .day, value: 2, to: Date())!.formatted(.iso8601.year().month().day())
        return [
            m(1, "王经理", "wang@company.com", "Q4 预算调整，请确认", "王经理：周五前确认 Q4 预算表",
              "王经理发来调整后的 Q4 预算表，市场部预算下调 8%，需要你在周五前确认或提出修改意见。",
              .important, .high, minutesAgo: 12, action: "回复确认或提出修改意见", deadline: due, attachments: ["Q4预算.xlsx"]),
            m(2, "GitHub", "noreply@github.com", "[GitHub] Please verify your device", "GitHub 验证码 482913，10 分钟内有效",
              "GitHub 登录设备验证码。", .notification, .normal, minutesAgo: 25, code: "482913"),
            m(3, "招商银行信用卡", "service@cmbchina.com", "您的 10 月账单已出", "招行信用卡 ¥3,280 将于 10/15 自动扣款",
              "本期账单金额 3,280 元，最后还款日 10 月 15 日，已绑定自动还款。", .finance, .normal, minutesAgo: 90, read: true),
            m(4, "Sarah Chen", "sarah@partner.io", "Re: Partnership proposal", "Sarah：希望下周二开会讨论合作方案",
              "合作方 Sarah 回复了合作提案，希望下周二下午开视频会议讨论细节。", .work, .high, minutesAgo: 180,
              action: "确认下周二是否有空"),
            m(5, "京东", "jd@jd.com", "您的订单已发货", "京东：订单已发货，预计明天送达",
              "订单 #2026100812 已由京东快递发出。", .notification, .low, minutesAgo: 60 * 26, read: true),
            m(6, "Medium Daily Digest", "noreply@medium.com", "Top stories for you", "Medium 今日推荐：5 篇技术文章",
              "每日推荐文章合集。", .marketing, .low, minutesAgo: 60 * 30, read: true),
        ]
    }()
}
