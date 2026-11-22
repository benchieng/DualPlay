import SwiftUI
import AVFoundation
import WebKit
import UniformTypeIdentifiers

// MARK: - Player model

@MainActor
final class PlayerModel: ObservableObject, Identifiable {
    let id = UUID()
    let player = AVPlayer()
    @Published var name: String = "No video loaded"
    @Published var volume: Double = 1.0 {
        didSet { player.volume = Float(volume) }
    }
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    init() {
        // Loop: when the current item reaches its end, rewind and keep playing.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let item = note.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
            self.player.seek(to: .zero)
            self.player.play()
            self.isPlaying = true
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            Task { @MainActor in self?.currentTime = seconds }
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        name = url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent
        duration = 0
        currentTime = 0
        // Surface unplayable picks instead of failing silently.
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status) { [weak self] observed, _ in
            guard observed.status == .failed, let error = observed.error else { return }
            DispatchQueue.main.async {
                self?.name = "Can't play \(url.lastPathComponent) — \(error.localizedDescription)"
            }
        }
        durationObservation?.invalidate()
        durationObservation = item.observe(\.duration) { [weak self] observed, _ in
            let seconds = CMTimeGetSeconds(observed.duration)
            guard seconds.isFinite, seconds > 0 else { return }
            DispatchQueue.main.async { self?.duration = seconds }
        }
        player.play()
        isPlaying = true
    }

    func setPlaying(_ on: Bool) {
        on ? player.play() : player.pause()
        isPlaying = on
    }

    func skip(_ delta: Double) {
        seek(to: max(0, min(currentTime + delta, duration > 0 ? duration : .greatestFiniteMagnitude)))
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func restart() {
        seek(to: 0)
    }

    var hasVideo: Bool { player.currentItem != nil }
}

// MARK: - Video layer (AVPlayerLayer instead of VideoPlayer: no built-in chrome)

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - Document picker (raw UIKit; SwiftUI fileImporter taps are dead on iOS 27 iPhone)

@MainActor
final class FilePickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePickerPresenter()

    private var onPick: ((URL) -> Void)?
    private var retaining = false

    func presentVideoPicker(onPick: ((URL) -> Void)? = nil) {
        self.onPick = onPick
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
              var top = window.rootViewController
        else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .video], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        retaining = true   // keep the delegate alive until pick/cancel
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        retaining = false
        let callback = onPick
        onPick = nil
        // asCopy: true already placed the file in our sandbox.
        if let url = urls.first { callback?(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        retaining = false
        onPick = nil
    }
}

// MARK: - Web browser sheet (sniffs <video> sources for streaming)

final class BrowserHolder: ObservableObject {
    weak var web: WKWebView?
}

struct WebView: UIViewRepresentable {
    let url: URL?
    let holder: BrowserHolder

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        holder.web = web
        if let url { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if let url, web.url != url { web.load(URLRequest(url: url)) }
    }
}

/// Extract the first non-blob video URL from the page.
private let videoProbeJS = """
(() => {
  const vs = [...document.querySelectorAll('video')]
    .map(v => v.currentSrc || v.querySelector('source')?.src || v.src)
    .filter(s => s && !s.startsWith('blob:'));
  if (vs.length) return vs[0];
  const links = [...document.querySelectorAll('a[href]')]
    .map(a => a.href)
    .filter(h => /\.(mp4|m4v|mov|mov|m3u8)(\\?|$)/i.test(h));
  return links.length ? links[0] : null;
})()
"""

struct WebVideoSheet: View {
    var onPlay: (URL, PaneID) -> Void
    @Environment(\.dismiss) private var dismiss

    enum PaneID { case a, b }

    @State private var address = "https://"
    @State private var pageURL: URL?
    @State private var note = ""
    @StateObject private var holder = BrowserHolder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("URL", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Button("Go") { loadAddress() }
                }
                .padding(8)

                WebView(url: pageURL, holder: holder)

                HStack(spacing: 12) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Play in A") { probe(.a) }.buttonStyle(.bordered)
                    Button("Play in B") { probe(.b) }.buttonStyle(.bordered)
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding(8)
            }
            .navigationTitle("Browse & Stream")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func loadAddress() {
        let text = address.hasPrefix("http") ? address : "https://" + address
        if let url = URL(string: text) {
            pageURL = url
            note = ""
        }
    }

    private func probe(_ pane: PaneID) {
        guard let web = holder.web else { return }
        web.evaluateJavaScript(videoProbeJS) { result, error in
            DispatchQueue.main.async {
                if error != nil {
                    note = "Page blocked the probe."
                } else if let string = result as? String, let url = URL(string: string) {
                    onPlay(url, pane)
                    note = "Playing \(url.lastPathComponent.isEmpty ? url.host ?? "" : url.lastPathComponent)"
                } else {
                    note = "No playable video found (blob/MSE streams can't be grabbed)."
                }
            }
        }
    }
}

// MARK: - Content

struct ContentView: View {
    @StateObject private var a = PlayerModel()
    @StateObject private var b = PlayerModel()

    @State private var playing = false
    @State private var showWeb = false

    // Duo rule from Apple: outer display reports compact width, inner display
    // regular. Two branches, no idiom checks.
    @Environment(\.horizontalSizeClass) private var hSize
    private var wide: Bool { hSize == .regular }

    var body: some View {
        VStack(spacing: 8) {
            if wide {
                HStack(spacing: 6) { panes }
            } else {
                VStack(spacing: 6) { panes }
            }

            controls
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { Audio.configure() }
        .sheet(isPresented: $showWeb) {
            WebVideoSheet { url, pane in
                let model = pane == .a ? a : b
                model.load(url)
                playing = true
            }
        }
    }

    @ViewBuilder
    private var panes: some View {
        pane(model: a, label: "A", volume: $a.volume)
        pane(model: b, label: "B", volume: $b.volume)
    }

    // MARK: Panes

    @ViewBuilder
    private func pane(model: PlayerModel, label: String,
                      volume: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                PlayerLayerView(player: model.player)
                    .background(Color(white: 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(label)
                    .font(.caption.bold())
                    .padding(4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { model.setPlaying(!model.isPlaying) }

            HStack {
                Text(model.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Load") {
                    let target = model
                    Task { @MainActor in
                        FilePickerPresenter.shared.presentVideoPicker { url in
                            importVideo(url, into: target)
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            transport(model: model)

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: volume, in: 0...1)
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func transport(model: PlayerModel) -> some View {
        HStack(spacing: 6) {
            Button {
                model.setPlaying(!model.isPlaying)
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            Button {
                model.skip(-15)
            } label: {
                Text("−15").font(.caption.bold())
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(fmt(model.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.currentTime },
                               set: { model.seek(to: $0) }),
                in: 0...max(model.duration, 0.1)
            )
            .controlSize(.mini)
            .disabled(model.duration <= 0)
            Text(fmt(model.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                model.skip(15)
            } label: {
                Text("+15").font(.caption.bold())
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Shared controls

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    playing.toggle()
                    a.setPlaying(playing)
                    b.setPlaying(playing)
                } label: {
                    Label(playing ? "Pause Both" : "Play Both",
                          systemImage: playing ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!a.hasVideo || !b.hasVideo)

                Button {
                    a.restart()
                    b.restart()
                    playing = true
                    a.setPlaying(true)
                    b.setPlaying(true)
                } label: {
                    Label("Restart Both", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!a.hasVideo || !b.hasVideo)

                Button {
                    showWeb = true
                } label: {
                    Label("Web", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.roundedRectangle)

            Text("Tap a video to pause/resume it. −15/+15 and the timeline scrub per pane. Web streams direct MP4/HLS links; each clip loops.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 4)
    }

    // MARK: Import

    private func importVideo(_ url: URL, into model: PlayerModel) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let dest = URL.temporaryDirectory
            .appending(path: "DualPlay-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            model.load(dest)
            playing = true
        } catch {
            model.name = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "--:--" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    ContentView()
}
