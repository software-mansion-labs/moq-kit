import Foundation

extension DVR {
    enum MediaKind: String, Sendable, Hashable {
        case video
        case audio
    }

    struct Segment: Sendable, Equatable {
        let index: Int
        let startTimestampUs: UInt64
        let endTimestampUs: UInt64
        let videoGroup: UInt64
        let audioGroups: ClosedRange<UInt64>

        var durationUs: UInt64 {
            endTimestampUs - startTimestampUs
        }
    }

    struct HLSPlan: Sendable, Equatable {
        let originTimestampUs: UInt64
        let segments: [DVR.Segment]

        var durationUs: UInt64 {
            guard let last = segments.last else { return 0 }
            return last.endTimestampUs - originTimestampUs
        }

        init(selection: DVR.Selection) throws {
            let video = selection.video.timeline
            let audio = selection.audio.timeline
            guard video.count >= 2 else {
                throw SessionError.invalidConfiguration("DVR selection needs a trailing video boundary")
            }
            guard audio.count >= 2 else {
                throw SessionError.invalidConfiguration("DVR selection needs audio boundaries around the video window")
            }
            guard Self.isStrictlyIncreasing(video), Self.isStrictlyIncreasing(audio) else {
                throw SessionError.invalidConfiguration("DVR timeline boundaries must increase by group and timestamp")
            }

            let origin = video[0].timestampUs
            guard audio[0].timestampUs <= origin,
                audio[audio.count - 1].timestampUs >= video[video.count - 1].timestampUs
            else {
                throw SessionError.invalidConfiguration("The audio timeline does not cover the video DVR window")
            }

            var segments: [DVR.Segment] = []
            for index in 0..<video.count - 1 {
                let start = video[index]
                let end = video[index + 1]
                let audioStart = Self.group(at: start.timestampUs, in: audio)
                let audioEnd = Self.group(at: end.timestampUs - 1, in: audio)
                guard audioStart <= audioEnd else {
                    throw SessionError.invalidConfiguration("A DVR segment has no matching audio groups")
                }
                segments.append(
                    DVR.Segment(
                        index: index,
                        startTimestampUs: start.timestampUs,
                        endTimestampUs: end.timestampUs,
                        videoGroup: start.group,
                        audioGroups: audioStart...audioEnd
                    )
                )
            }

            self.originTimestampUs = origin
            self.segments = segments
        }

        private static func isStrictlyIncreasing(_ entries: [DVR.TimelinePoint]) -> Bool {
            zip(entries, entries.dropFirst()).allSatisfy {
                $0.group < $1.group && $0.timestampUs < $1.timestampUs
            }
        }

        /// Estimate a short-group sequence between two real timeline anchors. Timeline publishing may
        /// thin audio records, but group sequences remain contiguous between the advertised anchors.
        private static func group(at timestampUs: UInt64, in entries: [DVR.TimelinePoint]) -> UInt64 {
            if timestampUs <= entries[0].timestampUs { return entries[0].group }

            let indices = Self.bracketingIndices(for: timestampUs, in: entries)
            guard timestampUs < entries[indices.upper].timestampUs else {
                return entries[indices.upper].group
            }

            let lower = entries[indices.lower]
            let upper = entries[indices.upper]
            let elapsed = timestampUs - lower.timestampUs
            let timeSpan = upper.timestampUs - lower.timestampUs
            let groupSpan = upper.group - lower.group
            let product = elapsed.multipliedFullWidth(by: groupSpan)
            let scaled = timeSpan.dividingFullWidth(product).quotient
            return lower.group + min(scaled, groupSpan - 1)
        }

        private static func bracketingIndices(
            for timestampUs: UInt64,
            in entries: [DVR.TimelinePoint]
        ) -> (lower: Int, upper: Int) {
            var lowerIndex = 0
            var upperIndex = entries.count - 1
            while lowerIndex + 1 < upperIndex {
                let midpoint = lowerIndex + (upperIndex - lowerIndex) / 2
                if timestampUs < entries[midpoint].timestampUs {
                    upperIndex = midpoint
                } else {
                    lowerIndex = midpoint
                }
            }
            return (lowerIndex, upperIndex)
        }
    }

    enum HLSManifest {
        static func mediaPlaylist(
            kind: DVR.MediaKind,
            segments: [DVR.Segment],
            initializationURI: String
        ) -> String {
            let maximumDurationUs = segments.lazy.map(\.durationUs).max() ?? 1_000_000
            let targetDuration = max(1, Int((maximumDurationUs + 999_999) / 1_000_000))
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-TARGETDURATION:\(targetDuration)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MAP:URI=\"\(initializationURI)\"",
            ]
            for segment in segments {
                lines.append(
                    String(
                        format: "#EXTINF:%.6f,",
                        locale: Locale(identifier: "en_US_POSIX"),
                        Double(segment.durationUs) / 1_000_000
                    )
                )
                lines.append("\(kind.rawValue)/\(segment.index).m4s")
            }
            lines.append("#EXT-X-ENDLIST")
            return lines.joined(separator: "\n") + "\n"
        }

        static func multivariantPlaylist(
            videoCodec: String,
            audioCodec: String,
            bandwidth: UInt64?
        ) -> String {
            let peakBandwidth = max(1, bandwidth ?? 1_000_000)
            return """
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
                #EXT-X-STREAM-INF:BANDWIDTH=\(peakBandwidth),CODECS="\(videoCodec),\(audioCodec)",AUDIO="audio"
                video.m3u8
                """ + "\n"
        }
    }
}
