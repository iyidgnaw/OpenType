import Foundation

/// Parses simple `KEY=VALUE` environment-file text (shell-style comments,
/// optional `export ` prefix, optional quoting) — used by
/// `SidecarClient.loadBundledEnvironment(resourcePath:)` to read the
/// `sidecar.env` file `build-app.sh` bundles into the packaged app's
/// Resources so the sidecar child process can find its DeepSeek API key at
/// runtime. Previously also backed the now-removed cloud-provider
/// `CredentialProvider`/`~/.openclaw/.env` lookup; this is its only
/// remaining consumer.
enum EnvironmentFileParser {
    static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let normalized = line.hasPrefix("export ")
                ? String(line.dropFirst("export ".count))
                : line
            guard let separator = normalized.firstIndex(of: "=") else { continue }

            let key = normalized[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var value = normalized[normalized.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }

            guard !key.isEmpty else { continue }
            result[key] = value
        }

        return result
    }
}

/// Errors surfaced by `SidecarClient` while launching, health-checking, or
/// issuing HTTP-over-Unix-socket requests to the local sidecar process.
enum SidecarClientError: Error, LocalizedError, Equatable {
    /// The child process could not be spawned at all (e.g. bad executable path).
    case processFailedToStart(String)
    /// The sidecar did not become ready (socket + healthy `/health`) within the timeout.
    case timedOutWaitingForReadiness
    /// The `curl` subprocess exited non-zero, or failed to launch.
    case requestFailed(exitCode: Int32, stderr: String)
    /// The body didn't decode as the expected type. Carries the HTTP status
    /// curl observed (0 if it couldn't be determined) so a decode failure
    /// caused by an unexpected error page/shape is distinguishable from one
    /// caused by a genuinely malformed 2xx body.
    case responseDecodingFailed(status: Int, reason: String, body: String)
    /// stdout from `curl` was empty.
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .processFailedToStart(let reason):
            return "Failed to start opentype-sidecar: \(reason)"
        case .timedOutWaitingForReadiness:
            return "Timed out waiting for opentype-sidecar to become ready."
        case .requestFailed(let exitCode, let stderr):
            return "Sidecar request failed (curl exit \(exitCode)): \(stderr)"
        case .responseDecodingFailed(let status, let reason, let body):
            return "Failed to decode sidecar response (HTTP \(status)): \(reason) — body: \(body)"
        case .emptyResponse:
            return "Sidecar returned an empty response."
        }
    }
}

/// Thin wrapper around the `Encodable` existential so a heterogeneous request
/// body can still be routed through `JSONEncoder`, which requires a concrete
/// `Encodable`-conforming type rather than the `Encodable` protocol itself.
private struct AnyEncodableBody: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeClosure = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

/// Wall-clock ceiling (seconds) handed to `curl --max-time` for every request,
/// so a wedged Unix socket can't pin a request forever (P0-2). Finite but
/// generous enough for a long agent/tool-calling run. File-scope (rather than a
/// `SidecarClient` static) so the `nonisolated` `curlInvocation` seam can read
/// it without crossing the class's `@MainActor` isolation.
private let sidecarRequestTimeoutSeconds = 300

/// A minimal thread-safe `Data` accumulator so a background pipe-drain can
/// hand its bytes back to whichever context reads them once the drain
/// finishes. `@unchecked Sendable` because access is serialized by an
/// `NSLock` rather than by the type system.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(data)
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Thread-safe custody of an in-flight `curl` child process so a Swift Task's
/// cancellation handler — which can fire from any thread at any time — can
/// terminate it, while guaranteeing the request's continuation is resumed
/// exactly once no matter which racing path (normal exit, spawn failure, or
/// cancellation-driven termination) reaches it first. `@unchecked Sendable`
/// because all mutable state is guarded by `lock`.
private final class CurlProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var resumed = false

    func setProcess(_ newProcess: Process) {
        lock.lock(); defer { lock.unlock() }
        process = newProcess
    }

    /// Returns `true` for the first caller only. Gates the single legal
    /// `continuation.resume(...)`; every later caller gets `false` and must
    /// not resume again.
    func claimResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    /// The child's exit status. Only valid once the process has actually
    /// exited (i.e. from the termination path); returns `-1` if no process was
    /// ever recorded.
    func terminationStatus() -> Int32 {
        lock.lock(); let process = self.process; lock.unlock()
        guard let process else { return -1 }
        return process.terminationStatus
    }

    /// Best-effort SIGTERM to the child if it's still running. Safe to call
    /// from a task-cancellation handler on any thread.
    func terminate() {
        lock.lock(); let process = self.process; lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

/// Launches the local TypeScript/Bun sidecar as a child process and talks to
/// it over a Unix domain socket (via `curl`, since `URLSession` cannot speak
/// to Unix sockets directly). Mirrors the rest of this codebase's
/// `@MainActor final class` convention for stateful collaborators
/// (`AudioRecorder`, `AppModel`) since this type owns mutable process state
/// that should only ever be touched from one place at a time.
/// Thread-safe one-shot flag distinguishing an INTENTIONAL sidecar stop (app
/// quit / explicit `stop()` / a failed-startup teardown) from an UNEXPECTED
/// crash. A fresh instance is created per `start()` and handed to that run's
/// `terminationHandler`, which fires on an arbitrary background thread — so it
/// can't touch the `@MainActor` `SidecarClient` directly. `@unchecked
/// Sendable` because access is serialized by an `NSLock`.
private final class TerminationIntentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var intentional = false

    func markIntentional() {
        lock.lock(); defer { lock.unlock() }
        intentional = true
    }

    var isIntentional: Bool {
        lock.lock(); defer { lock.unlock() }
        return intentional
    }
}

@MainActor
final class SidecarClient {
    private let socketURL: URL
    private var process: Process?

    /// The intent flag for the currently-running child, so `stop()` can mark an
    /// intentional teardown before terminating it. Replaced on every `start()`.
    private var terminationIntent = TerminationIntentFlag()

    /// Invoked (on the main actor) when the sidecar child dies UNEXPECTEDLY —
    /// i.e. not via `stop()` / app quit / a failed-startup teardown. `AppModel`
    /// wires this to its bounded auto-restart loop (P1-4). A crash used to only
    /// write a debug log, leaving `sidecarStatus` stuck reading "ready" forever
    /// while every subsequent request failed against a dead process.
    var onUnexpectedTermination: (() -> Void)?

    /// Derives the dev-mode sidecar source directory from this file's own
    /// location — `<repo>/Sources/OpenType/SidecarClient.swift` → `<repo>/sidecar`
    /// (up 3 path components, then `/sidecar`). Replaces a hardcoded,
    /// user-specific absolute fallback path so a checkout in any location works.
    /// Overridden ahead of this by the `OPENTYPE_SIDECAR_DEV_PATH` env var; only
    /// consulted in dev-mode (`bun run`) launches, never for the bundled binary.
    ///
    /// - Parameter sourceFilePath: Overridable for testing; defaults to the
    ///   compile-time location of this source file.
    nonisolated static func defaultDevSidecarDirectory(
        sourceFilePath: String = #filePath
    ) -> String {
        var url = URL(fileURLWithPath: sourceFilePath)
        url.deleteLastPathComponent() // SidecarClient.swift → Sources/OpenType
        url.deleteLastPathComponent() // → Sources
        url.deleteLastPathComponent() // → repo root
        return url.appendingPathComponent("sidecar", isDirectory: true).path
    }

    /// - Parameter socketURL: Override for testing. Defaults to
    ///   `~/Library/Application Support/OpenType/sidecar.sock`, following the
    ///   same Application Support convention as `HistoryStore`/`AgentMemoryStore`.
    init(socketURL: URL? = nil) {
        if let socketURL {
            self.socketURL = socketURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let directory = support.appendingPathComponent(
                "OpenType",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.socketURL = directory.appendingPathComponent("sidecar.sock")
        }
    }

    deinit {
        process?.terminate()
    }

    /// Hard cap (bytes) on the sidecar debug log; it's truncated once it grows
    /// past this so a long-lived app instance streaming stdout/stderr into it
    /// can't grow it without bound (P2).
    nonisolated private static let debugLogMaxBytes = 1_000_000

    /// Location of the sidecar debug log, under the app's Application Support
    /// directory (same convention as the socket/db paths) rather than a fixed,
    /// world-readable `/tmp` path (P2): the sidecar's stdout/stderr can contain
    /// locally-sensitive content and shouldn't be readable by every user on the
    /// machine. Returns `nil` if Application Support can't be resolved.
    nonisolated private static func debugLogURL() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = support.appendingPathComponent("OpenType", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("sidecar-client-debug.log")
    }

    /// Appends a timestamped line to the sidecar debug log so startup can be
    /// diagnosed from a launched (non-Terminal) app instance, where stdout
    /// isn't visible. Kept under Application Support (not `/tmp`) and truncated
    /// once it exceeds `debugLogMaxBytes`, so it stays a bounded, user-private
    /// diagnostic aid rather than an unbounded world-readable file (P2).
    nonisolated private static func debugLog(_ message: String) {
        guard let url = debugLogURL() else { return }
        let path = url.path
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default

        // Rotate by truncating once the log passes its size cap.
        if let attributes = try? fileManager.attributesOfItem(atPath: path),
           let size = attributes[.size] as? Int,
           size > debugLogMaxBytes {
            try? fileManager.removeItem(atPath: path)
        }

        if fileManager.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Lifecycle

    /// Every sidecar path that must be WRITABLE, pinned next to the socket.
    ///
    /// The sidecar's own defaults for these are relative to its source
    /// checkout (`sidecar/.data/...`), which is only correct under a
    /// `bun run` dev launch. A Process spawned without an explicit
    /// `currentDirectoryURL` inherits the app's cwd — often `/`, a read-only
    /// volume — so a packaged launch would fail to create them. Pinning is
    /// what makes both launch modes behave the same.
    ///
    /// One function rather than five assignments scattered through `start()`
    /// so the list is a single thing to keep complete, and so a test can
    /// assert that completeness. That test exists because two of these
    /// (spill and run-log roots) shipped unpinned: both features write
    /// best-effort and swallow their own failures, so in the packaged app
    /// they simply did nothing, silently.
    ///
    /// - Parameter socketURL: the sidecar's Unix socket; its directory is the
    ///   data directory.
    /// - Returns: environment entries to merge into the spawn environment.
    nonisolated static func dataDirectoryEnvironment(socketURL: URL) -> [String: String] {
        let dataDirectory = socketURL.deletingLastPathComponent()
        func path(_ component: String) -> String {
            dataDirectory.appendingPathComponent(component).path
        }
        return [
            "OPENTYPE_SIDECAR_DB_PATH": path("opentype.sqlite3"),
            // Proof-of-context-usage log (`contextDebugLog.ts`).
            "OPENTYPE_CONTEXT_LOG_PATH": path("context-debug.log"),
            // Socket for the local MLX-Whisper server the sidecar manages.
            "OPENTYPE_WHISPER_SOCKET": path("whisper.sock"),
            // Oversized tool results moved out of context (`agent/spill.ts`).
            "OPENTYPE_SPILL_ROOT": path("spill"),
            // Durable per-run agent step logs (`agent/runLog.ts`).
            "OPENTYPE_RUN_LOG_ROOT": path("run-logs"),
        ]
    }

    /// Spawns the sidecar and blocks (asynchronously) until it responds
    /// healthily on its Unix socket, or throws after a short timeout.
    func start() async throws {
        Self.debugLog("start() called, socketURL=\(socketURL.path)")
        // Remove any stale socket left behind by a previous run so readiness
        // polling below can't be fooled by a dead file.
        try? FileManager.default.removeItem(at: socketURL)

        // Fresh intent flag for this run; `stop()` (and the failed-startup
        // teardown below) mark it so the terminationHandler can tell an
        // intentional shutdown from an unexpected crash.
        let terminationIntent = TerminationIntentFlag()
        self.terminationIntent = terminationIntent

        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        // Merge bundled sidecar.env values first, then always set the socket
        // path last, so nothing in a bundled env file can ever override it.
        for (key, value) in Self.loadBundledEnvironment() {
            environment[key] = value
        }
        environment["OPENTYPE_SIDECAR_SOCKET"] = socketURL.path
        for (key, value) in Self.dataDirectoryEnvironment(socketURL: socketURL) {
            environment[key] = value
        }

        let bundledBinaryPath = (Bundle.main.resourcePath ?? "")
            .appending("/opentype-sidecar")
        let bundledIsExecutable = FileManager.default.isExecutableFile(atPath: bundledBinaryPath)
        Self.debugLog("bundledBinaryPath=\(bundledBinaryPath) isExecutable=\(bundledIsExecutable) loadedEnvKeys=\(Self.loadBundledEnvironment().keys.sorted())")
        if bundledIsExecutable {
            process.executableURL = URL(fileURLWithPath: bundledBinaryPath)
            process.arguments = []
            // `build-app.sh` copies `sidecar/whisper-env/` and
            // `sidecar/whisper/` into Contents/Resources alongside the
            // compiled `opentype-sidecar` binary itself -- the bundled
            // binary has no reliable way to find the original source
            // checkout at an arbitrary launch-time cwd (same reasoning as
            // OPENTYPE_SIDECAR_DB_PATH above), so point it at the bundled,
            // absolute copies instead of `WhisperClient`'s relative
            // dev-mode defaults.
            let resourcePath = Bundle.main.resourcePath ?? ""
            environment["OPENTYPE_WHISPER_PYTHON_BIN"] = resourcePath
                .appending("/whisper-env/bin/python3")
            environment["OPENTYPE_WHISPER_SCRIPT_PATH"] = resourcePath
                .appending("/whisper/serve.py")
        } else {
            // Dev-mode fallback: run the sidecar straight from TypeScript
            // source via `bun run`. There is no reliable way to find the
            // repo root from a built app bundle at runtime, so this is a
            // dev-only convenience — packaging replaces this whole branch
            // with the bundled-binary path above.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bun", "run", "src/server.ts"]
            let devPath = ProcessInfo.processInfo
                .environment["OPENTYPE_SIDECAR_DEV_PATH"]
                ?? Self.defaultDevSidecarDirectory()
            process.currentDirectoryURL = URL(
                fileURLWithPath: devPath,
                isDirectory: true
            )
        }
        process.environment = environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        // Drain the sidecar's stdout/stderr CONTINUOUSLY on background readers
        // rather than once inside `terminationHandler` (P1-6). This is a
        // long-lived child: once it writes more than the OS pipe buffer
        // (~64 KB) over its lifetime, a pipe read deferred to termination
        // would block the sidecar itself the moment its buffer fills, and it
        // never terminates during normal operation. Streaming each chunk to
        // the debug log as it arrives preserves (and improves on) the previous
        // startup-diagnostics behavior.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                Self.debugLog("sidecar stdout: \(text)")
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                Self.debugLog("sidecar stderr: \(text)")
            }
        }

        process.terminationHandler = { [weak self] finished in
            // Pipes are already being drained by the readability handlers
            // above; tear them down and just record the exit here.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.debugLog("terminated status=\(finished.terminationStatus) reason=\(finished.terminationReason.rawValue)")
            // An INTENTIONAL stop (app quit / explicit stop() / a failed-startup
            // teardown) is expected — do nothing. An UNEXPECTED crash after a
            // healthy start must notify AppModel so it can move to a visible
            // non-ready state and attempt a bounded auto-restart (P1-4), instead
            // of leaving the status stuck reading "ready" against a dead process.
            if terminationIntent.isIntentional { return }
            Task { @MainActor in
                self?.onUnexpectedTermination?()
            }
        }

        do {
            try process.run()
            Self.debugLog("process.run() succeeded, pid=\(process.processIdentifier)")
        } catch {
            Self.debugLog("process.run() threw: \(error)")
            throw SidecarClientError.processFailedToStart(
                error.localizedDescription
            )
        }
        self.process = process

        do {
            try await waitUntilReady()
            Self.debugLog("waitUntilReady() succeeded")
        } catch {
            Self.debugLog("waitUntilReady() threw: \(error) isRunning=\(process.isRunning)")
            // This teardown is intentional (start() is about to throw and the
            // caller handles it) — don't let the terminationHandler mistake it
            // for a crash and kick off an auto-restart.
            terminationIntent.markIntentional()
            process.terminate()
            self.process = nil
            throw error
        }
    }

    /// Reads `<resourcePath>/sidecar.env` (KEY=VALUE lines, via the existing
    /// `EnvironmentFileParser`) if present, for injection into the sidecar
    /// child process's environment. A `bun build --compile` binary doesn't
    /// carry `sidecar/.env.local` with it and has no reliable way to find the
    /// source checkout at an arbitrary launch-time cwd, so `build-app.sh`
    /// copies that file into `Contents/Resources/sidecar.env` at package
    /// time — this is the only way the bundled binary learns provider
    /// credentials. Returns `[:]` if the file doesn't exist (e.g. in dev-mode
    /// runs, where Bun already auto-loads `.env.local` from the sidecar
    /// source directory itself).
    ///
    /// - Parameter resourcePath: Overridable for testing; defaults to
    ///   `Bundle.main.resourcePath`.
    nonisolated static func loadBundledEnvironment(
        resourcePath: String? = Bundle.main.resourcePath
    ) -> [String: String] {
        guard let resourcePath else { return [:] }
        let envFilePath = resourcePath.appending("/sidecar.env")
        guard let contents = try? String(contentsOfFile: envFilePath, encoding: .utf8) else {
            return [:]
        }
        return EnvironmentFileParser.parse(contents)
    }

    /// Terminates the child process, if running, and clears our reference to
    /// it. `OpenTypeApp.swift`'s `applicationWillTerminate(_:)` invokes this on
    /// app quit (via `AppModel.stopSidecar()`); `deinit` above provides a
    /// best-effort fallback for any other teardown path.
    func stop() {
        guard let process else { return }
        // Mark this as an intentional shutdown so the terminationHandler doesn't
        // treat the exit as a crash and trigger an auto-restart.
        terminationIntent.markIntentional()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
    }

    private func waitUntilReady(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketURL.path),
               let healthy = try? await healthCheck(),
               healthy {
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw SidecarClientError.timedOutWaitingForReadiness
    }

    // MARK: - Requests

    private struct HealthResponse: Decodable {
        let status: String
    }

    /// Hits `GET /health` and reports whether the sidecar considers itself ok.
    func healthCheck() async throws -> Bool {
        let response: HealthResponse = try await request(
            method: "GET",
            path: "/health"
        )
        return response.status == "ok"
    }

    /// The sidecar's `GET /agent/progress/:runId` response — the live,
    /// display-truncated progress snapshot for one Agent run. `status` is
    /// `"running"`/`"done"`/`"failed"`, or `"unknown"` (with empty `events`)
    /// for an id the sidecar isn't tracking, always as a 200 — an unknown id
    /// is "nothing to show", not an error.
    struct AgentProgressResponse: Decodable {
        let status: String
        let events: [SidecarAgentProgressEvent]
    }

    /// Polls the live progress feed for the Agent run dispatched with
    /// `runId` (see `AppModel.dispatchAgentRun`). The id rides on the URL
    /// path, so it's percent-encoded here — including `/`, which
    /// `.urlPathAllowed` alone would let through as a path separator.
    func agentProgress(runId: String) async throws -> AgentProgressResponse {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = runId.addingPercentEncoding(withAllowedCharacters: allowed) ?? runId
        return try await request(method: "GET", path: "/agent/progress/\(encoded)")
    }

    /// The sidecar's answer to `POST /agent/cancel/:runId`.
    struct AgentCancelResponse: Decodable {
        /// `false` for an unknown or already-settled id — not an error, just
        /// nothing to cancel (the sidecar's documented semantics).
        let cancelled: Bool
    }

    /// Asks the sidecar to stop an in-flight Agent run (T1). The run itself
    /// reports its own terminal state: the blocked `/agent/run` call answers
    /// 499, and `AppModel.runAgentDispatch` turns that into `.cancelled`. This
    /// call only delivers the signal, so a lost response cannot leave the
    /// record disagreeing with the run.
    func cancelAgentRun(runId: String) async throws -> AgentCancelResponse {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = runId.addingPercentEncoding(withAllowedCharacters: allowed) ?? runId
        return try await request(method: "POST", path: "/agent/cancel/\(encoded)")
    }

    /// Reads the question one Agent run is currently waiting on (T5), or an
    /// empty list when it is not waiting on anything. Polled on the same tick
    /// as progress, so asking needs no second polling loop.
    func agentQuestion(runId: String) async throws -> AgentQuestionPrompt {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = runId.addingPercentEncoding(withAllowedCharacters: allowed) ?? runId
        return try await request(method: "GET", path: "/agent/question/\(encoded)")
    }

    /// Delivers the user's answer back to a waiting Agent run (T5).
    @discardableResult
    func answerAgentQuestion(
        runId: String,
        answers: [AgentQuestionAnswerItem]
    ) async throws -> AgentAnswerAck {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = runId.addingPercentEncoding(withAllowedCharacters: allowed) ?? runId
        return try await request(
            method: "POST",
            path: "/agent/answer/\(encoded)",
            body: AgentAnswerBody(answers: answers)
        )
    }

    private struct AgentAnswerBody: Encodable {
        let answers: [AgentQuestionAnswerItem]
    }

    /// The sidecar's acknowledgement of a delivered answer.
    struct AgentAnswerAck: Decodable {
        let delivered: Bool
    }

    /// Generic request helper: shells out to `curl --unix-socket`, then
    /// decodes stdout as JSON into `Response`. More endpoints beyond
    /// `/health` will be added to the sidecar later; this method doesn't
    /// assume anything about which paths exist.
    func request<Response: Decodable>(
        method: String,
        path: String,
        body: Encodable? = nil,
        timeoutSeconds: Int = sidecarRequestTimeoutSeconds
    ) async throws -> Response {
        let bodyData: Data?
        if let body {
            bodyData = try JSONEncoder().encode(AnyEncodableBody(body))
        } else {
            bodyData = nil
        }

        let rawOutput = try await runCurl(
            method: method,
            path: path,
            bodyData: bodyData,
            timeoutSeconds: timeoutSeconds
        )
        let (body, status) = Self.splitBodyAndStatus(fromRawOutput: rawOutput)
        return try Self.decodeResponse(fromRawOutput: body, status: status ?? 0)
    }

    /// Splits `curl -w '\n%{http_code}'`'s output into the response body and
    /// the observed HTTP status. `nonisolated`/`static` so it's directly unit
    /// testable. Falls back to treating the whole output as body (status
    /// `nil`) if the trailing line isn't a bare integer, rather than
    /// crashing — a defensive guard against `curl`'s output format ever
    /// changing shape underneath this parsing.
    nonisolated static func splitBodyAndStatus(
        fromRawOutput output: String
    ) -> (body: String, status: Int?) {
        guard let lastNewline = output.lastIndex(of: "\n") else {
            return (output, nil)
        }
        let trailing = output[output.index(after: lastNewline)...]
        guard let status = Int(trailing) else {
            return (output, nil)
        }
        return (String(output[output.startIndex..<lastNewline]), status)
    }

    /// Builds the `curl` argument list (and any stdin payload) for one
    /// request, as a pure function so the argv construction can be unit tested
    /// without spawning a process — mirroring the `nonisolated static`
    /// `splitBodyAndStatus` / `decodeResponse` seams.
    ///
    /// The request body is delivered over **stdin** (`-d @-`), never as an
    /// argv element: a real recording's base64 audio payload can exceed Darwin
    /// ARG_MAX (~1 MB), which fails the spawn with `E2BIG`, and putting a body
    /// (or the API key it may carry) on argv also leaks it to every `ps`
    /// observer for the lifetime of the process (P0-1 / P1-13). A finite
    /// `--max-time` is always included so a wedged socket can't hang the
    /// request forever (P0-2).
    ///
    /// - Returns: the curl `arguments` (body-free) and the `stdinBody` to feed
    ///   the process's standard input (`nil` when there is no request body).
    nonisolated static func curlInvocation(
        socketPath: String,
        method: String,
        path: String,
        bodyData: Data?,
        /// Overridable per request, defaulted so every existing call site keeps
        /// the shared ceiling. Transcription is the one caller that raises it:
        /// while the speech model is still downloading the whisper server holds
        /// the request until it is ready, and 300s would walk away from a
        /// recording the user has already spoken — see
        /// `WhisperReadinessPolicy.transcribeTimeoutSeconds`.
        timeoutSeconds: Int = sidecarRequestTimeoutSeconds
    ) -> (arguments: [String], stdinBody: Data?) {
        var arguments = [
            "--unix-socket", socketPath,
            "-sS",
            "--max-time", String(timeoutSeconds),
            "-w", "\n%{http_code}",
            "-X", method
        ]
        if let bodyData {
            arguments += [
                "-H", "Content-Type: application/json",
                // Suppress curl's automatic `Expect: 100-continue`. Against a
                // local Unix-socket sidecar it only costs a round trip — curl
                // stalls ~1s waiting for a `100 Continue` the sidecar never
                // sends before releasing the body — and sending the request
                // headers and body together is what a simple HTTP reader
                // expects anyway.
                "-H", "Expect:",
                // Stream the request body from stdin (`@-`); see the method
                // doc for why it must never ride on argv.
                "-d", "@-"
            ]
            arguments.append("http://localhost\(path)")
            return (arguments, bodyData)
        }
        arguments.append("http://localhost\(path)")
        return (arguments, nil)
    }

    /// Runs `curl` against the Unix socket and returns raw stdout text (the
    /// response body followed by a newline and the HTTP status code, per
    /// `-w '\n%{http_code}'` — see `splitBodyAndStatus`). Separated from
    /// response decoding so the decoding logic can be unit tested against
    /// canned strings without spawning a process.
    private func runCurl(
        method: String,
        path: String,
        bodyData: Data?,
        timeoutSeconds: Int = sidecarRequestTimeoutSeconds
    ) async throws -> String {
        let invocation = Self.curlInvocation(
            socketPath: socketURL.path,
            method: method,
            path: path,
            bodyData: bodyData,
            timeoutSeconds: timeoutSeconds
        )
        let control = CurlProcessControl()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = invocation.arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdinPipe: Pipe? = invocation.stdinBody != nil ? Pipe() : nil
                if let stdinPipe {
                    process.standardInput = stdinPipe
                }

                // Drain stdout AND stderr on independent background queues so a
                // response larger than the OS pipe buffer (~64 KB) can't block
                // curl mid-write and wedge the request forever (P0-2). Reading
                // only inside `terminationHandler` deadlocks in exactly that
                // case: curl blocks writing to a full stdout pipe, never
                // exits, and the handler never fires.
                let ioQueue = DispatchQueue(
                    label: "ai.rain.opentype.curl-io",
                    attributes: .concurrent
                )
                let group = DispatchGroup()
                let stdoutBox = DataBox()
                let stderrBox = DataBox()

                group.enter()
                ioQueue.async {
                    stdoutBox.append(
                        stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    )
                    group.leave()
                }
                group.enter()
                ioQueue.async {
                    stderrBox.append(
                        stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    )
                    group.leave()
                }

                group.enter()
                process.terminationHandler = { _ in
                    group.leave()
                }

                // Resume once both drains have hit EOF and the process has
                // exited — the DispatchGroup gives a happens-before edge, so
                // the boxes are safe to read here without further locking.
                group.notify(queue: ioQueue) {
                    guard control.claimResume() else { return }
                    let stdoutString = String(data: stdoutBox.value, encoding: .utf8) ?? ""
                    let stderrString = String(data: stderrBox.value, encoding: .utf8) ?? ""
                    let status = control.terminationStatus()
                    if status != 0 {
                        continuation.resume(
                            throwing: SidecarClientError.requestFailed(
                                exitCode: status,
                                stderr: stderrString
                            )
                        )
                    } else {
                        continuation.resume(returning: stdoutString)
                    }
                }

                control.setProcess(process)

                do {
                    try process.run()
                    if let stdinPipe, let body = invocation.stdinBody {
                        // Feed the body over stdin from a background queue so a
                        // large payload filling the stdin pipe buffer can't
                        // block before curl starts reading it.
                        let writeHandle = stdinPipe.fileHandleForWriting
                        ioQueue.async {
                            try? writeHandle.write(contentsOf: body)
                            try? writeHandle.close()
                        }
                    }
                } catch {
                    // The child never launched, so its termination handler will
                    // never fire and the drain reads would block forever on
                    // pipes whose write ends the parent still holds. Close them
                    // so the readers hit EOF and unwind, then resume the error.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    try? stdinPipe?.fileHandleForWriting.close()
                    if control.claimResume() {
                        continuation.resume(
                            throwing: SidecarClientError.requestFailed(
                                exitCode: -1,
                                stderr: error.localizedDescription
                            )
                        )
                    }
                }
            }
        } onCancel: {
            // A cancelled Swift Task promptly SIGTERMs the curl child; it then
            // exits, the group completes, and the continuation resumes with a
            // non-zero status (throwing) instead of hanging forever (P0-2).
            control.terminate()
        }
    }

    /// Decodes raw `curl` stdout text into `Response`. `nonisolated` and
    /// `static` so it can be exercised directly from unit tests without
    /// needing a running process or MainActor hop.
    nonisolated static func decodeResponse<Response: Decodable>(
        fromRawOutput output: String,
        status: Int = 0
    ) throws -> Response {
        guard let data = output.data(using: .utf8), !data.isEmpty else {
            throw SidecarClientError.emptyResponse
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SidecarClientError.responseDecodingFailed(
                status: status,
                reason: error.localizedDescription,
                body: output
            )
        }
    }
}
