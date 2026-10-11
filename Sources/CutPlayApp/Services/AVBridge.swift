#if os(macOS)
import AppKit
import AVFoundation
import CutPlayCore

extension MediaTime {
    var cmTime: CMTime { CMTime(value: ticks, timescale: CMTimeScale(MediaTime.timescale)) }

    init(_ time: CMTime) {
        guard time.isValid, !time.isIndefinite else { self = .zero; return }
        self.init(ticks: time.convertScale(CMTimeScale(MediaTime.timescale), method: .roundHalfAwayFromZero).value)
    }
}

extension TimeRange {
    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}

enum CompositionError: LocalizedError {
    case missingAsset(String)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name): return "找不到素材檔案：\(name)"
        }
    }
}

/// Builds the AVFoundation composition for a timeline. Preview and export share this path,
/// so what the user sees is exactly what gets exported.
enum CompositionBuilder {
    static func build(_ clips: [TimelineClip], assets: [UUID: MediaAsset]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var transformSet = false

        for clip in clips {
            guard let asset = assets[clip.assetID] else { continue }
            guard FileManager.default.fileExists(atPath: asset.playbackURL.path) else {
                throw CompositionError.missingAsset(asset.name)
            }
            let source = AVURLAsset(url: asset.playbackURL)
            let range = clip.sourceRange.cmTimeRange

            if let src = try await source.loadTracks(withMediaType: .video).first {
                let available = try await src.load(.timeRange)
                let r = range.intersection(available)
                try videoTrack?.insertTimeRange(r, of: src, at: cursor)
                if r.duration < range.duration {
                    videoTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor + r.duration, duration: range.duration - r.duration))
                }
                if !transformSet {
                    videoTrack?.preferredTransform = try await src.load(.preferredTransform)
                    transformSet = true
                }
            } else {
                videoTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }

            if let src = try await source.loadTracks(withMediaType: .audio).first {
                let available = try await src.load(.timeRange)
                let r = range.intersection(available)
                try audioTrack?.insertTimeRange(r, of: src, at: cursor)
                if r.duration < range.duration {
                    audioTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor + r.duration, duration: range.duration - r.duration))
                }
            } else {
                audioTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }
            cursor = cursor + range.duration
        }
        return composition
    }
}

enum ExportService {
    static func avPreset(_ preset: ExportPreset) -> String {
        switch preset {
        case .social1080p: return AVAssetExportPreset1920x1080
        case .high4K: return AVAssetExportPreset3840x2160
        case .audioOnly: return AVAssetExportPresetAppleM4A
        }
    }

    static func fileExtension(_ preset: ExportPreset) -> String {
        preset == .audioOnly ? "m4a" : "mp4"
    }

    static func export(_ clips: [TimelineClip], assets: [UUID: MediaAsset], preset: ExportPreset, to url: URL,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let composition = try await CompositionBuilder.build(clips, assets: assets)
        guard let session = AVAssetExportSession(asset: composition, presetName: avPreset(preset)) else {
            throw NSError(domain: "CutPlay", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法建立匯出工作"])
        }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = preset == .audioOnly ? .m4a : .mp4
        session.shouldOptimizeForNetworkUse = true

        let poller = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if let error = session.error { throw error }
        guard session.status == .completed else {
            throw NSError(domain: "CutPlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "匯出未完成"])
        }
        await progress(1)
    }
}

enum Thumbnailer {
    static func image(for url: URL, at seconds: Double = 1, maxSize: CGSize = CGSize(width: 240, height: 136)) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        guard let (cg, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
#endif
