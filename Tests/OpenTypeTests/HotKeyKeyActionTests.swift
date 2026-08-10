import Carbon
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for P1-10: no cancel path.
///
/// In "stop on any key" mode (`stopOnAnyKeyEnabled`), `GlobalHotKey`'s event-tap
/// `handleEventTap` treats EVERY `.keyDown` — Esc included — as "commit/finish"
/// the recording: it flips `stopOnAnyKeyEnabled` off, suppresses the key, and
/// fires `onStopRequested` (which commits the in-flight session). There is no
/// way to discard/cancel a recording from the keyboard; pressing Esc mid-record
/// commits whatever was captured instead of throwing it away.
///
/// The desired fix extracts the keyDown-in-stop-mode decision into a pure seam
/// `GlobalHotKey.keyAction(keyCode:stopOnAnyKeyEnabled:) -> HotKeyKeyAction` so
/// the commit-vs-cancel branch can be unit-tested without a live CGEvent tap.
/// The mapping must:
///   - when `stopOnAnyKeyEnabled == true`:
///       * Esc (`kVK_Escape`, keyCode 53) -> `.cancel` (discard, the fix), and
///       * any other key -> `.commit` (today's stop-on-any-key behavior), and
///   - when `stopOnAnyKeyEnabled == false`: any key -> `.ignore`
///     (the tap does not treat keystrokes as stop/commit when not armed — Esc
///     included, so this seam never steals Esc outside an armed recording).
///
/// These tests assert that desired mapping and are RED until Stage 3 adds the
/// `HotKeyKeyAction` enum and the `keyAction(keyCode:stopOnAnyKeyEnabled:)`
/// seam (and routes `handleEventTap`'s stop-on-any-key branch through it).
/// They currently fail to COMPILE because neither symbol exists yet — that is
/// the intended red.
final class HotKeyKeyActionTests: XCTestCase {

    private var escapeKeyCode: Int64 { Int64(kVK_Escape) }
    private var spaceKeyCode: Int64 { Int64(kVK_Space) }
    private var returnKeyCode: Int64 { Int64(kVK_Return) }

    // MARK: - P1-10: the bug fix — Esc cancels instead of committing

    func testEscapeCancelsWhenStopOnAnyKeyEnabled() {
        XCTAssertEqual(
            GlobalHotKey.keyAction(
                keyCode: escapeKeyCode,
                stopOnAnyKeyEnabled: true
            ),
            .cancel
        )
    }

    // MARK: - Any non-Esc key still commits when armed (unchanged)

    func testSpaceCommitsWhenStopOnAnyKeyEnabled() {
        XCTAssertEqual(
            GlobalHotKey.keyAction(
                keyCode: spaceKeyCode,
                stopOnAnyKeyEnabled: true
            ),
            .commit
        )
    }

    func testReturnCommitsWhenStopOnAnyKeyEnabled() {
        XCTAssertEqual(
            GlobalHotKey.keyAction(
                keyCode: returnKeyCode,
                stopOnAnyKeyEnabled: true
            ),
            .commit
        )
    }

    // MARK: - Not armed: keys are ignored (Esc included — no cancel outside a recording)

    func testEscapeIsIgnoredWhenStopOnAnyKeyDisabled() {
        XCTAssertEqual(
            GlobalHotKey.keyAction(
                keyCode: escapeKeyCode,
                stopOnAnyKeyEnabled: false
            ),
            .ignore
        )
    }

    func testOrdinaryKeyIsIgnoredWhenStopOnAnyKeyDisabled() {
        XCTAssertEqual(
            GlobalHotKey.keyAction(
                keyCode: spaceKeyCode,
                stopOnAnyKeyEnabled: false
            ),
            .ignore
        )
    }
}
