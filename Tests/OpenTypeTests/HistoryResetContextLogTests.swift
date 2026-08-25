import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the gap
/// `docs/superpowers/specs/2026-08-09-current-system-state.md`'s 2026-08-25
/// newly-surfaced list names: `DELETE /memory/context-log` shipped in
/// `849e01a` alongside doc comments in `sidecar/src/oneshot/contextDebugLog.ts`
/// and `sidecar/src/memory/routes.ts` claiming it is "what makes 「重置输入历史」
/// actually clear this log" — but it is not. `grep -rn "context-log"
/// Sources/OpenType` returns nothing: `AppModel.resetHistory()`
/// (`AppModel.swift:1371`) calls only `history.clear()`, a local JSON-file
/// removal with no network call. The route has zero callers anywhere in the
/// app.
///
/// ## Why a request-shape seam and not a mock sidecar
///
/// `AppModel.init` spawns the sidecar child process, registers global
/// hotkeys, and touches `NSApp` — no test in this suite constructs one
/// (`AssistantEscalationWiringTests`, `TranscribeRequestLanguageTests` both
/// document the same constraint), and this fix does not justify being the
/// first. Unlike `transcribeRequestBody`, there is no per-call input to map
/// here — `DELETE /memory/context-log` takes no body and no parameters — so
/// the only real, pinnable content is the request's own shape: which HTTP
/// method and which path `resetHistory()` sends. That is still worth a test:
/// a `POST` where the route only serves `DELETE`, or a typo'd path
/// (`/memory/context_log`, `/memory/contextlog`), fails exactly the way this
/// whole bug did — the panel still says "reset" succeeded, `history.clear()`
/// still ran, and nothing anywhere observes that the second half silently
/// no-opped. `sidecar/src/memory/routes.ts` pins the serving side
/// (`method: "DELETE"`, `path: "/memory/context-log"`); this pins the
/// calling side.
///
/// The missing piece (Stage 3 creates it; nothing here builds it):
///
///     extension AppModel {
///         struct ContextLogResetRequest: Equatable {
///             let method: String
///             let path: String
///         }
///         static let contextLogResetRequest: ContextLogResetRequest
///     }
///
/// `resetHistory()` must be `contextLogResetRequest`'s only reader (the same
/// discipline `transcribeRequestBody` establishes for `transcribeLocally`) —
/// a parallel, unused constant that merely happens to hold the right string
/// would make this test pin nothing real.
///
/// ## What this file does *not* pin
///
/// Three things `resetHistory()` must still get right are not testable
/// through this seam, because they are either about a live `AppModel`
/// instance (`@Published` error state, `sidecarClient` call timing) or about
/// a SwiftUI view (`SettingsViews2.swift`'s `ClearLocalDataPage`) — neither
/// of which this suite can construct:
///
///   1. That the sidecar call actually runs and does not block or roll back
///      `history.clear()` on failure.
///   2. That a failed clear is surfaced somewhere the user can see, rather
///      than failing silently while the confirmation dialog still reads as
///      success.
///   3. That `resetHistory()` stays callable synchronously from the
///      confirmation dialog's button action (`SettingsViews2.swift:996`).
///
/// These are stage-4 reading, not a test — flagged here rather than left
/// implicit, per the same call this batch already made once for a
/// comparably thin two-line change.
final class HistoryResetContextLogTests: XCTestCase {

    /// Pins the HTTP method and path `resetHistory()` sends to clear the
    /// sidecar's `context-debug.log`, matching what `sidecar/src/memory/
    /// routes.ts` actually serves (`buildMemoryRoutes`'s `DELETE
    /// /memory/context-log` entry). A `POST`, a `PUT`, or a stray/missing
    /// leading slash would compile, run, and report success while clearing
    /// nothing — exactly the failure mode this whole bug already was.
    func testContextLogResetRequestMatchesTheSidecarRoute() {
        let request = AppModel.contextLogResetRequest

        XCTAssertEqual(
            request,
            AppModel.ContextLogResetRequest(method: "DELETE", path: "/memory/context-log"),
            "resetHistory() must call the exact method/path buildMemoryRoutes serves as DELETE /memory/context-log"
        )
    }
}
