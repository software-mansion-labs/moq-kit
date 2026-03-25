import Foundation

// MARK: - CMAFSample

/// A single sample extracted from a CMAF fragment, with microsecond timestamps.
struct CMAFSample {
    /// Decode timestamp in microseconds (DTS).
    let decodeTimeUs: UInt64
    /// Presentation timestamp in microseconds (DTS + composition time offset).
    let presentationTimeUs: UInt64
    /// Whether this sample is a sync (key) frame.
    let isKeyframe: Bool
    /// Raw encoded sample bytes.
    let payload: Data
}

// MARK: - CMAFFragment

/// Parsed CMAF media fragment (moof + mdat).
struct CMAFFragment {
    /// Sequence number from the mfhd box.
    let sequenceNumber: UInt32
    /// Ordered samples with microsecond timestamps.
    let samples: [CMAFSample]
}

// MARK: - CMAFUtils

/// Utilities for parsing CMAF (ISO 14496-12 fragmented MP4) boxes.
///
/// Supports parsing moof + mdat fragments to extract per-sample decode/presentation
/// timestamps and payloads. The timescale from `Container.cmaf(timescale:trackId:)`
/// is used to convert timestamps to microseconds.
enum CMAFUtils {

    // MARK: - Errors

    enum ParseError: Error {
        case truncated
        case invalidBoxSize
        case missingBox(String)
        case unsupportedVersion(UInt8)
    }

    // MARK: - Public API

    /// Returns `true` if `data` begins with a CMAF initialization segment (moov box).
    static func isInitSegment(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return boxTypeString(in: data, at: data.startIndex + 4) == "moov"
    }

    /// Parse a CMAF media fragment (moof + mdat) and return its samples.
    ///
    /// - Parameters:
    ///   - data: Raw fragment bytes starting at a moof box.
    ///   - timescale: Track timescale from `Container.cmaf(timescale:trackId:)`.
    /// - Returns: A `CMAFFragment` with per-sample microsecond timestamps.
    static func parseFragment(_ data: Data, timescale: UInt64) throws -> CMAFFragment {
        var moofStart: Int = 0
        var moofBody: Range<Int>? = nil
        var mdatBody: Range<Int>? = nil

        try enumerateBoxes(in: data, from: data.startIndex) { type, boxStart, bodyRange in
            switch type {
            case "moof":
                moofStart = boxStart
                moofBody = bodyRange
            case "mdat":
                mdatBody = bodyRange
            default:
                break
            }
        }

        guard let moofBodyRange = moofBody else { throw ParseError.missingBox("moof") }
        guard let mdatBodyRange = mdatBody else { throw ParseError.missingBox("mdat") }

        let moofInfo = try parseMoof(in: data, body: moofBodyRange)
        let samples = try buildSamples(
            moofInfo: moofInfo,
            moofStart: moofStart,
            mdatBody: mdatBodyRange,
            data: data,
            timescale: timescale
        )

        return CMAFFragment(sequenceNumber: moofInfo.sequenceNumber, samples: samples)
    }

    // MARK: - Box Scanning

    private static func enumerateBoxes(
        in data: Data,
        from start: Int,
        to end: Int? = nil,
        handler: (_ type: String, _ boxStart: Int, _ bodyRange: Range<Int>) throws -> Void
    ) throws {
        let limit = end ?? data.endIndex
        var offset = start

        while offset < limit {
            guard offset + 8 <= limit else { throw ParseError.truncated }
            guard let rawSize = data.readUInt32BE(at: offset) else { throw ParseError.truncated }
            let typeStr = boxTypeString(in: data, at: offset + 4)

            let headerSize: Int
            let boxSize: Int
            if rawSize == 1 {
                // 64-bit extended size field follows the type
                guard let largeSize = data.readUInt64BE(at: offset + 8) else {
                    throw ParseError.truncated
                }
                headerSize = 16
                boxSize = Int(largeSize)
            } else if rawSize == 0 {
                // Box extends to the end of the enclosing container
                headerSize = 8
                boxSize = limit - offset
            } else {
                headerSize = 8
                boxSize = Int(rawSize)
            }

            guard boxSize >= headerSize, offset + boxSize <= limit else {
                throw ParseError.invalidBoxSize
            }

            let bodyRange = (offset + headerSize)..<(offset + boxSize)
            try handler(typeStr, offset, bodyRange)
            offset += boxSize
        }
    }

    private static func boxTypeString(in data: Data, at offset: Int) -> String {
        guard offset + 4 <= data.endIndex else { return "" }
        let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    // MARK: - moof Parsing

    private struct MoofInfo {
        var sequenceNumber: UInt32 = 0
        var trackId: UInt32 = 0
        var baseDataOffset: UInt64? = nil
        var defaultSampleDuration: UInt32 = 0
        var defaultSampleSize: UInt32 = 0
        var defaultSampleFlags: UInt32 = 0
        var baseDecodeTime: UInt64 = 0
        var runs: [TrunInfo] = []
    }

    private struct TrunInfo {
        var dataOffset: Int32 = 0
        var firstSampleFlags: UInt32? = nil
        var samples: [TrunSample] = []
    }

    private struct TrunSample {
        var duration: UInt32? = nil
        var size: UInt32? = nil
        var flags: UInt32? = nil
        var compositionTimeOffset: Int64 = 0
    }

    private static func parseMoof(in data: Data, body: Range<Int>) throws -> MoofInfo {
        var info = MoofInfo()

        try enumerateBoxes(in: data, from: body.lowerBound, to: body.upperBound) {
            type, _, bodyRange in
            switch type {
            case "mfhd":
                // version(1) + flags(3) + sequence_number(4)
                guard bodyRange.count >= 8 else { throw ParseError.truncated }
                info.sequenceNumber = data.readUInt32BE(at: bodyRange.lowerBound + 4)!
            case "traf":
                try parseTraf(in: data, body: bodyRange, into: &info)
            default:
                break
            }
        }

        return info
    }

    private static func parseTraf(in data: Data, body: Range<Int>, into info: inout MoofInfo) throws
    {
        var trun = TrunInfo()
        var hasTrun = false

        try enumerateBoxes(in: data, from: body.lowerBound, to: body.upperBound) {
            type, _, bodyRange in
            switch type {
            case "tfhd":
                try parseTfhd(in: data, body: bodyRange, into: &info)
            case "tfdt":
                try parseTfdt(in: data, body: bodyRange, into: &info)
            case "trun":
                trun = try parseTrun(in: data, body: bodyRange, defaults: info)
                hasTrun = true
            default:
                break
            }
        }

        if hasTrun {
            info.runs.append(trun)
        }
    }

    private static func parseTfhd(in data: Data, body: Range<Int>, into info: inout MoofInfo) throws
    {
        // version(1) + flags(3) + track_ID(4) = 8 bytes minimum
        guard body.count >= 8 else { throw ParseError.truncated }
        let flags =
            UInt32(data[body.lowerBound + 1]) << 16
            | UInt32(data[body.lowerBound + 2]) << 8
            | UInt32(data[body.lowerBound + 3])
        var offset = body.lowerBound + 4  // skip version + flags

        info.trackId = data.readUInt32BE(at: offset)!
        offset += 4

        if flags & 0x000001 != 0 {  // base-data-offset-present
            guard offset + 8 <= body.upperBound else { throw ParseError.truncated }
            info.baseDataOffset = data.readUInt64BE(at: offset)
            offset += 8
        }
        if flags & 0x000002 != 0 {  // sample-description-index-present
            offset += 4
        }
        if flags & 0x000008 != 0 {  // default-sample-duration-present
            guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
            info.defaultSampleDuration = data.readUInt32BE(at: offset)!
            offset += 4
        }
        if flags & 0x000010 != 0 {  // default-sample-size-present
            guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
            info.defaultSampleSize = data.readUInt32BE(at: offset)!
            offset += 4
        }
        if flags & 0x000020 != 0 {  // default-sample-flags-present
            guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
            info.defaultSampleFlags = data.readUInt32BE(at: offset)!
        }
    }

    private static func parseTfdt(in data: Data, body: Range<Int>, into info: inout MoofInfo) throws
    {
        // version(1) + flags(3) + base_media_decode_time(4 or 8)
        guard body.count >= 8 else { throw ParseError.truncated }
        let version = data[body.lowerBound]
        let dataStart = body.lowerBound + 4  // skip version + flags

        switch version {
        case 0:
            info.baseDecodeTime = UInt64(data.readUInt32BE(at: dataStart)!)
        case 1:
            guard body.count >= 12 else { throw ParseError.truncated }
            info.baseDecodeTime = data.readUInt64BE(at: dataStart)!
        default:
            throw ParseError.unsupportedVersion(version)
        }
    }

    private static func parseTrun(in data: Data, body: Range<Int>, defaults: MoofInfo) throws
        -> TrunInfo
    {
        // version(1) + flags(3) + sample_count(4) = 8 bytes minimum
        guard body.count >= 8 else { throw ParseError.truncated }
        let version = data[body.lowerBound]
        let flags =
            UInt32(data[body.lowerBound + 1]) << 16
            | UInt32(data[body.lowerBound + 2]) << 8
            | UInt32(data[body.lowerBound + 3])
        let sampleCount = data.readUInt32BE(at: body.lowerBound + 4)!
        var offset = body.lowerBound + 8

        var trun = TrunInfo()

        if flags & 0x0001 != 0 {  // data-offset-present
            guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
            trun.dataOffset = data.readInt32BE(at: offset)!
            offset += 4
        }
        if flags & 0x0004 != 0 {  // first-sample-flags-present
            guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
            trun.firstSampleFlags = data.readUInt32BE(at: offset)
            offset += 4
        }

        let hasDuration = flags & 0x0100 != 0
        let hasSize = flags & 0x0200 != 0
        let hasSampleFlags = flags & 0x0400 != 0
        let hasCTO = flags & 0x0800 != 0

        trun.samples.reserveCapacity(Int(sampleCount))
        for _ in 0..<sampleCount {
            var sample = TrunSample()

            if hasDuration {
                guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
                sample.duration = data.readUInt32BE(at: offset)
                offset += 4
            }
            if hasSize {
                guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
                sample.size = data.readUInt32BE(at: offset)
                offset += 4
            }
            if hasSampleFlags {
                guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
                sample.flags = data.readUInt32BE(at: offset)
                offset += 4
            }
            if hasCTO {
                guard offset + 4 <= body.upperBound else { throw ParseError.truncated }
                // version 1: signed offset (for B-frames); version 0: unsigned
                sample.compositionTimeOffset =
                    version == 1
                    ? Int64(data.readInt32BE(at: offset)!)
                    : Int64(data.readUInt32BE(at: offset)!)
                offset += 4
            }

            trun.samples.append(sample)
        }

        return trun
    }

    // MARK: - Sample Assembly

    private static func buildSamples(
        moofInfo: MoofInfo,
        moofStart: Int,
        mdatBody: Range<Int>,
        data: Data,
        timescale: UInt64
    ) throws -> [CMAFSample] {
        guard timescale > 0 else { return [] }

        var result: [CMAFSample] = []
        var decodeTime = moofInfo.baseDecodeTime

        for run in moofInfo.runs {
            // trun data_offset is relative to the start of the enclosing moof box
            // (default-base-is-moof semantics per CMAF/iso5). An explicit
            // base_data_offset in tfhd overrides this with an absolute file offset.
            let runAbsoluteStart: Int
            if let base = moofInfo.baseDataOffset {
                runAbsoluteStart = Int(base) + Int(run.dataOffset)
            } else {
                runAbsoluteStart = moofStart + Int(run.dataOffset)
            }

            var sampleAbsoluteStart = runAbsoluteStart

            for (sampleIndex, trunSample) in run.samples.enumerated() {
                let sampleSize = Int(trunSample.size ?? moofInfo.defaultSampleSize)

                // Determine keyframe from sample_flags (bit 16 = sample_is_non_sync_sample).
                // Keyframe overrides for the first sample come via first_sample_flags.
                let sampleFlags: UInt32
                if sampleIndex == 0, let firstFlags = run.firstSampleFlags {
                    sampleFlags = firstFlags
                } else {
                    sampleFlags = trunSample.flags ?? moofInfo.defaultSampleFlags
                }
                let isKeyframe = (sampleFlags & 0x0001_0000) == 0

                let sampleEnd = sampleAbsoluteStart + sampleSize
                guard sampleSize > 0,
                    sampleAbsoluteStart >= mdatBody.lowerBound,
                    sampleEnd <= mdatBody.upperBound
                else {
                    let duration = trunSample.duration ?? moofInfo.defaultSampleDuration
                    decodeTime += UInt64(duration)
                    sampleAbsoluteStart += sampleSize
                    continue
                }

                // TODO: we probably don't want to copy the data, this could cause tons
                // of additional alloactions
                let payload = Data(data[sampleAbsoluteStart..<sampleEnd])

                let decodeTimeUs = decodeTime * 1_000_000 / timescale
                let ptsTicks = Int64(decodeTime) + trunSample.compositionTimeOffset
                let presentationTimeUs =
                    ptsTicks >= 0
                    ? UInt64(ptsTicks) * 1_000_000 / timescale
                    : 0

                result.append(
                    CMAFSample(
                        decodeTimeUs: decodeTimeUs,
                        presentationTimeUs: presentationTimeUs,
                        isKeyframe: isKeyframe,
                        payload: payload
                    ))

                let duration = trunSample.duration ?? moofInfo.defaultSampleDuration
                decodeTime += UInt64(duration)
                sampleAbsoluteStart += sampleSize
            }
        }

        return result
    }
}

// MARK: - Data Reading Helpers

extension Data {

    /// Read a big-endian UInt32 at an absolute byte offset.
    fileprivate func readUInt32BE(at offset: Index) -> UInt32? {
        guard offset + 4 <= endIndex else { return nil }
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    /// Read a big-endian UInt64 at an absolute byte offset.
    fileprivate func readUInt64BE(at offset: Index) -> UInt64? {
        guard offset + 8 <= endIndex else { return nil }
        let hi =
            UInt64(self[offset]) << 56
            | UInt64(self[offset + 1]) << 48
            | UInt64(self[offset + 2]) << 40
            | UInt64(self[offset + 3]) << 32
        let lo =
            UInt64(self[offset + 4]) << 24
            | UInt64(self[offset + 5]) << 16
            | UInt64(self[offset + 6]) << 8
            | UInt64(self[offset + 7])
        return hi | lo
    }

    /// Read a big-endian Int32 at an absolute byte offset.
    fileprivate func readInt32BE(at offset: Index) -> Int32? {
        guard let v = readUInt32BE(at: offset) else { return nil }
        return Int32(bitPattern: v)
    }
}
