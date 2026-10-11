#if os(macOS)
import SwiftUI
import CutPlayCore

@MainActor
struct SettingsView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        @Bindable var editor = editor
        TabView {
            Form {
                Toggle("信心高時直接套用", isOn: $editor.settings.autoApplyHighConfidence)
                Text("關閉時，助理每次都會先列出候選片段請你確認。").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("一般", systemImage: "gear") }

            Form {
                Picker("AI 執行位置", selection: $editor.settings.aiMode) {
                    ForEach(AppSettings.AIMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if editor.settings.aiMode == .localServer {
                    TextField("伺服器網址", text: $editor.settings.localServerURL)
                    TextField("模型名稱", text: $editor.settings.localModel)
                }
                if editor.settings.aiMode == .cloud {
                    TextField("API 網址", text: $editor.settings.cloudURL)
                    TextField("模型名稱", text: $editor.settings.cloudModel)
                    SecureField("API 金鑰（存在鑰匙圈）", text: Binding(get: { editor.settings.cloudAPIKey }, set: { editor.settings.cloudAPIKey = $0 }))
                    Toggle("我了解只會上傳文字索引，不會上傳影片", isOn: $editor.settings.cloudConsentGiven)
                    Text("第一次送出前請再確認一次。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onChange(of: editor.settings.aiMode) { _, _ in editor.applyPolicyAndPlanner() }
            .tabItem { Label("AI 助理", systemImage: "sparkles") }

            Form {
                Picker("語音辨識語言", selection: $editor.settings.language) {
                    Text("中文").tag("zh")
                    Text("自動").tag("auto")
                    Text("英文").tag("en")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("分析", systemImage: "waveform") }
        }
        .frame(width: 520, height: 360)
        .onChange(of: editor.settings.autoApplyHighConfidence) { _, _ in editor.applyPolicyAndPlanner() }
    }
}
#endif
