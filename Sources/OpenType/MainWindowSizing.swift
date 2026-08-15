import AppKit
import CoreGraphics

/// How wide/tall the main window opens by default, before the user has ever
/// resized it by hand — Bug 2 of the popover-and-window fix batch.
///
/// A fixed `1120×720` (this file's predecessor, inline in
/// `MainWindowController.init`) is a compromise tuned for one screen size:
/// comfortable on a 14" MacBook, an inch of unused width on a 27" external
/// display, and able to overflow a small or unusually shaped screen it was
/// never measured against. This scales with the screen the window opens on
/// instead — a fraction of its usable area, clamped to a floor (today's
/// `1120×720`, so a normal laptop screen keeps today's exact size — no
/// regression for the common case) and a ceiling (so a very large display
/// doesn't balloon the window past where the extra width would do anything
/// but stretch empty space), and never larger than the screen itself.
///
/// Deliberately does not touch `MainWindowController.window.minSize` — the
/// user's freedom to shrink the window afterwards, once it's open, is a
/// separate and explicit product decision that a bigger *default* must not
/// take away.
///
/// Pure over a plain `CGRect` rather than reading `NSScreen` directly, for
/// the same reason `ScreenPlacement` is (`ScreenPlacement.swift`): the choice
/// can be tested without a screen. `currentDefaultContentSize()` below is the
/// second, deliberately tiny step that reads the live AppKit value.
enum MainWindowSizing {
    /// Today's pre-existing default, and the floor below which this function
    /// never shrinks the window on a screen that can accommodate it — the
    /// size sidebar (212) + list (334) + a genuinely usable detail column
    /// was already tuned to.
    static let minimumSize = CGSize(width: 1120, height: 720)
    /// Past this, more width only stretches the list and detail columns
    /// without helping either, so growth stops here regardless of how large
    /// the screen is.
    static let maximumSize = CGSize(width: 1440, height: 900)

    /// The fraction of the screen's usable area the window would like to
    /// claim, before the floor/ceiling clamp. Chosen so that today's common
    /// laptop and 1080p-class screens land exactly on `minimumSize` (no
    /// visible change there) while larger displays are given noticeably more
    /// room.
    private static let widthFraction: CGFloat = 0.62
    private static let heightFraction: CGFloat = 0.75

    static func defaultContentSize(forVisibleFrame frame: CGRect) -> CGSize {
        let width = min(
            max(frame.width * widthFraction, minimumSize.width),
            maximumSize.width
        )
        let height = min(
            max(frame.height * heightFraction, minimumSize.height),
            maximumSize.height
        )
        // The clamp above answers "how big would we like to be"; this second
        // clamp is the one that actually guarantees no overflow, since a
        // screen smaller than `minimumSize` would otherwise still get the
        // floor value.
        return CGSize(
            width: min(width, frame.width),
            height: min(height, frame.height)
        )
    }
}

@MainActor
extension MainWindowSizing {
    /// `defaultContentSize(forVisibleFrame:)` fed with what AppKit reports
    /// right now for the main screen — the screen `NSWindow.center()` (called
    /// immediately after, in `MainWindowController.init`) also centers a new
    /// window on.
    static func currentDefaultContentSize() -> CGSize {
        defaultContentSize(
            forVisibleFrame: NSScreen.main?.visibleFrame
                ?? CGRect(origin: .zero, size: minimumSize)
        )
    }
}
