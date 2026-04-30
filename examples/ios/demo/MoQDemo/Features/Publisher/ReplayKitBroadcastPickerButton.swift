import ReplayKit
import SwiftUI
import UIKit

struct ReplayKitBroadcastPickerButton: UIViewRepresentable {
    let preferredExtension: String?

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = preferredExtension
        picker.showsMicrophoneButton = true
        
        // Optional: Change the button's tint if it's hard to see
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.imageView?.tintColor = .systemBlue
            }
        }
        
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = preferredExtension
    }
}
