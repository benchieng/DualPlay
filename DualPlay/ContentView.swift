import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Player model

@MainActor
final class PlayerModel: ObservableObject, Identifiable {
    let id = UUID()
    let player = AVPlayer()
    @Published var name: String = "No video loaded"
    @Published var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }

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
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.volume = volume
        name = url.lastPathComponent
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

// MARK: - Photos video transfer (PhotosPicker → playable file URL)

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let safeName = received.file.lastPathComponent
                .replacingOccurrences(of: " ", with: "-")
            let dest = URL.temporaryDirectory.appending(path: safeName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}

// MARK: - Content

struct ContentView: View {
    @StateObject private var a = PlayerModel()
    @StateObject private var b = PlayerModel()

    @State private var pickingA: PhotosPickerItem?
    @State private var pickingB: PhotosPickerItem?
    @State private var playing = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                pane(model: a, label: "A", selection: $pickingA)
                pane(model: b, label: "B", selection: $pickingB)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
        }
        .padding(8)
        .background(Color.black.ignoresSafeArea())
        .onAppear { Audio.configure() }
        .onChange(of: pickingA) { _, item in Task { await load(item, into: a) } }
        .onChange(of: pickingB) { _, item in Task { await load(item, into: b) } }
    }

    // MARK: Panes

    @ViewBuilder
    private func pane(model: PlayerModel, label: String,
                      selection: Binding<PhotosPickerItem?>) -> some View {
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
            HStack {
                Text(model.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                PhotosPicker(selection: selection, matching: .videos) {
                    Text("Load").font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.25))
                .foregroundStyle(.primary)
            }
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: model.volume, in: 0...1)
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

            Text("Both clips play in one app, so iOS mixes the two soundtracks. Each clip loops. Drag the sliders to blend A/B.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 4)
    }

    // MARK: Loading

    private func load(_ item: PhotosPickerItem?, into model: PlayerModel) async {
        guard let item,
              let video = try? await item.loadTransferable(type: PickedVideo.self)
        else { return }
        model.load(video.url)
        playing = true
    }
}

#Preview {
    ContentView()
}
