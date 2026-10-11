#if os(macOS)
import AppKit
import SwiftUI

@main
struct CutPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var editor = EditorViewModel()

    var body: some Scene {
        WindowGroup("CutPlay") {
            MainWindow()
                .environment(editor)
                .frame(minWidth: 1280, minHeight: 800)
                .task { editor.start() }
        }
        .commands { EditorCommands(editor: editor) }

        Settings {
            SettingsView()
                .environment(editor)
        }
    }
}

/// Lets `swift run CutPlayApp` behave like a regular app (Dock icon, key window) without an Xcode bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
@main
enum CutPlayApp {
    static func main() {
        print("CutPlay 的 App 介面只能在 macOS 上執行。核心與媒體模組可以用 `swift test` 測試。")
    }
}
#endif
