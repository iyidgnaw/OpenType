import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for reconciling `McpServerViews.swift`'s prose
/// with `b1d61cc` ("Let a saved MCP server take effect without a restart"):
/// a `PUT`/`POST`/`DELETE /config/mcp` write now reloads live, closing and
/// replacing only the servers whose config actually changed — connecting new
/// ones and dropping removed ones immediately, on save. Before that commit,
/// every one of these strings was true: connections really were only made
/// once, at boot, and a save really did just sit there until the next
/// launch. Several of the panel's strings still say that.
///
/// ---------------------------------------------------------------------------
/// The seam
/// ---------------------------------------------------------------------------
///
/// The status wording lives inline in three SwiftUI computed properties —
/// `McpServerRowView.statusText`, `McpStartupFailureLine.text`, and
/// `McpServerSheet.disabledNotice`'s `Text(...)` — and neither
/// `McpServerRowView` nor `McpServerSheet` is instantiable in this test
/// target (`AssistantEscalationWiringTests`'s doc comment documents the same
/// constraint for `AppModel`-adjacent SwiftUI views generally). So this pins
/// a new pure type, `McpServerStatusWording`, that Stage 3 is expected to add
/// to `Sources/OpenType/McpServerViews.swift` and have those three computed
/// properties delegate to:
///
/// - `rowStatusText(isEnabled:testedToolCount:)` — the row's one-line dot
///   caption (`McpServerRowView.statusText`, ~McpServerViews.swift:764-781).
///   `testedToolCount` mirrors `McpServerRowView.toolCount`'s own contract:
///   non-nil only when *this session's* Test Connection produced a count: it
///   is not live server status, so the wording must not claim it is.
/// - `failureLineText(_:)` — the warning line under a row when the last
///   connection attempt didn't land (`McpStartupFailureLine.text`,
///   ~McpServerViews.swift:871-884). Takes the same `McpStartupFailure`
///   `Models.swift` already defines — no new type needed there.
/// - `disabledExplanation()` — the edit sheet's explanatory banner for an
///   already-disabled server (`McpServerSheet.disabledNotice`,
///   ~McpServerViews.swift:1210-1231). No branching state; pinned anyway
///   since its text is one of the strings this commit invalidated.
///
/// RED until Stage 3 adds `McpServerStatusWording` with these three static
/// members. This file currently fails to COMPILE because the type does not
/// exist yet — that is the intended red.
///
/// ---------------------------------------------------------------------------
/// What changed, and what didn't
/// ---------------------------------------------------------------------------
///
/// **Now false — the "next start" framing.** `rowStatusText`'s tested and
/// untested enabled cases (~773, ~778) and `disabledExplanation()` (~1216)
/// all said connecting, or *not* connecting, was pinned to "the next start".
/// `createReloadableMcpToolSet.apply()` (`sidecar/src/agent/mcpClient.ts`)
/// proves otherwise: a save's `reload()` immediately closes anything gone or
/// changed and immediately (re)connects anything new or changed, synchronously
/// and without waiting for a restart. A disabled server is filtered out of
/// the "enabled servers" list *before* `reload()` even sees it (`enabled` is
/// applied upstream, per `ReloadableMcpToolSet.reload`'s own doc comment), so
/// disabling one drops its live connection on that same save, not merely
/// promises to skip it "at the next start". These three are pinned by exact
/// equality below, replacing "下次启动时"/"at the next start" with save-time
/// language.
///
/// **True but misleading — the startup-only framing on a failure/timeout.**
/// `McpStartupFailureLine.text` (~875/~881) says "启动超时"/"Timed out at
/// startup" and "启动失败"/"Failed at startup". The *fact* — this server's
/// last connection attempt didn't land — is still real and still worth
/// showing; what's no longer accurate is pinning it to *boot*. `lastStartupError`
/// (`sidecar/src/agent/mcpConfigRoutes.ts`'s `startupErrorFor`) is read from
/// `connectionReport()` on every `GET /config/mcp`, and `connectionReport` is
/// `mcpTools.status` on the very `ReloadableMcpToolSet` `reload()` mutates —
/// so a failure recorded here can just as easily be from the most recent
/// *save* as from boot. The two tests below pin that the "startup"/"启动"
/// framing is gone while the substance (which kind, and the failure's own
/// message) survives untouched.
///
/// **Deliberately NOT covered here (left to Stage 4's reading of the diff):**
/// the purely static prose that isn't reachable through any state this seam
/// takes as input —
///  - ~235 "MCP 连接只在语音服务启动时建立，重启会用当前配置重新连接一次。"
///    ("MCP connections are made when the voice service starts; restarting
///    reconnects with the current configuration.") — the header's "Restart
///    and connect" tooltip. **Now false**: connections are no longer made
///    *only* at start; a save makes them too. The tooltip needs to say what
///    the manual restart button actually adds (reconnecting *unchanged*
///    servers too, which a save never touches), not that it's the only time
///    a connection happens.
///  - ~373 "连接在语音服务启动时建立，改动从下次启动生效。" ("Connections are
///    made when the voice service starts; changes take effect from the next
///    start.") — the server list's footer note. **Now false**, same reason.
///  - ~1283 "连接在下次启动语音服务时建立" ("The connection is made the next
///    time the voice service starts") — the add-sheet's footer note for a
///    brand-new (not-yet-existing) server. **Now false**: a new server is in
///    `apply()`'s "new or changed" `toConnect` set, connected on that same
///    save.
///  - ~1322 "存下你填的内容，但标记为停用 —— 下次启动不会连接它。…" ("Keeps what
///    you typed but marks it disabled, so the next start won't connect it.
///    …") — the "Save disabled" button's tooltip. **Now false** in the same
///    "next start" way as `disabledExplanation()` above; this one just isn't
///    reachable as a pure function of anything other than "the user is
///    looking at this button", so there's no state to test it against.
///  - ~1237-1245 "连不上的服务器会拖慢语音服务启动。仍要保存的话，它会以停用状态
///    存下，不参与下次连接。" ("A server that can't be reached slows the voice
///    service down at start. Save anyway and it is stored disabled, taking no
///    part in the next connection.") — the failed-test advice banner. **Now
///    false**, and for a stronger reason than the others: `startMcpConnections`'s
///    own doc comment says serving *never* waits on a connection, at boot or
///    at save — that was the whole point of the bug fix its doc comment
///    describes. A server that can't be reached costs its own connection
///    attempt (bounded at `MCP_CONNECT_TIMEOUT_MS`), never the app's startup.
///    The underlying advice — test before you save — is still good, just not
///    for the stated reason.
///  - ~1338 "先测试连接。连不上的服务器会拖慢下次启动，测试是在保存前发现这件事
///    的唯一方式。" ("Test the connection first. A server that can't be reached
///    slows the next start down, and the test is the only way to learn that
///    before saving.") — the disabled Save button's tooltip. **Now false**,
///    same "slows down start" claim as the banner above.
///
/// None of these six are wired to state a unit test can vary — they are
/// fixed prose attached to a button or a static banner — so there is nothing
/// for a pure function to take as input. Stage 3 rewrites them by hand;
/// Stage 4 confirms by reading the diff that the "slows down start"/"next
/// start" claims are gone and nothing that replaced them overclaims what
/// Swift can actually know (in particular: Swift never learns *live*
/// per-server connectedness, only whether the last attempt failed/timed out
/// — see `McpServerRowView.statusText`'s own doc comment, ~756-763).
final class McpServerStatusWordingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OpenTypeL10n.current = .chinese
    }

    override func tearDown() {
        OpenTypeL10n.current = .system
        super.tearDown()
    }

    // MARK: - A. `rowStatusText` — the row's one-line dot caption

    /// A disabled server isn't merely *going to be* left unconnected "at the
    /// next start" — `reload()` drops it (or never adds it back) on the very
    /// save that disabled it, so right now, already, it has no connection.
    func testDisabledRowSaysNotConnectedRatherThanDeferringToTheNextStart() {
        let text = McpServerStatusWording.rowStatusText(isEnabled: false, testedToolCount: nil)

        XCTAssertEqual(text, "已停用 · 未连接")
        XCTAssertFalse(
            text.contains("下次启动"),
            "a disabled server is already not connected, not merely 'not connected at the next start': \(text)"
        )
    }

    func testDisabledRowSaysNotConnectedRatherThanDeferringToTheNextStartInEnglish() {
        OpenTypeL10n.current = .english

        let text = McpServerStatusWording.rowStatusText(isEnabled: false, testedToolCount: nil)

        XCTAssertEqual(text, "Disabled · not connected")
        XCTAssertFalse(text.lowercased().contains("next start"), "got: \(text)")
    }

    /// A disabled server ignores whatever tool count this session's Test
    /// Connection happened to produce — the guard in `McpServerRowView.
    /// statusText` returns before ever consulting `toolCount`, and that must
    /// survive the reword.
    func testDisabledRowIgnoresALeftoverTestedToolCount() {
        let text = McpServerStatusWording.rowStatusText(isEnabled: false, testedToolCount: 6)

        XCTAssertEqual(text, "已停用 · 未连接")
    }

    /// The tested, enabled case: the count and "test passed" are still
    /// exactly the facts Swift actually has (this session's own Test
    /// Connection, not live status — see the file doc comment), but the
    /// timing claim moves from "the next start" to save time.
    func testEnabledTestedRowSaysConnectsOnSaveRatherThanAtTheNextStart() {
        let text = McpServerStatusWording.rowStatusText(isEnabled: true, testedToolCount: 6)

        XCTAssertEqual(text, "6 个工具 · 测试通过 · 保存时连接")
        XCTAssertFalse(text.contains("下次启动"), "got: \(text)")
        XCTAssertTrue(text.contains("6"), "the tested tool count must still be shown: \(text)")
        XCTAssertTrue(text.contains("测试通过"), "the test-passed fact must still be shown: \(text)")
    }

    func testEnabledTestedRowSaysConnectsOnSaveRatherThanAtTheNextStartInEnglish() {
        OpenTypeL10n.current = .english

        let text = McpServerStatusWording.rowStatusText(isEnabled: true, testedToolCount: 6)

        XCTAssertEqual(text, "6 tools · test passed · connects on save")
        XCTAssertFalse(text.lowercased().contains("next start"), "got: \(text)")
    }

    /// The untested, enabled case: no tool count to show (this session never
    /// ran Test Connection), same timing fix.
    func testEnabledUntestedRowSaysConnectsOnSaveRatherThanAtTheNextStart() {
        let text = McpServerStatusWording.rowStatusText(isEnabled: true, testedToolCount: nil)

        XCTAssertEqual(text, "已启用 · 保存时连接")
        XCTAssertFalse(text.contains("下次启动"), "got: \(text)")
    }

    func testEnabledUntestedRowSaysConnectsOnSaveRatherThanAtTheNextStartInEnglish() {
        OpenTypeL10n.current = .english

        let text = McpServerStatusWording.rowStatusText(isEnabled: true, testedToolCount: nil)

        XCTAssertEqual(text, "Enabled · connects on save")
        XCTAssertFalse(text.lowercased().contains("next start"), "got: \(text)")
    }

    // MARK: - B. `failureLineText` — the warning line under a row

    /// The fact ("gave up waiting") survives; the "启动"/"startup" framing
    /// does not, because a timeout recorded in `lastStartupError` can now be
    /// from the most recent save's reconnect attempt just as easily as from
    /// boot (`connectionReport` is read live off the same `ReloadableMcpToolSet`
    /// a save's `reload()` mutates).
    func testTimedOutFailureLineDropsTheStartupFramingButKeepsTheFact() {
        let text = McpServerStatusWording.failureLineText(.timedOut)

        XCTAssertEqual(text, "连接超时，已跳过")
        XCTAssertFalse(text.contains("启动"), "must not pin the timeout to boot specifically: \(text)")
    }

    func testTimedOutFailureLineDropsTheStartupFramingButKeepsTheFactInEnglish() {
        OpenTypeL10n.current = .english

        let text = McpServerStatusWording.failureLineText(.timedOut)

        XCTAssertEqual(text, "Timed out and was skipped")
        XCTAssertFalse(text.lowercased().contains("startup"), "got: \(text)")
    }

    /// `spawn npx ENOENT` is the actionable half of the message and must
    /// still arrive verbatim — only the label placing it "at startup" is
    /// being dropped, not the sidecar's own text.
    func testFailedFailureLineDropsTheStartupFramingButKeepsTheServersOwnMessage() {
        let text = McpServerStatusWording.failureLineText(.failed("spawn npx ENOENT"))

        XCTAssertEqual(text, "连接失败：spawn npx ENOENT")
        XCTAssertFalse(text.contains("启动"), "must not pin the failure to boot specifically: \(text)")
        XCTAssertTrue(text.contains("spawn npx ENOENT"), "the server's own error must pass through verbatim: \(text)")
    }

    func testFailedFailureLineDropsTheStartupFramingButKeepsTheServersOwnMessageInEnglish() {
        OpenTypeL10n.current = .english

        let text = McpServerStatusWording.failureLineText(.failed("spawn npx ENOENT"))

        XCTAssertEqual(text, "Failed to connect: spawn npx ENOENT")
        XCTAssertFalse(text.lowercased().contains("startup"), "got: \(text)")
        XCTAssertTrue(text.contains("spawn npx ENOENT"), "got: \(text)")
    }

    // MARK: - C. `disabledExplanation` — the edit sheet's disabled banner

    /// Same "next start" fix as the row: a server the sheet is showing as
    /// disabled has no connection right now, not merely a promise to stay
    /// unconnected until a restart. The re-enable-on-a-passing-save half of
    /// the sentence was already true and stays.
    func testDisabledExplanationSaysWontConnectRatherThanDeferringToTheNextStart() {
        let text = McpServerStatusWording.disabledExplanation()

        XCTAssertEqual(
            text,
            "这个服务器已停用，不会连接。改好之后重新测试，通过再保存就会重新启用。"
        )
        XCTAssertFalse(text.contains("下次启动"), "got: \(text)")
        XCTAssertTrue(
            text.contains("重新测试") && text.contains("重新启用"),
            "the retest-then-save-re-enables path must still be explained: \(text)"
        )
    }

    func testDisabledExplanationSaysWontConnectRatherThanDeferringToTheNextStartInEnglish() {
        OpenTypeL10n.current = .english

        let text = McpServerStatusWording.disabledExplanation()

        XCTAssertEqual(
            text,
            "This server is disabled and won't connect. Fix it, test again, and a passing save turns it back on."
        )
        XCTAssertFalse(text.lowercased().contains("next start"), "got: \(text)")
    }
}
