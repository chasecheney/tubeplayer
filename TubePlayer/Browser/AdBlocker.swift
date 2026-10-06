import Foundation
import WebKit

/// Blocks common ad and tracking hosts with a WebKit content rule list,
/// and hides leftover ad slots on popular video sites.
@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    private var compiled: WKContentRuleList?
    private let identifier = "TubePlayerAdBlock-v1"

    private static let blockedHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "imasdk.googleapis.com", "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com",
        "criteo.com", "criteo.net", "outbrain.com", "taboola.com", "scorecardresearch.com", "quantserve.com",
        "moatads.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com", "smartadserver.com",
        "spotxchange.com", "springserve.com", "teads.tv", "yieldmo.com", "33across.com", "sharethrough.com",
        "adform.net", "bidswitch.net", "mathtag.com", "zedo.com", "popads.net", "popcash.net", "propellerads.com",
        "exoclick.com", "juicyads.com", "trafficjunky.net", "adsterra.com", "hilltopads.net", "mgid.com",
        "revcontent.com", "media.net", "adcolony.com", "applovin.com", "unityads.unity3d.com", "chartbeat.com",
        "hotjar.com", "mixpanel.com", "segment.io", "branch.io", "facebook.net", "ads-twitter.com",
        "ads.reddit.com", "ads.tiktok.com", "analytics.tiktok.com", "static.ads-twitter.com",
    ]

    /// Element selectors hidden on every page (ad slots, promoted cards).
    private static let hiddenSelectors = [
        "ytm-promoted-sparkles-web-renderer", "ytm-promoted-video-renderer", "ytm-companion-ad-renderer",
        "ad-slot-renderer", "ytm-ad-slot-renderer", "ytd-ad-slot-renderer", "ytd-promoted-sparkles-web-renderer",
        "ytm-statement-banner-renderer", "#player-ads", ".ytp-ad-module", ".video-ads",
        "[id^='google_ads_iframe']", "iframe[src*='doubleclick.net']", ".adsbygoogle",
        "[data-testid='ad-slot']", ".promotedlink", "shreddit-ad-post",
    ]

    private var rulesJSON: String {
        var rules: [[String: Any]] = Self.blockedHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^https?://+([^:/]+\\.)?\(escaped)[:/]", "load-type": ["third-party"]] as [String: Any],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Self.hiddenSelectors.joined(separator: ", ")],
        ])
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func apply(to webView: WKWebView) async {
        let enabled = UserDefaults.standard.object(forKey: SettingsKey.blockAds) as? Bool ?? true
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard enabled, let list = await ruleList() else { return }
        controller.add(list)
    }

    private func ruleList() async -> WKContentRuleList? {
        if let compiled { return compiled }
        guard let store = WKContentRuleListStore.default() else { return nil }
        let list = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rulesJSON)
        compiled = list
        return list
    }
}

/// Recognises URLs that point at a single video (as opposed to search or home pages).
enum VideoPageDetector {
    private static let patterns: [(host: String, regex: String)] = [
        ("youtube.com", #"^/(watch|shorts/|live/)"#),
        ("youtu.be", #"^/[\w-]{6,}"#),
        ("vimeo.com", #"^/(\d+|channels/[^/]+/\d+)"#),
        ("dailymotion.com", #"^/video/"#),
        ("dai.ly", #"^/\w+"#),
        ("twitch.tv", #"^/(videos/\d+|[^/]+/clip/)"#),
        ("clips.twitch.tv", #"^/\w+"#),
        ("tiktok.com", #"^/@[^/]+/video/\d+"#),
        ("instagram.com", #"^/(reel|reels|p|tv)/"#),
        ("facebook.com", #"^/(watch|reel|[^/]+/videos/)"#),
        ("x.com", #"^/[^/]+/status/\d+"#),
        ("twitter.com", #"^/[^/]+/status/\d+"#),
        ("reddit.com", #"^/r/[^/]+/comments/"#),
        ("streamable.com", #"^/\w+"#),
        ("rumble.com", #"^/v\w+"#),
        ("bilibili.com", #"^/video/"#),
        ("soundcloud.com", #"^/[^/]+/[^/]+$"#),
    ]

    static func isVideoPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        if url.pathExtension.lowercased() == "mp4" || url.pathExtension.lowercased() == "m3u8" { return true }
        for (pattern, regex) in patterns where host == pattern || host.hasSuffix("." + pattern) {
            if path.range(of: regex, options: .regularExpression) != nil {
                if host.contains("youtube.com"), path.hasPrefix("/watch"),
                   !(url.query?.contains("v=") ?? false) { return false }
                return true
            }
        }
        return false
    }
}
