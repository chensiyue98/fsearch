import Darwin
import Foundation

private struct ReplyEnvelope: Decodable {
    let ok: Bool
    let error: String?
}

private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Runs the bundled engine directly over pipes, with no daemon or socket.
/// All pipe operations run on a private serial queue, never on the UI thread.
final class SearchClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FSearch.connection", qos: .userInitiated)
    private let lifetime = RequestCancellation()
    private let embeddedEngine: Bool
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var executable: String?
    private var buffered = Data()

    init(embeddedEngine: Bool = true) { self.embeddedEngine = embeddedEngine }

    static func locateExecutable(customPath: String, bundle: Bundle = .main) -> String? {
        let fm = FileManager.default
        // A packaged app always uses the matching bundled engine, even if an
        // older installation saved an external executable override.
        if let bundled = bundle.url(forAuxiliaryExecutable: "fsearch")?.path,
           fm.isExecutableFile(atPath: bundled) { return bundled }
        if bundle.bundleURL.pathExtension == "app" { return nil }
        if !customPath.isEmpty {
            let path = (customPath as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        let candidates: [String?] = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/fsearch").path,
            fm.currentDirectoryPath + "/target/release/fsearch",
            fm.currentDirectoryPath + "/../target/release/fsearch",
            "/opt/homebrew/bin/fsearch", "/usr/local/bin/fsearch"
        ]
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0) }
    }

    func request(_ request: SearchRequest, executable: String?) async throws -> SearchReply {
        try await self.request(request, executable: executable, as: SearchReply.self)
    }

    func request<Response: Decodable & Sendable>(
        _ request: SearchRequest, executable: String?, as responseType: Response.Type
    ) async throws -> Response {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request) + Data([10])
        let cancellation = RequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try self.lifetime.check()
                        try cancellation.check()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    do {
                        guard let executable else { throw SearchFailure.missingExecutable }
                        try self.connect(executable)
                        try self.input?.write(contentsOf: data)
                        // Once sent, consume this reply even if the UI moved on.
                        // Killing an embedded engine on every cancelled query
                        // would restart indexing and lose stream alignment.
                        let line = try self.readLine(self.embeddedEngine ? self.lifetime : cancellation)
                        if self.embeddedEngine, cancellation.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let reply = try JSONDecoder().decode(ReplyEnvelope.self, from: line)
                        guard reply.ok else { throw SearchFailure.backend(reply.error ?? "Search failed.") }
                        continuation.resume(returning: try JSONDecoder().decode(responseType, from: line))
                    } catch {
                        // Backend query errors leave the JSON stream usable.
                        if case SearchFailure.backend = error {} else { self.disconnect() }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func close() {
        lifetime.cancel()
        queue.async { self.disconnect() }
    }

    func shutdown() async {
        lifetime.cancel()
        await withCheckedContinuation { continuation in
            queue.async {
                self.disconnect()
                continuation.resume()
            }
        }
    }

    private func connect(_ path: String) throws {
        if executable == path, process?.isRunning == true { return }
        disconnect()
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [embeddedEngine ? "embedded-gui" : "stdio"]
        process.environment = ProcessInfo.processInfo.environment.merging(["MallocSpaceEfficient": "1"]) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        executable = path
    }

    private static func waitForExit(_ process: Process) {
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        let forcedDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < forcedDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func readLine(_ cancellation: RequestCancellation) throws -> Data {
        guard let output else { throw SearchFailure.disconnected }
        return try readLine(from: output, buffer: &buffered, cancellation: cancellation)
    }

    private func readLine(from output: FileHandle, buffer: inout Data, cancellation: RequestCancellation) throws -> Data {
        let deadline = Date().addingTimeInterval(20)
        while true {
            try cancellation.check()
            try lifetime.check()
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                return line
            }
            guard buffer.count < 32 * 1024 * 1024 else { throw SearchFailure.invalidReply }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SearchFailure.timeout }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
            if ready < 0, errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0 else { throw SearchFailure.disconnected }
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw SearchFailure.disconnected }
            buffer.append(chunk)
        }
    }

    private func disconnect() {
        try? input?.close()
        try? output?.close()
        if let process {
            if process.isRunning { process.terminate() }
            Self.waitForExit(process)
        }
        process = nil
        input = nil
        output = nil
        executable = nil
        buffered.removeAll(keepingCapacity: true)
    }
}
