import Foundation
import Testing
@testable import OpenType

// MARK: - TDD Stage 1 (write failing tests) for sidecar crash recovery
//
// Bug P1-4 (verified): when the sidecar child process dies AFTER a successful
// startup, `SidecarClient.terminationHandler` only writes a debug log (see
// `Sources/OpenType/SidecarClient.swift` ~line 339). `AppModel.sidecarStatus`
// is set exactly once, in `AppModel.init`'s post-`start()` Task (AppModel.swift
// ~line 228), and is never re-evaluated afterward — so it forever shows
// "Sidecar 已就绪"/"Sidecar ready" even though every subsequent request now
// fails against a dead process, and nothing ever restarts it.
//
// Intended fix (Stage 3): on unexpected termination, (a) move the status to a
// visible non-ready error/degraded state, and (b) auto-restart with bounded
// backoff, giving up after a capped number of attempts and exposing a manual
// "restart service" affordance.
//
// AppModel/SidecarClient are not cleanly unit-instantiable (they spawn real
// processes, touch Accessibility, drive AppKit UI). So — per the repo's
// 4-stage TDD pipeline — these tests target the EXTRACTABLE PURE SEAMS the
// implementer will introduce for the decision logic; the actual process/UI
// wiring that calls into these seams is applied and reviewed in Stage 3, not
// unit-tested here.
//
// ---------------------------------------------------------------------------
// Seams Stage 3 MUST add for this file to compile and pass:
//
//   1. enum SidecarRestartDecision: Equatable {
//          case restart(afterSeconds: TimeInterval)
//          case giveUp
//      }
//
//   2. enum SidecarStatus: Equatable {
//          case ready          // healthy / running (the only case asserted by
//                              // exact name here — the rest are the
//                              // implementer's to name, e.g. .starting,
//                              // .degraded, .failed)
//          ...
//      }
//
//   3. enum SidecarLifecycleEvent {           // (name flexible; these 3 cases
//          case unexpectedTermination         //  are the contract)
//          case restartSucceeded
//          case gaveUp
//      }
//
//   4. enum SidecarSupervisor {               // pure, stateless decision logic
//          static var maxRestartAttempts: Int
//          static func restartDecision(consecutiveFailureCount: Int)
//              -> SidecarRestartDecision
//          static func status(for event: SidecarLifecycleEvent) -> SidecarStatus
//      }
//
//   5. (P2, dev-path hardcode) SidecarClient.defaultDevSidecarDirectory(
//          sourceFilePath: String = #filePath) -> String
//      replacing the hardcoded "/Users/diywang/hackathon/OpenType/sidecar"
//      fallback at SidecarClient.swift ~line 297 with a value derived from the
//      source-file location (or an env override), never a user-specific path.
// ---------------------------------------------------------------------------

// MARK: - Helpers

private func restartDelay(_ decision: SidecarRestartDecision) -> TimeInterval? {
    if case let .restart(afterSeconds) = decision { return afterSeconds }
    return nil
}

// MARK: - 1. Restart / backoff decision

@Suite("SidecarSupervisor restart backoff")
struct SidecarSupervisorRestartDecisionTests {

    @Test("The cap is a small, positive, finite number of attempts")
    func maxRestartAttemptsIsSane() {
        #expect(SidecarSupervisor.maxRestartAttempts >= 1)
        #expect(SidecarSupervisor.maxRestartAttempts <= 10)
    }

    @Test("First failure schedules a quick restart, not a give-up")
    func firstAttemptRestartsQuickly() {
        let decision = SidecarSupervisor.restartDecision(consecutiveFailureCount: 1)
        let delay = restartDelay(decision)
        #expect(delay != nil, "attempt 1 must be .restart, got \(decision)")
        if let delay {
            #expect(delay >= 0)
            #expect(delay <= 1.0, "first restart should be quick (<= 1s), got \(delay)s")
        }
    }

    @Test("Backoff delays are non-decreasing and bounded up to the cap")
    func backoffIsMonotonicAndBounded() {
        var previous: TimeInterval = -1
        for count in 1...SidecarSupervisor.maxRestartAttempts {
            let decision = SidecarSupervisor.restartDecision(consecutiveFailureCount: count)
            let delay = restartDelay(decision)
            #expect(
                delay != nil,
                "count \(count) (<= cap) must still restart, got \(decision)"
            )
            guard let delay else { continue }
            #expect(delay.isFinite)
            #expect(delay >= 0)
            #expect(
                delay >= previous,
                "delay must not decrease: \(delay)s after \(previous)s at count \(count)"
            )
            #expect(delay <= 60.0, "backoff must stay bounded, got \(delay)s at count \(count)")
            previous = delay
        }
    }

    @Test("Past the cap, the supervisor gives up instead of restarting")
    func givesUpPastTheCap() {
        let justPast = SidecarSupervisor.restartDecision(
            consecutiveFailureCount: SidecarSupervisor.maxRestartAttempts + 1
        )
        #expect(justPast == .giveUp)

        let farPast = SidecarSupervisor.restartDecision(consecutiveFailureCount: 100)
        #expect(farPast == .giveUp)
    }
}

// MARK: - 2. Termination -> status mapping

@Suite("SidecarSupervisor status mapping")
struct SidecarSupervisorStatusMappingTests {

    @Test("An unexpected termination is NOT reported as ready")
    func unexpectedTerminationIsNotReady() {
        let status = SidecarSupervisor.status(for: .unexpectedTermination)
        #expect(
            status != .ready,
            "a dead sidecar must surface a visible non-ready state, not stay .ready"
        )
    }

    @Test("A successful restart maps back to ready")
    func successfulRestartIsReady() {
        #expect(SidecarSupervisor.status(for: .restartSucceeded) == .ready)
    }

    @Test("Giving up is a distinct non-ready terminal state")
    func giveUpIsNonReadyAndDistinct() {
        let gaveUp = SidecarSupervisor.status(for: .gaveUp)
        #expect(gaveUp != .ready)
        // A give-up (no more retries, needs manual restart) must be
        // distinguishable from the transient post-crash state, so the UI can
        // offer the "restart service" affordance rather than implying recovery
        // is still in progress.
        #expect(gaveUp != SidecarSupervisor.status(for: .unexpectedTermination))
    }
}

// MARK: - 3. (P2) Dev-path fallback must not be a hardcoded user path

@Suite("SidecarClient dev-path fallback")
struct SidecarClientDevPathTests {

    @Test("Dev sidecar dir is derived from source location, not a user path")
    func devSidecarFallbackIsDerivedNotHardcoded() {
        let derived = SidecarClient.defaultDevSidecarDirectory(
            sourceFilePath: "/tmp/RepoRoot/Sources/OpenType/SidecarClient.swift"
        )
        #expect(derived == "/tmp/RepoRoot/sidecar")
        #expect(!derived.contains("diywang"))
        #expect(derived.hasSuffix("/sidecar"))
    }
}
