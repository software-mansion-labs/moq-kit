import AVFoundation
import CoreMedia

/// Availability adapter for the background-safe iOS 17/macOS 14 video renderer while
/// preserving the package's iOS 16/macOS 13 deployment baseline.
final class VideoRenderTarget: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    var isReadyForMoreMediaData: Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            return layer.sampleBufferRenderer.isReadyForMoreMediaData
        }
        return layer.isReadyForMoreMediaData
    }

    var status: AVQueuedSampleBufferRenderingStatus {
        if #available(iOS 17.0, macOS 14.0, *) {
            return layer.sampleBufferRenderer.status
        }
        return layer.status
    }

    var error: Error? {
        if #available(iOS 17.0, macOS 14.0, *) {
            return layer.sampleBufferRenderer.error
        }
        return layer.error
    }

    var requiresFlushToResumeDecoding: Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            return layer.sampleBufferRenderer.requiresFlushToResumeDecoding
        }
        return layer.requiresFlushToResumeDecoding
    }

    func requestMediaDataWhenReady(
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        if #available(iOS 17.0, macOS 14.0, *) {
            layer.sampleBufferRenderer.requestMediaDataWhenReady(on: queue, using: block)
        } else {
            layer.requestMediaDataWhenReady(on: queue, using: block)
        }
    }

    func stopRequestingMediaData() {
        if #available(iOS 17.0, macOS 14.0, *) {
            layer.sampleBufferRenderer.stopRequestingMediaData()
        } else {
            layer.stopRequestingMediaData()
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if #available(iOS 17.0, macOS 14.0, *) {
            layer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            layer.enqueue(sampleBuffer)
        }
    }

    func flush(removeDisplayedImage: Bool) {
        if #available(iOS 17.0, macOS 14.0, *) {
            layer.sampleBufferRenderer.flush(
                removingDisplayedImage: removeDisplayedImage,
                completionHandler: nil
            )
        } else if removeDisplayedImage {
            layer.flushAndRemoveImage()
        } else {
            layer.flush()
        }
    }
}
