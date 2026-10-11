import Foundation
import CutPlayCore

public protocol Transcriber: Sendable {
    /// `audio` is 16 kHz mono WAV. Returned segments are in asset time.
    func transcribe(audio: URL, assetID: UUID, language: String,
                    progress: (@Sendable (Double) -> Void)?) async throws -> [AnalysisSegment]
}

/// Runs whisper.cpp's `whisper-cli` (Metal-accelerated on Apple Silicon).
/// A WhisperKit / Core ML implementation can replace it behind the same protocol.
public struct WhisperCppTranscriber: Transcriber {
    public var executable: URL
    public var model: URL
    public var threads: Int

    public init(executable: URL, model: URL, threads: Int = max(ProcessInfo.processInfo.activeProcessorCount - 2, 2)) {
        self.executable = executable
        self.model = model
        self.threads = threads
    }

    /// Looks for `whisper-cli` and a ggml model (`CUTPLAY_WHISPER_MODEL`, or
    /// `~/Library/Application Support/CutPlay/models/ggml-*.bin`). Returns nil when either is missing.
    public static func discover(locator: ToolLocator = ToolLocator()) -> WhisperCppTranscriber? {
        guard let exe = locator.locate("whisper-cli") ?? locator.locate("whisper-cpp") else { return nil }
        let env = ProcessInfo.processInfo.environment
        if let path = env["CUTPLAY_WHISPER_MODEL"], FileManager.default.fileExists(atPath: path) {
            return WhisperCppTranscriber(executable: exe, model: URL(fileURLWithPath: path))
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CutPlay/models")
        let models = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let preferred = ["large-v3-turbo", "large-v3", "medium", "small", "base"]
        let ggml = models.filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
        let pick = preferred.lazy.compactMap { name in ggml.first { $0.lastPathComponent.contains(name) } }.first ?? ggml.first
        return pick.map { WhisperCppTranscriber(executable: exe, model: $0) }
    }

    /// Whisper tends to answer Chinese in Simplified characters; a Traditional prompt steers it.
    static func prompt(for language: String) -> String? {
        language.hasPrefix("zh") ? "以下是繁體中文的句子。" : nil
    }

    public func transcribe(audio: URL, assetID: UUID, language: String = "zh",
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> [AnalysisSegment] {
        let outBase = audio.deletingPathExtension().appendingPathExtension("whisper")
        var args = ["-m", model.path, "-f", audio.path, "-l", language, "-t", "\(threads)",
                    "-oj", "-of", outBase.path, "--print-progress"]
        if let p = Self.prompt(for: language) { args += ["--prompt", p] }
        try await ProcessRunner.check(executable, args, onStderrLine: { line in
            if let r = line.range(of: "progress = "), let v = Double(line[r.upperBound...].prefix { $0.isNumber }) {
                progress?(v / 100)
            }
        })
        let json = try Data(contentsOf: outBase.appendingPathExtension("json"))
        return try Self.parse(json, assetID: assetID)
    }

    struct Output: Decodable {
        struct Item: Decodable {
            struct Offsets: Decodable { var from: Int; var to: Int }
            var offsets: Offsets
            var text: String
        }
        var transcription: [Item]
    }

    public static func parse(_ json: Data, assetID: UUID) throws -> [AnalysisSegment] {
        let output = try JSONDecoder().decode(Output.self, from: json)
        return output.transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("[") else { return nil }
            let range = TimeRange(start: MediaTime(seconds: Double(item.offsets.from) / 1000),
                                  end: MediaTime(seconds: Double(item.offsets.to) / 1000))
            return range.isEmpty ? nil : AnalysisSegment(assetID: assetID, kind: .transcript, range: range, text: text)
        }
    }
}
