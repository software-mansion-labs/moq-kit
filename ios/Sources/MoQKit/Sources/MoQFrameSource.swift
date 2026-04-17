import CoreMedia

/// A source that produces CMSampleBuffer frames.
///
/// Conforming types deliver frames to a consumer via the ``onFrame`` callback.
/// The callback returns `Bool`: `true` to continue, `false` to signal the source
/// should shut down.
public protocol MoQFrameSource: AnyObject, Sendable {
    /// Set by the consumer. Called for each captured frame.
    /// Return `false` to signal the source to stop.
    var onFrame: (@Sendable (CMSampleBuffer) -> Bool)? { get set }
}

/// A passthrough frame source for wiring non-conforming producers
/// (e.g. ScreenCapture's separate video/audio streams).
public final class MoQFrameRelay: MoQFrameSource, @unchecked Sendable {
    public var onFrame: (@Sendable (CMSampleBuffer) -> Bool)?

    public init() {}

    /// Feed a frame to the consumer. Returns `false` if the consumer signaled stop,
    /// or `true` if no consumer is attached.
    @discardableResult
    public func send(_ sampleBuffer: CMSampleBuffer) -> Bool {
        onFrame?(sampleBuffer) ?? true
    }
}
