import SwiftUI

@main
struct MoQDemoApp: App {
    init() {
        PublisherViewModel.configurePlaybackAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
