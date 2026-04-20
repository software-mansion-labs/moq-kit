import CoreMedia

/// A source that produces CMSampleBuffer frames.
///
/// Conforming types deliver frames to a consumer via the ``onFrame`` callback.
/// The callback returns `Bool`: `true` to continue, `false` to signal the source
/// should shut down.
public protocol FrameSource: AnyObject, Sendable {
    /// Set by the consumer. Called for each captured frame.
    /// Return `false` to signal the source to stop.
    var onFrame: (@Sendable (CMSampleBuffer) -> Bool)? { get set }
}
