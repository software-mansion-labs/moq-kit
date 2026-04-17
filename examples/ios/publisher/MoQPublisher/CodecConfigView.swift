import MoQKit
import SwiftUI

// MARK: - Picker Option Types

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd = "HD"
    case fhd = "FHD"

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .hd: return 720
        case .fhd: return 1920
        }
    }

    var height: Int32 {
        switch self {
        case .hd: return 1280
        case .fhd: return 1080
        }
    }

    var label: String {
        switch self {
        case .hd: return "HD (720p)"
        case .fhd: return "FHD (1080p)"
        }
    }
}

enum VideoFrameRate: Double, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Double { rawValue }
    var value: Double { rawValue }

    var label: String {
        "\(Int(rawValue)) fps"
    }
}

enum AudioSampleRate: Double, CaseIterable, Identifiable {
    case khz44 = 44100
    case khz48 = 48000

    var id: Double { rawValue }
    var value: Double { rawValue }

    var label: String {
        switch self {
        case .khz44: return "44.1 kHz"
        case .khz48: return "48 kHz"
        }
    }
}

// MARK: - View

struct CodecConfigView: View {
    @Binding var videoCodec: MoQVideoCodec
    @Binding var videoResolution: VideoResolution
    @Binding var videoFrameRate: VideoFrameRate
    @Binding var audioCodec: MoQAudioCodec
    @Binding var audioSampleRate: AudioSampleRate

    var body: some View {
        VStack(spacing: 16) {
            // Video codec settings
            VStack(alignment: .leading, spacing: 4) {
                Text("Video Codec")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                Picker("Codec", selection: $videoCodec) {
                    Text("H.264").tag(MoQVideoCodec.h264)
                    Text("H.265").tag(MoQVideoCodec.h265)
                }
                .pickerStyle(.segmented)

                Picker("Resolution", selection: $videoResolution) {
                    ForEach(VideoResolution.allCases) { res in
                        Text(res.label).tag(res)
                    }
                }

                Picker("Frame Rate", selection: $videoFrameRate) {
                    ForEach(VideoFrameRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
            }

            // Audio codec settings
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Codec")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                Picker("Codec", selection: $audioCodec) {
                    Text("Opus").tag(MoQAudioCodec.opus)
                    Text("AAC").tag(MoQAudioCodec.aac)
                }
                .pickerStyle(.segmented)

                Picker("Sample Rate", selection: $audioSampleRate) {
                    if audioCodec == .aac {
                        ForEach(AudioSampleRate.allCases) { rate in
                            Text(rate.label).tag(rate)
                        }
                    } else {
                        Text("48 kHz").tag(AudioSampleRate.khz48)
                    }
                }
                .disabled(audioCodec == .opus)
                .onChange(of: audioCodec) {
                    if audioCodec == .opus {
                        audioSampleRate = .khz48
                    }
                }
            }
        }
        .padding(12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}
