#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import CutPlayCore

@MainActor
struct MainWindow: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var transcriptWidth: CGFloat = 290
    @State private var chatWidth: CGFloat = 400
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var editor = editor
        let _ = editor.revision
        VSplitView {
            HSplitView {
                MediaLibraryView()
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
                PreviewPane()
                    .frame(minWidth: 360)
                if editor.project.settings.showTranscriptPane {
                    TranscriptPane()
                        .frame(minWidth: 220, idealWidth: transcriptWidth, maxWidth: 520)
                }
            }
            TimelineView()
                .frame(minHeight: 180, idealHeight: 260)
        }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if editor.showChat {
                ChatPanel()
                    .frame(minWidth: 320, idealWidth: chatWidth, maxWidth: 520)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
            }
        }
        .toolbar { toolbar }
        .navigationTitle(editor.project.name)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task { await ingest(providers) }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(8)
            }
        }
        .alert("發生問題", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })) {
            Button("好") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .onAppear { transcriptWidth = editor.project.settings.transcriptPaneWidth }
        .onChange(of: transcriptWidth) { _, w in
            editor.session.updateSettings { $0.transcriptPaneWidth = w }
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("匯入") { pickFiles() }
            if editor.isBusy {
                ProgressView().controlSize(.small)
                Text("分析中").foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("復原", action: editor.undo).disabled(!editor.session.canUndo)
            privacyBadge
            Button(editor.showChat ? "隱藏助理" : "AI 助理") { editor.showChat.toggle() }
            Button("匯出…") { Task { await editor.export(.social1080p) } }
                .keyboardShortcut("e", modifiers: [.command])
        }
    }

    var privacyBadge: some View {
        Label(editor.settings.isCloud ? "雲端（只傳文字）" : "本機模式",
              systemImage: editor.settings.isCloud ? "cloud" : "lock.fill")
            .foregroundStyle(editor.settings.isCloud ? Color.orange : Color.green)
            .help(editor.settings.isCloud ? "分析索引的文字會送到雲端模型，影片不會上傳" : "分析與助理都在這台 Mac 上進行")
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio, .item]
        if panel.runModal() == .OK { editor.importURLs(panel.urls) }
    }

    func ingest(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for p in providers {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                urls.append(url)
            } else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        editor.importURLs(urls)
    }
}

@MainActor
struct PreviewPane: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                PlayerView(player: editor.previewPlayer)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let pending = editor.pendingProposal {
                    Text("預覽：候選方案（\(pending.proposal.selectedCandidates.count) 段）")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(10)
                }
            }
            HStack(spacing: 14) {
                Text(editor.playhead.formatted(fractional: true)).monospacedDigit()
                Button { editor.seek(.zero) } label: { Image(systemName: "backward.end.fill") }
                Button(action: editor.togglePlayback) {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                Button {
                    editor.seek(min(editor.playhead + MediaTime(seconds: 5), editor.project.sequence.duration))
                } label: { Image(systemName: "forward.end.fill") }
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 8)
        }
        .padding(12)
    }
}
#endif
