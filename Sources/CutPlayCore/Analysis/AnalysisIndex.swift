import Foundation

public enum SegmentKind: String, Codable, CaseIterable, Sendable {
    case transcript
    case scene
    case silence
    case audioEvent
    case caption

    public var displayName: String {
        switch self {
        case .transcript: return "逐字稿"
        case .scene: return "場景"
        case .silence: return "停頓"
        case .audioEvent: return "聲音事件"
        case .caption: return "畫面描述"
        }
    }
}

/// One timestamped analysis result, always in asset (source) time.
public struct AnalysisSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var assetID: UUID
    public var kind: SegmentKind
    public var range: TimeRange
    public var text: String?
    public var speaker: String?
    public var confidence: Double?

    public init(id: String? = nil, assetID: UUID, kind: SegmentKind, range: TimeRange,
                text: String? = nil, speaker: String? = nil, confidence: Double? = nil) {
        self.id = id ?? "\(kind.rawValue)-\(assetID.uuidString.prefix(8))-\(range.start.ticks)"
        self.assetID = assetID
        self.kind = kind
        self.range = range
        self.text = text
        self.speaker = speaker
        self.confidence = confidence
    }
}

public struct SearchHit: Hashable, Sendable {
    public var segment: AnalysisSegment
    public var score: Double
}

/// The per-project knowledge base the assistant grounds edits on.
/// MVP keeps it in memory and persists as JSON; SQLite + FTS5 can replace the storage without changing this API.
public struct AnalysisIndex: Codable, Hashable, Sendable {
    public private(set) var segments: [AnalysisSegment]

    public init(segments: [AnalysisSegment] = []) {
        self.segments = segments.sorted(by: Self.order)
    }

    private static func order(_ a: AnalysisSegment, _ b: AnalysisSegment) -> Bool {
        a.range.start == b.range.start ? a.kind.rawValue < b.kind.rawValue : a.range.start < b.range.start
    }

    /// Replaces all segments of `kind` for `assetID` (re-analysis is idempotent).
    public mutating func replace(_ kind: SegmentKind, for assetID: UUID, with newSegments: [AnalysisSegment]) {
        segments.removeAll { $0.assetID == assetID && $0.kind == kind }
        segments.append(contentsOf: newSegments)
        segments.sort(by: Self.order)
    }

    public mutating func removeAll(for assetID: UUID) {
        segments.removeAll { $0.assetID == assetID }
    }

    public func segments(_ kind: SegmentKind, assetID: UUID? = nil) -> [AnalysisSegment] {
        segments.filter { $0.kind == kind && (assetID == nil || $0.assetID == assetID) }
    }

    public func segment(id: String) -> AnalysisSegment? {
        segments.first { $0.id == id }
    }

    public func segments(overlapping range: TimeRange, assetID: UUID, kinds: Set<SegmentKind>) -> [AnalysisSegment] {
        segments.filter { $0.assetID == assetID && kinds.contains($0.kind) && $0.range.overlaps(range) }
    }

    public func speakers(assetID: UUID? = nil) -> [String] {
        var seen: [String] = []
        for s in segments(.transcript, assetID: assetID) {
            if let sp = s.speaker, !seen.contains(sp) { seen.append(sp) }
        }
        return seen
    }

    public func hasAnalysis(_ kind: SegmentKind) -> Bool {
        segments.contains { $0.kind == kind }
    }

    /// Keyword search over text-bearing segments. Scores 1.0 for an exact (normalized) substring match,
    /// otherwise the fraction of query character bigrams present (works for CJK without a tokenizer).
    public func search(_ query: String, kinds: Set<SegmentKind> = [.transcript, .caption],
                       minScore: Double = 0.5, assetID: UUID? = nil) -> [SearchHit] {
        let q = TextNormalizer.normalize(query)
        guard !q.isEmpty else { return [] }
        let qBigrams = TextNormalizer.bigrams(q)
        return segments.compactMap { segment -> SearchHit? in
            guard kinds.contains(segment.kind), assetID == nil || segment.assetID == assetID,
                  let text = segment.text else { return nil }
            let t = TextNormalizer.normalize(text)
            let score: Double
            if t.contains(q) {
                score = 1.0
            } else if qBigrams.isEmpty {
                score = 0
            } else {
                let tBigrams = Set(TextNormalizer.bigrams(t))
                let bigramScore = Double(qBigrams.filter { tBigrams.contains($0) }.count) / Double(qBigrams.count)
                let substringScore = Double(TextNormalizer.longestCommonSubstring(q, t)) / Double(q.count)
                score = max(bigramScore, substringScore)
            }
            return score >= minScore ? SearchHit(segment: segment, score: score) : nil
        }
    }

    /// Moves `time` to the nearest scene cut within `tolerance`, if any.
    public func snapToSceneCut(_ time: MediaTime, assetID: UUID, tolerance: MediaTime = MediaTime(seconds: 0.5)) -> MediaTime {
        let cuts = segments(.scene, assetID: assetID).map(\.range.start)
        guard let nearest = cuts.min(by: { abs(($0 - time).ticks) < abs(($1 - time).ticks) }),
              abs((nearest - time).ticks) <= tolerance.ticks else { return time }
        return nearest
    }
}

public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        return String(lowered.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }.map(Character.init))
    }

    /// Length (in characters) of the longest substring shared by `a` and `b`.
    public static func longestCommonSubstring(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }

    public static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [String(chars)] }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }
}
