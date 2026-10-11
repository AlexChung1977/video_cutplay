import Foundation

public enum TimelineEditError: Error, Equatable {
    case timeOutOfBounds(MediaTime)
    case clipNotFound(UUID)
    case emptyRange
}

extension EditSequence {
    /// Ensures there is a clip boundary at `time` and returns the index of the clip that starts there
    /// (`clips.count` when `time` is the end of the sequence).
    @discardableResult
    public mutating func split(at time: MediaTime) throws -> Int {
        guard time >= .zero, time <= duration else { throw TimelineEditError.timeOutOfBounds(time) }
        for p in placements {
            if p.timelineRange.start == time { return p.index }
            if p.timelineRange.contains(time) {
                let cut = p.sourceTime(at: time)
                var head = p.clip
                head.sourceRange.end = cut
                var tail = p.clip
                tail.id = UUID()
                tail.sourceRange.start = cut
                clips.replaceSubrange(p.index...p.index, with: [head, tail])
                return p.index + 1
            }
        }
        return clips.count
    }

    /// Inserts clips at a timeline time, pushing later content back. Splits a clip if `time` falls inside it.
    public mutating func insert(_ newClips: [TimelineClip], at time: MediaTime) throws {
        let index = try split(at: time)
        clips.insert(contentsOf: newClips, at: index)
    }

    /// Ripple-deletes a timeline range. Returns the duration actually removed.
    @discardableResult
    public mutating func removeRange(_ range: TimeRange) throws -> MediaTime {
        let bounded = range.clamped(to: TimeRange(start: .zero, end: duration))
        guard !bounded.isEmpty else { return .zero }
        let first = try split(at: bounded.start)
        let last = try split(at: bounded.end)
        clips.removeSubrange(first..<last)
        return bounded.duration
    }

    /// Ripple-deletes every timeline occurrence of a source range. Returns the total duration removed.
    @discardableResult
    public mutating func removeSource(assetID: UUID, range: TimeRange) throws -> MediaTime {
        var removed = MediaTime.zero
        for timelineRange in timelineRanges(forSource: assetID, range: range).reversed() {
            removed += try removeRange(timelineRange)
        }
        return removed
    }

    /// Keeps only the parts of existing clips that fall inside `keep` (per asset), in timeline order.
    /// Returns the duration removed.
    @discardableResult
    public mutating func keepOnly(_ keep: [AssetRange]) -> MediaTime {
        let before = duration
        var result: [TimelineClip] = []
        for clip in clips {
            let ranges = keep.filter { $0.assetID == clip.assetID }.map(\.range).merged()
            for r in ranges {
                guard let overlap = clip.sourceRange.intersection(r) else { continue }
                var piece = clip
                piece.id = result.contains { $0.id == clip.id } ? UUID() : clip.id
                piece.sourceRange = overlap
                result.append(piece)
            }
        }
        clips = result
        return before - duration
    }

    public mutating func moveClip(_ id: UUID, to index: Int) throws {
        guard let from = clips.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.clipNotFound(id) }
        let clip = clips.remove(at: from)
        clips.insert(clip, at: min(max(index, 0), clips.count))
    }
}
