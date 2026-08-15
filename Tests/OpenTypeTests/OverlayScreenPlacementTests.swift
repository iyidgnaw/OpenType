import CoreGraphics
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the last third of P2-10
/// (`docs/superpowers/specs/2026-08-14-product-batch-plan.md`,
/// "P2-10 录音计时 + 最长时长 + 浮层跟随焦点屏"):
///
///   「`OverlayController` 的 `visibleFrame()` 从 `NSScreen.main` 改为
///    「鼠标所在屏 → 主屏」兜底。Review 面板同理。」
///
/// Today both floating panels ask AppKit for one specific screen:
///
///   `OverlayController.visibleFrame()`  — `(NSScreen.main ?? NSScreen.screens.first)?.visibleFrame`
///   `ReviewPanelController.position(_:)` — the same expression, inline
///
/// `NSScreen.main` is the screen holding the *key window*, which for a
/// menubar-resident accessory app is whatever app the user was last typing in
/// — but it is also stale or wrong often enough (nothing key, a full-screen
/// space, a display that just came back from sleep) that on a multi-monitor
/// desk the HUD regularly appears on the monitor the user is not looking at.
/// The replacement is "the screen the mouse is on, falling back to main."
///
/// This file tests the *choice*, factored out as a pure function over plain
/// `CGRect`s. It deliberately does not test AppKit: no `NSScreen` is created,
/// no panel is shown, and the two controllers keep their own (untested,
/// unchanged) job of reading `NSEvent.mouseLocation`, `NSScreen.screens` and
/// `NSScreen.main` and handing them to this seam.
///
/// **Two rects per screen, and they are not interchangeable.** `frame` is the
/// whole display and is what the mouse is hit-tested against — a pointer up in
/// the menu bar or down over the Dock is still on that screen. `visibleFrame`
/// is the usable area and is what a panel is laid out inside. Hit-testing
/// against `visibleFrame` would drop the pointer into "no screen" whenever it
/// is over the menu bar, which is a place people leave the mouse constantly.
///
/// **Review shares this seam, and is pinned to the same standard.**
/// `ReviewPanelController` centres its panel on `midX`/`midY` of whatever rect
/// it is given. The spec says 「Review 面板同理」, and the failure mode if that
/// half is forgotten is silent: the HUD follows the mouse, the Review panel
/// keeps opening on `NSScreen.main`, and every test about `ScreenPlacement`
/// alone still passes. So Review's centring is extracted into
/// `ReviewPanelLayout` — the same pure-namespace treatment
/// `VoiceSurfacePanelLayout` already gets — and tested in
/// `ReviewPanelScreenPlacementTests` below, so that the Review half of P2-10
/// has a test that can go red at all.
///
/// The classes are not `@MainActor`: `ScreenPlacement` and `ReviewPanelLayout`
/// must stay nonisolated so the `@MainActor` controllers can call them but
/// nothing forces the reverse.
///
/// **What these tests cannot reach.** Neither seam is pure enough to prove the
/// *wiring*: an implementation can satisfy every assertion in this file and
/// still leave either `visibleFrame()` (`OverlayController.swift:509`) or
/// `position(_:)` (`ReviewPanelController.swift:211`) reading `NSScreen.main`
/// directly. Stage 4 must read both call sites and confirm each one now feeds
/// `NSEvent.mouseLocation` + `NSScreen.screens` + `NSScreen.main` into
/// `ScreenPlacement`, and that `OverlayController` still recomputes the frame
/// on every `presentSurface` (line 431) rather than only on first show — that
/// recomputation is what lets an already-open panel follow the mouse to another
/// display, and is not observable from here.
///
/// RED until Stage 3 adds `ScreenPlacement` with a `Screen` struct
/// (memberwise `frame:` then `visibleFrame:`),
/// `ScreenPlacement.visibleFrame(mouseAt:screens:main:) -> CGRect?` and
/// `ReviewPanelLayout.frame(for:visibleFrame:) -> CGRect`, and routes both
/// controllers through them. It currently fails to COMPILE because none of
/// those symbols exist — that is the intended red.
final class OverlayScreenPlacementTests: XCTestCase {

    // MARK: - A desk with three displays

    /// The built-in laptop display, origin of the global coordinate space.
    /// 38pt of menu bar at the top, no Dock inset.
    private let main = ScreenPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
    )

    /// An external display to the right. 25pt menu bar at the top, 30pt Dock
    /// at the bottom, so its `visibleFrame` is inset on both edges and its
    /// origin is non-zero — the case a width/height-only implementation gets
    /// wrong.
    private let secondary = ScreenPlacement.Screen(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 30, width: 1920, height: 1025)
    )

    /// A third display to the left, at negative x.
    private let tertiary = ScreenPlacement.Screen(
        frame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
        visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 775)
    )

    private var desk: [ScreenPlacement.Screen] { [main, secondary, tertiary] }

    private let pill = CGSize(width: 388, height: 96)

    // MARK: - The rule: the mouse picks the screen

    func testTheMouseOnTheMainScreenKeepsTodaysBehavior() {
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 700, y: 500),
                screens: desk,
                main: main
            ),
            main.visibleFrame
        )
    }

    func testTheMouseOnASecondaryScreenMovesThePanelToThatScreen() {
        // The whole feature: the user is working on the external monitor, so
        // that is where the HUD belongs — regardless of which screen AppKit
        // currently calls `main`.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 2000, y: 500),
                screens: desk,
                main: main
            ),
            secondary.visibleFrame
        )
    }

    func testEveryScreenInTheListIsHitTestedNotJustTheFirstTwo() {
        // Negative coordinates included: a display arranged to the left of the
        // built-in one lives at negative x, which is where sign slips show up.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: -600, y: 400),
                screens: desk,
                main: main
            ),
            tertiary.visibleFrame
        )
    }

    func testTheAnswerIsTheUsableAreaNotTheWholeDisplay() {
        // Returning `frame` instead of `visibleFrame` would tuck the bottom of
        // the panel under the Dock — 54pt up from the screen's bottom edge
        // rather than 54pt up from the top of the Dock.
        let chosen = ScreenPlacement.visibleFrame(
            mouseAt: CGPoint(x: 2000, y: 500),
            screens: desk,
            main: main
        )
        XCTAssertEqual(chosen, secondary.visibleFrame)
        XCTAssertNotEqual(chosen, secondary.frame)
    }

    // MARK: - The mouse is hit-tested against the whole display

    func testThePointerParkedInTheMenuBarIsStillOnThatScreen() {
        // y = 1070 is inside `secondary.frame` (maxY 1080) but above
        // `secondary.visibleFrame` (maxY 1055). Hit-testing against the usable
        // area would call this "no screen" and bounce the HUD back to the
        // laptop display every time the user leaves the pointer near the menu
        // bar — which, on the screen you are reading, is most of the time.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 2000, y: 1070),
                screens: desk,
                main: main
            ),
            secondary.visibleFrame
        )
    }

    func testThePointerOverTheDockIsStillOnThatScreen() {
        // The mirror image at the bottom: y = 10 is inside `frame` (minY 0)
        // and below `visibleFrame` (minY 30).
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 2000, y: 10),
                screens: desk,
                main: main
            ),
            secondary.visibleFrame
        )
    }

    // MARK: - The fallback chain

    func testAPointerOnNoScreenAtAllFallsBackToMain() {
        // Reachable in practice: `NSEvent.mouseLocation` is sampled
        // independently of `NSScreen.screens`, so between a display being
        // unplugged and the arrangement settling, the last known pointer
        // location can sit in a region no screen covers any more. Falling back
        // to main reproduces exactly today's behavior, which is the right
        // thing to do when the new information is missing.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 5_000, y: 5_000),
                screens: desk,
                main: main
            ),
            main.visibleFrame
        )
    }

    func testAPointerInTheGapBetweenTwoUnalignedScreensFallsBackToMain() {
        // Displays of different heights arranged side by side leave real dead
        // regions in the global coordinate space. (-600, 900) is above
        // `tertiary` (maxY 800) and left of `main` (minX 0).
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: -600, y: 900),
                screens: desk,
                main: main
            ),
            main.visibleFrame
        )
    }

    func testWithNoMainScreenTheFirstScreenWins() {
        // `NSScreen.main` is optional and really can be nil (no key window on
        // any screen). Today's expression already ends
        // `?? NSScreen.screens.first`, and that tail must survive.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 5_000, y: 5_000),
                screens: desk,
                main: nil
            ),
            main.visibleFrame,
            "with no main screen the head of the list stands in for it"
        )
    }

    func testAKnownPointerBeatsAMissingMainScreen() {
        // The fallback chain is ordered: the mouse is consulted first, so a
        // nil main is irrelevant whenever the pointer is somewhere real.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 2000, y: 500),
                screens: desk,
                main: nil
            ),
            secondary.visibleFrame
        )
    }

    func testAScreenThatHasBeenUnpluggedIsNeverChosenAgain() {
        // The panel is open on the external display and someone pulls the
        // cable. `NSScreen.screens` loses `secondary` immediately, but
        // `NSEvent.mouseLocation` can still report the pointer's last position
        // inside the region that display used to occupy — the arrangement and
        // the pointer are not updated atomically. The answer must come from the
        // screens that exist NOW: main, not a rect belonging to a display that
        // is no longer attached.
        let remaining = [main, tertiary]
        let stalePointer = CGPoint(x: 2000, y: 500) // was inside `secondary`

        let chosen = ScreenPlacement.visibleFrame(
            mouseAt: stalePointer,
            screens: remaining,
            main: main
        )
        XCTAssertEqual(chosen, main.visibleFrame)
        XCTAssertNotEqual(chosen, secondary.visibleFrame)
        XCTAssertNotEqual(chosen, secondary.frame)
    }

    func testAfterAnUnplugThePointerOnASurvivingScreenPicksThatScreen() {
        // And once the pointer catches up onto a display that is still there,
        // that display wins — the function has no memory of where the panel
        // used to be, which is exactly why it recovers on its own.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: -600, y: 400),
                screens: [main, tertiary],
                main: main
            ),
            tertiary.visibleFrame
        )
    }

    func testWithNoScreensAtAllThereIsNoFrame() {
        // Both call sites already handle a nil frame by leaving the panel
        // where it is (`guard let frame = visibleFrame() else { return }`), so
        // the empty case stays nil rather than inventing a rect at the origin.
        XCTAssertNil(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 700, y: 500),
                screens: [],
                main: nil
            )
        )
    }

    func testASingleScreenIsAlwaysTheAnswerWhereverThePointerIs() {
        // The overwhelmingly common setup. Whatever the pointer is doing —
        // on the screen, in the menu bar, or nowhere at all — there is only
        // one possible answer, and the function must never return nil for it.
        let laptop = [main]
        for mouse in [
            CGPoint(x: 700, y: 500),
            CGPoint(x: 700, y: 970),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 5_000, y: 5_000),
            CGPoint(x: -5_000, y: -5_000)
        ] {
            XCTAssertEqual(
                ScreenPlacement.visibleFrame(mouseAt: mouse, screens: laptop, main: main),
                main.visibleFrame,
                "mouse at \(mouse) on a one-screen desk"
            )
        }
    }

    // MARK: - Boundaries and ties

    func testTheSharedEdgeBetweenTwoScreensBelongsToExactlyOneOfThem() {
        // `main.frame` spans x in [0, 1512) and `secondary.frame` spans
        // [1512, 3432): `CGRect.contains` is half-open at the max edge, so the
        // seam between two abutting displays is unambiguous and no pointer
        // position is ever on both or on neither.
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 1511.999, y: 500),
                screens: desk,
                main: main
            ),
            main.visibleFrame
        )
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 1512, y: 500),
                screens: desk,
                main: main
            ),
            secondary.visibleFrame
        )
    }

    func testWhenTwoScreensBothContainThePointerTheFirstOneWins() {
        // Mirrored displays report overlapping frames. Any answer is
        // defensible; an answer that changes from call to call is not, because
        // it would make the HUD flicker between two screens while the pointer
        // holds still.
        let mirror = ScreenPlacement.Screen(
            frame: main.frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 900)
        )
        let mouse = CGPoint(x: 700, y: 500)

        XCTAssertEqual(
            ScreenPlacement.visibleFrame(mouseAt: mouse, screens: [main, mirror], main: main),
            main.visibleFrame
        )
        XCTAssertEqual(
            ScreenPlacement.visibleFrame(mouseAt: mouse, screens: [mirror, main], main: main),
            mirror.visibleFrame
        )
    }

    func testTheAnswerIsAlwaysOneOfTheScreensItWasHandedIn() {
        // Swept over the whole desk and well past its edges: the function may
        // pick, but it may never synthesise a rect of its own.
        let allowed = Set(desk.map(\.visibleFrame))

        for x in stride(from: -2_000, through: 4_000, by: 97) {
            for y in stride(from: -500, through: 1_500, by: 89) {
                let chosen = ScreenPlacement.visibleFrame(
                    mouseAt: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                    screens: desk,
                    main: main
                )
                guard let chosen else {
                    return XCTFail("a non-empty desk always has an answer (mouse \(x), \(y))")
                }
                XCTAssertTrue(
                    allowed.contains(chosen),
                    "mouse (\(x), \(y)) produced \(chosen), which is not any screen's visible frame"
                )
            }
        }
    }

    func testTheSamePointerAlwaysProducesTheSameScreen() {
        // Purity: no `NSScreen`, no `NSEvent`, nothing read from the
        // environment at call time.
        let mouse = CGPoint(x: 2000, y: 500)
        let first = ScreenPlacement.visibleFrame(mouseAt: mouse, screens: desk, main: main)
        let second = ScreenPlacement.visibleFrame(mouseAt: mouse, screens: desk, main: main)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, secondary.visibleFrame)
    }

    // MARK: - The existing layout math, on the newly chosen screen

    func testTheBottomCentreMathIsUnchangedWhenTheChosenScreenIsTheMainOne() throws {
        // The regression guard for the single-display majority: on a laptop
        // alone, P2-10 must change nothing at all about where the HUD sits.
        // Asserted as the concrete numbers `VoiceSurfaceTests` already pins,
        // not as "equals whatever the function returns".
        let chosen = ScreenPlacement.visibleFrame(
            mouseAt: CGPoint(x: 700, y: 500),
            screens: desk,
            main: main
        )
        let frame = VoiceSurfacePanelLayout.frame(
            for: pill,
            visibleFrame: try XCTUnwrap(chosen)
        )

        XCTAssertEqual(frame.midX, 756)
        XCTAssertEqual(frame.minY, 54)
        XCTAssertEqual(frame.minX, 756 - 194)
        XCTAssertEqual(frame.size, pill)
    }

    func testTheVoiceSurfaceLandsBottomCentredOnWhicheverScreenTheMouseIsOn() throws {
        let chosen = try XCTUnwrap(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 2000, y: 500),
                screens: desk,
                main: main
            )
        )
        let frame = VoiceSurfacePanelLayout.frame(for: pill, visibleFrame: chosen)

        // Centred on the external display, 54pt above its Dock — the same
        // geometry as always, just measured against a different screen.
        XCTAssertEqual(frame.midX, secondary.visibleFrame.midX)
        XCTAssertEqual(frame.midX, 2472) // 1512 + 1920/2
        XCTAssertEqual(frame.minY, secondary.visibleFrame.minY + VoiceSurfacePanelLayout.bottomMargin)
        XCTAssertEqual(frame.minY, 84) // 30 + 54
        XCTAssertEqual(frame.size, pill)

        // And it really left the laptop display behind.
        XCTAssertFalse(main.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertTrue(secondary.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
    }

    func testMovingTheMouseToAnotherScreenMovesThePanelWithoutReshapingIt() throws {
        // Only the anchor changes. If the size or the 54pt bottom offset moved
        // too, the HUD would visibly re-lay-out rather than simply relocate.
        let onMain = VoiceSurfacePanelLayout.frame(
            for: pill,
            visibleFrame: try XCTUnwrap(
                ScreenPlacement.visibleFrame(
                    mouseAt: CGPoint(x: 700, y: 500),
                    screens: desk,
                    main: main
                )
            )
        )
        let onSecondary = VoiceSurfacePanelLayout.frame(
            for: pill,
            visibleFrame: try XCTUnwrap(
                ScreenPlacement.visibleFrame(
                    mouseAt: CGPoint(x: 2000, y: 500),
                    screens: desk,
                    main: main
                )
            )
        )

        XCTAssertEqual(onMain.size, onSecondary.size)
        XCTAssertEqual(
            onMain.minY - main.visibleFrame.minY,
            onSecondary.minY - secondary.visibleFrame.minY
        )
        XCTAssertNotEqual(onMain.midX, onSecondary.midX)
    }

    func testTheResultCardGrowsUpwardFromTheSameEdgeOnASecondaryScreen() throws {
        // The pill-morphs-into-the-card moment survives the move: both sizes
        // share the bottom edge on whichever screen was chosen.
        let chosen = try XCTUnwrap(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 2000, y: 500),
                screens: desk,
                main: main
            )
        )
        let pillFrame = VoiceSurfacePanelLayout.frame(for: pill, visibleFrame: chosen)
        let cardFrame = VoiceSurfacePanelLayout.frame(
            for: CGSize(width: 620, height: 480),
            visibleFrame: chosen
        )

        XCTAssertEqual(pillFrame.minY, cardFrame.minY)
        XCTAssertEqual(pillFrame.midX, cardFrame.midX)
        XCTAssertGreaterThan(cardFrame.maxY, pillFrame.maxY)
    }

    func testAPanelCentredInTheChosenFrameStaysOnTheChosenScreen() throws {
        // The property `ReviewPanelController` depends on: the chosen rect's
        // centre is on the screen the user is actually looking at. Review's own
        // arithmetic is pinned separately in `ReviewPanelScreenPlacementTests`.
        let chosen = try XCTUnwrap(
            ScreenPlacement.visibleFrame(
                mouseAt: CGPoint(x: 2000, y: 500),
                screens: desk,
                main: main
            )
        )
        let centre = CGPoint(x: chosen.midX, y: chosen.midY)

        XCTAssertTrue(secondary.frame.contains(centre))
        XCTAssertFalse(main.frame.contains(centre))
        XCTAssertFalse(tertiary.frame.contains(centre))
    }
}

/// The Review panel's half of 「Review 面板同理」.
///
/// `ReviewPanelController.position(_:)` today is four lines: read
/// `NSScreen.main ?? NSScreen.screens.first`, take its `visibleFrame`, centre a
/// fixed 460×340 panel in it. P2-10 changes only the first line — but with the
/// centring left inline behind a `private func` on a `@MainActor` class that
/// takes an `NSPanel`, there is no assertion any test can make about it, and
/// "Review was updated too" would rest entirely on someone remembering. Pulling
/// the arithmetic into `ReviewPanelLayout` (exactly what `VoiceSurfacePanelLayout`
/// already is for the HUD) gives this half of the spec line a seam that can go
/// red.
///
/// What this pins is Review's geometry *relative to whichever rect it is
/// handed*, composed with `ScreenPlacement` so the pairing is exercised end to
/// end. The `NSScreen`-reading line inside `position(_:)` remains a Stage-4
/// read-review item — see this file's header.
final class ReviewPanelScreenPlacementTests: XCTestCase {

    private let main = ScreenPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
    )
    private let secondary = ScreenPlacement.Screen(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 30, width: 1920, height: 1025)
    )

    private var desk: [ScreenPlacement.Screen] { [main, secondary] }

    /// `ReviewPanelController.panelSize`.
    private let panelSize = CGSize(width: 460, height: 340)

    private func chosenFrame(mouseAt mouse: CGPoint) throws -> CGRect {
        try XCTUnwrap(
            ScreenPlacement.visibleFrame(mouseAt: mouse, screens: desk, main: main)
        )
    }

    func testOnASingleDisplayTheReviewPanelDoesNotMove() throws {
        // The regression guard: for the laptop-only majority P2-10 must be
        // invisible. These are the numbers `position(_:)` produces today —
        // `main.visibleFrame` is 1512×944 at the origin, so a 460×340 panel
        // centred in it sits at (526, 302).
        let frame = ReviewPanelLayout.frame(
            for: panelSize,
            visibleFrame: try chosenFrame(mouseAt: CGPoint(x: 700, y: 500))
        )

        XCTAssertEqual(frame.origin.x, 526)
        XCTAssertEqual(frame.origin.y, 302)
        XCTAssertEqual(frame.size, panelSize)
    }

    func testTheReviewPanelOpensOnWhicheverScreenTheMouseIsOn() throws {
        // The feature, for Review: voice-correcting a transcript while working
        // on the external display must not throw the editable panel onto the
        // laptop screen.
        let frame = ReviewPanelLayout.frame(
            for: panelSize,
            visibleFrame: try chosenFrame(mouseAt: CGPoint(x: 2000, y: 500))
        )

        XCTAssertEqual(frame.midX, secondary.visibleFrame.midX)
        XCTAssertEqual(frame.midY, secondary.visibleFrame.midY)
        XCTAssertEqual(frame.midX, 2472)  // 1512 + 1920/2
        XCTAssertEqual(frame.midY, 542.5) // 30 + 1025/2
        XCTAssertEqual(frame.size, panelSize)

        // And it really left the built-in display behind.
        XCTAssertFalse(main.frame.intersects(frame))
        XCTAssertTrue(secondary.frame.contains(frame))
    }

    func testTheReviewPanelIsCentredInTheUsableAreaNotTheWholeDisplay() throws {
        // `secondary` has a 30pt Dock and a 25pt menu bar, so centring in
        // `frame` instead of `visibleFrame` would sit the panel 2.5pt low —
        // small, but it is the same slip that puts the HUD under the Dock, and
        // it is the reason the seam returns `visibleFrame` at all.
        let frame = ReviewPanelLayout.frame(
            for: panelSize,
            visibleFrame: try chosenFrame(mouseAt: CGPoint(x: 2000, y: 500))
        )

        XCTAssertEqual(frame.midY, secondary.visibleFrame.midY)
        XCTAssertNotEqual(frame.midY, secondary.frame.midY)
    }

    func testMovingScreensRelocatesTheReviewPanelWithoutResizingIt() throws {
        let onMain = ReviewPanelLayout.frame(
            for: panelSize,
            visibleFrame: try chosenFrame(mouseAt: CGPoint(x: 700, y: 500))
        )
        let onSecondary = ReviewPanelLayout.frame(
            for: panelSize,
            visibleFrame: try chosenFrame(mouseAt: CGPoint(x: 2000, y: 500))
        )

        XCTAssertEqual(onMain.size, onSecondary.size)
        XCTAssertNotEqual(onMain.origin, onSecondary.origin)
    }

    func testTheReviewPanelCentresRatherThanSharingTheHUDsBottomEdge() {
        // The two panels are deliberately laid out differently — the HUD is
        // bottom-anchored so it can morph in place, Review is centred because
        // it is a modal editing surface. One shared `ReviewPanelLayout` that
        // just forwarded to `VoiceSurfacePanelLayout` would quietly move the
        // Review panel to the bottom of the screen.
        let visible = secondary.visibleFrame
        let review = ReviewPanelLayout.frame(for: panelSize, visibleFrame: visible)
        let hud = VoiceSurfacePanelLayout.frame(for: panelSize, visibleFrame: visible)

        XCTAssertEqual(review.midX, hud.midX, "both are horizontally centred")
        XCTAssertNotEqual(review.minY, hud.minY)
        XCTAssertGreaterThan(review.minY, hud.minY)
    }

    func testAnyPanelSizeStaysCentred() {
        // Nothing here may hardcode 460×340: the panel's content is variable
        // enough that the size is the caller's business.
        for size in [
            CGSize(width: 460, height: 340),
            CGSize(width: 200, height: 100),
            CGSize(width: 900, height: 700)
        ] {
            let frame = ReviewPanelLayout.frame(for: size, visibleFrame: secondary.visibleFrame)
            XCTAssertEqual(frame.midX, secondary.visibleFrame.midX, "size \(size)")
            XCTAssertEqual(frame.midY, secondary.visibleFrame.midY, "size \(size)")
            XCTAssertEqual(frame.size, size)
        }
    }
}
