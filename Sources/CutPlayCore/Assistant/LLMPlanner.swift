import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LLMMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol ChatCompletionTransport: Sendable {
    /// Returns the assistant message content. Implementations should request JSON output.
    func complete(_ messages: [LLMMessage]) async throws -> String
}

public enum LLMError: Error, Equatable {
    case badResponse(status: Int, body: String)
    case emptyResponse
    case invalidJSON(String)
}

/// Any OpenAI-compatible `/chat/completions` endpoint: a cloud API, or a local server
/// such as llama.cpp `llama-server`, LM Studio, or Ollama (`http://localhost:11434/v1`).
public struct OpenAICompatibleTransport: ChatCompletionTransport {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    public var temperature: Double
    public var timeout: TimeInterval

    public init(baseURL: URL, apiKey: String? = nil, model: String, temperature: Double = 0.1, timeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.timeout = timeout
    }

    struct RequestBody: Encodable {
        struct Format: Encodable { var type = "json_object" }
        var model: String
        var messages: [LLMMessage]
        var temperature: Double
        var response_format = Format()
    }

    struct ResponseBody: Decodable {
        struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }
        var choices: [Choice]
    }

    public func complete(_ messages: [LLMMessage]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages, temperature: temperature))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.badResponse(status: status, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let content = try JSONDecoder().decode(ResponseBody.self, from: data).choices.first?.message.content,
              !content.isEmpty else { throw LLMError.emptyResponse }
        return content
    }
}

/// Plans with an LLM, grounded on the analysis index. The model only sees text evidence
/// (never media), must cite evidence IDs, and its times are clamped to the cited evidence.
public struct LLMPlanner: EditPlanner {
    public var transport: ChatCompletionTransport
    public var maxEvidence: Int
    /// How far a candidate may extend past the evidence it cites.
    public var groundingSlack: MediaTime

    public init(transport: ChatCompletionTransport, maxEvidence: Int = 150, groundingSlack: MediaTime = MediaTime(seconds: 0.5)) {
        self.transport = transport
        self.maxEvidence = maxEvidence
        self.groundingSlack = groundingSlack
    }

    struct Response: Decodable {
        struct CandidateDTO: Decodable {
            var evidence_ids: [String]
            var start: Double?
            var end: Double?
            var confidence: Double?
            var reason: String?
        }
        var type: String
        var message: String?
        var action: String?
        var position: String?
        var candidates: [CandidateDTO]?
        var export: String?
        var question: String?
        var options: [String]?
        var suggestions: [String]?
    }

    static let systemPrompt = """
    你是 Mac 影片剪輯 App 的剪輯助理。使用者用繁體中文描述想怎麼剪，你根據「素材分析索引」回答。
    規則：
    1. 只能引用索引裡出現的 evidence id，不可以編造時間碼。
    2. 時間單位是秒，都是素材內的時間（不是時間軸時間）。
    3. 只輸出一個 JSON 物件，不要有其他文字。
    4. 不確定使用者指哪一段時，回 clarification。
    5. 回覆訊息用簡短白話繁體中文，不要用專業術語。
    JSON 格式：
    {"type":"proposal"|"clarification"|"not_found"|"info",
     "message":"給使用者看的一句話",
     "action":"insert"|"select"|"remove"|"keep_only",
     "position":"start"|"end"|"after_first_clip",
     "candidates":[{"evidence_ids":["..."],"start":秒,"end":秒,"confidence":0到1,"reason":"為什麼選這段"}],
     "export":"social1080p"|"high4K"|"audioOnly"|null,
     "question":"clarification 時的問題","options":["選項"],"suggestions":["not_found 時的建議說法"]}
    """

    public func reply(to text: String, context: PlannerContext) async throws -> PlannerReply {
        let evidence = selectEvidence(for: text, context: context)
        var messages = [LLMMessage(role: "system", content: Self.systemPrompt)]
        messages.append(LLMMessage(role: "system", content: "素材分析索引：\n" + Self.render(evidence, project: context.project)
            + "\n時間軸目前的片段：\n" + Self.render(context.project)))
        for m in context.recentMessages.suffix(6) {
            messages.append(LLMMessage(role: m.role == .user ? "user" : "assistant", content: m.plainText))
        }
        var userText = text
        if let sel = context.selection {
            userText += "\n（使用者目前選取：asset=\(sel.assetID.uuidString.prefix(8)) \(sel.range.start.seconds)–\(sel.range.end.seconds) 秒）"
        }
        messages.append(LLMMessage(role: "user", content: userText))

        let raw = try await transport.complete(messages)
        return try parse(raw, evidence: evidence, context: context)
    }

    func selectEvidence(for text: String, context: PlannerContext) -> [AnalysisSegment] {
        let kinds: Set<SegmentKind> = [.transcript, .caption, .silence, .audioEvent]
        let hits = context.index.search(text, kinds: [.transcript, .caption], minScore: 0.2)
            .sorted { $0.score > $1.score }.map(\.segment)
        var chosen: [AnalysisSegment] = []
        var seen = Set<String>()
        for s in hits + context.index.segments.filter({ kinds.contains($0.kind) }) where !seen.contains(s.id) {
            chosen.append(s)
            seen.insert(s.id)
            if chosen.count >= maxEvidence { break }
        }
        return chosen.sorted { $0.range.start < $1.range.start }
    }

    static func render(_ segments: [AnalysisSegment], project: Project) -> String {
        segments.map { s in
            let asset = project.asset(s.assetID)?.name ?? s.assetID.uuidString
            let speaker = s.speaker.map { " \($0)" } ?? ""
            return String(format: "[%@] %@ %.1f-%.1f %@%@ %@", s.id, asset, s.range.start.seconds, s.range.end.seconds,
                          s.kind.rawValue, speaker, s.text ?? "")
        }.joined(separator: "\n")
    }

    static func render(_ project: Project) -> String {
        let lines = project.sequence.placements.map { p in
            String(format: "%d. %@ 素材 %.1f-%.1f 秒", p.index + 1, project.asset(p.clip.assetID)?.name ?? "?",
                   p.clip.sourceRange.start.seconds, p.clip.sourceRange.end.seconds)
        }
        return lines.isEmpty ? "（空的）" : lines.joined(separator: "\n")
    }

    func parse(_ raw: String, evidence: [AnalysisSegment], context: PlannerContext) throws -> PlannerReply {
        let json = Self.extractJSONObject(raw)
        guard let data = json.data(using: .utf8), let r = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LLMError.invalidJSON(String(raw.prefix(300)))
        }
        let message = r.message ?? ""
        switch r.type {
        case "clarification":
            return .clarification(question: r.question ?? message, options: r.options ?? [])
        case "not_found":
            return .notFound(message: message.isEmpty ? "沒找到符合的片段。" : message, suggestions: r.suggestions ?? [])
        case "info":
            return .info(message)
        default:
            break
        }

        let byID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var candidates: [Candidate] = []
        for dto in r.candidates ?? [] {
            let cited = dto.evidence_ids.compactMap { byID[$0] }
            guard let first = cited.first, cited.allSatisfy({ $0.assetID == first.assetID }),
                  let asset = context.project.asset(first.assetID) else { continue }
            let lo = cited.map(\.range.start).min()!, hi = cited.map(\.range.end).max()!
            var start = dto.start.map(MediaTime.init(seconds:)) ?? lo
            var end = dto.end.map(MediaTime.init(seconds:)) ?? hi
            start = min(max(start, lo - groundingSlack), hi)
            end = max(min(end, hi + groundingSlack), start)
            let range = TimeRange(start: start, end: end).clamped(to: asset.fullRange)
            guard !range.isEmpty else { continue }
            candidates.append(Candidate(assetID: asset.id, range: range, confidence: min(max(dto.confidence ?? 0.6, 0), 1),
                                        reason: dto.reason ?? first.text ?? "", evidenceIDs: cited.map(\.id)))
        }

        let action: CandidateAction
        switch r.action {
        case "insert":
            switch r.position {
            case "start": action = .insert(.start)
            case "after_first_clip": action = .insert(.afterFirstClip)
            default: action = .insert(.end)
            }
        case "remove": action = .remove
        case "keep_only": action = .keepOnly
        default: action = .select
        }
        let trailing = r.export.flatMap(ExportPreset.init(rawValue:)).map { [EditOperation.export($0)] } ?? []
        if candidates.isEmpty && trailing.isEmpty {
            return .notFound(message: "沒找到有根據的片段，可以換個說法再試一次。", suggestions: RuleBasedPlanner.suggestions)
        }
        let proposal = PlanProposal(candidates: candidates, action: action, trailingOperations: trailing)
        return .proposal(proposal, message: message.isEmpty ? "找到 \(candidates.count) 段：" : message)
    }

    /// Tolerates models that wrap JSON in prose or code fences.
    static func extractJSONObject(_ raw: String) -> String {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close else { return raw }
        return String(raw[open...close])
    }
}

/// Rules first (fast, offline, deterministic); LLM only for requests the rules don't recognise.
public struct HybridPlanner: EditPlanner {
    public var rules: RuleBasedPlanner
    public var llm: EditPlanner?

    public init(rules: RuleBasedPlanner = RuleBasedPlanner(), llm: EditPlanner? = nil) {
        self.rules = rules
        self.llm = llm
    }

    public func reply(to text: String, context: PlannerContext) async throws -> PlannerReply {
        if rules.intent(for: text, hasSelection: context.selection != nil) == nil, let llm {
            return try await llm.reply(to: text, context: context)
        }
        return try await rules.reply(to: text, context: context)
    }
}
