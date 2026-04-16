import AVFoundation
import SwiftUI

@main
struct MoQPublisherApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
