import SwiftData
import SwiftUI

/// Full-screen, swipe-up feed of downloaded videos.
struct FeedView: View {
    @State var scope: FeedScope
    var startKey: String?
    var showsClose = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Video.addedAt, order: .reverse) private var allVideos: [Video]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]

    @State private var currentKey: String?
    @State private var playlistTarget: Video?
    @State private var pendingDelete: Video?

    private var videos: [Video] {
        let ready = allVideos.filter(\.isPlayable)
        switch scope {
        case .all:
            return ready
        case .favorites:
            return ready.filter(\.isFavorite)
        case .playlist(let id):
            guard let playlist = playlists.first(where: { $0.persistentModelID == id }) else { return [] }
            let byKey = Dictionary(ready.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            return playlist.videoKeys.compactMap { byKey[$0] }
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "All Videos"
        case .favorites: "Favorites"
        case .playlist(let id): playlists.first { $0.persistentModelID == id }?.name ?? "Playlist"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if videos.isEmpty {
                ContentUnavailableView("Nothing to Watch", systemImage: "play.square.stack",
                                       description: Text("Downloaded videos show up here."))
                    .foregroundStyle(.white)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(videos) { video in
                            FeedPage(video: video,
                                     isActive: currentKey == video.key,
                                     onAddToPlaylist: { playlistTarget = video },
                                     onDelete: { pendingDelete = video })
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(video.key)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentKey)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }

            header
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if currentKey == nil { currentKey = startKey ?? videos.first?.key }
        }
        .onChange(of: videos.map(\.key)) { _, keys in
            if let currentKey, keys.contains(currentKey) { return }
            currentKey = keys.first
        }
        .sheet(item: $playlistTarget) { AddToPlaylistSheet(video: $0) }
        .confirmationDialog("Delete this video?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { video in
            Button("Delete Video", role: .destructive) { delete(video) }
        }
    }

    private var header: some View {
        HStack {
            if showsClose {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            Spacer()
            Menu {
                Picker("Show", selection: $scope) {
                    Text("All Videos").tag(FeedScope.all)
                    Text("Favorites").tag(FeedScope.favorites)
                    ForEach(playlists) { playlist in
                        Text(playlist.name).tag(FeedScope.playlist(playlist.persistentModelID))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scopeTitle).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if showsClose { Color.clear.frame(width: 40, height: 40) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func delete(_ video: Video) {
        let keys = videos.map(\.key)
        if let index = keys.firstIndex(of: video.key) {
            let next = index + 1 < keys.count ? keys[index + 1] : (index > 0 ? keys[index - 1] : nil)
            currentKey = next
        }
        context.deleteVideo(video)
    }
}

/// One full-screen page in the feed.
struct FeedPage: View {
    let video: Video
    let isActive: Bool
    var onAddToPlaylist: () -> Void
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var controller: PlayerController?
    @State private var showPlayIcon = false
    @State private var heartBurst = false

    var body: some View {
        ZStack {
            Color.black
            if let controller {
                VLCVideoView(controller: controller)
            } else {
                Thumbnail(video: video).scaledToFit().opacity(0.6)
            }

            if showPlayIcon {
                Image(systemName: "play.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.85))
                    .transition(.scale.combined(with: .opacity))
            }
            if heartBurst {
                Image(systemName: "heart.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.pink)
                    .shadow(radius: 10)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }

            overlay
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { favoriteBurst() }
        .onTapGesture { togglePlay() }
        .onChange(of: isActive, initial: true) { _, active in
            active ? activate() : deactivate()
        }
        .onDisappear { teardown() }
    }

    private var overlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if let uploader = video.uploader {
                        Text(uploader).font(.subheadline.weight(.semibold))
                    }
                    Text(video.title).font(.subheadline).lineLimit(3)
                }
                .shadow(radius: 4)
                Spacer(minLength: 24)
                VStack(spacing: 22) {
                    sideButton(video.isFavorite ? "heart.fill" : "heart",
                               label: "Favorite", tint: video.isFavorite ? .pink : .white) {
                        video.isFavorite.toggle()
                        try? context.save()
                    }
                    sideButton("text.badge.plus", label: "Playlist", action: onAddToPlaylist)
                    if let url = video.videoURL {
                        ShareLink(item: url) {
                            sideIcon("square.and.arrow.up", label: "Share", tint: .white)
                        }
                    }
                    sideButton("trash", label: "Delete", action: onDelete)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 28)

            if let controller, controller.duration > 0 {
                GeometryReader { geo in
                    Rectangle().fill(.white.opacity(0.9))
                        .frame(width: geo.size.width * min(controller.currentTime / controller.duration, 1))
                }
                .frame(height: 2)
                .background(.white.opacity(0.2))
                .padding(.bottom, 4)
            }
        }
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private func sideButton(_ symbol: String, label: String, tint: Color = .white,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { sideIcon(symbol, label: label, tint: tint) }
            .accessibilityLabel(label)
    }

    private func sideIcon(_ symbol: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(tint)
            Text(label).font(.caption2.weight(.medium))
        }
        .shadow(radius: 4)
        .frame(minWidth: 44)
    }

    private func activate() {
        guard let source = PlaybackSource(video: video) else { return }
        let player = controller ?? PlayerController()
        player.loops = true
        controller = player
        player.load(source)
        showPlayIcon = false
    }

    private func deactivate() {
        guard let controller else { return }
        savePosition()
        controller.pause()
    }

    private func teardown() {
        savePosition()
        controller?.stop()
        controller = nil
    }

    private func savePosition() {
        guard let controller, controller.duration > 0 else { return }
        let t = controller.currentTime
        video.lastPosition = t > controller.duration - 5 ? 0 : t
        try? context.save()
    }

    private func togglePlay() {
        guard let controller else { return }
        let wasPlaying = controller.isPlaying
        controller.togglePlay()
        withAnimation(.easeOut(duration: 0.2)) { showPlayIcon = wasPlaying }
    }

    private func favoriteBurst() {
        if !video.isFavorite {
            video.isFavorite = true
            try? context.save()
        }
        withAnimation(.spring(duration: 0.3)) { heartBurst = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.3)) { heartBurst = false }
        }
    }
}
