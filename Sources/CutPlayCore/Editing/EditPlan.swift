import Foundation

public enum InsertPosition: Codable, Hashable, Sendable {
    case start
    case end
    /// After the first clip on the timeline (typically the intro / 片頭).
    case afterFirstClip
    case at(MediaTime)

    public var displayName: String {
        switch self {
        case .start: return "最前面"
        case .end: return "最後面"
        case .afterFirstClip: return "片頭後面"
        case .at(let t): return t.formatted()
        }
    }
}

public enum ExportPreset: String, Codable, CaseIterable, Sendable {
    case social1080p
    case high4K
    case audioOnly

    public var displayName: String {
        switch self {
        case .social1080p: return "社群影片（1080p）"
        case .high4K: return "高畫質（4K）"
        case .audioOnly: return "只要聲音"
        }
    }
}

/// Structured timeline operations. The assistant may only change the project through these.
public enum EditOperation: Codable, Hashable, Sendable {
    case insertClips([AssetRange], position: InsertPosition)
    case removeTimelineRange(TimeRange)
    case removeSourceRange(AssetRange)
    case keepOnly([AssetRange])
    case moveClip(clipID: UUID, toIndex: Int)
    /// UI selection only; never mutates the project.
    case select([AssetRange])
    /// Requests an export; handled by the app after the plan is applied.
    case export(ExportPreset)

    public var mutatesTimeline: Bool {
        switch self {
        case .select, .export: return false
        default: return true
        }
    }
}

public struct PlannedOperation: Codable, Hashable, Sendable {
    public var operation: EditOperation
    public var confidence: Double
    public var evidenceIDs: [String]

    public init(_ operation: EditOperation, confidence: Double, evidenceIDs: [String] = []) {
        self.operation = operation
        self.confidence = confidence
        self.evidenceIDs = evidenceIDs
    }
}

public struct EditPlan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Plain-language description shown to the user ("將會：…").
    public var summary: String
    public var operations: [PlannedOperation]

    public init(id: UUID = UUID(), summary: String, operations: [PlannedOperation]) {
        self.id = id
        self.summary = summary
        self.operations = operations
    }

    public var confidence: Double {
        operations.map(\.confidence).min() ?? 0
    }

    public var mutatesTimeline: Bool { operations.contains { $0.operation.mutatesTimeline } }
}

public enum ConfidenceLevel: String, Codable, Sendable {
    case high, medium, low

    public static let highThreshold = 0.8
    public static let mediumThreshold = 0.5

    public init(_ score: Double) {
        if score >= Self.highThreshold { self = .high }
        else if score >= Self.mediumThreshold { self = .medium }
        else { self = .low }
    }

    public var displayName: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}
