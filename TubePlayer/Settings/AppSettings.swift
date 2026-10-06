import SwiftUI

struct PlaybackSettings {
    var maxHeight: Int
    var preferCompatible: Bool

    static var current: PlaybackSettings {
        let defaults = UserDefaults.standard
        let height = defaults.integer(forKey: SettingsKey.maxHeight)
        return PlaybackSettings(
            maxHeight: height == 0 ? 1080 : height,
            preferCompatible: defaults.object(forKey: SettingsKey.preferCompatible) as? Bool ?? true
        )
    }
}

enum SettingsKey {
    static let maxHeight = "maxHeight"
    static let preferCompatible = "preferCompatible"
    static let autoOpenVideos = "autoOpenVideos"
    static let searchEngine = "searchEngine"
    static let homePage = "homePage"
    static let blockAds = "blockAds"
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case youtube, duckduckgo, google

    var id: String { rawValue }

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .duckduckgo: "DuckDuckGo"
        case .google: "Google"
        }
    }

    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .youtube: return URL(string: "https://m.youtube.com/results?search_query=\(q)")
        case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(q)")
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsKey.maxHeight) private var maxHeight = 1080
    @AppStorage(SettingsKey.preferCompatible) private var preferCompatible = true
    @AppStorage(SettingsKey.autoOpenVideos) private var autoOpenVideos = true
    @AppStorage(SettingsKey.searchEngine) private var searchEngine = SearchEngine.youtube.rawValue
    @AppStorage(SettingsKey.blockAds) private var blockAds = true

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var engineVersion = "…"
    @State private var jscAvailable = false
    @State private var updateMessage: String?
    @State private var isUpdating = false
    @State private var storageText = ""
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Maximum quality", selection: $maxHeight) {
                        ForEach([360, 480, 720, 1080, 1440, 2160], id: \.self) { h in
                            Text(h == 2160 ? "4K" : "\(h)p").tag(h)
                        }
                    }
                    Toggle("Prefer H.264 (best battery)", isOn: $preferCompatible)
                }

                Section("Browsing") {
                    Toggle("Open video pages in player", isOn: $autoOpenVideos)
                    Toggle("Block ads and trackers", isOn: $blockAds)
                    Picker("Search with", selection: $searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }

                Section {
                    LabeledContent("yt-dlp", value: engineVersion)
                    LabeledContent("JavaScript solver", value: jscAvailable ? "JavaScriptCore" : "Unavailable")
                    Button {
                        Task { await runUpdate() }
                    } label: {
                        if isUpdating {
                            HStack { ProgressView(); Text("Checking…") }
                        } else {
                            Text("Update yt-dlp")
                        }
                    }
                    .disabled(isUpdating)
                    if let updateMessage {
                        Text(updateMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Engine")
                } footer: {
                    Text("Sites change often. If videos stop loading, update yt-dlp and relaunch the app.")
                }

                Section("Storage") {
                    LabeledContent("Downloads", value: storageText)
                    Button("Delete All Downloads", role: .destructive) { confirmDeleteAll = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                refreshStorage()
                if let info = try? await YTDLPEngine.shared.version() {
                    engineVersion = info.version
                    jscAvailable = info.javaScriptCore
                } else {
                    engineVersion = "Not loaded"
                }
            }
            .confirmationDialog("Delete every downloaded video?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { deleteAll() }
            }
        }
    }

    private func runUpdate() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            let result = try await YTDLPEngine.shared.update()
            updateMessage = result.updated
                ? "Downloaded yt-dlp \(result.version). Relaunch TubePlayer to use it."
                : "yt-dlp is up to date (\(result.version))."
        } catch {
            updateMessage = error.localizedDescription
        }
    }

    private func refreshStorage() {
        storageText = ByteCountFormatter.string(fromByteCount: MediaStore.usedBytes(), countStyle: .file)
    }

    private func deleteAll() {
        DownloadManager.shared.cancelAll()
        if let videos = try? context.fetch(FetchDescriptor<Video>()) {
            for video in videos { context.deleteVideo(video) }
        }
        refreshStorage()
    }
}
