import MoQKit

final class SampleHandler: MoQReplayKitBroadcastSampleHandler {
    override var replayKitAppGroupIdentifier: String? {
        "group.com.swmansion.moqdemo"
    }
}
