import MoQKitFFI
    import CoreMedia
    import Foundation

    /// Resolves video format descriptions and preprocesses payloads for AVSampleBufferDisplayLayer.
    ///
    /// Strategy is determined by whether a decoder configuration record is present:
    /// - **Has description** (e.g. avc1, hev1, hvc1): payloads arrive length-prefixed (AVCC/HVCC)
    ///   and are passed through as-is — AVSampleBufferDisplayLayer expects this format.
    /// - **No description** (e.g. avc3, hev3): payloads are Annex B. Parameter sets are extracted
    ///   in-band from the first keyframe; subsequent frames are converted to length-prefixed.
    enum VideoCodec {
        case h264
        case hevc
        case av1

        init?(string: String) {
            let s = string.lowercased()
            if s.hasPrefix("avc") { self = .h264 }
            else if s.hasPrefix("hev") || s.hasPrefix("hvc") { self = .hevc }
            else if s.hasPrefix("av0") { self = .av1 }
            else { return nil }
        }
    }

    final class VideoFrameProcessor: @unchecked Sendable {
        private let hasDescription: Bool
        private let codec: VideoCodec
        private let codedWidth: Int32
        private let codedHeight: Int32
        private var formatDescription: CMFormatDescription?
        private let lock = NSLock()

        init(config: MoqVideo) throws {
            guard let codec = VideoCodec(string: config.codec) else {
                throw MoQSessionError.unsupportedCodec(config.codec)
            }
            self.hasDescription = config.description != nil
            self.codec = codec
            self.codedWidth = Int32(config.coded?.width ?? 0)
            self.codedHeight = Int32(config.coded?.height ?? 0)

            if hasDescription {
                self.formatDescription = try SampleBufferFactory.makeVideoFormatDescription(
                    from: config)
                MoQLogger.player.debug(
                    "VideoFrameProcessor: format description ready for codec=\(config.codec)")
            } else {
                MoQLogger.player.debug(
                    "VideoFrameProcessor: no description for codec=\(config.codec) — deferring to in-band parameter sets"
                )
            }
        }

        /// Whether this processor has a format description ready.
        var hasFormatDescription: Bool {
            lock.lock()
            defer { lock.unlock() }
            return formatDescription != nil
        }

        /// Whether this processor can eventually produce frames.
        var canProcess: Bool {
            return hasFormatDescription || !hasDescription
        }

        /// Process a raw frame payload into a CMSampleBuffer.
        ///
        /// Returns nil if the format description isn't available yet
        /// (waiting for the first in-band keyframe).
        func process(payload: Data, timestampUs: UInt64, keyframe: Bool)
            throws -> CMSampleBuffer?
        {
            lock.lock()

            if !hasDescription && formatDescription == nil {
                // Annex B path: extract parameter sets from the first keyframe
                guard keyframe else {
                    lock.unlock()
                    MoQLogger.player.debug(
                        "Dropping non-keyframe: waiting for in-band parameter sets")
                    return nil
                }

                do {
                    guard let fmt = try extractInBandFormatDescription(from: payload) else {
                        lock.unlock()
                        return nil
                    }
                    formatDescription = fmt
                } catch {
                    lock.unlock()
                    MoQLogger.player.error(
                        "Failed to build format description from in-band params: \(error)")
                    return nil
                }
            }

            guard let fmt = formatDescription else {
                lock.unlock()
                MoQLogger.player.debug("Waiting for format description, skipping frame")
                return nil
            }

            lock.unlock()

            // AV1 OBU temporal units are already in the correct format for
            // AVSampleBufferDisplayLayer and never need Annex B → length-prefix conversion.
            // Has-description H.264/H.265 payloads are already length-prefixed — pass through.
            // Only in-band H.264/H.265 (no out-of-band description) require the conversion.
            let processedPayload =
                (hasDescription || codec == .av1) ? payload : AnnexBDemuxer.toLengthPrefixed(payload)

            return try SampleBufferFactory.makeSampleBuffer(
                payload: processedPayload, timestampUs: timestampUs,
                formatDescription: fmt)
        }

        // MARK: - Private

        private func extractInBandFormatDescription(from payload: Data) throws
            -> CMFormatDescription?
        {
            switch codec {
            case .av1:
                guard let seqHeader = AV1Utils.extractSequenceHeader(from: payload) else {
                    MoQLogger.player.debug("Keyframe lacks AV1 sequence header, dropping")
                    return nil
                }
                MoQLogger.player.debug(
                    "Extracted in-band AV1 sequence header: \(seqHeader.count) bytes")
                return try SampleBufferFactory.makeAV1FormatDescriptionFromSequenceHeader(
                    seqHeader, width: codedWidth, height: codedHeight)
            case .hevc:
                guard let params = H265Utils.extractParameterSets(from: payload) else {
                    MoQLogger.player.debug("Keyframe lacks H.265 VPS/SPS/PPS, dropping")
                    return nil
                }
                MoQLogger.player.debug(
                    "Extracted in-band HEVC parameter sets: vps=\(params.vps.count) sps=\(params.sps.count) pps=\(params.pps.count)"
                )
                return try SampleBufferFactory.makeHEVCFormatDescriptionFromParameterSets(
                    vps: params.vps, sps: params.sps, pps: params.pps)
            case .h264:
                guard let params = H264Utils.extractParameterSets(from: payload) else {
                    MoQLogger.player.debug("Keyframe lacks H.264 SPS/PPS, dropping")
                    return nil
                }
                MoQLogger.player.debug(
                    "Extracted in-band H.264 parameter sets: sps=\(params.sps.count) pps=\(params.pps.count)"
                )
                return try SampleBufferFactory.makeH264FormatDescriptionFromParameterSets(
                    sps: params.sps, pps: params.pps)
            }
        }
    }
