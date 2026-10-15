import SwiftUI
import WebKit
import CopyCore

@MainActor enum IsolatedWebPolicy {
    static func allows(_ url: URL?) -> Bool { ["https","http"].contains(url?.scheme?.lowercased() ?? "") }
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        return config
    }
}
struct IsolatedLinkPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var status = "正在加载…"
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(url.host ?? "链接预览").font(.title2); Spacer(); Button("完成") { dismiss() } }
            Text("临时浏览会话，不使用已有登录信息；脚本、弹出窗口和下载已禁用。").font(.caption)
            IsolatedWebView(url:url,status:$status)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(20).frame(width:780,height:620)
    }
}
struct IsolatedWebView: NSViewRepresentable {
    let url: URL
    @Binding var status: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame:.zero,configuration:IsolatedWebPolicy.configuration())
        view.navigationDelegate = context.coordinator
        if IsolatedWebPolicy.allows(url) { view.load(URLRequest(url:url)) }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: IsolatedWebView
        init(_ parent: IsolatedWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = IsolatedWebPolicy.allows(action.request.url) && !action.shouldPerformDownload && action.targetFrame != nil
            if !allowed { parent.status = "已阻止下载、弹出窗口或非网页链接" }
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Disposition")?.lowercased().contains("attachment") ?? false
            let allowed = response.canShowMIMEType && !attachment
            if !allowed { parent.status = "此内容需要下载，预览已停止" }
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.status = webView.url?.absoluteString ?? "已加载" }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.status = error.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.status = error.localizedDescription }
    }
}
