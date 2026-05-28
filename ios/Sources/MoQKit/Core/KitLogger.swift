import os
import MoqFFI

/// Centralized logging for MoQKit.
///
/// Use the per-component `Logger` instances for structured logging. Call
/// `setNativeLogLevel(_:)` once at startup to configure the Rust log output.
public enum KitLogger {
    /// The shared logging subsystem used by MoQKit's `Logger` categories.
    public static let subsystem = "com.swmansion.MoQKit"

    static let session = Logger(subsystem: subsystem, category: "session")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let publish = Logger(subsystem: subsystem, category: "publish")

    private static let initLock = OSAllocatedUnfairLock(initialState: false)

    /// Configures the native Rust log level.
    ///
    /// Only the first call takes effect; later calls are ignored so the log pipeline
    /// stays consistent for the lifetime of the process.
    ///
    /// Must be called before any other MoQKit API to capture early Rust logs.
    /// - Parameter level: One of `"error"`, `"warn"`, `"info"`, `"debug"`, `"trace"`.
    public static func setNativeLogLevel(_ level: String = "info") {
        initLock.withLock { initialized in
            guard !initialized else { return }
            initialized = true
            try? moqLogLevel(level: level)
        }
    }
}
