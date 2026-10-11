#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import CutPlayCore

struct EditorCommands: Commands {
    var editor: EditorViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新增專案") { editor.newProject() }
                .keyboardShortcut("n", modifiers: [.command])
            Button("開啟專案…") { open() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("儲存") { save() }
                .keyboardShortcut("s", modifiers: [.command])
            Divider()
            Button("匯入影片…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = true
                if panel.runModal() == .OK { editor.importURLs(panel.urls) }
            }
            .keyboardShortcut("i", modifiers: [.command])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("復原") { editor.undo() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!editor.session.canUndo)
            Button("重做") { editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.session.canRedo)
        }
        CommandMenu("剪輯") {
            Button("在播放頭切開") { editor.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: [.command])
            Button("把選取素材加到時間軸") { editor.appendSelectedToTimeline() }
        }
        CommandMenu("助理") {
            Button(editor.showChat ? "隱藏 AI 助理" : "顯示 AI 助理") { editor.showChat.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button(editor.project.settings.showTranscriptPane ? "隱藏逐字稿" : "顯示逐字稿") {
                editor.setTranscriptVisible(!editor.project.settings.showTranscriptPane)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Button("匯出社群影片…") { Task { await editor.export(.social1080p) } }
                .keyboardShortcut("e", modifiers: [.command])
        }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "開啟"
        if panel.runModal() == .OK, let url = panel.url { editor.open(url: url) }
    }

    func save() {
        if editor.store != nil {
            editor.save()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectStore.fileExtension) ?? .directory]
        panel.nameFieldStringValue = "\(editor.project.name).\(ProjectStore.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url { editor.save(as: url) }
    }
}
#endif
