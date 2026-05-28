import AVFoundation
import MoQKit
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}

struct MultiCameraPreviewView: UIViewRepresentable {
    let session: AVCaptureMultiCamSession
    let mainCameraPosition: CameraPosition
    let onSwap: () -> Void

    func makeUIView(context: Context) -> MultiCameraPreviewUIView {
        let view = MultiCameraPreviewUIView()
        view.configure(
            session: session,
            mainCameraPosition: mainCameraPosition,
            onSwap: onSwap
        )
        return view
    }

    func updateUIView(_ uiView: MultiCameraPreviewUIView, context: Context) {
        uiView.configure(
            session: session,
            mainCameraPosition: mainCameraPosition,
            onSwap: onSwap
        )
    }

    static func dismantleUIView(_ uiView: MultiCameraPreviewUIView, coordinator: ()) {
        uiView.disconnect()
    }
}

final class MultiCameraPreviewUIView: UIView {
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    private var backPreviewLayer: AVCaptureVideoPreviewLayer?
    private weak var session: AVCaptureMultiCamSession?
    private var mainCameraPosition: CameraPosition = .back
    private var onSwap: (() -> Void)?
    private var floatingFrame: CGRect = .zero
    private var frontPreviewConnection: AVCaptureConnection?
    private var backPreviewConnection: AVCaptureConnection?

    override init(frame: CGRect) {
        super.init(frame: frame)

        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Multi-camera preview"

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPreviewLayers()
    }

    func configure(
        session: AVCaptureMultiCamSession,
        mainCameraPosition: CameraPosition,
        onSwap: @escaping () -> Void
    ) {
        self.onSwap = onSwap
        self.mainCameraPosition = mainCameraPosition

        if self.session !== session {
            disconnect()

            let frontPreviewLayer = makePreviewLayer(session: session)
            let backPreviewLayer = makePreviewLayer(session: session)
            layer.addSublayer(backPreviewLayer)
            layer.addSublayer(frontPreviewLayer)

            self.frontPreviewLayer = frontPreviewLayer
            self.backPreviewLayer = backPreviewLayer
            self.session = session

            frontPreviewConnection = connect(previewLayer: frontPreviewLayer, cameraPosition: .front)
            backPreviewConnection = connect(previewLayer: backPreviewLayer, cameraPosition: .back)
        }
        layoutPreviewLayers()
    }

    func disconnect() {
        disconnectPreviewConnection(frontPreviewConnection)
        disconnectPreviewConnection(backPreviewConnection)
        frontPreviewConnection = nil
        backPreviewConnection = nil

        frontPreviewLayer?.removeFromSuperlayer()
        backPreviewLayer?.removeFromSuperlayer()
        frontPreviewLayer = nil
        backPreviewLayer = nil
        session = nil
    }

    private func makePreviewLayer(session: AVCaptureMultiCamSession) -> AVCaptureVideoPreviewLayer {
        let previewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        previewLayer.videoGravity = .resizeAspectFill
        return previewLayer
    }

    private func connect(
        previewLayer: AVCaptureVideoPreviewLayer,
        cameraPosition: CameraPosition
    ) -> AVCaptureConnection? {
        guard
            let session,
            let input = session.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput })
                .first(where: { $0.device.position == cameraPosition.avPosition }),
            let port = input.ports.first(where: { $0.mediaType == .video })
        else {
            return nil
        }

        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraPosition == .front
        }

        session.beginConfiguration()
        if session.canAddConnection(connection) {
            session.addConnection(connection)
            session.commitConfiguration()
            return connection
        }
        session.commitConfiguration()
        return nil
    }

    private func disconnectPreviewConnection(_ connection: AVCaptureConnection?) {
        guard let session, let connection else {
            return
        }

        session.beginConfiguration()
        if session.connections.contains(where: { $0 === connection }) {
            session.removeConnection(connection)
        }
        session.commitConfiguration()
    }

    private func layoutPreviewLayers() {
        guard frontPreviewLayer != nil, backPreviewLayer != nil else { return }

        let pipWidth = min(max(bounds.width * 0.28, 88), 128)
        let pipHeight = pipWidth * 4 / 3
        floatingFrame = CGRect(
            x: bounds.maxX - pipWidth - 10,
            y: bounds.minY + 10,
            width: pipWidth,
            height: pipHeight
        )

        let mainLayer = layer(for: mainCameraPosition)
        let floatingLayer = layer(for: floatingCameraPosition)

        mainLayer?.frame = bounds
        mainLayer?.cornerRadius = 0
        mainLayer?.borderWidth = 0
        mainLayer?.zPosition = 0

        floatingLayer?.frame = floatingFrame
        floatingLayer?.cornerRadius = 8
        floatingLayer?.masksToBounds = true
        floatingLayer?.borderColor = UIColor.white.withAlphaComponent(0.75).cgColor
        floatingLayer?.borderWidth = 1
        floatingLayer?.zPosition = 1
    }

    private var floatingCameraPosition: CameraPosition {
        mainCameraPosition == .front ? .back : .front
    }

    private func layer(for cameraPosition: CameraPosition) -> AVCaptureVideoPreviewLayer? {
        switch cameraPosition {
        case .front: return frontPreviewLayer
        case .back: return backPreviewLayer
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard floatingFrame.contains(recognizer.location(in: self)) else { return }
        onSwap?()
    }
}

private extension CameraPosition {
    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
