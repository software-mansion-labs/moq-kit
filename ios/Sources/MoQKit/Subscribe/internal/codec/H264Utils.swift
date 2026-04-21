import Foundation

// MARK: - H.264 NAL Unit Types

enum H264NALType {
    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    static let idr: UInt8 = 5
}

// MARK: - H264Utils

/// H.264-specific utilities for extracting parameter sets from Annex B payloads.
enum H264Utils {

    /// Extract SPS and PPS NAL units from an Annex B payload.
    /// Returns nil if no complete SPS+PPS pair is found.
    static func extractParameterSets(from data: Data) -> (sps: [Data], pps: [Data])? {
        var spsList: [Data] = []
        var ppsList: [Data] = []

        AnnexBDemuxer.enumerateNALUnits(in: data) { nalData in
            let nalType = nalData[nalData.startIndex] & 0x1F
            if nalType == H264NALType.sps {
                spsList.append(Data(nalData))
            } else if nalType == H264NALType.pps {
                ppsList.append(Data(nalData))
            }
        }

        guard !spsList.isEmpty && !ppsList.isEmpty else { return nil }
        return (sps: spsList, pps: ppsList)
    }
}
