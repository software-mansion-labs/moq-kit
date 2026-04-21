import MoQKit

final class SampleHandler: MoQReplayKitBroadcastSampleHandler {
    // Use the same App Group in both:
    // 1) Host app target capabilities
    // 2) Broadcast Upload Extension target capabilities
    override var replayKitAppGroupIdentifier: String? {
        "group.dev.moq.publisher"
    }
}
