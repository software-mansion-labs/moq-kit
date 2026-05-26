import Foundation

struct PerMediaKind<Value> {
    var audio: Value
    var video: Value

    init(audio: Value, video: Value) {
        self.audio = audio
        self.video = video
    }

    init(_ makeValue: () -> Value) {
        self.audio = makeValue()
        self.video = makeValue()
    }

    subscript(kind: MediaFrameKind) -> Value {
        get {
            switch kind {
            case .audio:
                return audio
            case .video:
                return video
            }
        }
        set {
            switch kind {
            case .audio:
                audio = newValue
            case .video:
                video = newValue
            }
        }
    }

    mutating func update(
        _ kind: MediaFrameKind,
        _ body: (inout Value) -> Void
    ) {
        switch kind {
        case .audio:
            body(&audio)
        case .video:
            body(&video)
        }
    }
}

extension PerMediaKind: Sendable where Value: Sendable {}
