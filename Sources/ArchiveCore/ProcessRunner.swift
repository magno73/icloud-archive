import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum ProcessRunner {
    /// Argument arrays (never shell interpolation), a deadline, and bounded
    /// output make this safe for filenames containing spaces or shell syntax.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }
            var output = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                if output.count < 128 * 1024 { output.append(chunk.prefix(128 * 1024 - output.count)) }
            }
            process.waitUntilExit()
            return ProcessResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        }.value
    }
}

public enum OpenFileProbe {
    public static func check(_ urls: [URL]) async -> OpenFileStatus {
        do {
            let result = try await ProcessRunner.run("/usr/sbin/lsof", ["-n", "-P", "-F", "n", "--"] + urls.map(\.path), timeout: 10)
            // lsof exits 1 with no output when there are no matching handles.
            // Permission warnings or a deadline are not evidence of inactivity.
            if result.output.contains("\nn/") || result.output.hasPrefix("n/") { return .open }
            if result.status == 1 && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .closed }
            return .unknown
        } catch { return .unknown }
    }
}
