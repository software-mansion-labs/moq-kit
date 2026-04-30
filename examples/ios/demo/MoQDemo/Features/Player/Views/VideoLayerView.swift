import AVFoundation
import SwiftUI
import UIKit

struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoContainerView {
        let view = VideoContainerView()
        view.displayLayer = layer
        view.layer.addSublayer(layer)
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: VideoContainerView, context: Context) {}
}

final class VideoContainerView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
