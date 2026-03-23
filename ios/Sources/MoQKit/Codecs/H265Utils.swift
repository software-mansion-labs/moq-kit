#if os(iOS)
    import Foundation

    // MARK: - H.265 NAL Unit Types

    enum H265NALType {
        /// Video Parameter Set
        static let vps: UInt8 = 32
        /// Sequence Parameter Set
        static let sps: UInt8 = 33
        /// Picture Parameter Set
        static let pps: UInt8 = 34
    }

    // MARK: - H265Utils

    /// H.265-specific utilities for extracting parameter sets from Annex B payloads.
    ///
    /// H.265 NAL unit type is encoded in bits 9–1 of the 2-byte NAL unit header:
    /// `(firstByte >> 1) & 0x3F`
    enum H265Utils {

        /// Extract VPS, SPS, and PPS NAL units from an Annex B payload.
        /// Returns nil if any of the three types are missing.
        static func extractParameterSets(from data: Data) -> (vps: [Data], sps: [Data], pps: [Data])? {
            var vpsList: [Data] = []
            var spsList: [Data] = []
            var ppsList: [Data] = []

            AnnexBDemuxer.enumerateNALUnits(in: data) { nalData in
                guard nalData.count >= 2 else { return }
                let nalType = (nalData[nalData.startIndex] >> 1) & 0x3F
                switch nalType {
                case H265NALType.vps: vpsList.append(Data(nalData))
                case H265NALType.sps: spsList.append(Data(nalData))
                case H265NALType.pps: ppsList.append(Data(nalData))
                default: break
                }
            }

            guard !vpsList.isEmpty && !spsList.isEmpty && !ppsList.isEmpty else { return nil }
            return (vps: vpsList, sps: spsList, pps: ppsList)
        }
    }

#endif
