import CoreGraphics
import XCTest
@testable import OpenType

/// Coverage for Bug 2 of the popover-and-window fix batch: the main window's
/// default open size used to be a hardcoded `1120×720` (`MainWindowController.init`,
/// `OpenTypeApp.swift`), which is a compromise tuned for one screen size — fine
/// on a 14" MacBook, an inch of wasted width on a 27" external display, and
/// able to overflow a small or unusually shaped screen it was never measured
/// against.
///
/// `MainWindowSizing.defaultContentSize(forVisibleFrame:)` is the pure
/// replacement: a fraction of the screen's usable area, clamped to a floor
/// (today's `1120×720`, so a normal laptop screen keeps today's exact
/// behaviour) and a ceiling (so a very large display doesn't balloon the
/// window unreasonably), and never larger than the screen itself.
///
/// Pure over a plain `CGRect` rather than reading `NSScreen` directly, for the
/// same reason `ScreenPlacement` is (`ScreenPlacement.swift`,
/// `OverlayScreenPlacementTests.swift`): the choice can be tested without a
/// screen. Deliberately does not touch `MainWindowController.minSize` — the
/// owner's rule is that a bigger *default* must not take away the user's
/// ability to shrink the window afterwards.
///
/// RED until `MainWindowSizing` exists — it currently fails to compile,
/// which is the intended red.
final class MainWindowSizingTests: XCTestCase {

    func testATypicalLaptopScreenReproducesTodaysDefaultExactly() {
        // MacBook Pro 14" built-in display, the same visibleFrame
        // `OverlayScreenPlacementTests` uses for its "main" screen. Today's
        // default must not regress for the common case.
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
        XCTAssertEqual(
            MainWindowSizing.defaultContentSize(forVisibleFrame: laptop),
            CGSize(width: 1120, height: 720)
        )
    }

    func testAScreenNarrowerThanTheFloorNeverOverflowsIt() {
        // An old 1024×768 external display. The floor (1120) is wider than
        // the screen itself, so the window must shrink to fit rather than
        // spill off the edge.
        let small = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let size = MainWindowSizing.defaultContentSize(forVisibleFrame: small)
        XCTAssertLessThanOrEqual(size.width, small.width)
        XCTAssertLessThanOrEqual(size.height, small.height)
    }

    func testAScreenJustAboveTheFloorStillGetsExactlyTheFloor() {
        // Wide enough that the floor fits, but not wide enough for the
        // fractional share to exceed it (1280 * 0.62 ≈ 794, well under 1120).
        let midSize = CGRect(x: 0, y: 0, width: 1280, height: 800)
        XCTAssertEqual(
            MainWindowSizing.defaultContentSize(forVisibleFrame: midSize),
            CGSize(width: 1120, height: 720)
        )
    }

    func testALargeExternalDisplayOpensNoticeablyWiderThanTheOldFixedDefault() {
        // A 27"-class display, comfortably above the floor on both axes.
        let external = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let size = MainWindowSizing.defaultContentSize(forVisibleFrame: external)
        XCTAssertGreaterThan(size.width, 1120)
        XCTAssertGreaterThan(size.height, 720)
    }

    func testTheSizeIsCappedRatherThanGrowingWithoutBound() {
        // Pro Display XDR-class resolution. Extra width past the cap only
        // stretches empty space, so growth must stop.
        let huge = CGRect(x: 0, y: 0, width: 6016, height: 3384)
        XCTAssertEqual(
            MainWindowSizing.defaultContentSize(forVisibleFrame: huge),
            MainWindowSizing.maximumSize
        )
    }

    func testTheCapItselfNeverExceedsTheScreen() {
        // A screen bigger than the floor but smaller than the cap on one
        // axis: the cap must still not push past that screen's own edge.
        let oddlyShaped = CGRect(x: 0, y: 0, width: 5000, height: 860)
        let size = MainWindowSizing.defaultContentSize(forVisibleFrame: oddlyShaped)
        XCTAssertLessThanOrEqual(size.height, oddlyShaped.height)
    }

    func testTheMeasuredDeskFromTheBugReportGetsAGenerouslyWiderDetailColumn() {
        // The 1920x1280 logical desk the window-size bug was reported
        // against (a 25pt menu-bar inset, no visible Dock).
        let desk = CGRect(x: 0, y: 25, width: 1920, height: 1255)
        let size = MainWindowSizing.defaultContentSize(forVisibleFrame: desk)
        // Sidebar (212) + list (334) + a detail column that reads as
        // spacious rather than an afterthought.
        XCTAssertGreaterThanOrEqual(size.width, 212 + 334 + 500)
    }

    func testASquareOffOriginIsIgnoredOnlySizeMatters() {
        // A screen whose visibleFrame doesn't start at (0, 0) (a secondary
        // display to the right, or one with a left-side Dock) must produce
        // the same size as the same-sized screen at the origin — this
        // function answers "how big", not "where".
        let atOrigin = MainWindowSizing.defaultContentSize(
            forVisibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let offset = MainWindowSizing.defaultContentSize(
            forVisibleFrame: CGRect(x: 1512, y: 30, width: 1920, height: 1080)
        )
        XCTAssertEqual(atOrigin, offset)
    }
}
