import Foundation

/// Media time stored as integer ticks at 90 kHz, so frame boundaries for 23.976/24/25/29.97/30/50/60 fps
/// stay exact. Maps 1:1 to `CMTime(value: ticks, timescale: 90_000)` on Apple platforms.
public struct MediaTime: Hashable, Comparable, Sendable {
    public static let timescale: Int64 = 90_000
    public static let zero = MediaTime(ticks: 0)

    public var ticks: Int64

    public init(ticks: Int64) {
        self.ticks = ticks
    }

    public init(seconds: Double) {
        self.ticks = Int64((seconds * Double(Self.timescale)).rounded())
    }

    public var seconds: Double { Double(ticks) / Double(Self.timescale) }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool { lhs.ticks < rhs.ticks }
    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime { MediaTime(ticks: lhs.ticks + rhs.ticks) }
    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime { MediaTime(ticks: lhs.ticks - rhs.ticks) }
    public static func += (lhs: inout MediaTime, rhs: MediaTime) { lhs.ticks += rhs.ticks }
    public static func -= (lhs: inout MediaTime, rhs: MediaTime) { lhs.ticks -= rhs.ticks }

    /// `mm:ss` or `h:mm:ss`; with `fractional`, appends tenths (`mm:ss.s`).
    public func formatted(fractional: Bool = false) -> String {
        let negative = ticks < 0
        let totalTenths = Int64((abs(seconds) * 10).rounded(.down))
        let tenths = totalTenths % 10
        let totalSeconds = totalTenths / 10
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        var text = h > 0
            ? String(format: "%lld:%02lld:%02lld", h, m, s)
            : String(format: "%02lld:%02lld", m, s)
        if fractional { text += ".\(tenths)" }
        return negative ? "-" + text : text
    }
}

extension MediaTime: Codable {
    /// Encoded as seconds for readable project files and LLM-friendly JSON.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(seconds: try container.decode(Double.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }
}

extension MediaTime: CustomStringConvertible {
    public var description: String { formatted(fractional: true) }
}

/// Half-open range `[start, end)`.
public struct TimeRange: Codable, Hashable, Sendable {
    public var start: MediaTime
    public var end: MediaTime

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.end = end
    }

    public init(start: MediaTime, duration: MediaTime) {
        self.init(start: start, end: start + duration)
    }

    public init(seconds start: Double, _ end: Double) {
        self.init(start: MediaTime(seconds: start), end: MediaTime(seconds: end))
    }

    public var duration: MediaTime { end - start }
    public var isEmpty: Bool { end <= start }

    public func contains(_ time: MediaTime) -> Bool { time >= start && time < end }

    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let r = TimeRange(start: max(start, other.start), end: min(end, other.end))
        return r.isEmpty ? nil : r
    }

    public func clamped(to bounds: TimeRange) -> TimeRange {
        TimeRange(start: min(max(start, bounds.start), bounds.end), end: max(min(end, bounds.end), bounds.start))
    }

    public func offset(by delta: MediaTime) -> TimeRange {
        TimeRange(start: start + delta, end: end + delta)
    }

    public func formatted() -> String { "\(start.formatted()) – \(end.formatted())" }
}

extension TimeRange: CustomStringConvertible {
    public var description: String { "[\(start) – \(end))" }
}

extension Array where Element == TimeRange {
    /// Sorts and merges ranges whose gap is at most `gap`.
    public func merged(gap: MediaTime = .zero) -> [TimeRange] {
        let sorted = self.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var result: [TimeRange] = []
        for range in sorted {
            if let last = result.last, range.start - last.end <= gap {
                result[result.count - 1].end = Swift.max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
