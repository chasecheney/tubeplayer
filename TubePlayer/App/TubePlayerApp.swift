import AVFoundation
import SwiftData
import SwiftUI

@main
struct TubePlayerApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Video.self, Playlist.self)
        } catch {
            fatalError("Could not open the library: \(error)")
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let container = container
        Task { @MainActor in
            DownloadManager.shared.configure(container: container)
        }
        // Warm up Python + yt-dlp so the first video opens quickly.
        Task.detached(priority: .utility) {
            try? await YTDLPEngine.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}

struct ContentView: View {
    enum Tab: Hashable { case browse, feed, library }

    @State private var tab: Tab = .browse
    private var downloads: DownloadManager { DownloadManager.shared }

    var body: some View {
        TabView(selection: $tab) {
            BrowserView()
                .tabItem { Label("Browse", systemImage: "globe") }
                .tag(Tab.browse)

            FeedView(scope: .all)
                .tabItem { Label("Feed", systemImage: "play.square.stack") }
                .tag(Tab.feed)
                .toolbarBackground(.black, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)

            LibraryView()
                .tabItem { Label("Library", systemImage: "rectangle.stack") }
                .tag(Tab.library)
                .badge(downloads.active.count)
        }
    }
}
