import Foundation
import CutPlayCore

public struct ProxySettings: Sendable, Hashable {
    public var maxWidth: Int
    public var useHardwareEncoder: Bool

    public init(maxWidth: Int = 1280, useHardwareEncoder: Bool? = nil) {
        self.maxWidth = maxWidth
        #if os(macOS)
        self.useHardwareEncoder = useHardwareEncoder ?? true
        #else
        self.useHardwareEncoder = useHardwareEncoder ?? false
        #endif
    }
}

/// Wraps the ffmpeg CLI. Shelling out (instead of linking libav) keeps the app LGPL-clean
/// and lets the binary be swapped or updated independently.
public struct FFmpegTools: Sendable {
    public var ffmpeg: URL

    public init(ffmpeg: URL) {
        self.ffmpeg = ffmpeg
    }

    public init(locator: ToolLocator = ToolLocator()) throws {
        self.ffmpeg = try locator.require("ffmpeg")
    }

    // MARK: Proxy

    public static func proxyArguments(input: URL, output: URL, hasVideo: Bool, settings: ProxySettings) -> [String] {
        var args = ["-hide_banner", "-nostats", "-y", "-i", input.path, "-progress", "pipe:1"]
        if hasVideo {
            args += ["-map", "0:v:0", "-map", "0:a:0?",
                     "-vf", "scale='min(\(settings.maxWidth),iw)':-2,format=yuv420p"]
            if settings.useHardwareEncoder {
                args += ["-c:v", "h264_videotoolbox", "-b:v", "6M", "-allow_sw", "1"]
            } else {
                args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]
            }
            args += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart"]
        } else {
            args += ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k", "-ar", "48000"]
        }
        args.append(output.path)
        return args
    }

    /// Transcodes to an H.264/AAC proxy AVFoundation can always play. `progress` receives 0…1.
    public func makeProxy(input: URL, output: URL, duration: MediaTime, hasVideo: Bool,
                          settings: ProxySettings = ProxySettings(),
                          progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let total = max(duration.seconds, 0.001)
        try await ProcessRunner.check(ffmpeg, Self.proxyArguments(input: input, output: output, hasVideo: hasVideo, settings: settings),
                                      onStdoutLine: { line in
            if let us = Self.progressMicroseconds(line) { progress?(min(Double(us) / 1_000_000 / total, 1)) }
        })
        progress?(1)
    }

    static func progressMicroseconds(_ line: String) -> Int64? {
        guard line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return nil }
        return Int64(line.split(separator: "=").last ?? "")
    }

    // MARK: Audio for ASR

    /// 16 kHz mono PCM, the input format Whisper expects.
    public func extractSpeechAudio(input: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ProcessRunner.check(ffmpeg, ["-hide_banner", "-nostats", "-y", "-i", input.path,
                                               "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path])
    }

    // MARK: Silence

    public func detectSilence(input: URL, assetID: UUID, duration: MediaTime, startOffset: MediaTime = .zero,
                              noiseDB: Double = -35, minimum: MediaTime = MediaTime(seconds: 0.5)) async throws -> [AnalysisSegment] {
        let result = try await ProcessRunner.check(ffmpeg, [
            "-hide_banner", "-nostats", "-i", input.path, "-vn",
            "-af", "silencedetect=noise=\(noiseDB)dB:d=\(minimum.seconds)", "-f", "null", "-",
        ])
        return Self.parseSilence(result.stderr, assetID: assetID, duration: duration, startOffset: startOffset)
    }

    public static func parseSilence(_ log: String, assetID: UUID, duration: MediaTime, startOffset: MediaTime = .zero) -> [AnalysisSegment] {
        var segments: [AnalysisSegment] = []
        var open: Double?
        for line in log.split(whereSeparator: \.isNewline) {
            if let v = value(after: "silence_start: ", in: line) {
                open = v
            } else if let v = value(after: "silence_end: ", in: line), let start = open {
                segments.append(silence(start, v, assetID: assetID, duration: duration, offset: startOffset))
                open = nil
            }
        }
        if let start = open {
            segments.append(silence(start, duration.seconds + startOffset.seconds, assetID: assetID, duration: duration, offset: startOffset))
        }
        return segments.filter { !$0.range.isEmpty }
    }

    private static func silence(_ start: Double, _ end: Double, assetID: UUID, duration: MediaTime, offset: MediaTime) -> AnalysisSegment {
        let range = TimeRange(start: MediaTime(seconds: max(start, 0)) - offset, end: MediaTime(seconds: end) - offset)
            .clamped(to: TimeRange(start: .zero, end: duration))
        return AnalysisSegment(assetID: assetID, kind: .silence, range: range, confidence: 0.95)
    }

    // MARK: Scenes

    public func detectScenes(input: URL, assetID: UUID, startOffset: MediaTime = .zero, threshold: Double = 0.3) async throws -> [AnalysisSegment] {
        let result = try await ProcessRunner.check(ffmpeg, [
            "-hide_banner", "-nostats", "-i", input.path, "-an",
            "-vf", "scale=320:-2,select='gt(scene,\(threshold))',showinfo", "-f", "null", "-",
        ])
        return Self.parseScenes(result.stderr, assetID: assetID, startOffset: startOffset)
    }

    /// Scene cuts are zero-length segments at the first frame of each new shot.
    public static func parseScenes(_ log: String, assetID: UUID, startOffset: MediaTime = .zero) -> [AnalysisSegment] {
        log.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains("Parsed_showinfo"), let t = value(after: "pts_time:", in: line) else { return nil }
            let time = MediaTime(seconds: t) - startOffset
            return AnalysisSegment(assetID: assetID, kind: .scene, range: TimeRange(start: time, end: time), confidence: 0.9)
        }
    }

    static func value(after marker: String, in line: Substring) -> Double? {
        guard let r = line.range(of: marker) else { return nil }
        let rest = line[r.upperBound...]
        let number = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "e" || $0 == "+" }
        return Double(number)
    }
}
