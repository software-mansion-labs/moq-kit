import SwiftUI

struct MoQDemoRelayURLs {
    let boyDemoURL: String
    let sharedRelayURL: String

    static let defaults = MoQDemoRelayURLs(
        boyDemoURL: "https://cdn.moq.dev/demo",
        // sharedRelayURL: "http://192.168.92.134:4443/anon"
        sharedRelayURL: "https://moq.fishjam.work/public"
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
