import CoreMedia
import VideoToolbox

/// Hardware H.264 encoder using `VTCompressionSession`.
final class VideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var handler: ((EncodedVideoFrame) -> Void)?
    private var sentInitData = false

    var config: VideoEncoderConfig

    init(config: VideoEncoderConfig) {
        self.config = config
    }

    func start(handler: @escaping (EncodedVideoFrame) -> Void) throws {
        self.handler = handler
        sentInitData = false

        let codecType: CMVideoCodecType
        switch config.codec {
        case .h264:
            codecType = kCMVideoCodecType_H264
        case .h265:
            codecType = kCMVideoCodecType_HEVC
        }

        var sessionRef: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard let refcon, status == noErr, let sampleBuffer else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedFrame(sampleBuffer)
        }
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: config.width,
            height: config.height,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionRef
        )

        guard status == noErr, let session = sessionRef else {
            throw SessionError.invalidConfiguration(
                "Failed to create compression session: \(status)")
        }
        self.session = session

        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: config.bitrate)
        )
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: config.maxFrameRate)
        )

        let keyframeIntervalFrames = Int(config.keyframeInterval * config.maxFrameRate)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: keyframeIntervalFrames)
        )

        if let profileLevel = config.profileLevel {
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel,
                value: profileLevel as CFString
            )
        } else {
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_High_AutoLevel)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration.isValid ? duration : .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        handler = nil
    }

    /// Tear down the current compression session and recreate it with new dimensions.
    /// The existing handler callback is preserved.
    func reset(width: Int32, height: Int32) throws {
        guard let handler = self.handler else { return }
        stop()
        config.width = width
        config.height = height
        try start(handler: handler)
    }

    // MARK: - Private

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false)
        var isKeyframe = true
        if let attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if let notSync = CFDictionaryGetValue(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            {
                isKeyframe = !(unsafeBitCast(notSync, to: CFBoolean.self) == kCFBooleanTrue)
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer)
        guard let dataPointer, totalLength > 0 else { return }
        var data = Data(bytes: dataPointer, count: totalLength)

        if config.naluFormat == .annexB {
            convertLengthPrefixedToAnnexB(&data)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var initData: Data?
        if isKeyframe && !sentInitData {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                initData = buildInitData(from: formatDesc)
                if initData != nil {
                    sentInitData = true
                }
            }
        }

        let frame = EncodedVideoFrame(
            data: data,
            presentationTime: pts,
            isKeyframe: isKeyframe,
            initData: initData
        )
        handler?(frame)
    }

    /// Replace 4-byte big-endian length prefixes with Annex B start codes (`00 00 00 01`) in-place.
    /// Both representations are exactly 4 bytes, so the data size is unchanged.
    private func convertLengthPrefixedToAnnexB(_ data: inout Data) {
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var offset = 0
        while offset + 4 <= data.count {
            let naluLength = Int(data[offset]) << 24
                | Int(data[offset + 1]) << 16
                | Int(data[offset + 2]) << 8
                | Int(data[offset + 3])
            data.replaceSubrange(offset..<offset + 4, with: startCode)
            offset += 4 + naluLength
        }
    }

    private func buildInitData(from formatDesc: CMFormatDescription) -> Data? {
        switch config.codec {
        case .h264:
            return buildAVCCRecord(from: formatDesc)
        case .h265:
            return buildHVCCRecord(from: formatDesc)
        }
    }

    /// Build an AVCDecoderConfigurationRecord from VTCompressionSession output.
    private func buildAVCCRecord(from formatDesc: CMFormatDescription) -> Data? {
        var count: Int = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, count > 0 else { return nil }

        var spsSets: [Data] = []
        var ppsSets: [Data] = []

        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let ptr, size > 0 else { continue }
            let data = Data(bytes: ptr, count: size)
            let nalType = data[0] & 0x1F
            if nalType == 7 {
                spsSets.append(data)
            } else if nalType == 8 {
                ppsSets.append(data)
            }
        }

        guard let firstSPS = spsSets.first, firstSPS.count >= 4, !ppsSets.isEmpty else {
            return nil
        }

        let profile = firstSPS[1]
        let compat = firstSPS[2]
        let level = firstSPS[3]

        var record = Data()
        record.append(1)  // configurationVersion
        record.append(profile)
        record.append(compat)
        record.append(level)
        record.append(0xFF)  // lengthSizeMinusOne = 3 (4 bytes) | reserved 0b111111
        record.append(UInt8(0xE0 | spsSets.count))  // numSPS | reserved 0b111

        for spsData in spsSets {
            var len = UInt16(spsData.count).bigEndian
            record.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
            record.append(spsData)
        }

        record.append(UInt8(ppsSets.count))
        for ppsData in ppsSets {
            var len = UInt16(ppsData.count).bigEndian
            record.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
            record.append(ppsData)
        }

        return record
    }

    /// Build an HEVCDecoderConfigurationRecord from VTCompressionSession output.
    /// Note: H.265 support is limited — the Rust side expects Annex B for "hev1".
    private func buildHVCCRecord(from formatDesc: CMFormatDescription) -> Data? {
        // For H.265, extract VPS/SPS/PPS via HEVC API
        var vpsList: [Data] = []
        var spsList: [Data] = []
        var ppsList: [Data] = []

        // Extract all parameter sets
        for i in 0..<64 {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let ptr, size > 0 else { break }
            let data = Data(bytes: ptr, count: size)
            // NAL unit type is in bits 1-6 of the first byte
            let nalType = (data[0] >> 1) & 0x3F
            switch nalType {
            case 32: vpsList.append(data)  // VPS
            case 33: spsList.append(data)  // SPS
            case 34: ppsList.append(data)  // PPS
            default: break
            }
        }

        guard !vpsList.isEmpty && !spsList.isEmpty && !ppsList.isEmpty else { return nil }

        // Build Annex B init data: [start code + VPS] [start code + SPS] [start code + PPS]
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var initData = Data()
        for vps in vpsList {
            initData.append(startCode)
            initData.append(vps)
        }
        for sps in spsList {
            initData.append(startCode)
            initData.append(sps)
        }
        for pps in ppsList {
            initData.append(startCode)
            initData.append(pps)
        }
        return initData
    }
}

// MARK: - Types

struct EncodedVideoFrame {
    let data: Data
    let presentationTime: CMTime
    let isKeyframe: Bool
    let initData: Data?
}

/// Codec for video encoding.
public enum VideoCodec: String, Sendable, Hashable, Codable {
    case h264
    case h265
}

/// NAL unit framing format.
public enum NaluFormat: String, Sendable, Codable {
    /// Annex B start codes (`00 00 00 01`).
    case annexB
    /// 4-byte big-endian length prefix (AVCC/HVCC box style).
    case avcc
}

/// Configuration for the hardware video encoder.
public struct VideoEncoderConfig: Sendable, Codable {
    public var codec: VideoCodec
    public var width: Int32
    public var height: Int32
    public var bitrate: UInt32
    public var keyframeInterval: Double
    public var maxFrameRate: Double
    public var profileLevel: String?
    public var naluFormat: NaluFormat

    public init(
        codec: VideoCodec = .h264,
        width: Int32 = 1920,
        height: Int32 = 1080,
        bitrate: UInt32 = 1_500_000,
        keyframeInterval: Double = 2.0,
        maxFrameRate: Double = 30.0,
        profileLevel: String? = nil,
        naluFormat: NaluFormat? = nil
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.keyframeInterval = keyframeInterval
        self.maxFrameRate = maxFrameRate
        self.profileLevel = profileLevel
        self.naluFormat = naluFormat ?? (codec == .h265 ? .annexB : .avcc)
    }

    var format: String {
        switch codec {
        case .h264: return "avc1"
        case .h265: return "hev1"
        }
    }
}
