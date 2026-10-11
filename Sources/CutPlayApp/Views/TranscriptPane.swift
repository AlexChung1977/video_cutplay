#if os(macOS)
import SwiftUI
import CutPlayCore

struct TranscriptPane: View {
    @Environment(EditorViewModel.self) private var editor

    var segments: [AnalysisSegment] {
        guard let id = editor.selectedAssetID ?? editor.project.sequence.placement(at: editor.playhead)?.clip.assetID else { return [] }
        return editor.index.segments(.transcript, assetID: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("逐字稿").font(.headline)
                if let name = editor.selectedAsset?.name { Text(name).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("收合") {
                    editor.setTranscriptVisible(false)
                }
            }
            if segments.isEmpty {
                ContentUnavailableView("還沒有逐字稿", systemImage: "text.alignleft",
                                       description: Text("匯入影片後會自動分析。分析完成前也可以先剪。"))
            } else {
                List(segments) { seg in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(seg.range.start.formatted()).font(.caption.monospaced())
                            Spacer()
                            if let s = seg.speaker { Text(s).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(seg.text ?? "")
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(isHit(seg) ? Color.accentColor.opacity(0.15) : Color.clear)
                    .onTapGesture { editor.seekToTranscript(seg) }
                    .onDrag {
                        editor.transcriptSelection = AssetRange(assetID: seg.assetID, range: seg.range)
                        return NSItemProvider(object: (seg.text ?? "") as NSString)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(10)
    }

    func isHit(_ seg: AnalysisSegment) -> Bool {
        if let pending = editor.pendingProposal,
           pending.proposal.candidates.contains(where: { $0.isSelected && $0.range.overlaps(seg.range) && $0.assetID == seg.assetID }) {
            return true
        }
        if let p = editor.project.sequence.placement(at: editor.playhead),
           p.clip.assetID == seg.assetID,
           seg.range.contains(p.sourceTime(at: editor.playhead)) {
            return true
        }
        return false
    }
}
#endif
