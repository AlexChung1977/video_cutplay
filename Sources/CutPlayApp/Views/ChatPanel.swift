#if os(macOS)
import SwiftUI
import CutPlayCore

struct ChatPanel: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var draft = ""

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            HStack {
                Text("✦ AI 助理").font(.headline)
                Text(editor.settings.isCloud ? "雲端" : "本機")
                    .font(.caption).foregroundStyle(editor.settings.isCloud ? .orange : .green)
                Spacer()
                Button("新對話") { editor.startNewConversation() }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if editor.messages.isEmpty {
                            Text("告訴我你想怎麼剪。例如「刪掉所有停頓」或「把講到電池續航的段落排在片頭後面」。")
                                .foregroundStyle(.secondary).padding()
                        }
                        ForEach(editor.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if editor.isSending {
                            Text("正在看逐字稿…").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: editor.messages.count) { _, _ in
                    if let last = editor.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ForEach(RuleBasedPlanner.suggestions.prefix(3), id: \.self) { s in
                        Button(s) { Task { await editor.send(s) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                HStack(alignment: .bottom) {
                    TextField("告訴我你想怎麼剪…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor))
                        .onSubmit {
                            let t = draft
                            draft = ""
                            Task { await editor.send(t) }
                        }
                    Button {
                        let t = draft
                        draft = ""
                        Task { await editor.send(t) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor.isSending)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
                Toggle(isOn: Binding(get: { editor.settings.autoApplyHighConfidence }, set: {
                    editor.settings.autoApplyHighConfidence = $0
                    editor.applyPolicyAndPlanner()
                })) {
                    Text("信心高時直接套用") + Text("（仍可復原）").foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct MessageBubble: View {
    @Environment(EditorViewModel.self) private var editor
    var message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            content
            if message.role == .assistant { Spacer(minLength: 20) }
        }
    }

    @ViewBuilder
    var content: some View {
        switch message.content {
        case .text(let t):
            Text(t)
                .padding(10)
                .background(message.role == .user ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        case .proposal(let proposal, let text, let state):
            ProposalCard(messageID: message.id, proposal: proposal, text: text, state: state)
        case .clarification(let q, let options):
            VStack(alignment: .leading, spacing: 8) {
                Text(q)
                ForEach(options, id: \.self) { o in
                    Button(o) { Task { await editor.send(o) } }
                }
            }
            .padding(10)
            .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        case .notFound(let m, let suggestions):
            VStack(alignment: .leading, spacing: 8) {
                Text(m)
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { Task { await editor.send(s) } }.buttonStyle(.bordered)
                }
            }
            .padding(10)
            .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct ProposalCard: View {
    @Environment(EditorViewModel.self) private var editor
    var messageID: UUID
    var proposal: PlanProposal
    var text: String
    var state: ChatMessage.ProposalState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("✦ AI 助理").font(.caption).foregroundStyle(.cyan)
            Text(text)
            ForEach(proposal.candidates) { c in
                HStack(alignment: .top, spacing: 8) {
                    if case .pending = state {
                        Toggle("", isOn: Binding(
                            get: { c.isSelected },
                            set: { editor.toggleCandidate(messageID, c.id, $0) }
                        )).labelsHidden().toggleStyle(.checkbox)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.range.formatted()).font(.caption.monospaced())
                        Text(c.reason).foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    Text(c.level.displayName)
                        .font(.caption)
                        .foregroundStyle(c.level == .high ? Color.green : Color.orange)
                }
            }
            Text(proposal.summary()).font(.caption).padding(6).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
            switch state {
            case .pending(let reasons):
                if !reasons.isEmpty {
                    Text(reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("逐段預覽") {
                        if let first = proposal.selectedCandidates.first { editor.seekToTranscript(AnalysisSegment(id: first.id, assetID: first.assetID, kind: .transcript, range: first.range, text: first.reason)) }
                    }
                    Button("套用") { editor.applyProposal(messageID) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                }
            case .applied(_, let auto):
                HStack {
                    Text(auto ? "✓ 已自動套用（信心高）" : "✓ 已套用").foregroundStyle(.green)
                    Spacer()
                    Button("復原") { editor.undoMessage(messageID) }
                }
                .font(.caption)
                .padding(6)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            case .undone:
                Text("已復原").font(.caption).foregroundStyle(.secondary)
            case .dismissed:
                Text("已略過").font(.caption).foregroundStyle(.secondary)
            case .failed(let m):
                Text(m).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
#endif
