import Foundation

public enum ValidationIssue: Error, Hashable, Sendable {
    case emptyPlan
    case unknownAsset(UUID)
    case emptyRange(TimeRange)
    case rangeOutsideAsset(AssetRange)
    case rangeOutsideTimeline(TimeRange)
    case unknownClip(UUID)

    public var message: String {
        switch self {
        case .emptyPlan: return "這個方案沒有任何操作"
        case .unknownAsset: return "找不到方案中引用的素材"
        case .emptyRange(let r): return "時間範圍無效（\(r.formatted())）"
        case .rangeOutsideAsset(let r): return "時間範圍超出素材長度（\(r.range.formatted())）"
        case .rangeOutsideTimeline(let r): return "時間範圍超出時間軸（\(r.formatted())）"
        case .unknownClip: return "找不到要移動的片段"
        }
    }
}

public enum EditPlanValidator {
    /// Small tolerance for analysis timestamps that overshoot the container duration.
    static let tolerance = MediaTime(seconds: 0.05)

    public static func validate(_ plan: EditPlan, in project: Project) -> [ValidationIssue] {
        guard !plan.operations.isEmpty else { return [.emptyPlan] }
        var issues: [ValidationIssue] = []
        func check(_ ar: AssetRange) {
            guard let asset = project.asset(ar.assetID) else { issues.append(.unknownAsset(ar.assetID)); return }
            if ar.range.isEmpty { issues.append(.emptyRange(ar.range)); return }
            if ar.range.start < .zero || ar.range.end > asset.duration + tolerance { issues.append(.rangeOutsideAsset(ar)) }
        }
        for planned in plan.operations {
            switch planned.operation {
            case .insertClips(let ranges, _), .keepOnly(let ranges), .select(let ranges):
                ranges.forEach(check)
            case .removeSourceRange(let ar):
                check(ar)
            case .removeTimelineRange(let r):
                if r.isEmpty { issues.append(.emptyRange(r)) }
                else if r.start < .zero || r.end > project.sequence.duration + tolerance { issues.append(.rangeOutsideTimeline(r)) }
            case .moveClip(let id, _):
                if !project.sequence.clips.contains(where: { $0.id == id }) { issues.append(.unknownClip(id)) }
            case .export:
                break
            }
        }
        return issues
    }
}

/// What a plan did (or would do) to the timeline. Used for the auto-apply policy and the chat summary.
public struct EditEffects: Hashable, Sendable {
    public var removedDuration: MediaTime = .zero
    public var insertedDuration: MediaTime = .zero
    /// Number of distinct timeline regions touched.
    public var affectedSegments: Int = 0
    /// Content replaced in place. Always 0 on the magnetic MVP timeline; kept for multi-track v2.
    public var overwrites: Int = 0

    public init() {}
}

public struct ApplyResult: Sendable {
    public var project: Project
    public var effects: EditEffects
    public var selection: [AssetRange]
    public var exports: [ExportPreset]
    /// Timeline ranges of clips the plan inserted, for highlighting.
    public var insertedClipIDs: [UUID]
}

public enum EditApplicator {
    /// Pure function: returns the edited copy. Calling it without committing is the dry run.
    public static func apply(_ plan: EditPlan, to project: Project) throws -> ApplyResult {
        let issues = EditPlanValidator.validate(plan, in: project)
        if let first = issues.first { throw first }

        var p = project
        var effects = EditEffects()
        var selection: [AssetRange] = []
        var exports: [ExportPreset] = []
        var inserted: [UUID] = []

        for planned in plan.operations {
            switch planned.operation {
            case .insertClips(let ranges, let position):
                let clips = ranges.map {
                    TimelineClip(assetID: $0.assetID, sourceRange: clampToAsset($0, in: p), origin: .assistant)
                }
                let time: MediaTime
                switch position {
                case .start: time = .zero
                case .end: time = p.sequence.duration
                case .afterFirstClip: time = p.sequence.clips.first?.duration ?? .zero
                case .at(let t): time = min(max(t, .zero), p.sequence.duration)
                }
                try p.sequence.insert(clips, at: time)
                inserted += clips.map(\.id)
                effects.insertedDuration += clips.reduce(.zero) { $0 + $1.duration }
                effects.affectedSegments += clips.count
            case .removeTimelineRange(let r):
                let removed = try p.sequence.removeRange(r)
                if removed > .zero { effects.removedDuration += removed; effects.affectedSegments += 1 }
            case .removeSourceRange(let ar):
                let occurrences = p.sequence.timelineRanges(forSource: ar.assetID, range: ar.range).count
                let removed = try p.sequence.removeSource(assetID: ar.assetID, range: ar.range)
                effects.removedDuration += removed
                effects.affectedSegments += occurrences
            case .keepOnly(let ranges):
                let before = p.sequence.clips.count
                let removed = p.sequence.keepOnly(ranges)
                effects.removedDuration += removed
                effects.affectedSegments += max(before, p.sequence.clips.count)
            case .moveClip(let id, let index):
                try p.sequence.moveClip(id, to: index)
                effects.affectedSegments += 1
            case .select(let ranges):
                selection += ranges
            case .export(let preset):
                exports.append(preset)
            }
        }
        return ApplyResult(project: p, effects: effects, selection: selection, exports: exports, insertedClipIDs: inserted)
    }

    private static func clampToAsset(_ ar: AssetRange, in project: Project) -> TimeRange {
        guard let asset = project.asset(ar.assetID) else { return ar.range }
        return ar.range.clamped(to: asset.fullRange)
    }
}
