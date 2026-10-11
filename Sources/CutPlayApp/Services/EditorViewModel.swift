#if os(macOS)
import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers
import CutPlayCore
import CutPlayMedia

@MainActor
@Observable
final class EditorViewModel {
    var settings = AppSettings()
    var session: EditorSession
    var store: ProjectStore?
    var selectedAssetID: UUID?
    var playhead: MediaTime = .zero
    var isPlaying = false
    var showChat = true
    var isSending = false
    var isExporting = false
    var exportProgress: Double = 0
    var errorMessage: String?
    var infoMessage: String?
    var libraryFilter = ""
    var draftText = ""
    var previewPlayer = AVPlayer()
    var thumbnails: [UUID: NSImage] = [:]
    var analysisJobs = 0
    /// Bumped after every `EditorSession` mutation so SwiftUI notices changes inside the class.
    var revision: UInt64 = 0

    private var compositionToken = 0
    private var analysisTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        session = EditorSession(project: Project(name: "未命名"))
        applyPolicyAndPlanner()
    }

    var project: Project { session.project }
    var index: AnalysisIndex { session.index }
    var messages: [ChatMessage] { session.messages }
    var selectedAsset: MediaAsset? { selectedAssetID.flatMap { session.project.asset($0) } }
    var isBusy: Bool { analysisJobs > 0 }

    var pendingProposal: (id: UUID, proposal: PlanProposal)? {
        for m in messages.reversed() {
            if case .proposal(let p, _, .pending) = m.content { return (m.id, p) }
        }
        return nil
    }

    func touch() { revision &+= 1 }

    func start() {
        applyPolicyAndPlanner()
        if let path = settings.lastProjectPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) {
                open(url: url)
            }
        }
    }

    func applyPolicyAndPlanner() {
        session.policy.isEnabled = settings.autoApplyHighConfidence
        session.planner = settings.makePlanner()
        touch()
    }

    func startNewConversation() {
        session.startNewConversation()
        touch()
    }

    func setTranscriptVisible(_ visible: Bool) {
        session.updateSettings { $0.showTranscriptPane = visible }
        touch()
    }

    // MARK: - Project

    func newProject() {
        analysisTask?.cancel()
        session = EditorSession(project: Project(name: "未命名"), policy: AutoApplyPolicy(isEnabled: settings.autoApplyHighConfidence), planner: settings.makePlanner())
        store = nil
        selectedAssetID = nil
        playhead = .zero
        thumbnails.removeAll()
        touch()
        rebuildPreview()
    }

    func open(url: URL) {
        do {
            let loaded = try ProjectStore(url: url).load()
            store = ProjectStore(url: url)
            session = EditorSession(project: loaded.project, index: loaded.index, messages: loaded.messages,
                                    policy: AutoApplyPolicy(isEnabled: settings.autoApplyHighConfidence), planner: settings.makePlanner())
            selectedAssetID = loaded.project.assets.first?.id
            settings.lastProjectPath = url.path
            rebuildPreview()
            touch()
            for asset in loaded.project.assets { loadThumbnail(asset) }
        } catch {
            errorMessage = "無法開啟專案：\(error.localizedDescription)"
        }
    }

    func save(as url: URL? = nil) {
        let dest: URL
        if let url { dest = url } else if let store { dest = store.url } else { return }
        store = ProjectStore(url: dest)
        do {
            try store?.save(session)
            session.updateSettings { $0 = session.project.settings }
            settings.lastProjectPath = dest.path
            infoMessage = "已儲存"
        } catch {
            errorMessage = "儲存失敗：\(error.localizedDescription)"
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.save() }
        }
    }

    // MARK: - Import & analysis

    func importURLs(_ urls: [URL]) {
        Task { await importAndAnalyze(urls) }
    }

    func importAndAnalyze(_ urls: [URL]) async {
        do {
            let locator = ToolLocator()
            let importer = try MediaImporter(prober: MediaProber(locator: locator))
            let ffmpeg = try FFmpegTools(locator: locator)
            let pipeline = AnalysisPipeline(ffmpeg: ffmpeg, transcriber: WhisperCppTranscriber.discover(locator: locator),
                                            language: settings.language, proxySettings: ProxySettings())
            for url in urls {
                guard !Task.isCancelled else { return }
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                var asset = try await importer.makeAsset(for: url)
                if session.project.assets.contains(where: { $0.sourceURL == url }) { continue }
                session.addAsset(asset)
                selectedAssetID = asset.id
                loadThumbnail(asset)
                if session.project.sequence.clips.isEmpty { session.appendToTimeline(asset.id) }
                touch()
                scheduleSave()
                analysisJobs += 1
                defer { analysisJobs = max(0, analysisJobs - 1) }
                let assetID = asset.id
                let storeURL = store?.cacheDirectory
                let cache: @Sendable (String) -> URL = { suffix in
                    let dir = storeURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("CutPlayCache")
                    return dir.appendingPathComponent("\(assetID.uuidString)-\(suffix)")
                }
                do {
                    let output = try await pipeline.analyze(asset, cacheURL: cache) { [weak self] state in
                        Task { @MainActor in
                            self?.session.updateAsset(assetID) { $0.analysis = state }
                            self?.touch()
                        }
                    }
                    session.updateAsset(asset.id) { a in
                        a.proxyURL = output.proxyURL
                        a.analysis = .done
                        a.playability = output.proxyURL == nil ? a.playability : .native
                    }
                    for (kind, segs) in output.segments {
                        session.replaceAnalysis(kind, for: asset.id, with: segs)
                    }
                    if let asset = session.project.asset(asset.id) { loadThumbnail(asset) }
                    touch()
                    rebuildPreview()
                    scheduleSave()
                } catch is CancellationError {
                    session.updateAsset(asset.id) { $0.analysis = .queued }
                } catch {
                    session.updateAsset(asset.id) { $0.analysis = .failed(message: error.localizedDescription) }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadThumbnail(_ asset: MediaAsset) {
        Task {
            let image = await Thumbnailer.image(for: asset.playbackURL)
            thumbnails[asset.id] = image
        }
    }

    // MARK: - Timeline / preview

    func appendSelectedToTimeline() {
        guard let id = selectedAssetID else { return }
        session.appendToTimeline(id)
        touch()
        rebuildPreview()
        scheduleSave()
    }

    func splitAtPlayhead() {
        let t = playhead
        session.edit("切開") { try $0.split(at: t) }
        touch()
        rebuildPreview()
        scheduleSave()
    }

    func deleteSelectionRipple() {
        guard let pending = pendingProposal else { return }
        _ = pending
    }

    func rebuildPreview() {
        compositionToken += 1
        let token = compositionToken
        let clips = session.project.sequence.clips
        let assets = Dictionary(uniqueKeysWithValues: session.project.assets.map { ($0.id, $0) })
        Task { @MainActor in
            do {
                let composition = try await CompositionBuilder.build(clips, assets: assets)
                guard token == compositionToken else { return }
                let item = AVPlayerItem(asset: composition)
                previewPlayer.replaceCurrentItem(with: item)
                previewPlayer.seek(to: playhead.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            } catch {
                if clips.isEmpty { previewPlayer.replaceCurrentItem(with: nil) }
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            previewPlayer.pause()
            isPlaying = false
        } else {
            previewPlayer.play()
            isPlaying = true
            Task { await pollPlayhead() }
        }
    }

    private func pollPlayhead() async {
        while isPlaying {
            playhead = MediaTime(previewPlayer.currentTime())
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func seek(_ time: MediaTime) {
        playhead = time
        previewPlayer.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekToTranscript(_ segment: AnalysisSegment) {
        selectedAssetID = segment.assetID
        if let t = session.project.sequence.timelineRanges(forSource: segment.assetID, range: segment.range).first {
            seek(t.start)
        } else {
            seek(segment.range.start)
        }
    }

    // MARK: - Chat

    func sendDraft() {
        let text = draftText
        draftText = ""
        Task { await send(text) }
    }

    func send(_ text: String) async {
        applyPolicyAndPlanner()
        isSending = true
        defer { isSending = false }
        let selection = transcriptSelection ?? timelineAssetRange
        await session.send(text, selection: selection)
        isSending = false
        touch()
        handleExports()
        rebuildPreview()
        scheduleSave()
    }

    var transcriptSelection: AssetRange?

    var timelineAssetRange: AssetRange? {
        guard let p = session.project.sequence.placement(at: playhead) else { return nil }
        return AssetRange(assetID: p.clip.assetID, range: p.clip.sourceRange)
    }

    func applyProposal(_ id: UUID) {
        session.apply(messageID: id)
        touch()
        handleExports()
        rebuildPreview()
        scheduleSave()
    }

    func toggleCandidate(_ messageID: UUID, _ candidateID: String, _ selected: Bool) {
        session.setCandidate(candidateID, selected: selected, in: messageID)
        touch()
        scheduleSave()
    }

    func undo() {
        session.undo()
        touch()
        rebuildPreview()
        scheduleSave()
    }

    func redo() {
        session.redo()
        touch()
        rebuildPreview()
        scheduleSave()
    }

    func undoMessage(_ id: UUID) {
        let result = session.undo(messageID: id)
        if result == .notLatest { infoMessage = "只能復原最近一次修改" }
        touch()
        rebuildPreview()
        scheduleSave()
    }

    func handleExports() {
        let presets = session.takePendingExports()
        guard let first = presets.first else { return }
        Task { await export(first) }
    }

    func export(_ preset: ExportPreset) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ExportService.fileExtension(preset)) ?? .mpeg4Movie]
        panel.nameFieldStringValue = "\(session.project.name).\(ExportService.fileExtension(preset))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }
        do {
            let assets = Dictionary(uniqueKeysWithValues: session.project.assets.map { ($0.id, $0) })
            try await ExportService.export(session.project.sequence.clips, assets: assets, preset: preset, to: url) { [weak self] p in
                self?.exportProgress = p
            }
            infoMessage = "已匯出 \(url.lastPathComponent)"
        } catch {
            errorMessage = "匯出失敗：\(error.localizedDescription)"
        }
    }
}
#endif
