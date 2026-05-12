import CoreMedia

/// Advanced protocol for custom capture sources that feed `CMSampleBuffer` values into ``Publisher``.
///
/// Most apps can use built-in sources such as ``CameraCapture``, ``MicrophoneCapture``,
/// and ``ScreenCapture``. Conform to `FrameSource` when you already have your own capture
/// pipeline and want to plug it into MoQKit publishing.
public protocol FrameSource: AnyObject, Sendable {
    /// Callback installed by the publisher when the track starts.
    ///
    /// Call this for every captured sample buffer. Return `false` from the callback means
    /// the downstream consumer no longer wants frames, so the source should stop producing them.
    var onFrame: (@Sendable (CMSampleBuffer) -> Bool)? { get set }
}
