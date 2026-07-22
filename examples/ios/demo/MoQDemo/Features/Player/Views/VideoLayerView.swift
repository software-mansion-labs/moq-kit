import AVFoundation
import SwiftUI
import UIKit

struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoContainerView {
        let view = VideoContainerView()
        view.backgroundColor = .black
        view.setDisplayLayer(layer)
        return view
    }

    func updateUIView(_ uiView: VideoContainerView, context: Context) {
        uiView.setDisplayLayer(layer)
    }

    static func dismantleUIView(_ uiView: VideoContainerView, coordinator: ()) {
        uiView.setDisplayLayer(nil)
    }
}

final class VideoContainerView: UIView {
    private(set) var displayLayer: AVSampleBufferDisplayLayer?

    func setDisplayLayer(_ newLayer: AVSampleBufferDisplayLayer?) {
        guard displayLayer !== newLayer else { return }

        if displayLayer?.superlayer === layer {
            displayLayer?.removeFromSuperlayer()
        }
        displayLayer = newLayer

        if let newLayer {
            newLayer.frame = bounds
            layer.addSublayer(newLayer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
