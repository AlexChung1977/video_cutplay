import Foundation

/// Directory-based project package:
///
///     MyEdit.cutplay/
///       project.json   timeline + asset references
///       index.json     analysis segments
///       chat.json      assistant conversation
///       cache/         proxies, extracted audio, thumbnails (safe to delete; rebuilt on demand)
public struct ProjectStore {
    public static let fileExtension = "cutplay"

    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public var cacheDirectory: URL { url.appendingPathComponent("cache", isDirectory: true) }
    var projectFile: URL { url.appendingPathComponent("project.json") }
    var indexFile: URL { url.appendingPathComponent("index.json") }
    var chatFile: URL { url.appendingPathComponent("chat.json") }

    public func cacheURL(for assetID: UUID, suffix: String) -> URL {
        cacheDirectory.appendingPathComponent("\(assetID.uuidString)-\(suffix)")
    }

    public struct Contents {
        public var project: Project
        public var index: AnalysisIndex
        public var messages: [ChatMessage]
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func save(project: Project, index: AnalysisIndex, messages: [ChatMessage]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(project).write(to: projectFile, options: .atomic)
        try Self.encoder.encode(index).write(to: indexFile, options: .atomic)
        try Self.encoder.encode(messages).write(to: chatFile, options: .atomic)
    }

    public func save(_ session: EditorSession) throws {
        try save(project: session.project, index: session.index, messages: session.messages)
    }

    public func load() throws -> Contents {
        let project = try Self.decoder.decode(Project.self, from: Data(contentsOf: projectFile))
        let index = (try? Self.decoder.decode(AnalysisIndex.self, from: Data(contentsOf: indexFile))) ?? AnalysisIndex()
        let messages = (try? Self.decoder.decode([ChatMessage].self, from: Data(contentsOf: chatFile))) ?? []
        return Contents(project: project, index: index, messages: messages)
    }
}
