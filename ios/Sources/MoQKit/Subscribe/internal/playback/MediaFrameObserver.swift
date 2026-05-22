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
    func onMediaTrackStarted(kind: MediaFrameKind, trackName: String)
    func onMediaFrame(_ frame: MediaFrame, kind: MediaFrameKind, trackName: String)
    func onFrameDiscontinuity(kind: MediaFrameKind, trackName: String, gapUs: UInt64)
}

final class CompositeMediaFrameObserver: MediaFrameObserver {
    private let observers: [any MediaFrameObserver]

    init(_ observers: [any MediaFrameObserver]) {
        self.observers = observers
    }

    func onMediaTrackStarted(kind: MediaFrameKind, trackName: String) {
        for observer in observers {
            observer.onMediaTrackStarted(kind: kind, trackName: trackName)
        }
    }

    func onMediaFrame(_ frame: MediaFrame, kind: MediaFrameKind, trackName: String) {
        for observer in observers {
            observer.onMediaFrame(frame, kind: kind, trackName: trackName)
        }
    }

    func onFrameDiscontinuity(kind: MediaFrameKind, trackName: String, gapUs: UInt64) {
        for observer in observers {
            observer.onFrameDiscontinuity(kind: kind, trackName: trackName, gapUs: gapUs)
        }
    }
}
