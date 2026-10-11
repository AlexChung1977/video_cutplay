import Foundation

/// Decides whether an assistant plan may be applied without the user pressing 套用.
/// Backs the 「信心高時直接套用」 checkbox; the UI must not re-implement these rules.
public struct AutoApplyPolicy: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var minimumConfidence: Double
    public var maxRemovedDuration: MediaTime
    public var maxAffectedSegments: Int

    public init(isEnabled: Bool = false, minimumConfidence: Double = ConfidenceLevel.highThreshold,
                maxRemovedDuration: MediaTime = MediaTime(seconds: 30), maxAffectedSegments: Int = 5) {
        self.isEnabled = isEnabled
        self.minimumConfidence = minimumConfidence
        self.maxRemovedDuration = maxRemovedDuration
        self.maxAffectedSegments = maxAffectedSegments
    }

    public enum Reason: Hashable, Sendable {
        case disabled
        case lowConfidence
        case removesTooMuch(MediaTime)
        case touchesTooManySegments(Int)
        case overwrites
        case noTimelineChange

        public var message: String {
            switch self {
            case .disabled: return "自動套用已關閉"
            case .lowConfidence: return "有片段信心度不是「高」"
            case .removesTooMuch(let d): return "會刪掉 \(Int(d.seconds.rounded())) 秒，超過自動套用上限"
            case .touchesTooManySegments(let n): return "一次影響 \(n) 段，超過自動套用上限"
            case .overwrites: return "會覆蓋已有片段"
            case .noTimelineChange: return "沒有修改時間軸"
            }
        }
    }

    public enum Decision: Hashable, Sendable {
        case autoApply
        case needsConfirmation([Reason])

        public var isAutoApply: Bool { self == .autoApply }
    }

    /// `effects` should come from a dry-run `EditApplicator.apply`.
    public func evaluate(_ plan: EditPlan, effects: EditEffects) -> Decision {
        var reasons: [Reason] = []
        if !isEnabled { reasons.append(.disabled) }
        if !plan.mutatesTimeline { reasons.append(.noTimelineChange) }
        if plan.operations.contains(where: { $0.confidence < minimumConfidence }) { reasons.append(.lowConfidence) }
        if effects.removedDuration > maxRemovedDuration { reasons.append(.removesTooMuch(effects.removedDuration)) }
        if effects.affectedSegments > maxAffectedSegments { reasons.append(.touchesTooManySegments(effects.affectedSegments)) }
        if effects.overwrites > 0 { reasons.append(.overwrites) }
        return reasons.isEmpty ? .autoApply : .needsConfirmation(reasons)
    }

    /// Like `evaluate(_:effects:)`, but also looks at candidates the user hasn't checked: a proposal
    /// containing any non-high candidate is never auto-applied, so nothing gets applied "halfway".
    public func evaluate(_ proposal: PlanProposal, plan: EditPlan, effects: EditEffects) -> Decision {
        let decision = evaluate(plan, effects: effects)
        guard proposal.candidates.contains(where: { $0.confidence < minimumConfidence }) else { return decision }
        switch decision {
        case .autoApply:
            return .needsConfirmation([.lowConfidence])
        case .needsConfirmation(let reasons):
            return .needsConfirmation(reasons.contains(.lowConfidence) ? reasons : reasons + [.lowConfidence])
        }
    }
}
