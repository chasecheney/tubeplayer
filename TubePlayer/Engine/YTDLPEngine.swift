import Foundation

/// Swift face of the embedded yt-dlp engine (python/app/tubeplayer_engine.py).
/// Every call crosses the bridge as one JSON object in and one JSON object out.
final class YTDLPEngine: @unchecked Sendable {
    static let shared = YTDLPEngine()

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let queue = DispatchQueue(label: "TubePlayer.python", qos: .userInitiated, attributes: .concurrent)
    private let startLock = NSLock()
    private var startTask: Task<String, Error>?

    private init() {}

    /// Starts Python and imports yt-dlp. Safe to call repeatedly; returns the yt-dlp version.
    @discardableResult
    func start() async throws -> String {
        let task = startLock.withLock {
            if let startTask { return startTask }
            let task = Task.detached(priority: .userInitiated) {
                try await self.boot()
            }
            startTask = task
            return task
        }
        return try await task.value
    }

    private func boot() async throws -> String {
        let resourcePath = Bundle.main.resourcePath ?? ""
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Engine", isDirectory: true)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                var error: UnsafeMutablePointer<CChar>?
                if tp_python_init(resourcePath, &error) == 0 {
                    cont.resume()
                } else {
                    let message = error.map { String(cString: $0) } ?? "Python failed to start"
                    if let error { tp_free(error) }
                    cont.resume(throwing: EngineError(message: message))
                }
            }
        }
        let result = try await rawCall("setup", ["support_dir": support.path], requireStarted: false)
        return result["version"] as? String ?? "unknown"
    }

    // MARK: - Calls

    private func rawCall(_ function: String, _ params: [String: Any], requireStarted: Bool = true) async throws -> [String: Any] {
        if requireStarted { try await start() }
        let data = try JSONSerialization.data(withJSONObject: params)
        let json = String(decoding: data, as: UTF8.self)
        let output: String = await withCheckedContinuation { cont in
            queue.async {
                guard let pointer = tp_python_call(function, json) else {
                    cont.resume(returning: #"{"ok": false, "error": "No response from engine"}"#)
                    return
                }
                let text = String(cString: pointer)
                tp_free(pointer)
                cont.resume(returning: text)
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw EngineError(message: "Unreadable engine response")
        }
        if object["ok"] as? Bool == false {
            throw EngineError(message: object["error"] as? String ?? "Unknown error")
        }
        return object
    }

    private func call<T: Decodable>(_ function: String, _ params: [String: Any], as type: T.Type) async throws -> T {
        let object = try await rawCall(function, params)
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - API

    func extract(url: String, settings: PlaybackSettings) async throws -> ExtractedMedia {
        try await call("extract", [
            "url": url,
            "max_height": settings.maxHeight,
            "prefer_compatible": settings.preferCompatible,
        ], as: ExtractedMedia.self)
    }

    func startDownload(jobID: String, url: String, folder: URL, settings: PlaybackSettings) async throws {
        _ = try await rawCall("start_download", [
            "job_id": jobID,
            "url": url,
            "folder": folder.path,
            "max_height": settings.maxHeight,
            "prefer_compatible": settings.preferCompatible,
        ])
    }

    func cancel(jobID: String) async {
        _ = try? await rawCall("cancel", ["job_id": jobID])
    }

    func status() async throws -> [JobStatus] {
        try await call("status", [:], as: StatusResponse.self).jobs
    }

    func version() async throws -> (version: String, javaScriptCore: Bool) {
        let object = try await rawCall("version", [:])
        return (object["version"] as? String ?? "unknown", object["javascriptcore"] as? Bool ?? false)
    }

    /// Downloads the newest yt-dlp from PyPI; active after the next launch.
    func update() async throws -> (updated: Bool, version: String) {
        let object = try await rawCall("update", [:])
        return (object["updated"] as? Bool ?? false, object["version"] as? String ?? "")
    }

    func resetUpdate() async throws {
        _ = try await rawCall("reset_update", [:])
    }
}

// MARK: - Models

struct MediaFormat: Codable, Hashable {
    var formatId: String?
    var url: String?
    var ext: String?
    var `protocol`: String?
    var width: Int?
    var height: Int?
    var vcodec: String?
    var acodec: String?
    var filesize: Double?
    var httpHeaders: [String: String]?
}

struct ExtractedMedia: Codable, Hashable, Identifiable {
    var key: String
    var id: String?
    var title: String
    var uploader: String?
    var duration: Double?
    var thumbnail: String?
    var webpageUrl: String
    var extractor: String?
    var isLive: Bool
    var video: MediaFormat?
    var audio: MediaFormat?

    var qualityLabel: String {
        guard let h = video?.height else { return "" }
        return "\(h)p"
    }
}

struct JobStatus: Codable {
    struct Meta: Codable {
        var key: String?
        var title: String?
        var uploader: String?
        var duration: Double?
        var webpageUrl: String?
    }
    var jobId: String
    var state: String
    var progress: Double
    var downloaded: Double?
    var total: Double?
    var speed: Double?
    var eta: Double?
    var files: [String: String]?
    var error: String?
    var meta: Meta?
}

private struct StatusResponse: Codable {
    var jobs: [JobStatus]
}
