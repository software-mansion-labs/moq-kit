import Foundation

// MARK: - AnnexBDemuxer

/// Generic Annex B start-code scanning and conversion utilities.
///
/// Annex B format delimits NAL units with 3-byte (`00 00 01`) or 4-byte (`00 00 00 01`)
/// start codes. `AVSampleBufferDisplayLayer` expects length-prefixed (AVCC/HEVC) format
/// where each NAL is preceded by a 4-byte big-endian length.
enum AnnexBDemuxer {

    /// Iterate over NAL units in Annex B data.
    /// The closure receives a zero-copy `Data` slice (no start code) for each NAL unit.
    static func enumerateNALUnits(in data: Data, body: (Data) -> Void) {
        let startCodes = findStartCodes(in: data)

        for (i, current) in startCodes.enumerated() {
            let payloadStart = current.payloadIndex
            let payloadEnd = (i + 1 < startCodes.count) ? startCodes[i + 1].startIndex : data.count

            guard payloadStart < payloadEnd else { continue }

            // Strip trailing zero-padding between NALUs
            var nalEnd = payloadEnd
            while nalEnd > payloadStart && data[nalEnd - 1] == 0x00 {
                nalEnd -= 1
            }
            guard nalEnd > payloadStart else { continue }

            body(data[payloadStart..<nalEnd])
        }
    }

    /// Convert Annex B data to 4-byte length-prefixed format in a single allocation.
    /// Each start code is replaced with a big-endian `UInt32` length prefix.
    static func toLengthPrefixed(_ data: Data) -> Data {
        // First pass: collect (payloadOffset, naluLength) tuples
        var nalus: [(offset: Int, length: Int)] = []
        var outputSize = 0

        let startCodes = findStartCodes(in: data)
        for (i, current) in startCodes.enumerated() {
            let payloadStart = current.payloadIndex
            let payloadEnd = (i + 1 < startCodes.count) ? startCodes[i + 1].startIndex : data.count

            guard payloadStart < payloadEnd else { continue }

            var nalEnd = payloadEnd
            while nalEnd > payloadStart && data[nalEnd - 1] == 0x00 {
                nalEnd -= 1
            }
            guard nalEnd > payloadStart else { continue }

            let length = nalEnd - payloadStart
            nalus.append((offset: payloadStart, length: length))
            outputSize += 4 + length
        }

        // Second pass: write length-prefixed NALUs into a single allocation
        var output = Data(count: outputSize)
        var writeOffset = 0
        for nalu in nalus {
            let len = UInt32(nalu.length).bigEndian
            withUnsafeBytes(of: len) { buf in
                output.replaceSubrange(writeOffset..<writeOffset + 4, with: buf)
            }
            writeOffset += 4
            output.replaceSubrange(writeOffset..<writeOffset + nalu.length, with: data[nalu.offset..<nalu.offset + nalu.length])
            writeOffset += nalu.length
        }

        return output
    }

    // MARK: - Private

    private struct StartCode {
        let startIndex: Int
        let payloadIndex: Int
    }

    private static func findStartCodes(in data: Data) -> [StartCode] {
        var codes: [StartCode] = []
        var i = 0
        let count = data.count

        while i + 2 < count {
            if data[i] == 0x00 && data[i + 1] == 0x00 {
                if i + 3 < count && data[i + 2] == 0x00 && data[i + 3] == 0x01 {
                    codes.append(StartCode(startIndex: i, payloadIndex: i + 4))
                    i += 4
                    continue
                } else if data[i + 2] == 0x01 {
                    codes.append(StartCode(startIndex: i, payloadIndex: i + 3))
                    i += 3
                    continue
                }
            }
            i += 1
        }

        return codes
    }
}
