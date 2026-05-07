import Foundation

enum MediaFrameKind: Sendable {
    case audio
    case video
}

protocol MediaFrameObserver: Sendable {
    func onMediaFrame(_ frame: MediaFrame, kind: MediaFrameKind)
    func onFrameDiscontinuity(kind: MediaFrameKind, gapUs: UInt64)
}

final class CompositeMediaFrameObserver: MediaFrameObserver {
    private let observers: [any MediaFrameObserver]

    init(_ observers: [any MediaFrameObserver]) {
        self.observers = observers
    }

    func onMediaFrame(_ frame: MediaFrame, kind: MediaFrameKind) {
        for observer in observers {
            observer.onMediaFrame(frame, kind: kind)
        }
    }

    func onFrameDiscontinuity(kind: MediaFrameKind, gapUs: UInt64) {
        for observer in observers {
            observer.onFrameDiscontinuity(kind: kind, gapUs: gapUs)
        }
    }
}
