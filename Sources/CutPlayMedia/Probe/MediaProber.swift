import Foundation
import CutPlayCore

/// Reads container/stream info with ffprobe. Works for any format ffmpeg understands,
/// including ones AVFoundation can't open, which is exactly when we need it.
public struct MediaProber: Sendable {
    public var ffprobe: URL

    public init(ffprobe: URL) {
        self.ffprobe = ffprobe
    }

    public init(locator: ToolLocator = ToolLocator()) throws {
        self.ffprobe = try locator.require("ffprobe")
    }

    public func probe(_ url: URL) async throws -> MediaProbe {
        let result = try await ProcessRunner.check(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        return try Self.parse(Data(result.stdout.utf8))
    }

    struct FFprobeOutput: Decodable {
        struct Stream: Decodable {
            var index: Int
            var codec_type: String?
            var codec_name: String?
            var width: Int?
            var height: Int?
            var avg_frame_rate: String?
            var r_frame_rate: String?
            var sample_rate: String?
            var channels: Int?
            var pix_fmt: String?
            var duration: String?
            var disposition: [String: Int]?
        }
        struct Format: Decodable {
            var format_name: String?
            var duration: String?
            var start_time: String?
            var bit_rate: String?
        }
        var streams: [Stream]?
        var format: Format?
    }

    public static func parse(_ json: Data) throws -> MediaProbe {
        let output = try JSONDecoder().decode(FFprobeOutput.self, from: json)
        let streams: [MediaStreamInfo] = (output.streams ?? []).compactMap { s in
            let kind: MediaStreamInfo.Kind
            switch s.codec_type {
            case "video":
                // Cover art in audio files shows up as a one-frame video stream.
                if s.disposition?["attached_pic"] == 1 { return nil }
                kind = .video
            case "audio": kind = .audio
            case "subtitle": kind = .subtitle
            default: kind = .other
            }
            return MediaStreamInfo(index: s.index, kind: kind, codec: s.codec_name ?? "unknown",
                                   width: s.width, height: s.height,
                                   frameRate: rate(s.avg_frame_rate) ?? rate(s.r_frame_rate),
                                   sampleRate: s.sample_rate.flatMap(Int.init), channels: s.channels, pixelFormat: s.pix_fmt)
        }
        let duration = output.format?.duration.flatMap(Double.init)
            ?? (output.streams ?? []).compactMap { $0.duration.flatMap(Double.init) }.max() ?? 0
        return MediaProbe(container: output.format?.format_name ?? "unknown",
                          duration: MediaTime(seconds: duration),
                          startTime: MediaTime(seconds: output.format?.start_time.flatMap(Double.init) ?? 0),
                          streams: streams,
                          bitRate: output.format?.bit_rate.flatMap(Int.init))
    }

    static func rate(_ fraction: String?) -> Double? {
        guard let fraction else { return nil }
        let parts = fraction.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0, parts[0] != 0 else { return nil }
        return parts[0] / parts[1]
    }
}

/// Decides whether AVFoundation can use a file directly or it needs a proxy first.
/// Deliberately conservative: anything uncertain goes through a proxy, which always works.
public enum PlayabilityClassifier {
    static let nativeVideoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let nativeAudioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"]
    static let nativeVideoCodecs: Set<String> = ["h264", "hevc", "prores"]
    static let nativeAudioCodecs: Set<String> = ["aac", "alac", "mp3", "ac3", "eac3"]
    /// Hardware decoders on Apple Silicon handle 8-bit H.264; 10-bit H.264 is software-only and stutters.
    static let unsupportedH264PixelFormats: Set<String> = ["yuv420p10le", "yuv422p10le", "yuv444p10le", "yuv422p", "yuv444p"]

    public static func classify(_ probe: MediaProbe, fileExtension: String) -> Playability {
        let ext = fileExtension.lowercased()
        let video = probe.videoStream
        let audio = probe.audioStream
        guard video != nil || audio != nil else { return .unsupported }

        func audioOK(_ a: MediaStreamInfo?) -> Bool {
            guard let a else { return true }
            return nativeAudioCodecs.contains(a.codec) || a.codec.hasPrefix("pcm_")
        }

        if let video {
            if video.codec == "unknown" || video.codec == "none" { return audio != nil ? .audioOnly : .unsupported }
            let containerOK = nativeVideoExtensions.contains(ext) && probe.container.contains("mov")
            var codecOK = nativeVideoCodecs.contains(video.codec)
            if video.codec == "h264", let pf = video.pixelFormat, unsupportedH264PixelFormats.contains(pf) { codecOK = false }
            return containerOK && codecOK && audioOK(audio) ? .native : .needsProxy
        }
        return nativeAudioExtensions.contains(ext) && audioOK(audio) ? .native : .needsProxy
    }
}

/// Probe + classify, producing a library asset.
public struct MediaImporter: Sendable {
    public var prober: MediaProber

    public init(prober: MediaProber) {
        self.prober = prober
    }

    public func makeAsset(for url: URL) async throws -> MediaAsset {
        let probe = try await prober.probe(url)
        let playability = PlayabilityClassifier.classify(probe, fileExtension: url.pathExtension)
        return MediaAsset(sourceURL: url, duration: probe.duration,
                          hasVideo: probe.videoStream != nil && playability != .audioOnly,
                          hasAudio: probe.audioStream != nil, probe: probe, playability: playability,
                          analysis: playability == .unsupported ? .failed(message: "無法讀取這個檔案") : .queued)
    }
}
