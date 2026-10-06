import SwiftUI

/// Hosts the VLC drawable.
struct VLCVideoView: UIViewRepresentable {
    let controller: PlayerController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(controller.drawable, to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if controller.drawable.superview !== uiView {
            attach(controller.drawable, to: uiView)
        }
    }

    private func attach(_ view: UIView, to container: UIView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// Scrubber with times.
struct ScrubBar: View {
    let controller: PlayerController
    @State private var dragFraction: Double?

    var body: some View {
        let fraction = dragFraction ?? (controller.duration > 0 ? controller.currentTime / controller.duration : 0)
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: max(0, geo.size.width * fraction))
                    Circle().fill(.white)
                        .frame(width: dragFraction == nil ? 12 : 18, height: dragFraction == nil ? 12 : 18)
                        .offset(x: geo.size.width * fraction - (dragFraction == nil ? 6 : 9))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(max($0.location.x / geo.size.width, 0), 1) }
                        .onEnded { _ in
                            if let f = dragFraction { controller.seek(toFraction: f) }
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 24)
            HStack {
                Text(formatTime(fraction * controller.duration))
                Spacer()
                Text(formatTime(controller.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// Full-screen player for a page from the browser: resolves the page with yt-dlp,
/// streams it immediately, and offers a download.
struct StreamPlayerScreen: View {
    let pageURL: String
    var onClose: () -> Void

    @State private var controller = PlayerController()
    @State private var media: ExtractedMedia?
    @State private var errorText: String?
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.modelContext) private var context

    private var downloads: DownloadManager { DownloadManager.shared }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(controller: controller)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if media == nil && errorText == nil {
                VStack(spacing: 12) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text("Getting video…").foregroundStyle(.white.opacity(0.8))
                }
            } else if let errorText {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Couldn't play this page").font(.headline)
                    Text(errorText).font(.footnote).multilineTextAlignment(.center).opacity(0.8)
                    Button("Try Again") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(32)
            } else if controller.isBuffering {
                ProgressView().tint(.white).controlSize(.large)
            }

            if showControls || errorText != nil {
                controls.transition(.opacity)
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .task { await load() }
        .onDisappear { controller.stop() }
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                if let media {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title).font(.headline).lineLimit(2)
                        HStack(spacing: 6) {
                            if let uploader = media.uploader { Text(uploader) }
                            if !media.qualityLabel.isEmpty { Text(media.qualityLabel).fontWeight(.semibold) }
                        }
                        .font(.caption).opacity(0.8)
                    }
                    .padding(.top, 4)
                }
                Spacer()
                if let media, !media.isLive { downloadButton(media) }
            }
            .foregroundStyle(.white)
            .padding()

            Spacer()

            if media != nil {
                HStack(spacing: 48) {
                    Button { controller.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                    Button { controller.togglePlay(); scheduleHide() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                    }
                    Button { controller.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                }
                .font(.title)
                .foregroundStyle(.white)

                Spacer()

                if media?.isLive == false {
                    ScrubBar(controller: controller).padding(.horizontal).padding(.bottom, 8)
                }
            }
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private func downloadButton(_ media: ExtractedMedia) -> some View {
        let saved = context.video(forKey: media.key)
        let item = downloads.active[media.key]
        Group {
            if let item {
                Button { downloads.stop(key: media.key) } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                        Circle().trim(from: 0, to: item.progress).stroke(.white, lineWidth: 3).rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill").font(.caption)
                    }
                    .frame(width: 30, height: 30)
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Stop download")
            } else if saved?.state == .ready {
                Image(systemName: "checkmark.circle.fill").font(.title3).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .accessibilityLabel("Downloaded")
            } else {
                Button { downloads.download(media) } label: {
                    Image(systemName: "arrow.down.circle").font(.title3).padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Download")
            }
        }
    }

    private func load() async {
        errorText = nil
        do {
            let result = try await YTDLPEngine.shared.extract(url: pageURL, settings: .current)
            guard let source = PlaybackSource(media: result) else {
                errorText = "No playable stream was found."
                return
            }
            media = result
            controller.load(source)
            scheduleHide()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func toggleControls() {
        withAnimation { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, controller.isPlaying else { return }
            withAnimation { showControls = false }
        }
    }

    private func close() {
        controller.stop()
        onClose()
    }
}
