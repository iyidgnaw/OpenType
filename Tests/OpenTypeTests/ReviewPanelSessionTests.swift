import AppKit
import Foundation
import XCTest
@testable import OpenType

/// Regression tests for P0-3: `ReviewPanelController` breaks on its *second*
/// (and every subsequent) session.
///
/// Mechanism: `hide()` nils the weak `textView` but keeps the cached `panel`
/// and the lazily-built `hostingView`. On the next `show()` SwiftUI reuses that
/// hosting view and runs `ReviewTextView.updateNSView` (a deliberate no-op)
/// instead of `makeNSView`, so `onTextViewReady` never re-fires and the
/// controller's `textView` stays nil for the whole second session. Two
/// user-visible consequences follow:
///
///  (a) `currentText()` falls back to `presentation.text` (the NEW transcript)
///      while the still-present NSTextView shows the PREVIOUS session's text,
///      and any `applyCorrection` the user makes is a silent no-op — so what
///      the panel would COMMIT (`AppModel.commitReview` reads `currentText()`
///      verbatim) diverges from what the user edited/sees.
///  (b) `currentSelection()` is guarded by `let textView`, so it returns nil
///      forever. `AppModel.hotKeyPressed` gates "start a voice-correction" on
///      `currentSelection() != nil`, so voice-correction is dead in every
///      session after the first.
///
/// These tests assert the DESIRED corrected behavior (re-show must re-bind a
/// live text view), so they are RED against the current controller and go
/// GREEN once Stage 3 fixes the re-show lifecycle. The first test is a control
/// that passes today, proving the later failures are specifically about
/// re-showing and not about SwiftUI never laying out in the test host.
@MainActor
final class ReviewPanelSessionTests: XCTestCase {

    /// SwiftUI builds the panel's `NSTextView` lazily during a layout pass, and
    /// `ReviewPanelController.show(...)` itself only reads `textView` after a
    /// main-runloop turn. Pump the main runloop so layout (and thus
    /// `makeNSView` -> `onTextViewReady`) actually runs before we assert.
    private func pumpMainRunLoop(for seconds: TimeInterval = 0.8) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Control (passes today): the FIRST session binds a live text view, so the
    /// second-session failures below are provably about re-showing, not about
    /// the SwiftUI representable never running in the XCTest host.
    func testFirstSessionBindsLiveTextView() {
        let controller = ReviewPanelController()
        defer { controller.hide() }

        controller.show(originalTranscript: "hello world")
        pumpMainRunLoop()

        // A correction on the first session splices into the live view and is
        // reflected by both currentText() and currentSelection().
        let committed = controller.applyCorrection(
            "goodbye",
            in: NSRange(location: 0, length: ("hello" as NSString).length)
        )
        XCTAssertEqual(
            committed,
            "goodbye world",
            "first session must have a live text view to splice into (else the pump is too short and later reds are meaningless)"
        )
        XCTAssertEqual(controller.currentText(), "goodbye world")
        XCTAssertEqual(controller.currentSelection()?.substring, "goodbye")
    }

    /// Consequence (b): after show -> hide -> show, `currentSelection()` must
    /// still report a real selection. Today it is permanently nil on the
    /// second session, which permanently disables voice-correction.
    func testSecondSessionSelectionIsReadable() {
        let controller = ReviewPanelController()
        defer { controller.hide() }

        controller.show(originalTranscript: "first")
        pumpMainRunLoop()
        XCTAssertEqual(
            controller.currentText(),
            "first",
            "precondition: first session shows its transcript"
        )

        controller.hide()
        controller.show(originalTranscript: "second session transcript")
        pumpMainRunLoop()

        // Voice-correct a span in the SECOND session; the resulting selection
        // must be readable so a follow-up correction can target it again.
        let range = NSRange(location: 0, length: ("second" as NSString).length)
        _ = controller.applyCorrection("SECOND", in: range)

        let selection = controller.currentSelection()
        XCTAssertNotNil(
            selection,
            "second session must re-bind a live text view; currentSelection() is nil today, so voice-correction is dead"
        )
        XCTAssertEqual(selection?.substring, "SECOND")
    }

    /// Consequence (a): after show -> hide -> show, the text the panel would
    /// COMMIT (`currentText()`, read verbatim by `AppModel.commitReview`) must
    /// reflect the correction the user actually made in the second session.
    /// Today the second-session `applyCorrection` is a silent no-op (textView
    /// is nil), so `currentText()` returns the un-corrected transcript while
    /// the visible panel and the user's intent say otherwise.
    func testSecondSessionCommitsTheCorrectedText() {
        let controller = ReviewPanelController()
        defer { controller.hide() }

        controller.show(originalTranscript: "alpha")
        pumpMainRunLoop()

        controller.hide()
        controller.show(originalTranscript: "bravo charlie")
        pumpMainRunLoop()
        XCTAssertEqual(
            controller.currentText(),
            "bravo charlie",
            "precondition: the new transcript is the starting point of session 2"
        )

        // User voice-corrects "bravo" -> "BRAVO" in the second session.
        let range = NSRange(location: 0, length: ("bravo" as NSString).length)
        let committed = controller.applyCorrection("BRAVO", in: range)

        XCTAssertEqual(
            committed,
            "BRAVO charlie",
            "second-session correction must splice into the live text, not no-op"
        )
        XCTAssertEqual(
            controller.currentText(),
            "BRAVO charlie",
            "currentText() (what commitReview writes out) must reflect the second-session correction, not a stale/uncorrected value"
        )
    }
}
