import Foundation
import Synchronization

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {
    /// Runs an executable. Each stdout line goes to `onLine`. Terminates the process on task cancellation.
    /// Throws when the exit status is non-zero, with the tail of stderr as the message.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        onLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let result = try await execute(
            executable, arguments, environment: environment, onLine: onLine, onErrorLine: onErrorLine)
        guard result.status == 0 else {
            throw ToolError.message(summarize(result.stderr, fallback: executable.lastPathComponent))
        }
        return result
    }

    /// Runs a command whose non-zero exit is an answer, not a failure (codesign, spctl, xattr).
    /// Returns stdout, stderr and status for every exit. Terminates the process on task cancellation.
    public static func capture(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessOutput {
        try await execute(executable, arguments, environment: environment, onLine: nil, onErrorLine: nil)
    }

    private static func execute(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]?,
        onLine: (@Sendable (String) -> Void)?,
        onErrorLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Toolchain.searchPath
        if let environment { env.merge(environment) { $1 } }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outBuffer = LineBuffer(onLine)
        let errBuffer = LineBuffer(onErrorLine)
        out.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outBuffer.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
                    outBuffer.flush()
                    errBuffer.flush()
                    if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(
                            returning: ProcessOutput(
                                status: p.terminationStatus,
                                stdout: outBuffer.text, stderr: errBuffer.text))
                    }
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Last meaningful stderr line, for an inline error.
    static func summarize(_ stderr: String, fallback: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let useful = lines.last { !$0.isEmpty && !$0.hasPrefix("Conversion failed") } ?? ""
        return useful.isEmpty ? "\(fallback) failed." : useful
    }
}

private final class LineBuffer: Sendable {
    private struct State {
        /// Bytes after the last line break.
        var pending = Data()
        var all = Data()
    }
    private let state = Mutex(State())
    private let onLine: (@Sendable (String) -> Void)?

    init(_ onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = state.withLock { state -> [String] in
            state.all.append(data)
            state.pending.append(data)
            var lines: [String] = []
            while let range = state.pending.firstRange(of: Data([0x0A])) ?? state.pending.firstRange(of: Data([0x0D])) {
                let line = state.pending.subdata(in: state.pending.startIndex..<range.lowerBound)
                state.pending.removeSubrange(state.pending.startIndex..<range.upperBound)
                lines.append(String(decoding: line, as: UTF8.self))
            }
            return lines
        }
        // Outside the lock: the callback may take its time.
        for line in lines { onLine?(line) }
    }

    func flush() {
        let rest = state.withLock { state -> Data in
            defer { state.pending = Data() }
            return state.pending
        }
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
    }

    var text: String {
        state.withLock { String(decoding: $0.all, as: UTF8.self) }
    }
}
