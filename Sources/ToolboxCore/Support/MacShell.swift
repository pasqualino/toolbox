import Foundation

/// Runs system commands whose non-zero exit is an answer, not a failure (codesign, spctl, xattr).
/// Unlike ProcessRunner it returns stdout, stderr and status for every exit. Terminates on task cancellation.
enum MacShell {
    static func run(_ path: String, _ arguments: [String]) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outData = DataBox()
        let errData = DataBox()
        out.fileHandleForReading.readabilityHandler = { outData.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outData.append(out.fileHandleForReading.readDataToEndOfFile())
                    errData.append(err.fileHandleForReading.readDataToEndOfFile())
                    if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: ProcessOutput(status: p.terminationStatus,
                                                             stdout: outData.text, stderr: errData.text))
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
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
