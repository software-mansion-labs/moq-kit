import AVFoundation
import SwiftUI

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
