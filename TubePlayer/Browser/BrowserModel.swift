import Foundation
import Observation
import WebKit

/// Owns the web view and tracks navigation state.
@MainActor
@Observable
final class BrowserModel: NSObject {
    var urlText = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var currentURL: URL?
    /// Set when the current page looks like a single video.
    var videoPageURL: URL?
    /// Set to open the player (by auto-detection or the Play button).
    var playerRequest: PlayerRequest?
    var showsStartPage = true

    struct PlayerRequest: Identifiable, Equatable {
        let id = UUID()
        let url: String
    }

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastAutoOpened: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Sites can't autoplay video (or pre-roll ads); TubePlayer plays it instead.
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
        Task { await AdBlocker.shared.apply(to: webView) }
    }

    private func observe() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.urlChanged(web.url) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.title = web.title ?? "" }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.progress = web.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.isLoading = web.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoForward = web.canGoForward }
            },
        ]
    }

    // MARK: - Navigation

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = Self.url(from: trimmed) {
            open(url)
        } else {
            let engine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: SettingsKey.searchEngine) ?? "") ?? .youtube
            if let url = engine.url(for: trimmed) { open(url) }
        }
    }

    func open(_ url: URL) {
        showsStartPage = false
        lastAutoOpened = nil
        webView.load(URLRequest(url: url))
    }

    func goHome() {
        showsStartPage = true
        urlText = ""
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { isLoading ? webView.stopLoading() : webView.reload() }

    func playCurrentPage() {
        guard let url = currentURL else { return }
        playerRequest = PlayerRequest(url: url.absoluteString)
    }

    static func url(from text: String) -> URL? {
        if text.contains(" ") { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme) {
            return url
        }
        // bare domains like "vimeo.com" or "youtu.be/abc"
        if text.contains("."), let url = URL(string: "https://" + text), url.host?.contains(".") == true {
            return url
        }
        return nil
    }

    private func urlChanged(_ url: URL?) {
        currentURL = url
        if let url { urlText = url.absoluteString }
        videoPageURL = url.flatMap { VideoPageDetector.isVideoPage($0) ? $0 : nil }

        let autoOpen = UserDefaults.standard.object(forKey: SettingsKey.autoOpenVideos) as? Bool ?? true
        if autoOpen, let page = videoPageURL, lastAutoOpened != page.absoluteString, playerRequest == nil {
            lastAutoOpened = page.absoluteString
            pauseWebMedia()
            playerRequest = PlayerRequest(url: page.absoluteString)
        }
    }

    func pauseWebMedia() {
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m => { m.pause(); })")
    }

    /// Called when the player closes, so returning to the page doesn't reopen it.
    func playerClosed() {
        playerRequest = nil
        pauseWebMedia()
    }
}

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open target=_blank links in place instead of spawning windows (and pop-ups).
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Keep the user in the browser instead of bouncing to native apps.
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
