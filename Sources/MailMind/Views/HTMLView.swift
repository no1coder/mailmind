import SwiftUI
import WebKit

/// 安全地显示 HTML 邮件：禁用 JavaScript，默认屏蔽所有远程资源（追踪像素），点击链接用默认浏览器打开。
struct HTMLView: NSViewRepresentable {
    let html: String
    let allowRemoteContent: Bool

    private static let blockRemoteRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let key = "\(allowRemoteContent)-\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        let controller = web.configuration.userContentController
        controller.removeAllContentRuleLists()
        let page = "<meta charset=\"utf-8\"><style>body{font-family:-apple-system;background:#fff;color:#000}</style>" + html
        if allowRemoteContent {
            web.loadHTMLString(page, baseURL: nil)
            return
        }
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "mailmind-block-remote",
            encodedContentRuleList: Self.blockRemoteRules
        ) { list, _ in
            if let list { controller.add(list) }
            web.loadHTMLString(page, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey = ""

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
