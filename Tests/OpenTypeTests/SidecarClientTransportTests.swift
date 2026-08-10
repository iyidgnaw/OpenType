import Foundation
import Darwin
import Testing
@testable import OpenType

// MARK: - TDD Stage 1 (write failing tests) for SidecarClient's curl transport
//
// These tests harden the `curl`-over-Unix-socket transport in
// `Sources/OpenType/SidecarClient.swift` against three already-verified bugs:
//
//   P0-1 / P1-13 — the request body is passed as a curl argv element
//     (`arguments += ["-d", bodyString, ...]`). This blows past macOS ARG_MAX
//     (~1 MB total argv+env) so recordings longer than ~20 s fail with E2BIG,
//     AND it leaks the API key / raw voice content to any `ps` observer while
//     curl is running. The body must instead be delivered over stdin
//     (`-d @-`) or a temp file (`--data-binary @file`), never on argv.
//
//   P0-2 (drain) — curl's stdout is only read inside `terminationHandler`
//     (`readDataToEndOfFile()`), so any response larger than the OS pipe
//     buffer (~64 KB) deadlocks: curl blocks writing to a full stdout pipe,
//     never exits, the termination handler never fires, and the continuation
//     never resumes. stdout must be drained concurrently with the process.
//
//   P0-2 (timeout / cancellation) — there is no `--max-time` and the transport
//     uses `withCheckedThrowingContinuation` (not `withTaskCancellationHandler`),
//     so a hung socket wedges forever and a cancelled Swift Task never unwinds.
//
// Frameworks note: the existing suite in `OpenTypeTests.swift` is XCTest, but
// this file uses Swift Testing (`import Testing`, `@Test`) per the Stage-1
// brief. Both frameworks coexist in the same SwiftPM test target under the
// Swift 6.3 toolchain.
//
// Two of the tests below (`largeRequestBodyIsDeliveredViaStdinNotArgv` and
// `requestWithoutBodyUsesNoStdinButStillSetsTimeout`) are DELIBERATE
// compile-reds: they target a not-yet-existing pure seam,
// `SidecarClient.curlInvocation(socketPath:method:path:bodyData:)`, which
// Stage 3 must add (mirroring the existing `nonisolated static`
// `splitBodyAndStatus` / `decodeResponse` seams) so the argv construction can
// be unit-tested without spawning a process. The remaining tests are runtime
// reds that compile against the current public API and fail on the live bugs.

// MARK: - Test helpers

/// A Sendable summary of a transport attempt, so async probe closures can hand
/// their result back across concurrency boundaries without moving a
/// non-Sendable `Error` or `SidecarClient` response.
private struct TransportProbe: Sendable {
    var succeeded: Bool
    var intValue: Int?
    var stringValue: String?
    var errorText: String?
}

/// Result of running an async operation under a wall-clock deadline.
private enum BoundedOutcome<T: Sendable>: Sendable {
    case completed(T)
    case timedOut
}

/// Resumes a `CheckedContinuation` at most once, from whichever of two racing
/// tasks (work vs. deadline) finishes first. Thread-safe via a plain lock.
private final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume { continuation.resume(returning: value) }
    }
}

/// Runs `operation` but never blocks the caller longer than `seconds`. If the
/// operation doesn't finish in time (e.g. it's wedged on a non-cancellable
/// continuation), `.timedOut` is returned and the still-running work is
/// cancelled and leaked — so a buggy hang shows up as a test failure instead of
/// hanging the whole suite forever. Unstructured tasks are used on purpose:
/// a structured task group would itself await the wedged child at scope exit.
private func runBounded<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async -> T
) async -> BoundedOutcome<T> {
    await withCheckedContinuation { (continuation: CheckedContinuation<BoundedOutcome<T>, Never>) in
        let once = OnceResume(continuation)
        let work = Task {
            let value = await operation()
            once.resume(.completed(value))
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            work.cancel()
            once.resume(.timedOut)
        }
    }
}

/// A minimal, dependency-free HTTP/1.1 responder bound to a Unix domain socket,
/// used to exercise the real `curl` transport without standing up the whole
/// TypeScript/Bun sidecar. Handles one connection at a time on a background
/// queue, which is all these tests need (one request each).
private final class MockUnixSocketHTTPServer: @unchecked Sendable {
    enum Mode {
        /// Read the whole request (headers + Content-Length body) and reply
        /// `{"receivedBodyBytes": N}` — lets a test assert a large body
        /// round-trips end to end.
        case reportReceivedBodySize
        /// Reply with a JSON body of roughly `byteCount` bytes (used to exceed
        /// the OS stdout pipe buffer and trip the drain deadlock).
        case largeResponse(byteCount: Int)
        /// Accept the connection, read the request, and never reply — the
        /// connection stays open until `stop()`. Forces the client to depend on
        /// `--max-time` or Task cancellation to unwedge.
        case hangWithoutResponding
    }

    let socketURL: URL
    private let mode: Mode
    private let queue = DispatchQueue(label: "MockUnixSocketHTTPServer")
    private var listenFD: Int32 = -1
    private let stopLock = NSLock()
    private var stopped = false

    init(mode: Mode) {
        self.mode = mode
        // Darwin caps sun_path at 104 bytes, so keep this short and in /tmp
        // rather than FileManager's long per-process temp directory.
        self.socketURL = URL(
            fileURLWithPath: "/tmp/ot-tx-\(UUID().uuidString.prefix(8)).sock"
        )
    }

    private func isStopped() -> Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }

    func start() {
        let path = socketURL.path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed: \(String(cString: strerror(errno)))")

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                path.withCString { src in
                    strncpy(dst, src, 103)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bindResult == 0, "bind() failed: \(String(cString: strerror(errno)))")
        precondition(listen(fd, 4) == 0, "listen() failed: \(String(cString: strerror(errno)))")

        listenFD = fd
        queue.async { [weak self] in self?.serveLoop() }
    }

    private func serveLoop() {
        while !isStopped() {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 {
                if isStopped() { break }
                continue
            }
            handle(conn)
        }
    }

    private func handle(_ conn: Int32) {
        // Self-releasing timeouts so a stuck read/write can't pin this thread
        // across the whole test run.
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let chunkSize = 65536
        var scratch = [UInt8](repeating: 0, count: chunkSize)
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?

        // Read until end of headers.
        while headerEnd == nil {
            let n = read(conn, &scratch, chunkSize)
            if n <= 0 { break }
            buffer.append(contentsOf: scratch[0..<n])
            headerEnd = buffer.range(of: terminator)
        }
        guard let end = headerEnd else { close(conn); return }

        let headers = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let contentLength = Self.parseContentLength(headers) ?? 0
        var bodyBytesSoFar = buffer.count - end.upperBound
        while bodyBytesSoFar < contentLength {
            let n = read(conn, &scratch, chunkSize)
            if n <= 0 { break }
            bodyBytesSoFar += n
        }

        guard let response = responseData(receivedBodyBytes: bodyBytesSoFar) else {
            // hangWithoutResponding: hold the connection open, silent, until stop.
            while !isStopped() { usleep(50_000) }
            close(conn)
            return
        }

        response.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < response.count {
                let written = write(conn, base + offset, response.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        close(conn)
    }

    private func responseData(receivedBodyBytes: Int) -> Data? {
        switch mode {
        case .hangWithoutResponding:
            return nil
        case .reportReceivedBodySize:
            return Self.httpJSONResponse(#"{"receivedBodyBytes":\#(receivedBodyBytes)}"#)
        case .largeResponse(let byteCount):
            let blob = String(repeating: "a", count: max(0, byteCount))
            return Self.httpJSONResponse(#"{"blob":"\#(blob)"}"#)
        }
    }

    private static func httpJSONResponse(_ json: String) -> Data {
        let body = Data(json.utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    private static func parseContentLength(_ headers: String) -> Int? {
        for rawLine in headers.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    func stop() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketURL.path)
    }

    deinit { stop() }
}

// MARK: - Canned Decodable response shapes

private struct BodySizeResponse: Decodable, Sendable {
    let receivedBodyBytes: Int
}

private struct BlobResponse: Decodable, Sendable {
    let blob: String
}

/// A large request body whose JSON encoding comfortably exceeds ARG_MAX
/// (1,048,576 bytes on Darwin). Stands in for a real multi-second recording's
/// base64 audio payload.
private struct LargeAudioBody: Encodable {
    let audioBase64: String
}

// MARK: - Tests

@Suite("SidecarClient curl transport")
struct SidecarClientTransportTests {

    // MARK: P0-1 / P1-13 — request body must not ride on curl argv
    //
    // COMPILE-RED (expected): targets the not-yet-existing pure seam
    // `SidecarClient.curlInvocation(...)`. Stage 3 adds it, then this passes.

    @Test @MainActor
    func largeRequestBodyIsDeliveredViaStdinNotArgv() {
        // ~1.5 MB payload: individually larger than ARG_MAX, so it must not be
        // placed on argv under any circumstances.
        let payload = String(repeating: "A", count: 1_500_000)
        let bodyData = Data(#"{"audioBase64":"\#(payload)"}"#.utf8)

        let invocation = SidecarClient.curlInvocation(
            socketPath: "/tmp/ot-transport-seam.sock",
            method: "POST",
            path: "/asr/transcribe",
            bodyData: bodyData
        )

        // The body bytes are handed to curl via stdin, never as an argument.
        #expect(invocation.stdinBody == bodyData)
        for argument in invocation.arguments {
            #expect(
                !argument.contains(payload),
                "request body must not appear on curl argv (ARG_MAX + `ps` leak)"
            )
        }
        // `-d @-` is curl's "read the request body from stdin" sentinel.
        #expect(invocation.arguments.contains("@-"))
        // A finite overall transport timeout must be present (P0-2).
        #expect(invocation.arguments.contains("--max-time"))
    }

    @Test @MainActor
    func requestWithoutBodyUsesNoStdinButStillSetsTimeout() {
        let invocation = SidecarClient.curlInvocation(
            socketPath: "/tmp/ot-transport-seam.sock",
            method: "GET",
            path: "/health",
            bodyData: nil
        )

        #expect(invocation.stdinBody == nil)
        #expect(!invocation.arguments.contains("-d"))
        #expect(invocation.arguments.contains("--unix-socket"))
        #expect(invocation.arguments.contains("/tmp/ot-transport-seam.sock"))
        // Even a bodyless GET must carry a finite timeout (P0-2).
        #expect(invocation.arguments.contains("--max-time"))
        // ...whose value parses as a positive number.
        if let idx = invocation.arguments.firstIndex(of: "--max-time"),
           idx + 1 < invocation.arguments.count,
           let seconds = Double(invocation.arguments[idx + 1]) {
            #expect(seconds > 0)
        } else {
            Issue.record("--max-time must be followed by a positive numeric value")
        }
    }

    // MARK: P0-1 / P1-13 — a ~2 MB body must round-trip (currently E2BIG)
    //
    // RUNTIME-RED: with the body on argv, spawning curl fails with E2BIG before
    // a single byte is sent, so `request` throws instead of succeeding.

    @Test @MainActor
    func largeRequestBodyRoundTripsThroughTheTransport() async {
        let server = MockUnixSocketHTTPServer(mode: .reportReceivedBodySize)
        server.start()
        defer { server.stop() }
        let client = SidecarClient(socketURL: server.socketURL)

        // ~2 MB, safely over ARG_MAX (1,048,576 bytes).
        let payloadByteCount = 2_000_000
        let body = LargeAudioBody(
            audioBase64: String(repeating: "A", count: payloadByteCount)
        )

        let outcome = await runBounded(20) { () -> TransportProbe in
            do {
                let response: BodySizeResponse = try await client.request(
                    method: "POST",
                    path: "/asr/transcribe",
                    body: body
                )
                return TransportProbe(
                    succeeded: true,
                    intValue: response.receivedBodyBytes
                )
            } catch {
                return TransportProbe(
                    succeeded: false,
                    errorText: String(describing: error)
                )
            }
        }

        switch outcome {
        case .completed(let probe):
            #expect(
                probe.succeeded,
                "large body request failed (likely E2BIG from argv): \(probe.errorText ?? "?")"
            )
            #expect(
                (probe.intValue ?? 0) >= payloadByteCount,
                "server did not receive the full body — expected >= \(payloadByteCount), got \(probe.intValue ?? -1)"
            )
        case .timedOut:
            Issue.record("large body request did not complete within 20s")
        }
    }

    // MARK: P0-2 (drain) — a >256 KB response must not deadlock
    //
    // RUNTIME-RED: stdout is only drained in `terminationHandler`, so curl
    // blocks writing to a full ~64 KB pipe, never exits, and the continuation
    // never resumes.

    @Test @MainActor
    func largeResponseIsReceivedWithoutStdoutDeadlock() async {
        // 512 KB response body — well past the OS stdout pipe buffer.
        let responseBytes = 512_000
        let server = MockUnixSocketHTTPServer(
            mode: .largeResponse(byteCount: responseBytes)
        )
        server.start()
        defer { server.stop() }
        let client = SidecarClient(socketURL: server.socketURL)

        let outcome = await runBounded(6) { () -> TransportProbe in
            do {
                let response: BlobResponse = try await client.request(
                    method: "GET",
                    path: "/oneshot/ask"
                )
                return TransportProbe(succeeded: true, intValue: response.blob.count)
            } catch {
                return TransportProbe(succeeded: false, errorText: String(describing: error))
            }
        }

        switch outcome {
        case .completed(let probe):
            #expect(
                probe.succeeded,
                "large response request failed: \(probe.errorText ?? "?")"
            )
            #expect(
                (probe.intValue ?? 0) >= responseBytes,
                "decoded blob was truncated — expected >= \(responseBytes), got \(probe.intValue ?? -1)"
            )
        case .timedOut:
            Issue.record(
                "large response deadlocked: curl's stdout is only drained in terminationHandler, so a response past the pipe buffer wedges forever"
            )
        }
    }

    // MARK: P0-2 (cancellation) — a cancelled Task must unwind promptly
    //
    // RUNTIME-RED: `withCheckedThrowingContinuation` ignores cancellation, so a
    // cancelled request never terminates its curl child nor resumes.

    @Test @MainActor
    func cancelledRequestUnwindsPromptlyInsteadOfHangingForever() async {
        let server = MockUnixSocketHTTPServer(mode: .hangWithoutResponding)
        server.start()
        defer { server.stop() }
        let client = SidecarClient(socketURL: server.socketURL)

        let requestTask = Task { @Sendable () -> String in
            do {
                let _: BlobResponse = try await client.request(
                    method: "GET",
                    path: "/agent/run"
                )
                return "returned"
            } catch {
                return "threw"
            }
        }

        // Let curl actually spawn and connect before cancelling.
        try? await Task.sleep(nanoseconds: 500_000_000)
        requestTask.cancel()

        let outcome = await runBounded(4) { () -> String in
            await requestTask.value
        }

        switch outcome {
        case .completed(let how):
            #expect(
                how == "threw",
                "a cancelled request should throw, not return a value (got \(how))"
            )
        case .timedOut:
            Issue.record(
                "cancelled request did not unwind within 4s — Task cancellation is not propagated to the curl subprocess (uses withCheckedThrowingContinuation, not withTaskCancellationHandler, and passes no --max-time)"
            )
        }
    }
}
