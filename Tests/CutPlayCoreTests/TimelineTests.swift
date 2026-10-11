import XCTest
@testable import CutPlayCore

final class MediaTimeTests: XCTestCase {
    func testRoundTripAndFormatting() {
        XCTAssertEqual(MediaTime(seconds: 1.5).ticks, 135_000)
        XCTAssertEqual(MediaTime(seconds: 245).formatted(), "04:05")
        XCTAssertEqual(MediaTime(seconds: 3725.25).formatted(fractional: true), "1:02:05.2")
    }

    func testCodableAsSeconds() throws {
        let data = try JSONEncoder().encode(TimeRange(seconds: 1.5, 3))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("1.5"))
        XCTAssertEqual(try JSONDecoder().decode(TimeRange.self, from: data), TimeRange(seconds: 1.5, 3))
    }

    func testMergeRanges() {
        let merged = [TimeRange(seconds: 5, 6), TimeRange(seconds: 0, 1), TimeRange(seconds: 1.5, 2)].merged(gap: MediaTime(seconds: 0.5))
        XCTAssertEqual(merged, [TimeRange(seconds: 0, 2), TimeRange(seconds: 5, 6)])
    }
}

final class TimelineEditingTests: XCTestCase {
    let a = UUID()

    func sequence() -> EditSequence {
        EditSequence(clips: [
            TimelineClip(assetID: a, sourceRange: TimeRange(seconds: 0, 10)),
            TimelineClip(assetID: a, sourceRange: TimeRange(seconds: 20, 30)),
        ])
    }

    func testSplitInsideClip() throws {
        var s = sequence()
        let index = try s.split(at: MediaTime(seconds: 4))
        XCTAssertEqual(index, 1)
        XCTAssertEqual(s.clips.map(\.sourceRange), [TimeRange(seconds: 0, 4), TimeRange(seconds: 4, 10), TimeRange(seconds: 20, 30)])
        XCTAssertEqual(s.duration, MediaTime(seconds: 20))
    }

    func testInsertPushesLaterClipsBack() throws {
        var s = sequence()
        let b = UUID()
        try s.insert([TimelineClip(assetID: b, sourceRange: TimeRange(seconds: 0, 5))], at: MediaTime(seconds: 10))
        XCTAssertEqual(s.clips.map(\.assetID), [a, b, a])
        XCTAssertEqual(s.placements[2].timelineRange, TimeRange(seconds: 15, 25))
    }

    func testRippleRemoveAcrossClips() throws {
        var s = sequence()
        let removed = try s.removeRange(TimeRange(seconds: 8, 12))
        XCTAssertEqual(removed, MediaTime(seconds: 4))
        XCTAssertEqual(s.clips.map(\.sourceRange), [TimeRange(seconds: 0, 8), TimeRange(seconds: 22, 30)])
        XCTAssertEqual(s.duration, MediaTime(seconds: 16))
    }

    func testRemoveSourceRangeOnlyWhereVisible() throws {
        var s = sequence()
        let removed = try s.removeSource(assetID: a, range: TimeRange(seconds: 5, 25))
        XCTAssertEqual(removed, MediaTime(seconds: 10))
        XCTAssertEqual(s.clips.map(\.sourceRange), [TimeRange(seconds: 0, 5), TimeRange(seconds: 25, 30)])
    }

    func testKeepOnly() {
        var s = sequence()
        s.keepOnly([AssetRange(assetID: a, range: TimeRange(seconds: 2, 3)), AssetRange(assetID: a, range: TimeRange(seconds: 6, 22))])
        XCTAssertEqual(s.clips.map(\.sourceRange), [TimeRange(seconds: 2, 3), TimeRange(seconds: 6, 10), TimeRange(seconds: 20, 22)])
        XCTAssertEqual(Set(s.clips.map(\.id)).count, 3)
    }

    func testTimelineRangesForSource() {
        let s = sequence()
        XCTAssertEqual(s.timelineRanges(forSource: a, range: TimeRange(seconds: 9, 21)),
                       [TimeRange(seconds: 9, 10), TimeRange(seconds: 10, 11)])
    }
}

final class EditApplicatorTests: XCTestCase {
    func testInsertAfterIntro() throws {
        let p = Fixtures.project()
        let plan = EditPlan(summary: "", operations: [
            PlannedOperation(.insertClips([AssetRange(assetID: Fixtures.keynoteID, range: Fixtures.r(245, 291.3))], position: .afterFirstClip), confidence: 0.9),
        ])
        let result = try EditApplicator.apply(plan, to: p)
        XCTAssertEqual(result.project.sequence.clips.count, 3)
        XCTAssertEqual(result.project.sequence.clips[1].sourceRange, Fixtures.r(245, 291.3))
        XCTAssertEqual(result.project.sequence.clips[1].origin, .assistant)
        XCTAssertEqual(result.effects.affectedSegments, 1)
        XCTAssertEqual(p.sequence.clips.count, 2, "apply must not mutate its input")
    }

    func testValidationRejectsOutOfBounds() {
        let plan = EditPlan(summary: "", operations: [
            PlannedOperation(.removeSourceRange(AssetRange(assetID: Fixtures.introID, range: Fixtures.r(5, 50))), confidence: 1),
        ])
        XCTAssertThrowsError(try EditApplicator.apply(plan, to: Fixtures.project())) { error in
            guard case ValidationIssue.rangeOutsideAsset = error else { return XCTFail("\(error)") }
        }
    }

    func testValidationRejectsUnknownAsset() {
        let plan = EditPlan(summary: "", operations: [
            PlannedOperation(.insertClips([AssetRange(assetID: UUID(), range: Fixtures.r(0, 1))], position: .end), confidence: 1),
        ])
        XCTAssertEqual(EditPlanValidator.validate(plan, in: Fixtures.project()).count, 1)
    }
}

final class AutoApplyPolicyTests: XCTestCase {
    func plan(confidence: Double) -> EditPlan {
        EditPlan(summary: "", operations: [
            PlannedOperation(.removeTimelineRange(Fixtures.r(0, 1)), confidence: confidence),
        ])
    }

    func effects(removed: Double = 1, segments: Int = 1) -> EditEffects {
        var e = EditEffects()
        e.removedDuration = MediaTime(seconds: removed)
        e.affectedSegments = segments
        return e
    }

    func testDisabledAlwaysConfirms() {
        XCTAssertEqual(AutoApplyPolicy(isEnabled: false).evaluate(plan(confidence: 0.99), effects: effects()),
                       .needsConfirmation([.disabled]))
    }

    func testHighConfidenceSmallEditAutoApplies() {
        XCTAssertEqual(AutoApplyPolicy(isEnabled: true).evaluate(plan(confidence: 0.9), effects: effects()), .autoApply)
    }

    func testAnyMediumOperationBlocksWholePlan() {
        var p = plan(confidence: 0.95)
        p.operations.append(PlannedOperation(.removeTimelineRange(Fixtures.r(2, 3)), confidence: 0.6))
        XCTAssertEqual(AutoApplyPolicy(isEnabled: true).evaluate(p, effects: effects()), .needsConfirmation([.lowConfidence]))
    }

    func testGuardrails() {
        let policy = AutoApplyPolicy(isEnabled: true)
        XCTAssertEqual(policy.evaluate(plan(confidence: 0.9), effects: effects(removed: 31)),
                       .needsConfirmation([.removesTooMuch(MediaTime(seconds: 31))]))
        XCTAssertEqual(policy.evaluate(plan(confidence: 0.9), effects: effects(segments: 6)),
                       .needsConfirmation([.touchesTooManySegments(6)]))
    }
}

final class UndoHistoryTests: XCTestCase {
    func testUndoRedo() {
        var h = UndoHistory()
        let s0 = EditSequence(), s1 = EditSequence(name: "1")
        let id = h.record(label: "x", before: s0, after: s1)
        XCTAssertTrue(h.isLatest(id))
        XCTAssertEqual(h.undo()?.before, s0)
        XCTAssertFalse(h.canUndo)
        XCTAssertEqual(h.redo()?.after, s1)
    }
}

final class ProjectStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cutplay")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(url: dir)
        let messages = [ChatMessage.user("刪掉所有停頓")]
        let project = Fixtures.project()
        try store.save(project: project, index: Fixtures.index(), messages: messages)
        let loaded = try store.load()
        XCTAssertEqual(loaded.project.sequence, project.sequence)
        XCTAssertEqual(loaded.project.assets, project.assets)
        XCTAssertEqual(loaded.index.segments.count, Fixtures.index().segments.count)
        XCTAssertEqual(loaded.messages.first?.plainText, "刪掉所有停頓")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cacheDirectory.path))
    }
}
