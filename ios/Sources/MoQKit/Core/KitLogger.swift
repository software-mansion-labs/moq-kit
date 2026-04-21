import os
import MoQKitFFI

/// Centralized logging for MoQKit.
///
/// Use the per-component `Logger` instances for structured logging. Call
/// `setNativeLogLevel(_:)` once at startup to configure the Rust log output.
public enum KitLogger {
    public static let subsystem = "com.swmansion.MoQKit"

    static let session = Logger(subsystem: subsystem, category: "session")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let publish = Logger(subsystem: subsystem, category: "publish")

    private static let initLock = OSAllocatedUnfairLock(initialState: false)

    /// Configures the native (Rust) log level. Only the first call takes effect;
    /// subsequent calls are silently ignored.
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
