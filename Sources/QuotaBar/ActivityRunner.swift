import Foundation

/// Resolves a bare executable name the way a login shell would, for GUI apps that start
/// with launchd's minimal `PATH`.
enum ExecutableResolver {
    static let commonDirectories: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/.nix-profile/bin", "/etc/profiles/per-user/\(NSUserName())/bin", "/run/current-system/sw/bin",
            "\(home)/.local/bin"
        ]
    }()

    static func resolve(
        _ name: String,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        fallbackDirectories: [String] = commonDirectories,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> URL? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            return isExecutable(url) ? url : nil
        }
        let directories = (path?.split(separator: ":").map(String.init) ?? []) + fallbackDirectories
        return directories.lazy.map { URL(fileURLWithPath: $0).appending(path: name) }.first(where: isExecutable)
    }
}

struct CommandResult: Sendable, Equatable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], input: Data?, timeout: Duration, outputLimit: Int) async throws -> CommandResult
}

/// Runs an argv command with `Process`, never through a shell, with a timeout, cancellation,
/// and a standard-output size limit.
struct ProcessCommandRunner: CommandRunning {
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    func run(executable: URL, arguments: [String], input: Data?, timeout: Duration, outputLimit: Int) async throws -> CommandResult {
        try Task.checkCancellation()
        _ = Self.ignoreSIGPIPE
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CodexProcessEnvironment.addingExecutableDirectory(to: ProcessInfo.processInfo.environment, executableURL: executable)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let state = CommandState(outputLimit: outputLimit)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.start(continuation) else { return }
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil; state.finishStream(stdout: true) }
                    else if !state.append(data, stdout: true) { state.fail(ActivitySourceError.outputTooLarge); Self.stop(process) }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil; state.finishStream(stdout: false) }
                    else { _ = state.append(data, stdout: false) }
                }
                process.terminationHandler = { state.exited($0.terminationStatus) }
                do { try process.run() } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    state.fail(ActivitySourceError.executableNotFound(executable.lastPathComponent))
                    return
                }
                // Cancellation may have landed between start and launch, when there was nothing to stop.
                if state.isFinished { Self.stop(process); return }
                let writer = stdin.fileHandleForWriting
                DispatchQueue.global(qos: .utility).async {
                    if let input { try? writer.write(contentsOf: input) }
                    try? writer.close()
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    if state.fail(ActivitySourceError.timedOut) { Self.stop(process) }
                }
            }
        } onCancel: {
            if state.fail(CancellationError()) { Self.stop(process) }
        }
    }

    private static func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}

/// Collects a command's output and resumes once after exit and both streams close, or on failure.
private final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLimit: Int
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var status: Int32?
    private var openStreams = 2
    private var finished = false
    private var pendingError: Error?

    init(outputLimit: Int) { self.outputLimit = outputLimit }

    /// Returns false when the run already failed (for example, cancelled before launch).
    func start(_ continuation: CheckedContinuation<CommandResult, Error>) -> Bool {
        lock.lock()
        if let pendingError {
            finished = true
            lock.unlock()
            continuation.resume(throwing: pendingError)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func append(_ data: Data, stdout isStdout: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isStdout {
            guard stdout.count + data.count <= outputLimit else { return false }
            stdout.append(data)
        } else if stderr.count < 65_536 {
            stderr.append(data.prefix(65_536 - stderr.count))
        }
        return true
    }

    func finishStream(stdout _: Bool) {
        lock.lock(); openStreams -= 1; lock.unlock()
        completeIfReady()
    }

    func exited(_ status: Int32) {
        lock.lock(); self.status = status; lock.unlock()
        completeIfReady()
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Fails the run once; returns whether this call finished it.
    @discardableResult
    func fail(_ error: Error) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        guard let continuation else {
            if pendingError == nil { pendingError = error }
            lock.unlock()
            return true
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
        return true
    }

    private func completeIfReady() {
        lock.lock()
        guard !finished, let status, openStreams == 0, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let result = CommandResult(status: status, stdout: stdout, stderr: stderr)
        lock.unlock()
        continuation.resume(returning: result)
    }
}

/// Runs one activity source and validates its output.
struct ActivityCollector: Sendable {
    let runner: any CommandRunning
    let collectorScript: Data?
    var timeout: Duration = .seconds(120)
    var outputLimit = 64 * 1_024 * 1_024
    var resolve: @Sendable (String) -> URL? = { ExecutableResolver.resolve($0) }

    static func bundledScript(in bundle: Bundle = .main) -> Data? {
        bundle.url(forResource: "claude_activity_collector", withExtension: "py").flatMap { try? Data(contentsOf: $0) }
    }

    func collect(_ source: ActivitySourceConfig, since: Date) async throws -> ActivityReport {
        guard let name = source.argv.first, !name.isEmpty else { throw ActivitySourceError.invalidCommand }
        guard let executable = resolve(name) else { throw ActivitySourceError.executableNotFound(name) }
        var arguments = Array(source.argv.dropFirst())
        var input: Data?
        if source.pipesCollector {
            guard let collectorScript else { throw ActivitySourceError.collectorMissing }
            input = collectorScript
            arguments += ["--since", InstantFormat.plain.string(from: since)]
        }
        let result = try await runner.run(executable: executable, arguments: arguments, input: input, timeout: timeout, outputLimit: outputLimit)
        try Task.checkCancellation()
        guard result.status == 0 else { throw ActivitySourceError.classify(status: result.status, stderr: result.stderr) }
        return try ActivityReportParser.parse(result.stdout)
    }
}
