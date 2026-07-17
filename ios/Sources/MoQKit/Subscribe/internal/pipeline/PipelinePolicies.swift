import Foundation

struct TimelinePolicy: Sendable {
    var maxGapUs: Int64 = 500_000
    var freshnessBudgetUs: Int64 = 1_000_000
    var targetLatencyUs: Int64 = 100_000
}

struct AdmissionPolicy: Sendable {
    var maxBytes: UInt64 = 64 * 1024 * 1024
    var maxFrames: Int = 1_024
    var maxDurationUs: Int64 = 5_000_000
    var evictWholeGops = true
    var requireKeyframeAfterReset = true
}

struct RecoveryPolicy: Sendable {
    var maxRecoveries = 2
    var windowNanos: UInt64 = 10_000_000_000
}

struct RenderPolicy: Sendable {
    var maxAheadUs: Int64 = 500_000
    var lateDropThresholdUs: Int64 = 50_000
}

struct ClockPolicy: Sendable {
    var retargetToleranceUs: Int64 = 20_000
    var jumpThresholdUs: Int64 = 500_000
    var minRate = 0.95
    var maxRate = 1.05
}

struct StallPolicy: Sendable {
    var arrivalGapUs: Int64 = 1_000_000
}

struct SwitchPolicy: Sendable {
    var keyframeTimeoutUs: Int64 = 5_000_000
    var cutInWindowUs: Int64 = 500_000
    var flushThresholdUs: Int64 = 2_000_000
}

enum PipelinePolicies {
    static let timeline = TimelinePolicy()
    static let admission = AdmissionPolicy()
    static let recovery = RecoveryPolicy()
    static let render = RenderPolicy()
    static let clock = ClockPolicy()
    static let stall = StallPolicy()
    static let `switch` = SwitchPolicy()
}
