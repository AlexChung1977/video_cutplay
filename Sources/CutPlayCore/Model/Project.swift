import Foundation

public enum ClipOrigin: String, Codable, Sendable {
    case user
    case assistant
}

/// A clip on the main storyline. Video and audio of the asset stay linked.
public struct TimelineClip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var sourceRange: TimeRange
    public var label: String?
    public var origin: ClipOrigin

    public init(id: UUID = UUID(), assetID: UUID, sourceRange: TimeRange, label: String? = nil, origin: ClipOrigin = .user) {
        self.id = id
        self.assetID = assetID
        self.sourceRange = sourceRange
        self.label = label
        self.origin = origin
    }

    public var duration: MediaTime { sourceRange.duration }
}

/// Where a clip sits on the timeline and which part of its source that covers.
public struct ClipPlacement: Hashable, Sendable {
    public var index: Int
    public var clip: TimelineClip
    public var timelineRange: TimeRange

    /// Converts a timeline time inside this placement to source time.
    public func sourceTime(at timelineTime: MediaTime) -> MediaTime {
        clip.sourceRange.start + (timelineTime - timelineRange.start)
    }

    /// Converts a source time inside this clip to timeline time.
    public func timelineTime(forSource sourceTime: MediaTime) -> MediaTime {
        timelineRange.start + (sourceTime - clip.sourceRange.start)
    }
}

/// MVP timeline: a single gapless main storyline (magnetic, like Final Cut Pro's primary storyline).
/// Removing content always closes the gap; inserting always pushes later clips back.
public struct EditSequence: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var clips: [TimelineClip]

    public init(id: UUID = UUID(), name: String = "序列 1", clips: [TimelineClip] = []) {
        self.id = id
        self.name = name
        self.clips = clips
    }

    public var duration: MediaTime {
        clips.reduce(MediaTime.zero) { $0 + $1.duration }
    }

    public var placements: [ClipPlacement] {
        var cursor = MediaTime.zero
        return clips.enumerated().map { index, clip in
            defer { cursor += clip.duration }
            return ClipPlacement(index: index, clip: clip, timelineRange: TimeRange(start: cursor, duration: clip.duration))
        }
    }

    public func placement(at time: MediaTime) -> ClipPlacement? {
        placements.first { $0.timelineRange.contains(time) }
    }

    /// Timeline ranges where the given source range of `assetID` is currently visible.
    public func timelineRanges(forSource assetID: UUID, range: TimeRange) -> [TimeRange] {
        placements.compactMap { p in
            guard p.clip.assetID == assetID, let overlap = p.clip.sourceRange.intersection(range) else { return nil }
            return TimeRange(start: p.timelineTime(forSource: overlap.start), end: p.timelineTime(forSource: overlap.end))
        }
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var transcriptPaneWidth: Double
    public var showTranscriptPane: Bool
    public var visibleAnalysisLanes: [SegmentKind]

    public init(transcriptPaneWidth: Double = 290, showTranscriptPane: Bool = true,
                visibleAnalysisLanes: [SegmentKind] = [.transcript, .scene]) {
        self.transcriptPaneWidth = transcriptPaneWidth
        self.showTranscriptPane = showTranscriptPane
        self.visibleAnalysisLanes = visibleAnalysisLanes
    }
}

public struct Project: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var assets: [MediaAsset]
    public var sequence: EditSequence
    public var settings: ProjectSettings

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), assets: [MediaAsset] = [],
                sequence: EditSequence = EditSequence(), settings: ProjectSettings = ProjectSettings()) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.assets = assets
        self.sequence = sequence
        self.settings = settings
    }

    public func asset(_ id: UUID) -> MediaAsset? {
        assets.first { $0.id == id }
    }

    public mutating func updateAsset(_ id: UUID, _ change: (inout MediaAsset) -> Void) {
        guard let i = assets.firstIndex(where: { $0.id == id }) else { return }
        change(&assets[i])
    }
}
