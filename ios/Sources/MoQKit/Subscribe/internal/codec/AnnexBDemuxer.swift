import Foundation

// MARK: - AnnexBDemuxer

/// Generic Annex B start-code scanning and conversion utilities.
///
/// Annex B format delimits NAL units with 3-byte (`00 00 01`) or 4-byte (`00 00 00 01`)
/// start codes. `AVSampleBufferDisplayLayer` expects length-prefixed (AVCC/HEVC) format
/// where each NAL is preceded by a 4-byte big-endian length.
enum AnnexBDemuxer {

    /// Byte range of a single NAL unit payload within an Annex B buffer (start code excluded).
    struct NALURange {
        /// Byte offset of the NAL unit payload within the source `Data`.
        let offset: Int
        /// Byte length of the NAL unit payload.
        let length: Int
    }

    /// Return the range of every NAL unit in an Annex B buffer (start codes stripped).
    ///
    /// Single pass over the data; ranges reference the original buffer so the caller can
    /// build length-prefixed output with one allocation and zero extra copies.
    static func nalUnitRanges(in data: Data) -> [NALURange] {
        let startCodes = findStartCodes(in: data)
        var ranges: [NALURange] = []
        ranges.reserveCapacity(startCodes.count)

        for (i, current) in startCodes.enumerated() {
            let payloadStart = current.payloadIndex
            let payloadEnd = (i + 1 < startCodes.count) ? startCodes[i + 1].startIndex : data.count

            guard payloadStart < payloadEnd else { continue }

            var nalEnd = payloadEnd
            while nalEnd > payloadStart && data[nalEnd - 1] == 0x00 {
                nalEnd -= 1
            }
            guard nalEnd > payloadStart else { continue }

            ranges.append(NALURange(offset: payloadStart, length: nalEnd - payloadStart))
        }

        return ranges
    }

    /// Iterate over NAL units in Annex B data.
    /// The closure receives a zero-copy `Data` slice (no start code) for each NAL unit.
    static func enumerateNALUnits(in data: Data, body: (Data) -> Void) {
        for range in nalUnitRanges(in: data) {
            body(data[range.offset..<range.offset + range.length])
        }
    }

    /// Convert Annex B data to 4-byte length-prefixed format in a single allocation.
    /// Each start code is replaced with a big-endian `UInt32` length prefix.
    static func toLengthPrefixed(_ data: Data) -> Data {
        let ranges = nalUnitRanges(in: data)
        let outputSize = ranges.reduce(0) { $0 + 4 + $1.length }

        var output = Data(count: outputSize)
        var writeOffset = 0
        for range in ranges {
            let len = UInt32(range.length).bigEndian
            withUnsafeBytes(of: len) { buf in
                output.replaceSubrange(writeOffset..<writeOffset + 4, with: buf)
            }
            writeOffset += 4
            output.replaceSubrange(
                writeOffset..<writeOffset + range.length,
                with: data[range.offset..<range.offset + range.length])
            writeOffset += range.length
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
