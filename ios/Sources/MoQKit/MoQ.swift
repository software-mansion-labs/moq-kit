import Clibmoq
import Foundation

public enum MoQ {
    private static var hasInitialized = false
    private static let initializationLock = NSLock()

    public enum LogLevel: String, Sendable {
        case error
        case warn
        case info
        case debug
        case trace
    }

    public static func setupLogger(logLevel: LogLevel) throws {
        initializationLock.lock()
        if hasInitialized {
            initializationLock.unlock()
            return
        }
        do {
            try logLevel.rawValue.withCStringLen { ptr, len in
                try moq_log_level(ptr, len).asSuccess()
            }
            hasInitialized = true
            initializationLock.unlock()
        } catch {
            initializationLock.unlock()
            throw error
        }
    }
}
