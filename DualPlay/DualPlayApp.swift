import SwiftUI
import AVFoundation

@main
struct DualPlayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// One app owns ONE audio session — that's the loophole: two AVPlayers inside
/// this app are never interrupted by each other, and iOS mixes their audio
/// together at the system mixer. The "one video at a time" rule only applies
/// BETWEEN apps.
enum Audio {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        // .playback keeps audio going when the screen locks / app backgrounds.
        // If you want the two clips to also coexist with, say, Spotify, add
        // [.mixWithOthers] here — at the cost of losing lock-screen priority.
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
