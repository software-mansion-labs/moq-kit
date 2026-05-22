import Foundation

extension Duration {
    static func nanosecondsClamped(_ nanoseconds: UInt64) -> Duration {
        .nanoseconds(Int64(min(nanoseconds, UInt64(Int64.max))))
    }

    static func microsecondsClamped(_ microseconds: UInt64) -> Duration {
        .microseconds(Int64(min(microseconds, UInt64(Int64.max))))
    }

    static func millisecondsClamped(_ milliseconds: UInt64) -> Duration {
        .milliseconds(Int64(min(milliseconds, UInt64(Int64.max))))
    }

    static func millisecondsClamped(_ milliseconds: Double) -> Duration {
        guard milliseconds.isFinite, milliseconds > 0 else { return .zero }
        let nanoseconds = milliseconds * 1_000_000
        guard nanoseconds < Double(Int64.max) else {
            return .nanoseconds(Int64.max)
        }
        return .nanoseconds(Int64(nanoseconds.rounded()))
    }

    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000.0
            + Double(components.attoseconds) / 1_000_000_000_000_000.0
    }

    var millisecondsUInt64Clamped: UInt64 {
        let milliseconds = milliseconds
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        guard milliseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(milliseconds.rounded())
    }
}
