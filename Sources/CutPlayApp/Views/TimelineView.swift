#if os(macOS)
import SwiftUI
import CutPlayCore

@MainActor
struct TimelineView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var pixelsPerSecond: CGFloat = 24

    var duration: MediaTime { max(editor.project.sequence.duration, MediaTime(seconds: 30)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("時間軸").font(.headline)
                Spacer()
                Text("顯示：").foregroundStyle(.secondary)
                ForEach(editor.project.settings.visibleAnalysisLanes, id: \.self) { kind in
                    Text(kind.displayName).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary).clipShape(Capsule())
                }
                Menu("＋ 更多") {
                    ForEach(SegmentKind.allCases, id: \.self) { kind in
                        let on = editor.project.settings.visibleAnalysisLanes.contains(kind)
                        Button(on ? "隱藏\(kind.displayName)" : "顯示\(kind.displayName)") {
                            editor.session.updateSettings { s in
                                if on { s.visibleAnalysisLanes.removeAll { $0 == kind } }
                                else { s.visibleAnalysisLanes.append(kind) }
                            }
                        }
                    }
                }
                Slider(value: $pixelsPerSecond, in: 8...80).frame(width: 100)
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)

            GeometryReader { geo in
                ScrollView([.horizontal]) {
                    let width = max(geo.size.width, CGFloat(duration.seconds) * pixelsPerSecond + 120)
                    HStack(alignment: .top, spacing: 0) {
                        labels.frame(width: 96)
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 6) {
                                ruler(width: width - 96)
                                clipLane(width: width - 96, video: true)
                                clipLane(width: width - 96, video: false)
                                ForEach(editor.project.settings.visibleAnalysisLanes, id: \.self) { kind in
                                    analysisLane(kind, width: width - 96)
                                }
                            }
                            playhead(height: geo.size.height)
                            candidates(width: width - 96)
                        }
                    }
                    .frame(width: width, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        let x = value.location.x - 96
                        editor.seek(MediaTime(seconds: max(0, Double(x / pixelsPerSecond))))
                    })
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
    }

    var labels: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: 18)
            label("影片", "film")
            label("聲音", "speaker.wave.2")
            ForEach(editor.project.settings.visibleAnalysisLanes, id: \.self) { kind in
                Text("✦ \(kind.displayName)").font(.caption).foregroundStyle(.cyan).frame(height: 28)
            }
        }
        .padding(.leading, 12)
    }

    func label(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.caption).frame(height: 34, alignment: .leading)
    }

    func ruler(width: CGFloat) -> some View {
        Canvas { ctx, size in
            let step: Double = pixelsPerSecond > 40 ? 1 : pixelsPerSecond > 16 ? 5 : 10
            var t = 0.0
            while t <= duration.seconds {
                let x = t * pixelsPerSecond
                var text = ctx.resolve(Text(MediaTime(seconds: t).formatted()).font(.system(size: 10)).foregroundColor(.secondary))
                ctx.draw(text, at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                t += step
            }
        }
        .frame(width: width, height: 18)
    }

    func clipLane(width: CGFloat, video: Bool) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)).frame(height: 34)
            ForEach(editor.project.sequence.placements, id: \.clip.id) { p in
                let x = CGFloat(p.timelineRange.start.seconds) * pixelsPerSecond
                let w = max(CGFloat(p.timelineRange.duration.seconds) * pixelsPerSecond - 2, 4)
                RoundedRectangle(cornerRadius: 4)
                    .fill(video
                          ? (editor.session.highlightedClipIDs.contains(p.clip.id) ? Color.accentColor : Color(red: 0.24, green: 0.35, blue: 0.50))
                          : Color(red: 0.18, green: 0.42, blue: 0.30))
                    .overlay(alignment: .leading) {
                        if video {
                            Text(p.clip.label ?? editor.project.asset(p.clip.assetID)?.name ?? "")
                                .font(.caption2).foregroundStyle(.white).padding(.horizontal, 6).lineLimit(1)
                        }
                    }
                    .frame(width: w, height: 30)
                    .offset(x: x)
            }
        }
        .frame(width: width, height: 34, alignment: .leading)
    }

    func analysisLane(_ kind: SegmentKind, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)).frame(height: 28)
            ForEach(mapped(kind), id: \.id) { item in
                let x = CGFloat(item.range.start.seconds) * pixelsPerSecond
                let w = max(CGFloat(item.range.duration.seconds) * pixelsPerSecond - 1, kind == .scene ? 2 : 8)
                Rectangle()
                    .fill(kind == .scene ? Color.orange : Color.cyan.opacity(0.25))
                    .frame(width: kind == .scene ? 2 : w, height: 24)
                    .overlay(alignment: .leading) {
                        if kind != .scene {
                            Text(item.text ?? "").font(.system(size: 9)).lineLimit(1).padding(.leading, 4)
                        }
                    }
                    .offset(x: x)
            }
        }
        .frame(width: width, height: 28, alignment: .leading)
    }

    struct Mapped: Identifiable {
        var id: String
        var range: TimeRange
        var text: String?
    }

    func mapped(_ kind: SegmentKind) -> [Mapped] {
        editor.project.sequence.placements.flatMap { p -> [Mapped] in
            editor.index.segments(overlapping: p.clip.sourceRange, assetID: p.clip.assetID, kinds: [kind]).map { s in
                let overlap = s.range.intersection(p.clip.sourceRange) ?? s.range
                let r = TimeRange(start: p.timelineTime(forSource: overlap.start),
                                  end: p.timelineTime(forSource: max(overlap.end, overlap.start)))
                return Mapped(id: "\(p.clip.id)-\(s.id)", range: r, text: s.text)
            }
        }
    }

    func playhead(height: CGFloat) -> some View {
        Rectangle().fill(Color.red).frame(width: 2, height: height)
            .offset(x: CGFloat(editor.playhead.seconds) * pixelsPerSecond)
    }

    func candidates(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if let pending = editor.pendingProposal {
                ForEach(Array(pending.proposal.candidates.enumerated()), id: \.element.id) { i, c in
                    ForEach(editor.project.sequence.timelineRanges(forSource: c.assetID, range: c.range), id: \.start.ticks) { r in
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(c.isSelected ? 0.12 : 0.04))
                            .frame(width: max(CGFloat(r.duration.seconds) * pixelsPerSecond, 8), height: 80)
                            .overlay(alignment: .topLeading) {
                                Text("候選 \(i + 1)").font(.caption2.bold()).padding(3)
                                    .background(Color.accentColor).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .offset(x: CGFloat(r.start.seconds) * pixelsPerSecond, y: 22)
                    }
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .allowsHitTesting(false)
    }
}
#endif
