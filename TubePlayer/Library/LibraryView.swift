import SwiftData
import SwiftUI

enum FeedScope: Hashable {
    case all
    case favorites
    case playlist(PersistentIdentifier)
}

struct FeedLaunch: Identifiable {
    let id = UUID()
    let scope: FeedScope
    let startKey: String?
}

struct LibraryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", favorites = "Favorites", playlists = "Playlists"
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \Video.addedAt, order: .reverse) private var videos: [Video]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]

    @State private var filter: Filter = .all
    @State private var feed: FeedLaunch?
    @State private var playlistTarget: Video?
    @State private var pendingDelete: Video?
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var showSettings = false
    @State private var stopTarget: ActiveDownload?

    private var downloads: DownloadManager { DownloadManager.shared }

    private var shown: [Video] {
        switch filter {
        case .favorites: videos.filter { $0.isFavorite && $0.state != .downloading }
        default: videos.filter { $0.state != .downloading }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !downloads.activeList.isEmpty { activeDownloads }

                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if filter == .playlists {
                        playlistList
                    } else if shown.isEmpty {
                        emptyState
                    } else {
                        VideoGrid(videos: shown,
                                  onPlay: { video in
                                      feed = FeedLaunch(scope: filter == .favorites ? .favorites : .all, startKey: video.key)
                                  },
                                  onFavorite: toggleFavorite,
                                  onAddToPlaylist: { playlistTarget = $0 },
                                  onDelete: { pendingDelete = $0 })
                    }
                }
                .padding()
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                if filter == .playlists {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNewPlaylist = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .navigationDestination(for: PersistentIdentifier.self) { id in
                if let playlist = playlists.first(where: { $0.persistentModelID == id }) {
                    PlaylistDetailView(playlist: playlist) { key in
                        feed = FeedLaunch(scope: .playlist(id), startKey: key)
                    }
                }
            }
            .fullScreenCover(item: $feed) { launch in
                FeedView(scope: launch.scope, startKey: launch.startKey, showsClose: true)
            }
            .sheet(item: $playlistTarget) { AddToPlaylistSheet(video: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
                Button("Create") {
                    context.createPlaylist(named: newPlaylistName)
                    newPlaylistName = ""
                }
            }
            .confirmationDialog("Delete this video?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible, presenting: pendingDelete) { video in
                Button("Delete Video", role: .destructive) { context.deleteVideo(video) }
            } message: { video in
                Text("“\(video.title)” will be removed from this device.")
            }
            .confirmationDialog("Stop this download?", isPresented: Binding(
                get: { stopTarget != nil }, set: { if !$0 { stopTarget = nil } }
            ), titleVisibility: .visible, presenting: stopTarget) { item in
                Button("Stop and Delete", role: .destructive) { downloads.stop(key: item.key) }
            } message: { _ in
                Text("The partly downloaded file will be deleted.")
            }
        }
    }

    // MARK: Sections

    private var activeDownloads: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloading").font(.headline)
            ForEach(downloads.activeList) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        ProgressView(value: item.progress)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { stopTarget = item } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .foregroundStyle(.red)
                    .accessibilityLabel("Stop download and delete file")
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            filter == .favorites ? "No Favorites Yet" : "No Downloads Yet",
            systemImage: filter == .favorites ? "heart" : "arrow.down.circle",
            description: Text(filter == .favorites
                ? "Tap the heart on any video to add it here."
                : "Open a video in the Browse tab and tap the download button.")
        )
        .padding(.top, 40)
    }

    private var playlistList: some View {
        VStack(spacing: 10) {
            if playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                                       description: Text("Tap + to create one."))
                    .padding(.top, 40)
            }
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist.persistentModelID) {
                    HStack(spacing: 12) {
                        Thumbnail(video: playlist.videoKeys.first.flatMap { context.video(forKey: $0) })
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.videoKeys.count) videos").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                        context.delete(playlist)
                        try? context.save()
                    }
                }
            }
        }
    }

    private func toggleFavorite(_ video: Video) {
        video.isFavorite.toggle()
        try? context.save()
    }
}

// MARK: - Grid

struct VideoGrid: View {
    let videos: [Video]
    var onPlay: (Video) -> Void
    var onFavorite: (Video) -> Void
    var onAddToPlaylist: (Video) -> Void
    var onDelete: (Video) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 16) {
            ForEach(videos) { video in
                VideoCard(video: video)
                    .onTapGesture {
                        if video.isPlayable { onPlay(video) }
                    }
                    .contextMenu {
                        if video.isPlayable {
                            Button("Play", systemImage: "play") { onPlay(video) }
                        }
                        if video.state == .failed {
                            Button("Retry Download", systemImage: "arrow.clockwise") {
                                DownloadManager.shared.retry(video)
                            }
                        }
                        Button(video.isFavorite ? "Unfavorite" : "Favorite",
                               systemImage: video.isFavorite ? "heart.slash" : "heart") { onFavorite(video) }
                        Button("Add to Playlist", systemImage: "text.badge.plus") { onAddToPlaylist(video) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(video) }
                    }
            }
        }
    }
}

struct VideoCard: View {
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(video: video)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = video.duration {
                        Text(formatTime(duration))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if video.isFavorite {
                        Image(systemName: "heart.fill").foregroundStyle(.pink).padding(6)
                            .shadow(radius: 2)
                    }
                }
                .overlay {
                    if video.state == .failed {
                        ZStack {
                            Color.black.opacity(0.55)
                            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
            if let uploader = video.uploader {
                Text(uploader).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

struct Thumbnail: View {
    let video: Video?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let url = video?.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "play.rectangle").font(.title).foregroundStyle(.secondary)
            }
        }
        .clipped()
    }
}

// MARK: - Playlists

extension ModelContext {
    @discardableResult
    func createPlaylist(named name: String) -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let playlist = Playlist(name: trimmed)
        insert(playlist)
        try? save()
        return playlist
    }
}

struct AddToPlaylistSheet: View {
    let video: Video
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { showNew = true } label: { Label("New Playlist…", systemImage: "plus") }
                ForEach(playlists) { playlist in
                    let contains = playlist.videoKeys.contains(video.key)
                    Button {
                        if contains {
                            playlist.videoKeys.removeAll { $0 == video.key }
                        } else {
                            playlist.videoKeys.append(video.key)
                        }
                        try? context.save()
                    } label: {
                        HStack {
                            Text(playlist.name).foregroundStyle(.primary)
                            Spacer()
                            if contains { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("New Playlist", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    if let playlist = context.createPlaylist(named: newName) {
                        playlist.videoKeys.append(video.key)
                        try? context.save()
                    }
                    newName = ""
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist
    var onPlay: (String) -> Void
    @Environment(\.modelContext) private var context
    @State private var renaming = false
    @State private var newName = ""

    private var items: [Video] {
        playlist.videoKeys.compactMap { context.video(forKey: $0) }
    }

    var body: some View {
        List {
            ForEach(items) { video in
                HStack(spacing: 12) {
                    Thumbnail(video: video)
                        .frame(width: 112, height: 63)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading) {
                        Text(video.title).font(.subheadline).lineLimit(2)
                        if let d = video.duration {
                            Text(formatTime(d)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if video.isPlayable { onPlay(video.key) } }
            }
            .onMove { from, to in
                playlist.videoKeys.move(fromOffsets: from, toOffset: to)
                try? context.save()
            }
            .onDelete { offsets in
                let keys = offsets.map { items[$0].key }
                playlist.videoKeys.removeAll { keys.contains($0) }
                try? context.save()
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Empty Playlist", systemImage: "music.note.list",
                                       description: Text("Add videos from the Library or Feed."))
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let first = items.first(where: \.isPlayable) {
                    Button { onPlay(first.key) } label: { Image(systemName: "play.fill") }
                }
                Menu {
                    Button("Rename", systemImage: "pencil") { newName = playlist.name; renaming = true }
                } label: { Image(systemName: "ellipsis.circle") }
                EditButton()
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { playlist.name = trimmed; try? context.save() }
            }
        }
    }
}
