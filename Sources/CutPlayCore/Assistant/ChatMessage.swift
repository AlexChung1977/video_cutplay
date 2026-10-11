import Foundation

public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public enum ProposalState: Codable, Hashable, Sendable {
        case pending(reasons: [String])
        /// `undoID` is nil for plans that don't change the timeline (selection, export).
        case applied(undoID: UUID?, automatically: Bool)
        case undone
        case dismissed
        case failed(message: String)
    }

    public enum Content: Codable, Hashable, Sendable {
        case text(String)
        case proposal(PlanProposal, message: String, state: ProposalState)
        case clarification(question: String, options: [String])
        case notFound(message: String, suggestions: [String])
    }

    public var id: UUID
    public var role: Role
    public var createdAt: Date
    public var content: Content

    public init(id: UUID = UUID(), role: Role, createdAt: Date = Date(), content: Content) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.content = content
    }

    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: .text(text)) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: .text(text)) }

    /// Plain text used when sending history to an LLM.
    public var plainText: String {
        switch content {
        case .text(let t): return t
        case .proposal(_, let message, let state):
            switch state {
            case .applied: return message + "（已套用）"
            case .undone: return message + "（已復原）"
            case .dismissed: return message + "（使用者略過）"
            default: return message
            }
        case .clarification(let q, let options): return q + " 選項：" + options.joined(separator: "／")
        case .notFound(let m, _): return m
        }
    }

    public var undoID: UUID? {
        if case .proposal(_, _, .applied(let id, _)) = content { return id }
        return nil
    }
}
