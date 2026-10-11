import Foundation

/// One range the assistant suggests, shown as a checkbox row in the chat.
public struct Candidate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var assetID: UUID
    public var range: TimeRange
    public var confidence: Double
    /// Why it matched, e.g. the transcript sentence. Shown under the time range.
    public var reason: String
    public var evidenceIDs: [String]
    public var isSelected: Bool

    public init(id: String = UUID().uuidString, assetID: UUID, range: TimeRange, confidence: Double,
                reason: String, evidenceIDs: [String] = [], isSelected: Bool? = nil) {
        self.id = id
        self.assetID = assetID
        self.range = range
        self.confidence = confidence
        self.reason = reason
        self.evidenceIDs = evidenceIDs
        self.isSelected = isSelected ?? (ConfidenceLevel(confidence) == .high)
    }

    public var level: ConfidenceLevel { ConfidenceLevel(confidence) }
    public var assetRange: AssetRange { AssetRange(assetID: assetID, range: range) }
}

public enum CandidateAction: Codable, Hashable, Sendable {
    case insert(InsertPosition)
    case select
    case remove
    case keepOnly
    case move(clipID: UUID, toIndex: Int)
}

/// What the assistant proposes. Becomes an `EditPlan` from the candidates the user leaves checked.
public struct PlanProposal: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var candidates: [Candidate]
    public var action: CandidateAction
    public var trailingOperations: [EditOperation]

    public init(id: UUID = UUID(), candidates: [Candidate], action: CandidateAction, trailingOperations: [EditOperation] = []) {
        self.id = id
        self.candidates = candidates
        self.action = action
        self.trailingOperations = trailingOperations
    }

    public var selectedCandidates: [Candidate] { candidates.filter(\.isSelected) }

    public func makePlan() -> EditPlan {
        let selected = selectedCandidates
        var ops: [PlannedOperation] = []
        switch action {
        case .insert(let position):
            if !selected.isEmpty {
                ops.append(PlannedOperation(.insertClips(selected.map(\.assetRange), position: position),
                                            confidence: selected.map(\.confidence).min() ?? 0,
                                            evidenceIDs: selected.flatMap(\.evidenceIDs)))
            }
        case .select:
            if !selected.isEmpty {
                ops.append(PlannedOperation(.select(selected.map(\.assetRange)),
                                            confidence: selected.map(\.confidence).min() ?? 0,
                                            evidenceIDs: selected.flatMap(\.evidenceIDs)))
            }
        case .remove:
            ops += selected.map {
                PlannedOperation(.removeSourceRange($0.assetRange), confidence: $0.confidence, evidenceIDs: $0.evidenceIDs)
            }
        case .keepOnly:
            if !selected.isEmpty {
                ops.append(PlannedOperation(.keepOnly(selected.map(\.assetRange)),
                                            confidence: selected.map(\.confidence).min() ?? 0,
                                            evidenceIDs: selected.flatMap(\.evidenceIDs)))
            }
        case .move(let clipID, let toIndex):
            if let c = selected.first {
                ops.append(PlannedOperation(.moveClip(clipID: clipID, toIndex: toIndex), confidence: c.confidence))
            }
        }
        ops += trailingOperations.map { PlannedOperation($0, confidence: 1.0) }
        return EditPlan(id: id, summary: summary(for: selected), operations: ops)
    }

    /// The 「將會：…」 line.
    public func summary(for selected: [Candidate]? = nil) -> String {
        let chosen = selected ?? selectedCandidates
        let total = chosen.reduce(MediaTime.zero) { $0 + $1.range.duration }
        var parts: [String] = []
        switch action {
        case .insert(let position):
            if !chosen.isEmpty {
                parts.append("在\(position.displayName)插入 \(chosen.count) 段（共 \(Self.describe(total))），後面的內容往後推")
            }
        case .select:
            if !chosen.isEmpty { parts.append("在時間軸上標出 \(chosen.count) 段") }
        case .remove:
            if !chosen.isEmpty { parts.append("刪掉 \(chosen.count) 段（共 \(Self.describe(total))），後面自動補上空隙") }
        case .keepOnly:
            if !chosen.isEmpty { parts.append("只保留 \(chosen.count) 段（共 \(Self.describe(total))），其他刪掉") }
        case .move(_, let toIndex):
            if !chosen.isEmpty { parts.append("把片段移到第 \(toIndex + 1) 個位置") }
        }
        for op in trailingOperations {
            if case .export(let preset) = op { parts.append("匯出成\(preset.displayName)") }
        }
        return parts.isEmpty ? "沒有選取任何片段" : "將會：" + parts.joined(separator: "，然後") + "。"
    }

    static func describe(_ t: MediaTime) -> String {
        let total = Int(t.seconds.rounded())
        if total < 60 { return t.seconds < 10 ? String(format: "%.1f 秒", t.seconds) : "\(total) 秒" }
        let m = total / 60, s = total % 60
        return s == 0 ? "\(m) 分鐘" : "\(m) 分 \(s) 秒"
    }
}

public enum PlannerReply: Hashable, Sendable {
    case proposal(PlanProposal, message: String)
    case clarification(question: String, options: [String])
    case notFound(message: String, suggestions: [String])
    case info(String)
}

public struct PlannerContext: Sendable {
    public var project: Project
    public var index: AnalysisIndex
    /// Current user selection on the timeline/transcript, in asset time.
    public var selection: AssetRange?
    /// Recent conversation, oldest first.
    public var recentMessages: [ChatMessage]

    public init(project: Project, index: AnalysisIndex, selection: AssetRange? = nil, recentMessages: [ChatMessage] = []) {
        self.project = project
        self.index = index
        self.selection = selection
        self.recentMessages = recentMessages
    }
}

public protocol EditPlanner: Sendable {
    func reply(to text: String, context: PlannerContext) async throws -> PlannerReply
}
