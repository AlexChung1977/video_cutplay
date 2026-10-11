#if os(macOS)
import SwiftUI
import CutPlayCore

@MainActor
struct MediaLibraryView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var query = ""

    var assets: [MediaAsset] {
        let all = editor.project.assets
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let nameHits = all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let contentIDs = Set(editor.index.search(q).map(\.segment.assetID))
        let contentHits = all.filter { contentIDs.contains($0.id) && !nameHits.contains($0) }
        return nameHits + contentHits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("媒體庫").font(.headline)
                Spacer()
                Text("\(editor.project.assets.count)").foregroundStyle(.secondary)
            }
            TextField("搜尋檔名或說過的話", text: $query)
                .textFieldStyle(.roundedBorder)
            List(assets, selection: Binding(get: { editor.selectedAssetID }, set: { editor.selectedAssetID = $0 })) { asset in
                HStack(spacing: 8) {
                    thumbnail(asset)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.name).lineLimit(1)
                        Text(asset.analysis.label).font(.caption).foregroundStyle(color(for: asset.analysis))
                    }
                }
                .tag(asset.id)
                .contextMenu {
                    Button("加到時間軸") { editor.session.appendToTimeline(asset.id); editor.rebuildPreview() }
                }
                .onTapGesture(count: 2) {
                    editor.appendSelectedToTimeline()
                }
            }
            .listStyle(.sidebar)
        }
        .padding(10)
    }

    func thumbnail(_ asset: MediaAsset) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = editor.thumbnails[asset.id] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
            Text(asset.duration.formatted()).font(.caption2).padding(2).background(.black.opacity(0.6)).foregroundStyle(.white)
        }
        .frame(width: 64, height: 38).clipped().clipShape(RoundedRectangle(cornerRadius: 4))
    }

    func color(for state: AnalysisState) -> Color {
        switch state {
        case .done: return .green
        case .failed: return .red
        case .queued: return .secondary
        default: return .orange
        }
    }
}
#endif
