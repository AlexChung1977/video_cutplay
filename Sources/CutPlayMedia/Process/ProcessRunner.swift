import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessError: Error, CustomStringConvertible {
    case toolNotFound(String)
    case failed(tool: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .toolNotFound(let name): return "找不到 \(name)，請確認已安裝。"
        case .failed(let tool, let status, let stderr):
            return "\(tool) 失敗（代碼 \(status)）：\(stderr.suffix(400))"
        }
    }
}

public enum ProcessRunner {
    /// Runs a tool to completion, streaming output lines to the optional handlers.
    /// Cancelling the calling task terminates the process.
    public static func run(_ executable: URL, _ arguments: [String],
                           onStdoutLine: (@Sendable (String) -> Void)? = nil,
                           onStderrLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = LineCollector(onLine: onStdoutLine)
        let err = LineCollector(onLine: onStderrLine)
        let group = DispatchGroup()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Read both pipes to EOF on background threads so a full pipe never blocks the child
                // and no output is lost between exit and the final read.
                for (pipe, collector) in [(outPipe, out), (errPipe, err)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let handle = pipe.fileHandleForReading
                        while true {
                            let data = handle.availableData
                            if data.isEmpty { break }
                            collector.append(data)
                        }
                        collector.finish()
                        group.leave()
                    }
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    group.leave()
                }
                group.notify(queue: .global()) {
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus,
                                                                 stdout: out.text, stderr: err.text))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs and throws `ProcessError.failed` on a non-zero exit.
    @discardableResult
    public static func check(_ executable: URL, _ arguments: [String],
                             onStdoutLine: (@Sendable (String) -> Void)? = nil,
                             onStderrLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)
        guard result.status == 0 else {
            throw ProcessError.failed(tool: executable.lastPathComponent, status: result.status, stderr: result.stderr)
        }
        return result
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        var lines: [String] = []
        if onLine != nil {
            pending.append(chunk)
            while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = pending[pending.startIndex..<nl]
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ToolLocator: Sendable {
    public var searchDirectories: [URL]

    public init(searchDirectories: [URL]? = nil) {
        if let searchDirectories {
            self.searchDirectories = searchDirectories
            return
        }
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("bin")) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { URL(fileURLWithPath: $0) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        dirs += path.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        self.searchDirectories = dirs
    }

    /// `CUTPLAY_<NAME>` (e.g. `CUTPLAY_FFMPEG`) overrides the search.
    public func locate(_ name: String) -> URL? {
        let envKey = "CUTPLAY_" + name.uppercased().replacingOccurrences(of: "-", with: "_")
        if let override = ProcessInfo.processInfo.environment[envKey], FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func require(_ name: String) throws -> URL {
        guard let url = locate(name) else { throw ProcessError.toolNotFound(name) }
        return url
    }
}
