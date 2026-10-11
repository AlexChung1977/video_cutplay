import Foundation
import CutPlayCore

public struct AnalysisOutput: Sendable {
    public var proxyURL: URL?
    public var segments: [SegmentKind: [AnalysisSegment]] = [:]
    /// Steps skipped (e.g. no Whisper model installed), for the progress popover.
    public var skipped: [String] = []
}

/// Runs the per-asset analysis in priority order: proxy → audio → silence → transcript → scenes.
/// Transcript comes before scenes because it gives natural-language editing the most value.
public struct AnalysisPipeline: Sendable {
    public var ffmpeg: FFmpegTools
    public var transcriber: Transcriber?
    public var language: String
    public var proxySettings: ProxySettings

    public init(ffmpeg: FFmpegTools, transcriber: Transcriber?, language: String = "zh", proxySettings: ProxySettings = ProxySettings()) {
        self.ffmpeg = ffmpeg
        self.transcriber = transcriber
        self.language = language
        self.proxySettings = proxySettings
    }

    /// `cacheURL(suffix)` returns where to write derived files for this asset.
    public func analyze(_ asset: MediaAsset, cacheURL: @Sendable (String) -> URL,
                        onState: @escaping @Sendable (AnalysisState) -> Void) async throws -> AnalysisOutput {
        var output = AnalysisOutput()
        let offset = asset.probe?.startTime ?? .zero
        var input = asset.sourceURL
        var inputOffset = offset

        if asset.playability == .needsProxy || asset.playability == .audioOnly {
            let proxy = cacheURL(asset.hasVideo ? "proxy.mp4" : "proxy.m4a")
            onState(.preparing(progress: 0))
            try await ffmpeg.makeProxy(input: asset.sourceURL, output: proxy, duration: asset.duration,
                                       hasVideo: asset.hasVideo, settings: proxySettings) { p in onState(.preparing(progress: p)) }
            output.proxyURL = proxy
            input = proxy
            inputOffset = .zero
        }

        // Weights for the overall percentage shown in the library.
        let hasTranscriber = transcriber != nil && asset.hasAudio
        let weights: [String: Double] = ["audio": 0.1, "silence": 0.1, "transcript": hasTranscriber ? 0.6 : 0, "scenes": asset.hasVideo ? 0.2 : 0]
        let total = max(weights.values.reduce(0, +), 0.001)
        @Sendable func progress(after completed: Double, in step: String, fraction: Double) -> AnalysisState {
            .analyzing(progress: min((completed + (weights[step] ?? 0) * fraction) / total, 0.99))
        }
        var done = 0.0
        func finish(_ step: String) {
            done += weights[step] ?? 0
            onState(progress(after: done, in: step, fraction: 0))
        }

        if asset.hasAudio {
            onState(progress(after: done, in: "audio", fraction: 0))
            let wav = cacheURL("speech.wav")
            try await ffmpeg.extractSpeechAudio(input: input, output: wav)
            finish("audio")

            output.segments[.silence] = try await ffmpeg.detectSilence(input: wav, assetID: asset.id, duration: asset.duration)
            finish("silence")

            if let transcriber {
                let completed = done
                output.segments[.transcript] = try await transcriber.transcribe(audio: wav, assetID: asset.id, language: language) { p in
                    onState(progress(after: completed, in: "transcript", fraction: p))
                }
                finish("transcript")
            } else {
                output.skipped.append("逐字稿（沒有安裝語音辨識模型）")
            }
        }

        if asset.hasVideo {
            output.segments[.scene] = try await ffmpeg.detectScenes(input: input, assetID: asset.id, startOffset: inputOffset)
            finish("scenes")
        }
        onState(.done)
        return output
    }
}
