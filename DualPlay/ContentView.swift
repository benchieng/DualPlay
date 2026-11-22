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
    @Published var fill = false   // false = fit (letterbox), true = fill (crop to pane)

    // Per-pane browser: a pane can browse the web independently of the other.
    @Published var showWeb = false
    @Published var webAddress = "https://"
    @Published var webURL: URL?
    @Published var webNote = ""
    let browser = WKHolder()

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

    func load(_ url: URL, httpHeaders: [String: String]? = nil) {
        let asset: AVURLAsset
        if let httpHeaders {
            // Constant was removed from the iOS 27 SDK; the runtime still
            // accepts the legacy raw key for URL-asset HTTP headers.
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
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
    let fill: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
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

// MARK: - Per-pane browser

final class WKHolder {
    weak var web: WKWebView?
}

struct WebView: UIViewRepresentable {
    let url: URL?
    let holder: WKHolder

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastRequested: URL? }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        holder.web = web
        context.coordinator.lastRequested = url
        if let url { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard let url, context.coordinator.lastRequested != url else { return }
        context.coordinator.lastRequested = url
        web.load(URLRequest(url: url))
    }
}

/// Finds a playable stream on the page: live <video> sources first, then
/// raw m3u8/mp4 URLs buried in player scripts (with JSON-escaped slashes
/// normalized). Returns JSON {url, page, ua} so playback can replay the
/// browser's Referer/Origin/User-Agent on hotlink-protected streams.
private let videoProbeJS = """
(() => {
  const direct = [];
  const v = document.querySelector('video');
  if (v) { const s = v.currentSrc || v.src; if (s && !s.startsWith('blob:')) direct.push(s); }
  for (const el of document.querySelectorAll('video source')) { if (el.src && !el.src.startsWith('blob:')) direct.push(el.src); }
  const html = document.documentElement.innerHTML.replaceAll('\\\\/', '/');
  const found = html.match(/https?:\\/\\/[^"'\\s<>]+?\\.(?:m3u8|mp4|m4v)(?:\\?[^"'\\s<>]*)?/gi) || [];
  const scored = [...direct.map(u => [0, u]),
                  ...found.map(u => [/\\.m3u8/i.test(u) ? 1 : 2, u])];
  const seen = new Set();
  const uniq = [];
  for (const [p, u] of scored) {
    const clean = u.replaceAll('\\\\', '');
    if (!seen.has(clean) && /^https?:/i.test(clean)) { seen.add(clean); uniq.push([p, clean]); }
  }
  uniq.sort((a, b) => a[0] - b[0]);
  return JSON.stringify({ url: uniq.length ? uniq[0][1] : null, page: location.href, ua: navigator.userAgent });
})()
"""

/// Runs the probe in a web view; completion always fires on the main queue.
func probeStream(in web: WKWebView,
                 completion: @escaping (_ url: URL?, _ headers: [String: String], _ error: String?) -> Void) {
    web.evaluateJavaScript(videoProbeJS) { result, error in
        DispatchQueue.main.async {
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let urlString = obj["url"], let url = URL(string: urlString)
            else {
                completion(nil, [:], error != nil
                    ? "Page blocked the probe."
                    : "No playable video found (blob/MSE streams can't be grabbed).")
                return
            }
            var headers: [String: String] = [:]
            if let page = obj["page"] {
                headers["Referer"] = page
                if let pageURL = URL(string: page), let scheme = pageURL.scheme, let host = pageURL.host {
                    headers["Origin"] = "\(scheme)://\(host)"
                }
            }
            if let ua = obj["ua"] { headers["User-Agent"] = ua }
            completion(url, headers, nil)
        }
    }
}

// MARK: - Pane (one per side: video player + browser mode)

struct PaneView: View {
    @ObservedObject var model: PlayerModel
    let label: String
    var onLoaded: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                Group {
                    if model.showWeb {
                        WebView(url: model.webURL, holder: model.browser)
                    } else {
                        PlayerLayerView(player: model.player, fill: model.fill)
                    }
                }
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(label)
                    .font(.caption.bold())
                    .padding(4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { if !model.showWeb { model.setPlaying(!model.isPlaying) } }

            if model.showWeb {
                webControls
            } else {
                videoControls
            }
        }
    }

    // MARK: Video-mode rows

    @ViewBuilder
    private var videoControls: some View {
        HStack {
            Text(model.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                model.fill.toggle()
            } label: {
                Image(systemName: model.fill
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .padding(6)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help(model.fill ? "Fit video (letterbox)" : "Fill pane (crop)")
            Button {
                model.showWeb = true
                if model.webURL == nil { model.webURL = URL(string: model.webAddress) }
            } label: {
                Image(systemName: "globe")
                    .padding(6)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Browse the web in this pane")
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

        transport

        HStack(spacing: 4) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: $model.volume, in: 0...1)
                .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var transport: some View {
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

    // MARK: Web-mode rows

    @ViewBuilder
    private var webControls: some View {
        HStack(spacing: 6) {
            TextField("URL", text: $model.webAddress)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .onSubmit { go() }
            Button("Go") { go() }
            Button {
                probeHere()
            } label: {
                Image(systemName: "play.circle")
            }
            .help("Capture this page's video and play it in this pane")
            Button {
                model.showWeb = false
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Back to video")
        }
        .buttonStyle(.bordered)
        .font(.caption)

        if !model.webNote.isEmpty {
            Text(model.webNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func go() {
        let text = model.webAddress.hasPrefix("http") ? model.webAddress : "https://" + model.webAddress
        if let url = URL(string: text) {
            model.webURL = url
            model.webNote = ""
        }
    }

    private func probeHere() {
        guard let web = model.browser.web else { return }
        model.webNote = "Probing page…"
        probeStream(in: web) { url, headers, error in
            if let url {
                model.load(url, httpHeaders: headers.isEmpty ? nil : headers)
                model.showWeb = false
                model.webNote = ""
                onLoaded()
            } else {
                model.webNote = error ?? "No playable video found."
            }
        }
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
            onLoaded()
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

// MARK: - Content

struct ContentView: View {
    @StateObject private var a = PlayerModel()
    @StateObject private var b = PlayerModel()

    @State private var playing = false

    // The Duo's size classes are identical in both orientations on the inner
    // display, so the only honest left/right-vs-top/bottom rule is geometry:
    // landscape container -> side-by-side, portrait -> stacked.
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
                if geo.size.width > geo.size.height {
                    HStack(spacing: 6) { panes }
                } else {
                    VStack(spacing: 6) { panes }
                }

                controls
            }
            .padding(8)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { Audio.configure() }
    }

    @ViewBuilder
    private var panes: some View {
        PaneView(model: a, label: "A") { playing = true }
        PaneView(model: b, label: "B") { playing = true }
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
            }
            .buttonBorderShape(.roundedRectangle)

            Text("Each pane: globe = browse the web in that pane; ▶ in web mode captures the page's video. −15/+15, scrub, fit/fill per pane; clips loop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 4)
    }
}

#Preview {
    ContentView()
}
