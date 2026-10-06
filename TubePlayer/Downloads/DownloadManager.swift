import Foundation
import Observation
import SwiftData

struct ActiveDownload: Identifiable, Equatable {
    var id: String { key }
    let key: String
    var title: String
    var state: String
    var progress: Double
    var downloaded: Double?
    var total: Double?
    var speed: Double?
    var eta: Double?

    var detail: String {
        switch state {
        case "queued": return "Waiting…"
        case "extracting": return "Finding video…"
        default:
            var parts: [String] = []
            if let downloaded {
                var text = ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file)
                if let total, total > 0 {
                    text += " of " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
                }
                parts.append(text)
            }
            if let speed, speed > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
            }
            if let eta, eta > 0 {
                let f = DateComponentsFormatter()
                f.allowedUnits = eta >= 3600 ? [.hour, .minute] : [.minute, .second]
                f.unitsStyle = .abbreviated
                if let s = f.string(from: eta) { parts.append("\(s) left") }
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Starts, tracks, stops and cleans up downloads.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var active: [String: ActiveDownload] = [:]
    var lastError: String?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private init() {}

    var activeList: [ActiveDownload] {
        active.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var context: ModelContext? { container?.mainContext }

    func configure(container: ModelContainer) {
        self.container = container
        // Anything left "downloading" from a previous run was interrupted.
        if let context, let stale = try? context.fetch(FetchDescriptor<Video>()) {
            for video in stale where video.state == .downloading {
                video.state = .failed
                video.errorMessage = "Interrupted. Tap retry to download again."
            }
            try? context.save()
        }
    }

    func isDownloading(key: String) -> Bool { active[key] != nil }

    /// Downloads the video for an already-extracted page.
    func download(_ media: ExtractedMedia) {
        download(key: media.key, title: media.title, uploader: media.uploader,
                 pageURL: media.webpageUrl, duration: media.duration)
    }

    func download(key: String, title: String, uploader: String?, pageURL: String, duration: Double?) {
        guard let context, active[key] == nil else { return }

        let video: Video
        if let existing = context.video(forKey: key) {
            if existing.state == .ready { return }
            video = existing
            video.state = .downloading
            video.errorMessage = nil
        } else {
            video = Video(key: key, title: title, uploader: uploader, sourceURL: pageURL, duration: duration)
            context.insert(video)
        }
        try? context.save()

        active[key] = ActiveDownload(key: key, title: title, state: "queued", progress: 0)
        let folder = video.folderURL
        let settings = PlaybackSettings.current

        Task {
            do {
                try await YTDLPEngine.shared.startDownload(jobID: key, url: pageURL, folder: folder, settings: settings)
                startPolling()
            } catch {
                finishFailed(key: key, message: error.localizedDescription)
            }
        }
    }

    func retry(_ video: Video) {
        download(key: video.key, title: video.title, uploader: video.uploader,
                 pageURL: video.sourceURL, duration: video.duration)
    }

    /// Stops a download in progress and deletes its partial files and library entry.
    func stop(key: String) {
        active[key] = nil
        Task { await YTDLPEngine.shared.cancel(jobID: key) }
        if let context, let video = context.video(forKey: key), video.state != .ready {
            context.deleteVideo(video)
        }
    }

    func cancelAll() {
        for key in active.keys { stop(key: key) }
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                if self.active.isEmpty {
                    self.pollTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func poll() async {
        guard let jobs = try? await YTDLPEngine.shared.status() else { return }
        for job in jobs {
            guard active[job.jobId] != nil else {
                // Stopped by the user; make sure nothing is left behind.
                if job.state == "finished", context?.video(forKey: job.jobId) == nil {
                    let folder = MediaStore.videosDirectory.appendingPathComponent(
                        job.jobId.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
                    try? FileManager.default.removeItem(at: folder)
                }
                continue
            }
            switch job.state {
            case "finished":
                finishSucceeded(job)
            case "failed":
                finishFailed(key: job.jobId, message: job.error ?? "Download failed")
            case "cancelled":
                active[job.jobId] = nil
            default:
                guard var item = active[job.jobId] else { continue }  // stopped by the user
                item.state = job.state
                item.progress = job.progress
                item.downloaded = job.downloaded
                item.total = job.total
                item.speed = job.speed
                item.eta = job.eta
                active[job.jobId] = item
            }
        }
    }

    private func finishSucceeded(_ job: JobStatus) {
        active[job.jobId] = nil
        guard let context, let video = context.video(forKey: job.jobId) else { return }
        video.videoFileName = job.files?["video"]
        video.audioFileName = job.files?["audio"]
        video.thumbnailFileName = job.files?["thumbnail"]
        if let title = job.meta?.title { video.title = title }
        if let uploader = job.meta?.uploader { video.uploader = uploader }
        if let duration = job.meta?.duration { video.duration = duration }
        video.state = video.videoFileName == nil ? .failed : .ready
        try? context.save()
    }

    private func finishFailed(key: String, message: String) {
        active[key] = nil
        lastError = message
        guard let context, let video = context.video(forKey: key) else { return }
        video.state = .failed
        video.errorMessage = message
        try? context.save()
    }
}
