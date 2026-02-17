import Clibmoq

public enum MoQ {
    public enum LogLevel: String, Sendable {
        case error
        case warn
        case info
        case debug
        case trace
    }

    public static func initialize(logLevel: LogLevel) throws {
        try logLevel.rawValue.withCStringLen { ptr, len in
            try moq_log_level(ptr, len).asSuccess()
        }
    }
}
