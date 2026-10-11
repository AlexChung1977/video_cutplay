import Foundation

/// Snapshot-based undo for the timeline. Every manual edit and every applied assistant plan is one entry.
public struct UndoHistory: Hashable, Sendable {
    public struct Entry: Hashable, Identifiable, Sendable {
        public var id: UUID
        public var label: String
        public var before: EditSequence
        public var after: EditSequence
        public var isAssistantEdit: Bool
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public var limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    public mutating func record(label: String, before: EditSequence, after: EditSequence, isAssistantEdit: Bool = false) -> UUID {
        let entry = Entry(id: UUID(), label: label, before: before, after: after, isAssistantEdit: isAssistantEdit)
        undoStack.append(entry)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        return entry.id
    }

    public func isLatest(_ id: UUID) -> Bool { undoStack.last?.id == id }

    public func contains(_ id: UUID) -> Bool { undoStack.contains { $0.id == id } }

    /// Pops the latest entry and returns the sequence to restore.
    public mutating func undo() -> Entry? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        return entry
    }

    public mutating func redo() -> Entry? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        return entry
    }
}
