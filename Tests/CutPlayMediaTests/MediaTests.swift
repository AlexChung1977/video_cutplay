import XCTest
import CutPlayCore
@testable import CutPlayMedia

final class ParserTests: XCTestCase {
    let id = UUID()

    func testFFprobeParsing() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30000/1001","pix_fmt":"yuv420p"},
          {"index":1,"codec_type":"audio","codec_name":"aac","sample_rate":"48000","channels":2},
          {"index":2,"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}
        ],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"12.5","start_time":"0.000000","bit_rate":"8000000"}}
        """
        let probe = try MediaProber.parse(Data(json.utf8))
        XCTAssertEqual(probe.streams.count, 2, "cover art is ignored")
        XCTAssertEqual(probe.duration, MediaTime(seconds: 12.5))
        XCTAssertEqual(try XCTUnwrap(probe.videoStream?.frameRate), 29.97, accuracy: 0.01)
        XCTAssertEqual(probe.audioStream?.sampleRate, 48000)
        XCTAssertEqual(PlayabilityClassifier.classify(probe, fileExtension: "MOV"), .native)
        XCTAssertEqual(PlayabilityClassifier.classify(probe, fileExtension: "3gp"), .needsProxy)
    }

    func testClassifier() {
        func probe(_ container: String, video: String?, pf: String? = "yuv420p", audio: String? = "aac") -> MediaProbe {
            var streams: [MediaStreamInfo] = []
            if let video { streams.append(MediaStreamInfo(index: 0, kind: .video, codec: video, pixelFormat: pf)) }
            if let audio { streams.append(MediaStreamInfo(index: 1, kind: .audio, codec: audio)) }
            return MediaProbe(container: container, duration: MediaTime(seconds: 1), streams: streams)
        }
        let mov = "mov,mp4,m4a,3gp,3g2,mj2"
        XCTAssertEqual(PlayabilityClassifier.classify(probe(mov, video: "hevc"), fileExtension: "mp4"), .native)
        XCTAssertEqual(PlayabilityClassifier.classify(probe(mov, video: "prores", audio: "pcm_s24le"), fileExtension: "mov"), .native)
        XCTAssertEqual(PlayabilityClassifier.classify(probe("matroska,webm", video: "h264"), fileExtension: "mkv"), .needsProxy)
        XCTAssertEqual(PlayabilityClassifier.classify(probe("avi", video: "mpeg4", audio: "mp3"), fileExtension: "avi"), .needsProxy)
        XCTAssertEqual(PlayabilityClassifier.classify(probe(mov, video: "h264", pf: "yuv420p10le"), fileExtension: "mov"), .needsProxy)
        XCTAssertEqual(PlayabilityClassifier.classify(probe(mov, video: "h264", audio: "opus"), fileExtension: "mp4"), .needsProxy)
        XCTAssertEqual(PlayabilityClassifier.classify(probe("mp3", video: nil, audio: "mp3"), fileExtension: "mp3"), .native)
        XCTAssertEqual(PlayabilityClassifier.classify(probe("ogg", video: nil, audio: "vorbis"), fileExtension: "ogg"), .needsProxy)
        XCTAssertEqual(PlayabilityClassifier.classify(probe("x", video: "unknown"), fileExtension: "x"), .audioOnly)
        XCTAssertEqual(PlayabilityClassifier.classify(probe("x", video: nil, audio: nil), fileExtension: "x"), .unsupported)
    }

    func testSilenceParsingIncludingOpenEnd() {
        let log = """
        [silencedetect @ 0x1] silence_start: 2.02117
        [silencedetect @ 0x1] silence_end: 3.52119 | silence_duration: 1.50002
        [silencedetect @ 0x1] silence_start: 9.5
        """
        let segs = FFmpegTools.parseSilence(log, assetID: id, duration: MediaTime(seconds: 10))
        XCTAssertEqual(segs.map(\.range), [TimeRange(seconds: 2.02117, 3.52119), TimeRange(seconds: 9.5, 10)])
        XCTAssertTrue(segs.allSatisfy { $0.kind == .silence })
    }

    func testSceneParsingWithOffset() {
        let log = """
        [Parsed_showinfo_2 @ 0x1] n:   0 pts:   2021 pts_time:2.021   duration:     33
        [Parsed_showinfo_2 @ 0x1] n:   1 pts:   4021 pts_time:4.021   duration:     33
        unrelated pts_time:9
        """
        let segs = FFmpegTools.parseScenes(log, assetID: id, startOffset: MediaTime(seconds: 0.021))
        XCTAssertEqual(segs.map(\.range.start), [MediaTime(seconds: 2), MediaTime(seconds: 4)])
    }

    func testWhisperParsing() throws {
        let json = """
        {"transcription":[
          {"timestamps":{"from":"00:00:00,000","to":"00:00:02,500"},"offsets":{"from":0,"to":2500},"text":" 大家好，歡迎收看"},
          {"offsets":{"from":2500,"to":4000},"text":" [音樂]"},
          {"offsets":{"from":4000,"to":7200},"text":"今天來看電池續航"}
        ]}
        """
        let segs = try WhisperCppTranscriber.parse(Data(json.utf8), assetID: id)
        XCTAssertEqual(segs.map(\.text), ["大家好，歡迎收看", "今天來看電池續航"])
        XCTAssertEqual(segs.last?.range, TimeRange(seconds: 4, 7.2))
    }

    func testProxyArguments() {
        let args = FFmpegTools.proxyArguments(input: URL(fileURLWithPath: "/in.mkv"), output: URL(fileURLWithPath: "/out.mp4"),
                                              hasVideo: true, settings: ProxySettings(useHardwareEncoder: true))
        XCTAssertTrue(args.contains("h264_videotoolbox"))
        XCTAssertEqual(args.last, "/out.mp4")
        XCTAssertEqual(FFmpegTools.progressMicroseconds("out_time_us=1500000"), 1_500_000)
    }
}

/// End-to-end against real ffmpeg. Skipped when ffmpeg/ffprobe aren't installed.
final class FFmpegIntegrationTests: XCTestCase {
    var dir: URL!
    var ffmpeg: FFmpegTools!
    var prober: MediaProber!

    override func setUpWithError() throws {
        let locator = ToolLocator()
        guard let f = locator.locate("ffmpeg"), let p = locator.locate("ffprobe") else {
            throw XCTSkip("ffmpeg not installed")
        }
        ffmpeg = FFmpegTools(ffmpeg: f)
        prober = MediaProber(ffprobe: p)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutplay-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// 6 s MKV: red/blue/green shots (cuts at 2 s and 4 s), tone with a gap from 2 s to 3.5 s.
    func makeSample() async throws -> URL {
        let url = dir.appendingPathComponent("sample.mkv")
        try await ProcessRunner.check(ffmpeg.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red:s=320x240:d=2:r=30",
            "-f", "lavfi", "-i", "color=blue:s=320x240:d=2:r=30",
            "-f", "lavfi", "-i", "color=green:s=320x240:d=2:r=30",
            "-f", "lavfi", "-i", "aevalsrc='0.5*sin(2*PI*440*t)*(lt(t,2)+gt(t,3.5))':s=48000:d=6",
            "-filter_complex", "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]", "-map", "[v]", "-map", "3:a",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path,
        ])
        return url
    }

    func testImportAnalyzeAndEdit() async throws {
        let url = try await makeSample()
        var asset = try await MediaImporter(prober: prober).makeAsset(for: url)
        XCTAssertEqual(asset.playability, .needsProxy, "MKV always goes through a proxy")
        XCTAssertEqual(asset.duration.seconds, 6, accuracy: 0.1)

        struct FakeTranscriber: Transcriber {
            func transcribe(audio: URL, assetID: UUID, language: String, progress: (@Sendable (Double) -> Void)?) async throws -> [AnalysisSegment] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
                progress?(1)
                return [AnalysisSegment(assetID: assetID, kind: .transcript, range: TimeRange(seconds: 0, 2), text: "紅色畫面的開場"),
                        AnalysisSegment(assetID: assetID, kind: .transcript, range: TimeRange(seconds: 3.5, 6), text: "接下來談電池續航")]
            }
        }
        let states = StateRecorder()
        let pipeline = AnalysisPipeline(ffmpeg: ffmpeg, transcriber: FakeTranscriber(), proxySettings: ProxySettings(useHardwareEncoder: false))
        let dir = self.dir!
        let output = try await pipeline.analyze(asset, cacheURL: { dir.appendingPathComponent($0) }, onState: { states.append($0) })

        let proxy = try XCTUnwrap(output.proxyURL)
        let proxyProbe = try await prober.probe(proxy)
        XCTAssertEqual(proxyProbe.videoStream?.codec, "h264")
        XCTAssertEqual(PlayabilityClassifier.classify(proxyProbe, fileExtension: proxy.pathExtension), .native)

        let silence = try XCTUnwrap(output.segments[.silence])
        XCTAssertEqual(silence.count, 1)
        XCTAssertEqual(silence[0].range.start.seconds, 2.0, accuracy: 0.1)
        XCTAssertEqual(silence[0].range.end.seconds, 3.5, accuracy: 0.1)

        let scenes = try XCTUnwrap(output.segments[.scene]).map(\.range.start.seconds)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0], 2.0, accuracy: 0.1)
        XCTAssertEqual(scenes[1], 4.0, accuracy: 0.1)

        XCTAssertEqual(states.values.last, .done)
        XCTAssertTrue(states.values.contains { if case .preparing = $0 { return true }; return false })

        // Feed the results into an editing session and drive it with natural language.
        asset.proxyURL = proxy
        asset.analysis = .done
        let session = EditorSession(project: Project(name: "整合測試", assets: [asset]))
        for (kind, segs) in output.segments { session.replaceAnalysis(kind, for: asset.id, with: segs) }
        session.appendToTimeline(asset.id)

        await session.send("刪掉所有停頓")
        session.apply(messageID: session.messages.last!.id)
        XCTAssertEqual(session.project.sequence.duration.seconds, 6 - 1.2, accuracy: 0.15)

        await session.send("把講到電池續航的段落放到最前面")
        session.apply(messageID: session.messages.last!.id)
        XCTAssertEqual(session.project.sequence.clips.first?.label, nil)
        XCTAssertEqual(session.project.sequence.clips.first?.origin, .assistant)
        XCTAssertEqual(session.project.sequence.clips.first?.sourceRange.start.seconds ?? 0, 3.5, accuracy: 0.6)
    }
}

final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [AnalysisState] = []
    func append(_ s: AnalysisState) { lock.lock(); _values.append(s); lock.unlock() }
    var values: [AnalysisState] { lock.lock(); defer { lock.unlock() }; return _values }
}
