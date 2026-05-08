@testable import MoQKit

final class TestPlaybackWallClock: PlaybackWallClock, @unchecked Sendable {
    var nowNs: Int64

    init(nowNs: Int64 = 0, nowUs: Int64? = nil) {
        self.nowNs = nowUs.map { Self.multipliedClamped($0, by: 1_000) } ?? nowNs
    }

    func now(in unit: PlaybackTimeUnit) -> Int64 {
        switch unit {
        case .ms:
            return nowNs / 1_000_000
        case .us:
            return nowNs / 1_000
        case .ns:
            return nowNs
        }
    }

    func advance(ms: Int64) {
        nowNs = addingClamped(nowNs, Self.multipliedClamped(ms, by: 1_000_000))
    }

    func setMicroseconds(_ value: Int64) {
        nowNs = Self.multipliedClamped(value, by: 1_000)
    }

    private static func multipliedClamped(_ value: Int64, by multiplier: Int64) -> Int64 {
        let result = value.multipliedReportingOverflow(by: multiplier)
        if result.overflow {
            return (value >= 0) == (multiplier >= 0) ? Int64.max : Int64.min
        }
        return result.partialValue
    }

    private func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        if result.overflow {
            return rhs >= 0 ? Int64.max : Int64.min
        }
        return result.partialValue
    }
}
