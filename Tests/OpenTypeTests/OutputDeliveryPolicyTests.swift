import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for three `OutputDeliveryPolicy` delivery defects.
/// Each test asserts the DESIRED corrected behavior and is expected to FAIL
/// until Stage 3 updates `OutputDeliveryPolicy` (`Sources/OpenType/Models.swift`).
///
/// - P1-17: `strategy(for:automaticallyInsert:)` currently ignores its `mode`
///   argument and returns `.automaticInsert` whenever `automaticallyInsert` is
///   set. An `ask` answer must never auto-paste into the focused field (high
///   misfire risk in a chat box) — it is delivered to the popup + clipboard
///   only. `transcribe`/`agent` keep the existing auto-insert-when-enabled
///   behavior.
/// - P1-15: `retainsClipboardCopy(for:)` unconditionally returns `true`, so the
///   result always overwrites the user's clipboard even when insert succeeded
///   and the user opted out. The desired seam is a decision that consults a new
///   opt-out setting (`retainClipboardAfterInsert`, default preserving current
///   behavior) plus whether the insert actually succeeded.
/// - P1-16: insert delivery targets whatever app is frontmost at completion
///   time, so switching apps mid-transcription pastes into the wrong app. The
///   desired seam is a pure decision comparing the captured bundle id to the
///   current frontmost bundle id and downgrading to clipboard-only when they
///   differ.
final class OutputDeliveryPolicyTests: XCTestCase {

    // MARK: - P1-17: `ask` must not auto-insert regardless of the flag

    func testAskModeNeverAutoInsertsEvenWhenAutomaticInsertEnabled() {
        let strategy = OutputDeliveryPolicy.strategy(
            for: .ask,
            automaticallyInsert: true
        )
        // `ask` answers land in the popup + clipboard, never the focused field.
        XCTAssertEqual(strategy, .clipboard)
    }

    func testTranscribeModeAutoInsertsWhenAutomaticInsertEnabled() {
        let strategy = OutputDeliveryPolicy.strategy(
            for: .transcribe,
            automaticallyInsert: true
        )
        XCTAssertEqual(strategy, .automaticInsert)
    }

    func testAgentModeAutoInsertsWhenAutomaticInsertEnabled() {
        let strategy = OutputDeliveryPolicy.strategy(
            for: .agent,
            automaticallyInsert: true
        )
        XCTAssertEqual(strategy, .automaticInsert)
    }

    func testNoModeAutoInsertsWhenAutomaticInsertDisabled() {
        for mode in InputMode.allCases {
            let strategy = OutputDeliveryPolicy.strategy(
                for: mode,
                automaticallyInsert: false
            )
            XCTAssertEqual(
                strategy,
                .clipboard,
                "\(mode) must not auto-insert when automaticallyInsert is off"
            )
        }
    }

    // MARK: - P1-15: clipboard-retain opt-out on successful insert

    func testRetainSettingOnAndInsertSucceededDoesNotOverwriteClipboard() {
        // User opted out AND the insert actually landed: the result must NOT
        // clobber the user's original clipboard.
        let shouldCopy = OutputDeliveryPolicy.retainsClipboardCopy(
            for: .transcribe,
            insertSucceeded: true,
            retainClipboardAfterInsert: true
        )
        XCTAssertFalse(shouldCopy)
    }

    func testRetainSettingOnButInsertFailedStillCopiesToClipboard() {
        // Nothing was inserted, so the clipboard-always-gets-the-result
        // guarantee still holds even with the opt-out enabled.
        let shouldCopy = OutputDeliveryPolicy.retainsClipboardCopy(
            for: .transcribe,
            insertSucceeded: false,
            retainClipboardAfterInsert: true
        )
        XCTAssertTrue(shouldCopy)
    }

    func testRetainSettingDefaultOffPreservesClipboardCopyGuarantee() {
        // Default (opt-out off) preserves the current always-copy behavior,
        // regardless of whether insert succeeded.
        XCTAssertTrue(
            OutputDeliveryPolicy.retainsClipboardCopy(
                for: .transcribe,
                insertSucceeded: true,
                retainClipboardAfterInsert: false
            )
        )
        XCTAssertTrue(
            OutputDeliveryPolicy.retainsClipboardCopy(
                for: .transcribe,
                insertSucceeded: false,
                retainClipboardAfterInsert: false
            )
        )
    }

    // MARK: - P1-16: insert only into the app that was captured

    func testShouldInsertFalseWhenCapturedAppDiffersFromFrontmost() {
        let shouldInsert = OutputDeliveryPolicy.shouldInsert(
            capturedBundleId: "com.apple.Notes",
            frontmostBundleId: "com.tinyspeck.slackmacgap"
        )
        // Focus moved to another app after capture: downgrade to clipboard-only.
        XCTAssertFalse(shouldInsert)
    }

    func testShouldInsertTrueWhenCapturedAppMatchesFrontmost() {
        let shouldInsert = OutputDeliveryPolicy.shouldInsert(
            capturedBundleId: "com.apple.Notes",
            frontmostBundleId: "com.apple.Notes"
        )
        XCTAssertTrue(shouldInsert)
    }

    func testShouldInsertTrueWhenCapturedBundleIsNil() {
        // No captured identity to compare against: keep the existing behavior
        // (allow insert), matching the pre-fix path when capture is unknown.
        let shouldInsert = OutputDeliveryPolicy.shouldInsert(
            capturedBundleId: nil,
            frontmostBundleId: "com.apple.Notes"
        )
        XCTAssertTrue(shouldInsert)
    }
}
