import Foundation
import SwiftData

enum VideoState: String, Codable {
    case downloading, ready, failed
}

@Model
final class Video {
    @Attribute(.unique) var key: String
    var title: String
    var uploader: String?
    var sourceURL: String
    var duration: Double?
    var folderName: String
    var videoFileName: String?
    var audioFileName: String?
    var thumbnailFileName: String?
    var isFavorite: Bool = false
    var addedAt: Date
    var stateRaw: String
    var errorMessage: String?
    var lastPosition: Double = 0

    init(key: String, title: String, uploader: String?, sourceURL: String, duration: Double?) {
        self.key = key
        self.title = title
        self.uploader = uploader
        self.sourceURL = sourceURL
        self.duration = duration
        self.folderName = key.replacingOccurrences(of: "/", with: "_")
        self.addedAt = .now
        self.stateRaw = VideoState.downloading.rawValue
    }

    var state: VideoState {
        get { VideoState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    var folderURL: URL { MediaStore.videosDirectory.appendingPathComponent(folderName, isDirectory: true) }
    var videoURL: URL? { videoFileName.map { folderURL.appendingPathComponent($0) } }
    var audioURL: URL? { audioFileName.map { folderURL.appendingPathComponent($0) } }
    var thumbnailURL: URL? { thumbnailFileName.map { folderURL.appendingPathComponent($0) } }
    var isPlayable: Bool { state == .ready && videoURL != nil }
}

@Model
final class Playlist {
    var name: String
    var createdAt: Date
    /// Ordered video keys.
    var videoKeys: [String]

    init(name: String) {
        self.name = name
        self.createdAt = .now
        self.videoKeys = []
    }
}

enum MediaStore {
    static var videosDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func removeFiles(for video: Video) {
        try? FileManager.default.removeItem(at: video.folderURL)
    }

    static func usedBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: videosDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

extension ModelContext {
    /// Deletes a video, its files, and its playlist entries.
    func deleteVideo(_ video: Video) {
        let key = video.key
        MediaStore.removeFiles(for: video)
        if let playlists = try? fetch(FetchDescriptor<Playlist>()) {
            for playlist in playlists where playlist.videoKeys.contains(key) {
                playlist.videoKeys.removeAll { $0 == key }
            }
        }
        delete(video)
        try? save()
    }

    func video(forKey key: String) -> Video? {
        var descriptor = FetchDescriptor<Video>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }
}
