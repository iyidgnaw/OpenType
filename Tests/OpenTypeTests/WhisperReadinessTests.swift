import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the Swift half of §E of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — 消灭「装完、按热键、
/// 说完、松开、什么都没有」这一分钟.
///
/// The minute in question (`docs/reviews/2026-08-15-product-review.md` §3): the
/// installer says 「The first thing you transcribe downloads a ~460 MB speech
/// model」 **in the terminal**, and the app says nothing at all. This file covers
/// the three decisions that make it visible, all of them pure — no timer, no
/// socket, no clock, and nothing here reaches `/asr/status` for real.
///
/// # Production API this file pins (`Sources/OpenType/WhisperReadiness.swift`)
///
/// ```swift
/// enum WhisperModelState: String, Codable, CaseIterable, Equatable {
///     case starting, downloading, loading, ready, failed
/// }
///
/// enum WhisperBackend: String, Codable, Equatable { case local, remote }
///
/// struct WhisperStatusSnapshot: Equatable, Decodable {
///     let state: WhisperModelState
///     let backend: WhisperBackend
///     let model: String?
///     let downloadedBytes: Int64?
///     let totalBytes: Int64?
///     let error: String?
///     var fractionComplete: Double? { get }
/// }
///
/// enum WhisperPollOutcome: Equatable {
///     case status(WhisperModelState)
///     case unreachable
/// }
///
/// enum WhisperPollDecision: Equatable {
///     case poll(afterSeconds: TimeInterval)
///     case stop
/// }
///
/// enum WhisperStatusPolling {
///     static let interval: TimeInterval
///     static let maxBackoff: TimeInterval
///     static let maxConsecutiveFailures: Int
///     static func shouldStart(sidecarStatus: SidecarStatus) -> Bool
///     static func decide(
///         outcome: WhisperPollOutcome,
///         consecutiveFailureCount: Int
///     ) -> WhisperPollDecision
/// }
///
/// enum WhisperReadinessPolicy {
///     static func allowsRecording(_ state: WhisperModelState) -> Bool
///     static func showsPreparingBanner(_ state: WhisperModelState) -> Bool
///     static func transcribeTimeoutSeconds(_ state: WhisperModelState) -> Int
/// }
/// ```
///
/// Everything above is expected to FAIL TO COMPILE until stage 3 creates that
/// file. That is the correct red for a Swift feature whose types do not exist
/// yet: nothing is stubbed in here, and no production file is created by this
/// stage.
///
/// # Four decisions this file makes on stage 3's behalf, deliberately
///
/// 1. **Polling stops at `.ready`, and `.stop` is a real case rather than a very
///    long interval.** 「**只在非 ready 时轮询**，ready 之后停，不做常驻定时器」 is
///    the spec's own wording. A local-first menu-bar app that keeps a timer alive
///    for a question that was answered once, at launch, and cannot change without
///    a restart, is spending the user's battery on nothing.
///
/// 2. **`.failed` also stops.** It is terminal until the user acts: §E-3's exit
///    is 重试 + 「改用远程识别」, both user-initiated. Continuing to poll a load
///    that has already failed produces a spinner that resolves to nothing and
///    hides the two buttons that would actually fix it.
///
/// 3. **Recording is never refused.** `allowsRecording` is asserted over
///    `allCases`, because 「用户在未就绪时按了热键：录音照常进行（不阻止）」 is a
///    product promise, and a policy function with a state-dependent answer is one
///    refactor away from breaking it. What changes while the model loads is the
///    浮层 copy, not whether the microphone opens.
///
/// 4. **`transcribeTimeoutSeconds` exists, and this is the load-bearing half of
///    「录音不能丢」.** serve.py blocking on `wait_until_ready()` only preserves the
///    recording if the *caller* is still there when the model arrives, and
///    `SidecarClient`'s `curl --max-time` budget is 300s for every request today.
///    A 460 MB download over a hotel connection outlasts that comfortably, and
///    when it fires the user's dictation is gone with no explanation — the exact
///    failure this section exists to remove, just moved five minutes later. So
///    the budget has to be a function of what the model is doing. Stage 3 owns
///    threading it through `SidecarClient`; the tests below only fix the shape
///    and the direction.
final class WhisperReadinessTests: XCTestCase {

    // MARK: - Decoding /asr/status

    private func decode(_ json: String) throws -> WhisperStatusSnapshot {
        try JSONDecoder().decode(WhisperStatusSnapshot.self, from: Data(json.utf8))
    }

    func testDecodesALocalDownloadInProgress() throws {
        let snapshot = try decode(
            """
            {"state":"downloading","backend":"local",
             "model":"mlx-community/whisper-small-mlx",
             "downloadedBytes":123456789,"totalBytes":460000000}
            """
        )

        XCTAssertEqual(snapshot.state, .downloading)
        XCTAssertEqual(snapshot.backend, .local)
        XCTAssertEqual(snapshot.model, "mlx-community/whisper-small-mlx")
        XCTAssertEqual(snapshot.downloadedBytes, 123_456_789)
        XCTAssertEqual(snapshot.totalBytes, 460_000_000)
        XCTAssertNil(snapshot.error)
    }

    func testDecodesTheRemoteAnswerWhichCarriesNothingElse() throws {
        // The whole body a remote-Whisper user ever gets. Every other field has
        // to be optional or this decode throws and the poller backs off forever
        // against a perfectly healthy configuration.
        let snapshot = try decode(#"{"state":"ready","backend":"remote"}"#)

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.backend, .remote)
        XCTAssertNil(snapshot.model)
        XCTAssertNil(snapshot.downloadedBytes)
        XCTAssertNil(snapshot.totalBytes)
    }

    func testDecodesStartingWhileThePythonChildIsNotUp() throws {
        let snapshot = try decode(#"{"state":"starting","backend":"local"}"#)

        XCTAssertEqual(snapshot.state, .starting)
        XCTAssertEqual(snapshot.backend, .local)
    }

    func testDecodesAFailedLoadWithItsErrorText() throws {
        let snapshot = try decode(
            """
            {"state":"failed","backend":"local","model":"mlx-community/whisper-small-mlx",
             "downloadedBytes":300000000,"totalBytes":460000000,
             "error":"OSError: [Errno 28] No space left on device"}
            """
        )

        XCTAssertEqual(snapshot.state, .failed)
        // The message is the actionable content — 「没磁盘了」 and 「网断了」 have
        // different fixes, and the failure surface offers a choice.
        XCTAssertEqual(snapshot.error, "OSError: [Errno 28] No space left on device")
    }

    func testAnUnknownTotalDecodesAsNilRatherThanZero() throws {
        // 「拿不到就退化成 totalBytes: null」. Zero would render a bar frozen at 0%,
        // which is the blank screen this section removes, wearing a progress
        // indicator.
        let snapshot = try decode(
            #"{"state":"downloading","backend":"local","downloadedBytes":8192,"totalBytes":null}"#
        )

        XCTAssertNil(snapshot.totalBytes)
        XCTAssertEqual(snapshot.downloadedBytes, 8_192)
    }

    func testAnUnknownStateIsARejectedDecodeRatherThanASilentReady() throws {
        // Nothing may decode into `.ready` by accident: `.ready` is what stops
        // the poller and removes the banner. An unrecognised state has to land
        // in the transport-failure branch, where backoff applies and the banner
        // stays up.
        XCTAssertThrowsError(try decode(#"{"state":"warming","backend":"local"}"#))
    }

    func testAMissingBackendIsARejectedDecode() throws {
        // `GET /asr/status` always sends it; a body without one is not this
        // contract, and guessing `.local` would show a download bar to a remote
        // user.
        XCTAssertThrowsError(try decode(#"{"state":"ready"}"#))
    }

    // MARK: - fractionComplete

    func testFractionCompleteIsNilWhenTheTotalIsUnknown() throws {
        let snapshot = try decode(
            #"{"state":"downloading","backend":"local","downloadedBytes":8192,"totalBytes":null}"#
        )

        // nil means 「画不定量的进度」, not 「画 0%」. The two look nothing alike to
        // someone waiting.
        XCTAssertNil(snapshot.fractionComplete)
    }

    func testFractionCompleteIsNilWhenTheTotalIsZero() throws {
        let snapshot = try decode(
            #"{"state":"downloading","backend":"local","downloadedBytes":0,"totalBytes":0}"#
        )

        XCTAssertNil(snapshot.fractionComplete)
    }

    func testFractionCompleteIsNilWithoutADownloadedCount() throws {
        let snapshot = try decode(#"{"state":"ready","backend":"remote"}"#)

        XCTAssertNil(snapshot.fractionComplete)
    }

    func testFractionCompleteIsTheRatio() throws {
        let snapshot = try decode(
            #"{"state":"downloading","backend":"local","downloadedBytes":230000000,"totalBytes":460000000}"#
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.fractionComplete), 0.5, accuracy: 0.0001)
    }

    func testFractionCompleteIsClampedToOne() throws {
        // `huggingface_hub`'s progress hook can overshoot a total it estimated
        // from a partially cached snapshot. A bar past 100% reads as a bug in
        // the app rather than an artefact of the download library.
        let snapshot = try decode(
            #"{"state":"downloading","backend":"local","downloadedBytes":999,"totalBytes":460}"#
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.fractionComplete), 1.0, accuracy: 0.0001)
    }

    func testFractionCompleteIsClampedAtZeroFromBelow() throws {
        let snapshot = try decode(
            #"{"state":"downloading","backend":"local","downloadedBytes":-5,"totalBytes":460}"#
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.fractionComplete), 0.0, accuracy: 0.0001)
    }

    // MARK: - When to poll

    func testPollingOnlyStartsOnceTheSidecarIsReady() {
        // There is nobody to ask before that, and asking anyway would spend the
        // failure budget below on a sidecar that is merely still booting — so
        // the poller would already be in backoff at the moment whisper starts
        // downloading, which is the one moment it needs to be responsive.
        XCTAssertTrue(WhisperStatusPolling.shouldStart(sidecarStatus: .ready))
        XCTAssertFalse(WhisperStatusPolling.shouldStart(sidecarStatus: .starting))
        XCTAssertFalse(WhisperStatusPolling.shouldStart(sidecarStatus: .degraded))
        XCTAssertFalse(WhisperStatusPolling.shouldStart(sidecarStatus: .failed))
    }

    func testThePollIntervalIsFastEnoughToLookAlive() {
        // A 460 MB download is minutes long; a bar that moves once every 10s
        // reads as stuck. Fast enough to move, slow enough that a unix-socket
        // round trip per tick is free.
        XCTAssertGreaterThanOrEqual(WhisperStatusPolling.interval, 0.5)
        XCTAssertLessThanOrEqual(WhisperStatusPolling.interval, 3.0)
    }

    // MARK: - When to stop

    func testReadyStopsThePoller() {
        // 「ready 之后停，不做常驻定时器」. The headline assertion of this section.
        XCTAssertEqual(
            WhisperStatusPolling.decide(outcome: .status(.ready), consecutiveFailureCount: 0),
            .stop
        )
    }

    func testReadyStopsThePollerEvenAfterEarlierFailures() {
        // The sidecar restarting mid-download is ordinary; a success has to
        // clear the failure history rather than be evaluated against it.
        XCTAssertEqual(
            WhisperStatusPolling.decide(outcome: .status(.ready), consecutiveFailureCount: 3),
            .stop
        )
    }

    func testFailedStopsThePoller() {
        // Terminal until the user acts — see header decision 2.
        XCTAssertEqual(
            WhisperStatusPolling.decide(outcome: .status(.failed), consecutiveFailureCount: 0),
            .stop
        )
    }

    func testAnUnfinishedStateKeepsPollingAtTheNormalInterval() {
        for state in [WhisperModelState.starting, .downloading, .loading] {
            XCTAssertEqual(
                WhisperStatusPolling.decide(outcome: .status(state), consecutiveFailureCount: 0),
                .poll(afterSeconds: WhisperStatusPolling.interval),
                "\(state) is still in progress and must keep the poller running"
            )
        }
    }

    func testASuccessfulPollIgnoresTheFailureCount() {
        // Backoff describes the transport, not the model. A status that arrives
        // is a working transport, whatever happened before it.
        XCTAssertEqual(
            WhisperStatusPolling.decide(
                outcome: .status(.downloading),
                consecutiveFailureCount: 4
            ),
            .poll(afterSeconds: WhisperStatusPolling.interval)
        )
    }

    // MARK: - How to back off

    private func failureDelay(_ count: Int) throws -> TimeInterval {
        let decision = WhisperStatusPolling.decide(
            outcome: .unreachable,
            consecutiveFailureCount: count
        )
        guard case .poll(let seconds) = decision else {
            XCTFail("expected a retry after \(count) consecutive failures, got \(decision)")
            return 0
        }
        return seconds
    }

    func testTheFirstFailureRetriesAtTheNormalInterval() throws {
        // One dropped request during a sidecar restart is not a reason to wait.
        XCTAssertEqual(try failureDelay(1), WhisperStatusPolling.interval, accuracy: 0.0001)
    }

    func testConsecutiveFailuresBackOff() throws {
        var previous = try failureDelay(1)
        for count in 2...WhisperStatusPolling.maxConsecutiveFailures {
            let delay = try failureDelay(count)
            XCTAssertGreaterThanOrEqual(
                delay, previous,
                "failure \(count) must not retry sooner than failure \(count - 1)"
            )
            previous = delay
        }
        // It actually grew — a constant "non-decreasing" sequence would pass the
        // loop above while being no backoff at all.
        XCTAssertGreaterThan(try failureDelay(2), try failureDelay(1))
    }

    func testBackoffIsCapped() throws {
        for count in 1...WhisperStatusPolling.maxConsecutiveFailures {
            XCTAssertLessThanOrEqual(try failureDelay(count), WhisperStatusPolling.maxBackoff)
        }
        XCTAssertLessThanOrEqual(WhisperStatusPolling.maxBackoff, 60)
    }

    func testTheLastAllowedFailureStillRetries() throws {
        XCTAssertNotEqual(
            WhisperStatusPolling.decide(
                outcome: .unreachable,
                consecutiveFailureCount: WhisperStatusPolling.maxConsecutiveFailures
            ),
            .stop
        )
    }

    func testPollingGivesUpAfterTheFailureBudgetIsSpent() {
        // Same shape as `SidecarSupervisor.restartDecision`: bounded, then a
        // manual retry. An unbounded retry loop against a dead sidecar is the
        // permanent background timer this section is not allowed to create,
        // wearing a different name.
        XCTAssertEqual(
            WhisperStatusPolling.decide(
                outcome: .unreachable,
                consecutiveFailureCount: WhisperStatusPolling.maxConsecutiveFailures + 1
            ),
            .stop
        )
    }

    func testTheFailureBudgetIsSmallButNotOne() {
        XCTAssertGreaterThanOrEqual(WhisperStatusPolling.maxConsecutiveFailures, 3)
        XCTAssertLessThanOrEqual(WhisperStatusPolling.maxConsecutiveFailures, 10)
    }

    // MARK: - The recording must not be lost

    func testRecordingIsNeverRefusedBecauseOfTheModel() {
        // 「用户在未就绪时按了热键：录音照常进行（不阻止）」 — over `allCases`, so a
        // 28th state cannot quietly acquire a refusal.
        for state in WhisperModelState.allCases {
            XCTAssertTrue(
                WhisperReadinessPolicy.allowsRecording(state),
                "the hotkey must open the microphone in state \(state)"
            )
        }
    }

    func testThePreparingBannerShowsExactlyWhileTheModelIsComingUp() {
        XCTAssertTrue(WhisperReadinessPolicy.showsPreparingBanner(.starting))
        XCTAssertTrue(WhisperReadinessPolicy.showsPreparingBanner(.downloading))
        XCTAssertTrue(WhisperReadinessPolicy.showsPreparingBanner(.loading))
        XCTAssertFalse(WhisperReadinessPolicy.showsPreparingBanner(.ready))
        // `.failed` gets the failure surface (重试 / 改用远程识别), not a
        // 「正在准备…」 banner that will never finish.
        XCTAssertFalse(WhisperReadinessPolicy.showsPreparingBanner(.failed))
    }

    func testAReadyModelKeepsTheOrdinaryRequestBudget() {
        // 300s is `SidecarClient`'s existing `curl --max-time` ceiling; a ready
        // model must not change anything about a normal dictation.
        XCTAssertEqual(WhisperReadinessPolicy.transcribeTimeoutSeconds(.ready), 300)
    }

    func testAModelStillComingUpGetsALongEnoughBudgetToSurviveTheDownload() throws {
        // See header decision 4. serve.py holds the request until the model is
        // ready; if `curl` walks away first, the user's words are gone and
        // nothing on screen says why. 30 minutes is 460 MB at roughly 0.25
        // MB/s — a bad hotel connection, not a pathological one.
        for state in [WhisperModelState.starting, .downloading, .loading] {
            XCTAssertGreaterThanOrEqual(
                WhisperReadinessPolicy.transcribeTimeoutSeconds(state), 1_800,
                "a recording taken in state \(state) has to outlive the download"
            )
        }
    }

    func testAFailedModelDoesNotGetTheExtendedBudget() {
        // A failed load answers immediately (serve.py's `wait_until_ready`
        // returns false rather than blocking), so the long budget would only
        // ever delay an error the user is waiting to see.
        XCTAssertEqual(WhisperReadinessPolicy.transcribeTimeoutSeconds(.failed), 300)
    }
}
