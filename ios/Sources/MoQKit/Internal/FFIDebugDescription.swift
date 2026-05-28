import Foundation
import MoqFFI

extension MoqVideo {
    var moqKitDebugDescription: String {
        "codec=\(codec), width=\(coded?.width ?? 0), height=\(coded?.height ?? 0)"
    }
}

extension MoqAudio {
    var moqKitDebugDescription: String {
        "codec=\(codec), sampleRate=\(sampleRate), channels=\(channelCount)"
    }
}

extension Container {
    var moqKitDescription: String {
        switch self {
        case .legacy:
            return "legacy"
        case .cmaf(let initData):
            return "cmaf{initBytes=\(initData.count)}"
        case .loc:
            return "loc"
        }
    }
}
