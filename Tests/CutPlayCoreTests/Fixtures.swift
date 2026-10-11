import Foundation
@testable import CutPlayCore

enum Fixtures {
    static let introID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let keynoteID = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    static func t(_ s: Double) -> MediaTime { MediaTime(seconds: s) }
    static func r(_ a: Double, _ b: Double) -> TimeRange { TimeRange(seconds: a, b) }

    /// Intro (10 s) + keynote (600 s) on the timeline; keynote has a transcript, scenes and pauses.
    static func project() -> Project {
        let intro = MediaAsset(id: introID, sourceURL: URL(fileURLWithPath: "/media/logo.mov"), duration: t(10), analysis: .done)
        let keynote = MediaAsset(id: keynoteID, sourceURL: URL(fileURLWithPath: "/media/keynote.mov"), duration: t(600), analysis: .done)
        var p = Project(name: "測試", assets: [intro, keynote])
        p.sequence.clips = [
            TimelineClip(assetID: introID, sourceRange: intro.fullRange, label: "片頭"),
            TimelineClip(assetID: keynoteID, sourceRange: keynote.fullRange),
        ]
        return p
    }

    static func index() -> AnalysisIndex {
        let k = keynoteID
        return AnalysisIndex(segments: [
            AnalysisSegment(id: "tr1", assetID: k, kind: .transcript, range: r(0, 15), text: "歡迎大家來到今天的發表會", speaker: "講者A"),
            AnalysisSegment(id: "tr2", assetID: k, kind: .transcript, range: r(238, 245), text: "好，價格的部分我們等一下再公布。", speaker: "講者A"),
            AnalysisSegment(id: "tr3", assetID: k, kind: .transcript, range: r(245, 259.6), text: "接下來我們來看電池續航的實測數據", speaker: "講者A"),
            AnalysisSegment(id: "tr4", assetID: k, kind: .transcript, range: r(259.6, 291.3), text: "相比上一代，續航多了整整四個小時", speaker: "講者A"),
            AnalysisSegment(id: "tr5", assetID: k, kind: .transcript, range: r(291.3, 302.8), text: "那我補充一下散熱設計", speaker: "講者B"),
            AnalysisSegment(id: "tr6", assetID: k, kind: .transcript, range: r(428, 446), text: "充電速度呢？電池可以撐多久", speaker: "觀眾"),
            AnalysisSegment(id: "cap1", assetID: k, kind: .caption, range: r(500, 520), text: "電池續航圖表特寫"),
            AnalysisSegment(id: "sc1", assetID: k, kind: .scene, range: r(244.8, 244.8)),
            AnalysisSegment(id: "sc2", assetID: k, kind: .scene, range: r(291.5, 291.5)),
            AnalysisSegment(id: "sil1", assetID: k, kind: .silence, range: r(100, 101.2), confidence: 0.95),
            AnalysisSegment(id: "sil2", assetID: k, kind: .silence, range: r(200, 202), confidence: 0.95),
            AnalysisSegment(id: "sil3", assetID: k, kind: .silence, range: r(300, 300.5), confidence: 0.95),
        ])
    }
}
