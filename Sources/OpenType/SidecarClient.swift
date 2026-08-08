import Foundation

/// Errors surfaced by `SidecarClient` while launching, health-checking, or
/// issuing HTTP-over-Unix-socket requests to the local sidecar process.
enum SidecarClientError: Error, LocalizedError, Equatable {
    /// The child process could not be spawned at all (e.g. bad executable path).
    case processFailedToStart(String)
    /// The sidecar did not become ready (socket + healthy `/health`) within the timeout.
    case timedOutWaitingForReadiness
    /// The `curl` subprocess exited non-zero, or failed to launch.
    case requestFailed(exitCode: Int32, stderr: String)
    /// stdout from `curl` was empty or not valid JSON for the requested type.
    case responseDecodingFailed(String)
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
        case .responseDecodingFailed(let reason):
            return "Failed to decode sidecar response: \(reason)"
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

/// Launches the local TypeScript/Bun sidecar as a child process and talks to
/// it over a Unix domain socket (via `curl`, since `URLSession` cannot speak
/// to Unix sockets directly). Mirrors the rest of this codebase's
/// `@MainActor final class` convention for stateful collaborators
/// (`AudioRecorder`, `AppModel`) since this type owns mutable process state
/// that should only ever be touched from one place at a time.
@MainActor
final class SidecarClient {
    private let socketURL: URL
    private var process: Process?

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

    // MARK: - Lifecycle

    /// Spawns the sidecar and blocks (asynchronously) until it responds
    /// healthily on its Unix socket, or throws after a short timeout.
    func start() async throws {
        // Remove any stale socket left behind by a previous run so readiness
        // polling below can't be fooled by a dead file.
        try? FileManager.default.removeItem(at: socketURL)

        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        environment["OPENTYPE_SIDECAR_SOCKET"] = socketURL.path

        let bundledBinaryPath = (Bundle.main.resourcePath ?? "")
            .appending("/opentype-sidecar")
        if FileManager.default.isExecutableFile(atPath: bundledBinaryPath) {
            // Packaging work later tonight will produce this compiled
            // binary; this branch isn't exercised yet but is the intended
            // production path.
            process.executableURL = URL(fileURLWithPath: bundledBinaryPath)
            process.arguments = []
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
                ?? "/Users/diywang/hackathon/OpenType/sidecar"
            process.currentDirectoryURL = URL(
                fileURLWithPath: devPath,
                isDirectory: true
            )
        }
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw SidecarClientError.processFailedToStart(
                error.localizedDescription
            )
        }
        self.process = process

        do {
            try await waitUntilReady()
        } catch {
            process.terminate()
            self.process = nil
            throw error
        }
    }

    /// Terminates the child process, if running, and clears our reference to
    /// it. Callers (or an app-quit hook, if one is wired up later) should
    /// invoke this on shutdown; there is currently no `applicationWillTerminate`
    /// hook in `OpenTypeApp.swift` to attach to, so `deinit` above provides a
    /// best-effort fallback.
    func stop() {
        guard let process else { return }
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

    /// Generic request helper: shells out to `curl --unix-socket`, then
    /// decodes stdout as JSON into `Response`. More endpoints beyond
    /// `/health` will be added to the sidecar later; this method doesn't
    /// assume anything about which paths exist.
    func request<Response: Decodable>(
        method: String,
        path: String,
        body: Encodable? = nil
    ) async throws -> Response {
        let bodyData: Data?
        if let body {
            bodyData = try JSONEncoder().encode(AnyEncodableBody(body))
        } else {
            bodyData = nil
        }

        let output = try await runCurl(
            method: method,
            path: path,
            bodyData: bodyData
        )
        return try Self.decodeResponse(fromRawOutput: output)
    }

    /// Runs `curl` against the Unix socket and returns raw stdout text.
    /// Separated from response decoding so the decoding logic can be unit
    /// tested against canned strings without spawning a process.
    private func runCurl(
        method: String,
        path: String,
        bodyData: Data?
    ) async throws -> String {
        var arguments = [
            "--unix-socket", socketURL.path,
            "-sS",
            "-X", method
        ]
        if let bodyData, let bodyString = String(data: bodyData, encoding: .utf8) {
            arguments += ["-d", bodyString, "-H", "Content-Type: application/json"]
        }
        arguments.append("http://localhost\(path)")

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { finishedProcess in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

                if finishedProcess.terminationStatus != 0 {
                    continuation.resume(
                        throwing: SidecarClientError.requestFailed(
                            exitCode: finishedProcess.terminationStatus,
                            stderr: stderrString
                        )
                    )
                    return
                }
                continuation.resume(returning: stdoutString)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: SidecarClientError.requestFailed(
                        exitCode: -1,
                        stderr: error.localizedDescription
                    )
                )
            }
        }
    }

    /// Decodes raw `curl` stdout text into `Response`. `nonisolated` and
    /// `static` so it can be exercised directly from unit tests without
    /// needing a running process or MainActor hop.
    nonisolated static func decodeResponse<Response: Decodable>(
        fromRawOutput output: String
    ) throws -> Response {
        guard let data = output.data(using: .utf8), !data.isEmpty else {
            throw SidecarClientError.emptyResponse
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SidecarClientError.responseDecodingFailed(
                error.localizedDescription
            )
        }
    }
}
