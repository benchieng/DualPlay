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
    @Published var fill = false   // false = fit (letterbox), true = fill (crop to pane)
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

    func load(_ url: URL, httpHeaders: [String: String]? = nil) {
        let asset: AVURLAsset
        if let httpHeaders {
            // Hotlink-protected streams (missav et al.) reject bare AVPlayer
            // requests — replay the browser's Referer/Origin/UA.
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

struct WebVideoSheet: View {
    var onPlay: (URL, PaneID, [String: String]) -> Void
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
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let urlString = obj["url"], let url = URL(string: urlString)
                else {
                    note = error != nil
                        ? "Page blocked the probe."
                        : "No playable video found (blob/MSE streams can't be grabbed)."
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
                onPlay(url, pane, headers)
                let leaf = url.lastPathComponent.isEmpty ? (url.host ?? "") : url.lastPathComponent
                note = "Captured: \(leaf)"
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
        .sheet(isPresented: $showWeb) {
            WebVideoSheet { url, pane, headers in
                let model = pane == .a ? a : b
                model.load(url, httpHeaders: headers.isEmpty ? nil : headers)
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
                PlayerLayerView(player: model.player, fill: model.fill)
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
