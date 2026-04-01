import AVFoundation
import SwiftUI
import MoQKit

@main
struct MoQSubscriberApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .moviePlayback, options: []
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
