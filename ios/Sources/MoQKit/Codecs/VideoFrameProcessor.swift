#if os(iOS)
    import CoreMedia
    import Foundation

    /// Resolves video format descriptions and preprocesses payloads for AVSampleBufferDisplayLayer.
    /// Handles codec-specific concerns (avc3 in-band params, Annex B → length-prefixed conversion)
    /// so the player doesn't need to know about them.
    final class VideoFrameProcessor: @unchecked Sendable {
        private let codec: String
        private let isAvc3: Bool
        private var formatDescription: CMFormatDescription?
        private let lock = NSLock()

        init(config: MoqVideo) throws {
            self.codec = config.codec.lowercased()
            self.isAvc3 = codec.hasPrefix("avc3")

            MoQLogger.player.debug(
                "VideoFrameProcessor: codec=\(self.codec), isAvc3=\(self.isAvc3), hasDescription=\(config.description?.count ?? 0 > 0)"
            )

            if isAvc3 && (config.description == nil || config.description!.isEmpty) {
                // avc3: format description will be built from in-band SPS/PPS on first keyframe
                MoQLogger.player.debug(
                    "avc3 detected — deferring format description to in-band parameter sets"
                )
            } else {
                self.formatDescription = try SampleBufferFactory.makeVideoFormatDescription(
                    from: config)
            }
        }

        /// Whether this processor has a format description ready (either from config or from in-band params).
        var hasFormatDescription: Bool {
            lock.lock()
            defer { lock.unlock() }
            return formatDescription != nil
        }

        /// Whether this processor can eventually produce frames (has format or expects in-band params).
        var canProcess: Bool {
            return hasFormatDescription || isAvc3
        }

        /// Process a raw frame payload into a CMSampleBuffer.
        /// Returns nil if format description isn't available yet (avc3 waiting for first keyframe).
        func process(payload: Data, timestampUs: UInt64, keyframe: Bool)
            throws -> CMSampleBuffer?
        {
            var processedPayload = payload

            lock.lock()

            // avc3: extract in-band SPS/PPS from keyframes and update format description
            if isAvc3 {
                if let params = H264Utils.extractParameterSets(from: payload) {
                    do {
                        let newFmt =
                            try SampleBufferFactory.makeH264FormatDescriptionFromParameterSets(
                                sps: params.sps, pps: params.pps)
                        if formatDescription == nil
                            || !CMFormatDescriptionEqual(
                                newFmt, otherFormatDescription: formatDescription!)
                        {
                            MoQLogger.player.debug(
                                "avc3: updated video format description from in-band parameter sets"
                            )
                            formatDescription = newFmt
                        }
                    } catch {
                        MoQLogger.player.error(
                            "avc3: failed to build format description from in-band params: \(error)"
                        )
                    }
                } else if formatDescription == nil {
                    lock.unlock()
                    MoQLogger.player.debug(
                        "avc3: keyframe has no in-band SPS/PPS, skipping")
                    return nil
                }

                // Convert Annex B → length-prefixed for AVSampleBufferDisplayLayer
                processedPayload = AnnexBDemuxer.toLengthPrefixed(payload)
            }

            guard let fmt = formatDescription else {
                lock.unlock()
                MoQLogger.player.debug("Waiting for format description, skipping frame")
                return nil
            }

            lock.unlock()

            return try SampleBufferFactory.makeSampleBuffer(
                payload: processedPayload, timestampUs: timestampUs,
                formatDescription: fmt)
        }
    }

#endif
