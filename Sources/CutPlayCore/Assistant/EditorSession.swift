import Foundation

/// Owns the editable state of one open project: timeline, analysis index, undo history and chat.
/// UI-agnostic; the macOS app wraps it in an `@Observable` view model and calls it on the main actor.
public final class EditorSession {
    public private(set) var project: Project
    public private(set) var index: AnalysisIndex
    public private(set) var history = UndoHistory()
    public private(set) var messages: [ChatMessage]
    public var policy: AutoApplyPolicy
    public var planner: EditPlanner

    /// Ranges to highlight after the last assistant action (selection or inserted clips).
    public private(set) var highlightedClipIDs: [UUID] = []
    public private(set) var assistantSelection: [AssetRange] = []
    /// Exports requested by applied plans; the app drains this.
    public private(set) var pendingExports: [ExportPreset] = []

    public init(project: Project, index: AnalysisIndex = AnalysisIndex(), messages: [ChatMessage] = [],
                policy: AutoApplyPolicy = AutoApplyPolicy(), planner: EditPlanner = HybridPlanner()) {
        self.project = project
        self.index = index
        self.messages = messages
        self.policy = policy
        self.planner = planner
    }

    // MARK: - Assets & analysis

    public func addAsset(_ asset: MediaAsset) {
        project.assets.append(asset)
    }

    public func updateAsset(_ id: UUID, _ change: (inout MediaAsset) -> Void) {
        project.updateAsset(id, change)
    }

    public func replaceAnalysis(_ kind: SegmentKind, for assetID: UUID, with segments: [AnalysisSegment]) {
        index.replace(kind, for: assetID, with: segments)
    }

    public func updateSettings(_ change: (inout ProjectSettings) -> Void) {
        change(&project.settings)
    }

    // MARK: - Manual edits

    /// Applies a manual timeline change as one undo step.
    @discardableResult
    public func edit(_ label: String, _ change: (inout EditSequence) throws -> Void) rethrows -> UUID? {
        let before = project.sequence
        var after = before
        try change(&after)
        guard after != before else { return nil }
        project.sequence = after
        return history.record(label: label, before: before, after: after)
    }

    public func appendToTimeline(_ assetID: UUID, range: TimeRange? = nil) {
        guard let asset = project.asset(assetID) else { return }
        edit("加入 \(asset.name)") { seq in
            seq.clips.append(TimelineClip(assetID: assetID, sourceRange: range ?? asset.fullRange))
        }
    }

    // MARK: - Undo

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        guard let entry = history.undo() else { return }
        project.sequence = entry.before
        markProposal(undoID: entry.id, as: .undone)
    }

    public func redo() {
        guard let entry = history.redo() else { return }
        project.sequence = entry.after
        if let i = messages.firstIndex(where: { $0.undoID == entry.id }), case .proposal(let p, let m, _) = messages[i].content {
            messages[i].content = .proposal(p, message: m, state: .applied(undoID: entry.id, automatically: false))
        }
    }

    public enum UndoMessageResult: Equatable {
        case undone
        case notLatest
        case nothingToUndo
    }

    /// The 「復原」 link on a chat message. Only the newest change can be undone this way, so
    /// later edits are never silently lost.
    @discardableResult
    public func undo(messageID: UUID) -> UndoMessageResult {
        guard let msg = messages.first(where: { $0.id == messageID }), let undoID = msg.undoID,
              history.contains(undoID) else { return .nothingToUndo }
        guard history.isLatest(undoID) else { return .notLatest }
        undo()
        return .undone
    }

    // MARK: - Chat

    /// Sends a user message, asks the planner, and auto-applies when the policy allows.
    public func send(_ text: String, selection: AssetRange? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let context = PlannerContext(project: project, index: index, selection: selection, recentMessages: Array(messages.suffix(8)))
        messages.append(.user(trimmed))
        do {
            let reply = try await planner.reply(to: trimmed, context: context)
            handle(reply)
        } catch {
            messages.append(.assistant("抱歉，處理時出了問題：\(error.localizedDescription)"))
        }
    }

    private func handle(_ reply: PlannerReply) {
        switch reply {
        case .info(let text):
            messages.append(.assistant(text))
        case .clarification(let q, let options):
            messages.append(ChatMessage(role: .assistant, content: .clarification(question: q, options: options)))
        case .notFound(let m, let s):
            messages.append(ChatMessage(role: .assistant, content: .notFound(message: m, suggestions: s)))
        case .proposal(let proposal, let message):
            let msg = ChatMessage(role: .assistant, content: .proposal(proposal, message: message, state: .pending(reasons: [])))
            messages.append(msg)
            evaluate(messageID: msg.id, autoApplyAllowed: true)
        }
    }

    /// Re-checks a pending proposal (after the user toggles candidates) and auto-applies if allowed.
    private func evaluate(messageID: UUID, autoApplyAllowed: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              case .proposal(let proposal, let message, .pending) = messages[i].content else { return }
        let plan = proposal.makePlan()
        if plan.operations.isEmpty {
            messages[i].content = .proposal(proposal, message: message, state: .pending(reasons: ["沒有選取任何片段"]))
            return
        }
        if !plan.mutatesTimeline && autoApplyAllowed {
            // Selection highlights and exports are non-destructive: do them right away.
            commit(messageID: messageID, automatically: true)
            return
        }
        do {
            let dryRun = try EditApplicator.apply(plan, to: project)
            let decision = policy.evaluate(proposal, plan: plan, effects: dryRun.effects)
            if autoApplyAllowed, decision.isAutoApply {
                commit(messageID: messageID, automatically: true)
            } else if case .needsConfirmation(let reasons) = decision {
                let shown = reasons.filter { $0 != .disabled }.map(\.message)
                messages[i].content = .proposal(proposal, message: message, state: .pending(reasons: shown))
            }
        } catch let issue as ValidationIssue {
            messages[i].content = .proposal(proposal, message: message, state: .pending(reasons: [issue.message]))
        } catch {
            messages[i].content = .proposal(proposal, message: message, state: .pending(reasons: ["\(error)"]))
        }
    }

    public func setCandidate(_ candidateID: String, selected: Bool, in messageID: UUID) {
        updatePendingProposal(messageID) { p in
            if let c = p.candidates.firstIndex(where: { $0.id == candidateID }) { p.candidates[c].isSelected = selected }
        }
    }

    public func setCandidateRange(_ candidateID: String, range: TimeRange, in messageID: UUID) {
        updatePendingProposal(messageID) { p in
            if let c = p.candidates.firstIndex(where: { $0.id == candidateID }), !range.isEmpty { p.candidates[c].range = range }
        }
    }

    private func updatePendingProposal(_ messageID: UUID, _ change: (inout PlanProposal) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              case .proposal(var p, let m, .pending) = messages[i].content else { return }
        change(&p)
        messages[i].content = .proposal(p, message: m, state: .pending(reasons: []))
        evaluate(messageID: messageID, autoApplyAllowed: false)
    }

    /// The 「套用」 button.
    public func apply(messageID: UUID) {
        commit(messageID: messageID, automatically: false)
    }

    public func dismiss(messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              case .proposal(let p, let m, .pending) = messages[i].content else { return }
        messages[i].content = .proposal(p, message: m, state: .dismissed)
    }

    private func commit(messageID: UUID, automatically: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              case .proposal(let proposal, let message, .pending) = messages[i].content else { return }
        let plan = proposal.makePlan()
        do {
            let result = try EditApplicator.apply(plan, to: project)
            var undoID: UUID?
            if plan.mutatesTimeline, result.project.sequence != project.sequence {
                undoID = history.record(label: "✦ AI 編輯", before: project.sequence, after: result.project.sequence, isAssistantEdit: true)
                project.sequence = result.project.sequence
            }
            highlightedClipIDs = result.insertedClipIDs
            assistantSelection = result.selection
            pendingExports += result.exports
            messages[i].content = .proposal(proposal, message: message, state: .applied(undoID: undoID, automatically: automatically))
        } catch let issue as ValidationIssue {
            messages[i].content = .proposal(proposal, message: message, state: .failed(message: issue.message))
        } catch {
            messages[i].content = .proposal(proposal, message: message, state: .failed(message: "\(error)"))
        }
    }

    public func takePendingExports() -> [ExportPreset] {
        defer { pendingExports.removeAll() }
        return pendingExports
    }

    public func clearHighlights() {
        highlightedClipIDs = []
        assistantSelection = []
    }

    /// 「新對話」: clears the conversation context; edits and undo history stay.
    public func startNewConversation() {
        messages.removeAll()
    }

    private func markProposal(undoID: UUID, as state: ChatMessage.ProposalState) {
        guard let i = messages.firstIndex(where: { $0.undoID == undoID }),
              case .proposal(let p, let m, _) = messages[i].content else { return }
        messages[i].content = .proposal(p, message: m, state: state)
    }
}
