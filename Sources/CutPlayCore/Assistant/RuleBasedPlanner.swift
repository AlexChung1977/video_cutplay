import Foundation

/// Offline planner for the MVP's core Chinese commands. Works without any model, and is the
/// first stage of `HybridPlanner`: anything it doesn't recognise goes to the LLM when one is configured.
public struct RuleBasedPlanner: EditPlanner {
    public enum Intent: Hashable, Sendable {
        case removeSilence(minimum: MediaTime)
        case findTopic(String, action: CandidateAction)
        case keepSpeaker(String)
        case moveClip(ordinal: Int, toStart: Bool)
        case actOnSelection(CandidateAction)
        case exportOnly
        case highlightReel
    }

    public var defaultMinimumSilence: MediaTime
    /// Padding left at each side of a removed pause so cuts don't feel abrupt.
    public var silencePadding: MediaTime
    public var mergeGap: MediaTime

    public init(defaultMinimumSilence: MediaTime = MediaTime(seconds: 0.8),
                silencePadding: MediaTime = MediaTime(seconds: 0.15),
                mergeGap: MediaTime = MediaTime(seconds: 2)) {
        self.defaultMinimumSilence = defaultMinimumSilence
        self.silencePadding = silencePadding
        self.mergeGap = mergeGap
    }

    public static let suggestions = ["刪掉所有停頓", "把講到〇〇的段落排在片頭後面", "只留講者 B", "匯出成社群影片"]

    // MARK: - Intent parsing

    public func intent(for text: String, hasSelection: Bool = false) -> Intent? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsRemove = t.matches("(刪|去掉|拿掉|剪掉|移除|不要)")
        let wantsKeepOnly = t.matches("(只留|只保留|只要)")
        let insertPosition = Self.insertPosition(in: t)

        if hasSelection, t.matches("(這段|這一段|選取|選起來|選的)") {
            if wantsKeepOnly { return .actOnSelection(.keepOnly) }
            if wantsRemove { return .actOnSelection(.remove) }
            if let p = insertPosition { return .actOnSelection(.insert(p)) }
        }

        if t.matches("(停頓|空白|靜音|沒聲音|沒有聲音|安靜)"), wantsRemove {
            var minimum = defaultMinimumSilence
            if let n = t.firstCapture("(?:超過|大於|長於|多於)\\s*(\\d+(?:\\.\\d+)?)\\s*秒").flatMap(Double.init) {
                minimum = MediaTime(seconds: n)
            }
            return .removeSilence(minimum: minimum)
        }

        if wantsKeepOnly, let speaker = t.firstCapture("(?:講者|說話者|發言人)\\s*([A-Za-z0-9一二三四五六七八九]+)") {
            return .keepSpeaker(speaker.uppercased())
        }

        if let (ordinal, toStart) = Self.moveRequest(in: t) {
            return .moveClip(ordinal: ordinal, toStart: toStart)
        }

        if t.matches("(精華|預告|highlight)") {
            return .highlightReel
        }

        if let topic = Self.topic(in: t) {
            let action: CandidateAction
            if let p = insertPosition { action = .insert(p) }
            else if wantsKeepOnly { action = .keepOnly }
            else if wantsRemove { action = .remove }
            else { action = .select }
            return .findTopic(topic, action: action)
        }

        if Self.exportPreset(in: t) != nil { return .exportOnly }
        return nil
    }

    static func insertPosition(in t: String) -> InsertPosition? {
        guard t.matches("(排在|放在|放到|接在|插在|加到|移到|排到)") else { return nil }
        if t.matches("片頭(之)?後") { return .afterFirstClip }
        if t.matches("(最前|開頭|一開始)") { return .start }
        if t.matches("(最後|結尾|片尾)") { return .end }
        return nil
    }

    static func topic(in t: String) -> String? {
        let stop = "(?:的段落|的部分|的片段|的地方|的內容|那段|那些|的|，|,|。|、|然後|並|$)"
        for pattern in ["(?:講到|提到|談到|說到|聊到|關於|有關)\\s*「?(.+?)」?\\s*" + stop,
                        "(?:找出|挑出|找到|挑|找)\\s*「?(.+?)」?\\s*" + stop] {
            if let c = t.firstCapture(pattern)?.trimmingCharacters(in: .whitespaces), !c.isEmpty, c.count <= 20 {
                return c
            }
        }
        return nil
    }

    static func exportPreset(in t: String) -> ExportPreset? {
        guard t.matches("(匯出|輸出|導出|export)") else { return nil }
        if t.matches("(4k|4K|高畫質)") { return .high4K }
        if t.matches("(只要聲音|音訊|音檔|聲音檔|mp3|m4a)") { return .audioOnly }
        return .social1080p
    }

    static func moveRequest(in t: String) -> (Int, Bool)? {
        guard let n = t.firstCapture("第\\s*([一二三四五六七八九十0-9]+)\\s*(?:段|個片段|個|支)"),
              let ordinal = ChineseNumber.parse(n), t.matches("(移到|放到|搬到|挪到|排到)") else { return nil }
        if t.matches("(最前|開頭)") { return (ordinal, true) }
        if t.matches("(最後|結尾)") { return (ordinal, false) }
        return nil
    }

    // MARK: - Planning

    public func reply(to text: String, context: PlannerContext) async throws -> PlannerReply {
        guard let intent = intent(for: text, hasSelection: context.selection != nil) else {
            return .notFound(message: "我還不太懂這個要求。可以換個說法，或試試下面這些：", suggestions: Self.suggestions)
        }
        let export = Self.exportPreset(in: text).map { [EditOperation.export($0)] } ?? []
        let note = Self.incompleteAnalysisNote(context.project)

        switch intent {
        case .removeSilence(let minimum):
            return removeSilence(minimum: minimum, context: context, trailing: export, note: note)
        case .findTopic(let topic, let action):
            return findTopic(topic, action: action, context: context, trailing: export, note: note)
        case .keepSpeaker(let speaker):
            return keepSpeaker(speaker, context: context, trailing: export, note: note)
        case .moveClip(let ordinal, let toStart):
            return moveClip(ordinal: ordinal, toStart: toStart, context: context)
        case .actOnSelection(let action):
            guard let sel = context.selection else { return .info("請先在時間軸或逐字稿上選一段。") }
            let c = Candidate(id: "selection", assetID: sel.assetID, range: sel.range, confidence: 1.0, reason: "你選取的範圍")
            let proposal = PlanProposal(candidates: [c], action: action, trailingOperations: export)
            return .proposal(proposal, message: "好，針對你選取的 \(sel.range.formatted())：")
        case .exportOnly:
            guard !context.project.sequence.clips.isEmpty else { return .info("時間軸上還沒有片段，沒有東西可以匯出。") }
            return .proposal(PlanProposal(candidates: [], action: .select, trailingOperations: export), message: "好，準備匯出。")
        case .highlightReel:
            return .info("自動做精華影片的功能還在開發中。現在可以先說「把講到〇〇的段落挑出來」，再把想要的段落排進時間軸。")
        }
    }

    private func removeSilence(minimum: MediaTime, context: PlannerContext, trailing: [EditOperation], note: String) -> PlannerReply {
        guard !context.project.sequence.clips.isEmpty else { return .info("時間軸上還沒有片段。先把素材拖到時間軸，再請我刪停頓。") }
        guard context.index.hasAnalysis(.silence) else {
            return .notFound(message: "停頓分析還沒完成，等分析好再試一次。", suggestions: [])
        }
        let sequence = context.project.sequence
        let onTimeline = Set(sequence.clips.map(\.assetID))
        var candidates: [Candidate] = []
        for s in context.index.segments(.silence) where onTimeline.contains(s.assetID) && s.range.duration >= minimum {
            if let sel = context.selection, sel.assetID != s.assetID || !sel.range.overlaps(s.range) { continue }
            var r = s.range
            if r.duration > silencePadding + silencePadding + MediaTime(seconds: 0.2) {
                r = TimeRange(start: r.start + silencePadding, end: r.end - silencePadding)
            }
            guard !sequence.timelineRanges(forSource: s.assetID, range: r).isEmpty else { continue }
            let name = context.project.asset(s.assetID)?.name ?? ""
            candidates.append(Candidate(id: s.id, assetID: s.assetID, range: r, confidence: s.confidence ?? 0.95,
                                        reason: "\(name) 停頓 \(PlanProposal.describe(s.range.duration))",
                                        evidenceIDs: [s.id], isSelected: true))
        }
        guard !candidates.isEmpty else {
            return .notFound(message: "時間軸上沒有超過 \(PlanProposal.describe(minimum)) 的停頓。", suggestions: ["刪掉超過 0.5 秒的停頓"])
        }
        let total = candidates.reduce(MediaTime.zero) { $0 + $1.range.duration }
        let proposal = PlanProposal(candidates: candidates, action: .remove, trailingOperations: trailing)
        return .proposal(proposal, message: "找到 \(candidates.count) 段停頓，共 \(PlanProposal.describe(total))。" + note)
    }

    private func findTopic(_ topic: String, action: CandidateAction, context: PlannerContext,
                           trailing: [EditOperation], note: String) -> PlannerReply {
        guard context.index.hasAnalysis(.transcript) || context.index.hasAnalysis(.caption) else {
            return .notFound(message: "逐字稿還沒好，等分析完成後我才能找內容。", suggestions: [])
        }
        let candidates = TopicMatcher.candidates(for: topic, in: context.index, project: context.project, mergeGap: mergeGap)
        guard !candidates.isEmpty else {
            return .notFound(message: "沒找到提到「\(topic)」的地方。", suggestions: ["換個關鍵字試試", "找出畫面裡有\(topic)的片段"])
        }
        let proposal = PlanProposal(candidates: candidates, action: action, trailingOperations: trailing)
        let high = candidates.filter { $0.level == .high }.count
        var message = "找到 \(candidates.count) 段跟「\(topic)」有關。"
        if high < candidates.count { message += high > 0 ? "前 \(high) 段很確定，其他的請你決定要不要：" : "都不太確定，請你看一下：" }
        return .proposal(proposal, message: message + note)
    }

    private func keepSpeaker(_ speaker: String, context: PlannerContext, trailing: [EditOperation], note: String) -> PlannerReply {
        let speakers = context.index.speakers()
        guard !speakers.isEmpty else {
            return .notFound(message: "逐字稿裡沒有分辨講者，暫時沒辦法只留某個人的段落。", suggestions: [])
        }
        let match = speakers.first { TextNormalizer.normalize($0).hasSuffix(TextNormalizer.normalize(speaker)) }
        guard let match else {
            return .clarification(question: "找不到講者 \(speaker)。你是指哪一位？", options: speakers.map { "只留\($0)" })
        }
        var candidates: [Candidate] = []
        let byAsset = Dictionary(grouping: context.index.segments(.transcript).filter { $0.speaker == match }, by: \.assetID)
        for (assetID, segs) in byAsset {
            for r in segs.map(\.range).merged(gap: MediaTime(seconds: 1.5)) {
                let ids = segs.filter { $0.range.overlaps(r) }.map(\.id)
                let text = segs.first { $0.range.overlaps(r) }?.text ?? ""
                candidates.append(Candidate(assetID: assetID, range: r, confidence: 0.9, reason: "\(match)：「\(text.prefix(24))」",
                                            evidenceIDs: ids, isSelected: true))
            }
        }
        candidates.sort { $0.range.start < $1.range.start }
        let proposal = PlanProposal(candidates: candidates, action: .keepOnly, trailingOperations: trailing)
        return .proposal(proposal, message: "\(match) 一共有 \(candidates.count) 段發言。" + note)
    }

    private func moveClip(ordinal: Int, toStart: Bool, context: PlannerContext) -> PlannerReply {
        let clips = context.project.sequence.clips
        guard ordinal >= 1, ordinal <= clips.count else {
            return .info("時間軸上只有 \(clips.count) 個片段。")
        }
        let clip = clips[ordinal - 1]
        let name = context.project.asset(clip.assetID)?.name ?? "片段"
        let c = Candidate(id: clip.id.uuidString, assetID: clip.assetID, range: clip.sourceRange, confidence: 1.0,
                          reason: "第 \(ordinal) 段：\(clip.label ?? name)")
        let proposal = PlanProposal(candidates: [c], action: .move(clipID: clip.id, toIndex: toStart ? 0 : clips.count - 1))
        return .proposal(proposal, message: "把第 \(ordinal) 段移到\(toStart ? "最前面" : "最後面")。")
    }

    static func incompleteAnalysisNote(_ project: Project) -> String {
        let pending = project.assets.filter { !$0.analysis.isFinished }
        guard let first = pending.first else { return "" }
        let more = pending.count > 1 ? " 等 \(pending.count) 個素材" : ""
        return "（\(first.name)\(more)還在分析，結果可能不完整）"
    }
}

/// Turns keyword hits into merged, scene-snapped candidate ranges.
public enum TopicMatcher {
    public static func candidates(for topic: String, in index: AnalysisIndex, project: Project,
                                  mergeGap: MediaTime = MediaTime(seconds: 2), limit: Int = 8) -> [Candidate] {
        let hits = index.search(topic)
        let byAsset = Dictionary(grouping: hits, by: \.segment.assetID)
        var result: [Candidate] = []
        for (assetID, assetHits) in byAsset {
            guard let asset = project.asset(assetID) else { continue }
            let merged = assetHits.map(\.segment.range).merged(gap: mergeGap)
            for r in merged {
                let inside = assetHits.filter { $0.segment.range.overlaps(r) }
                let best = inside.max { $0.score < $1.score }!
                let transcriptBacked = inside.contains { $0.segment.kind == .transcript }
                let confidence = (transcriptBacked ? 0.93 : 0.65) * best.score
                let start = index.snapToSceneCut(r.start, assetID: assetID)
                let end = index.snapToSceneCut(r.end, assetID: assetID)
                let range = TimeRange(start: start, end: max(end, start + MediaTime(seconds: 0.5))).clamped(to: asset.fullRange)
                let text = best.segment.text ?? ""
                let reason = best.segment.kind == .caption ? "畫面：\(text.prefix(24))" : "「\(text.prefix(24))…」"
                // Weak partial hits only extend a strong neighbour; on their own they are noise.
                guard ConfidenceLevel(confidence) != .low else { continue }
                result.append(Candidate(id: inside.map(\.segment.id).joined(separator: "+"), assetID: assetID, range: range,
                                        confidence: confidence, reason: reason, evidenceIDs: inside.map(\.segment.id)))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: project.assets.enumerated().map { ($1.id, $0) })
        result.sort { (order[$0.assetID] ?? 0, $0.range.start.ticks) < (order[$1.assetID] ?? 0, $1.range.start.ticks) }
        return Array(result.sorted { $0.confidence > $1.confidence }.prefix(limit))
            .sorted { (order[$0.assetID] ?? 0, $0.range.start.ticks) < (order[$1.assetID] ?? 0, $1.range.start.ticks) }
    }
}

enum ChineseNumber {
    static func parse(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let digits: [Character: Int] = ["一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if s == "十" { return 10 }
        if s.hasPrefix("十"), let d = s.last.flatMap({ digits[$0] }) { return 10 + d }
        if s.count == 1, let d = digits[s.first!] { return d }
        if s.count == 2, s.last == "十", let d = digits[s.first!] { return d * 10 }
        if s.count == 3, Array(s)[1] == "十", let a = digits[s.first!], let b = digits[s.last!] { return a * 10 + b }
        return nil
    }
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func firstCapture(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
