import Foundation

public struct MediaStreamInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, audio, subtitle, other }

    public var index: Int
    public var kind: Kind
    public var codec: String
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var sampleRate: Int?
    public var channels: Int?
    public var pixelFormat: String?

    public init(index: Int, kind: Kind, codec: String, width: Int? = nil, height: Int? = nil,
                frameRate: Double? = nil, sampleRate: Int? = nil, channels: Int? = nil, pixelFormat: String? = nil) {
        self.index = index
        self.kind = kind
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.sampleRate = sampleRate
        self.channels = channels
        self.pixelFormat = pixelFormat
    }
}

public struct MediaProbe: Codable, Hashable, Sendable {
    /// ffprobe `format_name`, e.g. `mov,mp4,m4a,3gp,3g2,mj2` or `matroska,webm`.
    public var container: String
    public var duration: MediaTime
    /// Container start time. ffmpeg filter timestamps include it; asset time is relative to it.
    public var startTime: MediaTime
    public var streams: [MediaStreamInfo]
    public var bitRate: Int?

    public init(container: String, duration: MediaTime, startTime: MediaTime = .zero, streams: [MediaStreamInfo], bitRate: Int? = nil) {
        self.container = container
        self.duration = duration
        self.startTime = startTime
        self.streams = streams
        self.bitRate = bitRate
    }

    public var videoStream: MediaStreamInfo? { streams.first { $0.kind == .video } }
    public var audioStream: MediaStreamInfo? { streams.first { $0.kind == .audio } }
}

public enum Playability: String, Codable, Sendable {
    /// AVFoundation can play the source directly.
    case native
    /// Needs a proxy transcode before it can go on the timeline.
    case needsProxy
    /// Video can't be decoded; only the audio is usable.
    case audioOnly
    case unsupported
}

public enum AnalysisState: Codable, Hashable, Sendable {
    case queued
    case preparing(progress: Double)
    case analyzing(progress: Double)
    case done
    case failed(message: String)

    public var isFinished: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }

    /// Short status for the media library badge.
    public var label: String {
        switch self {
        case .queued: return "排隊中"
        case .preparing(let p): return "準備中 \(Int(p * 100))%"
        case .analyzing(let p): return "分析中 \(Int(p * 100))%"
        case .done: return "✓ 已分析"
        case .failed: return "失敗"
        }
    }
}

public struct MediaAsset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceURL: URL
    public var proxyURL: URL?
    public var name: String
    public var duration: MediaTime
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var probe: MediaProbe?
    public var playability: Playability
    public var analysis: AnalysisState

    public init(id: UUID = UUID(), sourceURL: URL, proxyURL: URL? = nil, name: String? = nil,
                duration: MediaTime, hasVideo: Bool = true, hasAudio: Bool = true,
                probe: MediaProbe? = nil, playability: Playability = .native, analysis: AnalysisState = .queued) {
        self.id = id
        self.sourceURL = sourceURL
        self.proxyURL = proxyURL
        self.name = name ?? sourceURL.lastPathComponent
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.probe = probe
        self.playability = playability
        self.analysis = analysis
    }

    /// The file the player and composition should read.
    public var playbackURL: URL { proxyURL ?? sourceURL }

    public var fullRange: TimeRange { TimeRange(start: .zero, end: duration) }
}

/// A source range inside one asset.
public struct AssetRange: Codable, Hashable, Sendable {
    public var assetID: UUID
    public var range: TimeRange

    public init(assetID: UUID, range: TimeRange) {
        self.assetID = assetID
        self.range = range
    }
}
