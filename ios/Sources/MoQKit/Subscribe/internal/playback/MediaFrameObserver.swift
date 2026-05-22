import Foundation

enum MediaFrameKind: Sendable {
    case audio
    case video
}

extension MediaFrameKind {
    var eventName: String {
        switch self {
        case .audio:
            return "audio"
        case .video:
            return "video"
        }
    }
}

protocol MediaFrameObserver: Sendable {
    func onMediaTrackStarted(kind: MediaFrameKind)
    func onMediaFrame(kind: MediaFrameKind, frame: MediaFrame)
    func onMediaDiscontinuity(kind: MediaFrameKind, gapUs: UInt64)
}

final class CompositeMediaFrameObserver: MediaFrameObserver {
    private let observers: [any MediaFrameObserver]

    init(_ observers: [any MediaFrameObserver]) {
        self.observers = observers
    }

    func onMediaTrackStarted(kind: MediaFrameKind) {
        for observer in observers {
            observer.onMediaTrackStarted(kind: kind)
        }
    }

    func onMediaFrame(kind: MediaFrameKind, frame: MediaFrame) {
        for observer in observers {
            observer.onMediaFrame(kind: kind, frame: frame)
        }
    }

    func onMediaDiscontinuity(kind: MediaFrameKind, gapUs: UInt64) {
        for observer in observers {
            observer.onMediaDiscontinuity(kind: kind, gapUs: gapUs)
        }
    }
}
