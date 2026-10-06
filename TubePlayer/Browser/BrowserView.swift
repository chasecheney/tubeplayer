import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @State private var model = BrowserModel()
    @FocusState private var addressFocused: Bool
    @AppStorage(SettingsKey.blockAds) private var blockAds = true

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .bottomTrailing) {
                WebView(webView: model.webView)
                    .opacity(model.showsStartPage ? 0 : 1)
                if model.showsStartPage {
                    StartPage { model.open($0) }
                }
                if !model.showsStartPage, model.videoPageURL != nil, model.playerRequest == nil {
                    Button(action: model.playCurrentPage) {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                            .shadow(radius: 6, y: 2)
                    }
                    .padding(20)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.videoPageURL)
            navigationBar
        }
        .fullScreenCover(item: $model.playerRequest, onDismiss: { model.playerClosed() }) { request in
            StreamPlayerScreen(pageURL: request.url) { model.playerRequest = nil }
        }
        .onChange(of: blockAds) {
            Task { await AdBlocker.shared.apply(to: model.webView); model.webView.reload() }
        }
    }

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.currentURL?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                TextField("Search or enter address", text: $model.urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit { model.submit(model.urlText) }
                if addressFocused, !model.urlText.isEmpty {
                    Button { model.urlText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                } else if !model.showsStartPage {
                    Button(action: model.reload) {
                        Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.vertical, 8)

            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .opacity(model.isLoading ? 1 : 0)
                .frame(height: 2)
        }
        .background(.bar)
    }

    private var navigationBar: some View {
        HStack {
            Button(action: model.back) { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack || model.showsStartPage)
            Spacer()
            Button(action: model.forward) { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward)
            Spacer()
            Button(action: model.playCurrentPage) { Image(systemName: "play.rectangle") }
                .disabled(model.currentURL == nil || model.showsStartPage)
                .accessibilityLabel("Play this page")
            Spacer()
            Button(action: model.goHome) { Image(systemName: "house") }
            Spacer()
            if let url = model.currentURL, !model.showsStartPage {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }
        }
        .font(.title3)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Shortcuts to video sites.
struct StartPage: View {
    var open: (URL) -> Void

    struct Site {
        let name: String, url: String, symbol: String, color: Color
    }

    private let sites: [Site] = [
        Site(name: "YouTube", url: "https://m.youtube.com", symbol: "play.rectangle.fill", color: .red),
        Site(name: "Vimeo", url: "https://vimeo.com/watch", symbol: "v.square.fill", color: .cyan),
        Site(name: "Dailymotion", url: "https://www.dailymotion.com", symbol: "d.square.fill", color: .blue),
        Site(name: "Twitch", url: "https://m.twitch.tv", symbol: "gamecontroller.fill", color: .purple),
        Site(name: "Reddit", url: "https://www.reddit.com/r/videos", symbol: "bubble.left.and.bubble.right.fill", color: .orange),
        Site(name: "TikTok", url: "https://www.tiktok.com", symbol: "music.note", color: .pink),
        Site(name: "Rumble", url: "https://rumble.com", symbol: "r.square.fill", color: .green),
        Site(name: "SoundCloud", url: "https://soundcloud.com", symbol: "waveform", color: .orange),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Watch")
                    .font(.largeTitle.bold())
                    .padding(.top, 24)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 16)], spacing: 20) {
                    ForEach(sites, id: \.name) { site in
                        Button {
                            if let url = URL(string: site.url) { open(url) }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: site.symbol)
                                    .font(.title)
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                                    .background(site.color.gradient, in: RoundedRectangle(cornerRadius: 16))
                                Text(site.name).font(.caption).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Open any video page and TubePlayer plays it ad-free. Use the download button in the player to save it for offline viewing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
    }
}
