import SwiftUI
import AVFoundation
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

    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

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
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        name = url.lastPathComponent
        // Surface unplayable picks instead of failing silently.
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status) { [weak self] observed, _ in
            guard observed.status == .failed, let error = observed.error else { return }
            DispatchQueue.main.async {
                self?.name = "Can't play \(url.lastPathComponent) — \(error.localizedDescription)"
            }
        }
        player.play()
    }

    func setPlaying(_ on: Bool) {
        on ? player.play() : player.pause()
    }

    func restart() {
        player.seek(to: .zero)
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

// MARK: - Content

struct ContentView: View {
    @StateObject private var a = PlayerModel()
    @StateObject private var b = PlayerModel()

    @State private var playing = false

    // Duo rule from Apple: outer display reports compact width, inner display
    // regular. Two branches, no idiom checks.
    @Environment(\.horizontalSizeClass) private var hSize
    private var wide: Bool { hSize == .regular }

    var body: some View {
        VStack(spacing: 10) {
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

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: volume, in: 0...1)
                    .controlSize(.mini)
            }
        }
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

            Text("Both clips play in one app, so iOS mixes the two soundtracks. Each clip loops. The sliders blend A and B.")
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
}

#Preview {
    ContentView()
}
