import SwiftUI

struct MoQDemoRelayURLs {
    let boyDemoURL: String
    let sharedRelayURL: String

    static let defaults = MoQDemoRelayURLs(
        boyDemoURL: "https://cdn.moq.dev/demo",
        sharedRelayURL: "http://192.168.92.140:4443/anon"
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
