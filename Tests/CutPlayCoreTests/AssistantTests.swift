import XCTest
@testable import CutPlayCore

final class IntentParsingTests: XCTestCase {
    let planner = RuleBasedPlanner()

    func testSilence() {
        XCTAssertEqual(planner.intent(for: "刪掉所有停頓"), .removeSilence(minimum: MediaTime(seconds: 0.8)))
        XCTAssertEqual(planner.intent(for: "把超過 1.5 秒的空白剪掉"), .removeSilence(minimum: MediaTime(seconds: 1.5)))
    }

    func testTopicWithPosition() {
        XCTAssertEqual(planner.intent(for: "把講到電池續航的段落挑出來，排在片頭後面"),
                       .findTopic("電池續航", action: .insert(.afterFirstClip)))
        XCTAssertEqual(planner.intent(for: "找出提到價格的地方"), .findTopic("價格", action: .select))
        XCTAssertEqual(planner.intent(for: "只留關於散熱的部分"), .findTopic("散熱", action: .keepOnly))
    }

    func testSpeakerMoveSelectionExport() {
        XCTAssertEqual(planner.intent(for: "只留講者 b"), .keepSpeaker("B"))
        XCTAssertEqual(planner.intent(for: "把第二段移到最前面"), .moveClip(ordinal: 2, toStart: true))
        XCTAssertEqual(planner.intent(for: "刪掉這段", hasSelection: true), .actOnSelection(.remove))
        XCTAssertNil(planner.intent(for: "刪掉這段", hasSelection: false).flatMap { if case .actOnSelection = $0 { return $0 }; return nil })
        XCTAssertEqual(planner.intent(for: "匯出 4K"), .exportOnly)
        XCTAssertEqual(planner.intent(for: "做一支 30 秒精華"), .highlightReel)
        XCTAssertNil(planner.intent(for: "今天天氣如何"))
    }

    func testChineseNumbers() {
        XCTAssertEqual(ChineseNumber.parse("三"), 3)
        XCTAssertEqual(ChineseNumber.parse("十二"), 12)
        XCTAssertEqual(ChineseNumber.parse("二十"), 20)
        XCTAssertEqual(ChineseNumber.parse("7"), 7)
    }
}

final class RuleBasedPlannerTests: XCTestCase {
    func context(selection: AssetRange? = nil) -> PlannerContext {
        PlannerContext(project: Fixtures.project(), index: Fixtures.index(), selection: selection)
    }

    func testTopicCandidatesAreMergedSnappedAndRanked() async throws {
        let reply = try await RuleBasedPlanner().reply(to: "把講到電池續航的段落挑出來，排在片頭後面", context: context())
        guard case .proposal(let p, let message) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(p.action, .insert(.afterFirstClip))
        // tr3 is an exact match; tr4 ("續航") partially matches and is merged with tr3; snapped to scene cuts.
        let first = try XCTUnwrap(p.candidates.first)
        XCTAssertEqual(first.range, Fixtures.r(244.8, 291.5))
        XCTAssertEqual(first.level, .high)
        XCTAssertTrue(first.isSelected)
        XCTAssertTrue(message.contains("電池續航"))
    }

    func testSilenceCandidatesRespectMinimumAndPadding() async throws {
        let reply = try await RuleBasedPlanner().reply(to: "刪掉所有停頓", context: context())
        guard case .proposal(let p, _) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(p.action, .remove)
        XCTAssertEqual(p.candidates.map(\.range), [Fixtures.r(100.15, 101.05), Fixtures.r(200.15, 201.85)])
    }

    func testUnknownSpeakerAsksForClarification() async throws {
        let reply = try await RuleBasedPlanner().reply(to: "只留講者 C", context: context())
        guard case .clarification(_, let options) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(options, ["只留講者A", "只留講者B", "只留觀眾"])
    }

    func testNoMatch() async throws {
        let reply = try await RuleBasedPlanner().reply(to: "找出提到防水的地方", context: context())
        guard case .notFound = reply else { return XCTFail("\(reply)") }
    }
}

final class EditorSessionTests: XCTestCase {
    func session(autoApply: Bool) -> EditorSession {
        EditorSession(project: Fixtures.project(), index: Fixtures.index(), policy: AutoApplyPolicy(isEnabled: autoApply))
    }

    func lastProposalState(_ s: EditorSession) -> ChatMessage.ProposalState? {
        guard case .proposal(_, _, let state) = s.messages.last?.content else { return nil }
        return state
    }

    func testCheckboxOffRequiresConfirmation() async {
        let s = session(autoApply: false)
        await s.send("刪掉所有停頓")
        guard case .pending = lastProposalState(s) else { return XCTFail("\(String(describing: lastProposalState(s)))") }
        XCTAssertEqual(s.project.sequence.duration, MediaTime(seconds: 610))

        s.apply(messageID: s.messages.last!.id)
        guard case .applied(_, false) = lastProposalState(s) else { return XCTFail() }
        XCTAssertEqual(s.project.sequence.duration, MediaTime(seconds: 610 - 0.9 - 1.7))
    }

    func testCheckboxOnAutoAppliesHighConfidence() async {
        let s = session(autoApply: true)
        await s.send("刪掉所有停頓")
        guard case .applied(let undoID, true) = lastProposalState(s) else { return XCTFail("\(String(describing: lastProposalState(s)))") }
        XCTAssertNotNil(undoID)
        XCTAssertEqual(s.undo(messageID: s.messages.last!.id), .undone)
        XCTAssertEqual(s.project.sequence.duration, MediaTime(seconds: 610))
        guard case .undone = lastProposalState(s) else { return XCTFail() }
    }

    func testCheckboxOnStillConfirmsMediumCandidates() async {
        let s = session(autoApply: true)
        await s.send("把講到電池續航的段落放到最後")
        guard case .pending(let reasons) = lastProposalState(s) else { return XCTFail("\(String(describing: lastProposalState(s)))") }
        XCTAssertEqual(reasons, [AutoApplyPolicy.Reason.lowConfidence.message])
        // The caption-only match is medium confidence and unchecked by default.
        guard case .proposal(let p, _, _) = s.messages.last!.content else { return XCTFail() }
        XCTAssertEqual(p.candidates.map(\.level), [.high, .medium])
        XCTAssertEqual(p.candidates.map(\.isSelected), [true, false])
        XCTAssertEqual(s.project.sequence.duration, MediaTime(seconds: 610))
    }

    func testDeselectAllKeepsProposalPending() async {
        let s = session(autoApply: false)
        await s.send("刪掉所有停頓")
        let id = s.messages.last!.id
        guard case .proposal(let p, _, _) = s.messages.last!.content else { return XCTFail() }
        for c in p.candidates { s.setCandidate(c.id, selected: false, in: id) }
        guard case .pending(let reasons) = lastProposalState(s) else { return XCTFail() }
        XCTAssertEqual(reasons, ["沒有選取任何片段"])
        s.setCandidate(p.candidates[0].id, selected: true, in: id)
        s.apply(messageID: id)
        XCTAssertEqual(s.project.sequence.duration, MediaTime(seconds: 610 - 0.9))
    }

    func testUndoFromOlderMessageIsRefused() async {
        let s = session(autoApply: true)
        await s.send("刪掉所有停頓")
        let first = s.messages.last!.id
        s.appendToTimeline(Fixtures.introID)
        XCTAssertEqual(s.undo(messageID: first), .notLatest)
    }

    func testExportIsQueuedWithoutConfirmation() async {
        let s = session(autoApply: false)
        await s.send("匯出成社群影片")
        XCTAssertEqual(s.takePendingExports(), [.social1080p])
    }

    func testSelectionCommand() async {
        let s = session(autoApply: false)
        await s.send("刪掉這段", selection: AssetRange(assetID: Fixtures.keynoteID, range: Fixtures.r(10, 20)))
        s.apply(messageID: s.messages.last!.id)
        XCTAssertEqual(s.project.sequence.duration, MediaTime(seconds: 600))
    }
}

final class LLMPlannerTests: XCTestCase {
    struct MockTransport: ChatCompletionTransport {
        var response: String
        func complete(_ messages: [LLMMessage]) async throws -> String { response }
    }

    func context() -> PlannerContext {
        PlannerContext(project: Fixtures.project(), index: Fixtures.index())
    }

    func testGroundsAndClampsToEvidence() async throws {
        let json = """
        好的：```json
        {"type":"proposal","message":"找到兩段","action":"insert","position":"start",
         "candidates":[
           {"evidence_ids":["tr3"],"start":200,"end":259.6,"confidence":0.9,"reason":"電池"},
           {"evidence_ids":["made-up"],"start":1,"end":2,"confidence":0.99}
         ],"export":"high4K"}
        ```
        """
        let reply = try await LLMPlanner(transport: MockTransport(response: json)).reply(to: "開場那段電池的", context: context())
        guard case .proposal(let p, let message) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(message, "找到兩段")
        XCTAssertEqual(p.candidates.count, 1, "candidates citing unknown evidence are dropped")
        XCTAssertEqual(p.candidates[0].range, Fixtures.r(244.5, 259.6), "start is clamped to evidence minus slack")
        XCTAssertEqual(p.action, .insert(.start))
        XCTAssertEqual(p.trailingOperations, [.export(.high4K)])
    }

    func testClarification() async throws {
        let json = #"{"type":"clarification","question":"你是指哪一段？","options":["04:05","07:08"]}"#
        let reply = try await LLMPlanner(transport: MockTransport(response: json)).reply(to: "那段", context: context())
        XCTAssertEqual(reply, .clarification(question: "你是指哪一段？", options: ["04:05", "07:08"]))
    }

    func testInvalidJSONThrows() async {
        do {
            _ = try await LLMPlanner(transport: MockTransport(response: "not json")).reply(to: "x", context: context())
            XCTFail("expected throw")
        } catch {}
    }

    func testHybridRoutesUnknownRequestsToLLM() async throws {
        let llm = LLMPlanner(transport: MockTransport(response: #"{"type":"info","message":"from llm"}"#))
        let hybrid = HybridPlanner(llm: llm)
        let a = try await hybrid.reply(to: "幫我做得更有節奏感", context: context())
        XCTAssertEqual(a, .info("from llm"))
        let b = try await hybrid.reply(to: "刪掉所有停頓", context: context())
        guard case .proposal = b else { return XCTFail("rules should handle known intents") }
    }
}
