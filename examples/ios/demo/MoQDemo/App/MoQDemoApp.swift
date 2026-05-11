import SwiftUI

struct MoQDemoRelayURLs {
    let boyDemoURL: String
    let sharedRelayURL: String

    static let defaults = MoQDemoRelayURLs(
        boyDemoURL: "https://cdn.moq.dev/demo",
        sharedRelayURL: "https://cdn.moq.dev/demo"
    )
}

@main
struct MoQDemoApp: App {
    private let relayURLs = MoQDemoRelayURLs.defaults

    init() {
        PublisherViewModel.configurePlaybackAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(relayURLs: relayURLs)
        }
    }
}
