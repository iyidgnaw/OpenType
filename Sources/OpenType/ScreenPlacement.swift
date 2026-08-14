import AppKit
import CoreGraphics

/// Which display a floating panel belongs on (P2-10,
/// `docs/superpowers/specs/2026-08-14-product-batch-plan.md`):
/// 「`OverlayController` 的 `visibleFrame()` 从 `NSScreen.main` 改为「鼠标所在屏
/// → 主屏」兜底。Review 面板同理。」
///
/// Both floating panels used to ask AppKit for one specific screen —
/// `NSScreen.main ?? NSScreen.screens.first`. `NSScreen.main` is the screen
/// holding the *key window*, which for a menubar-resident accessory app is
/// whatever app the user was last typing in — but it is also stale or wrong
/// often enough (nothing key, a full-screen space, a display that just came back
/// from sleep) that on a multi-monitor desk the HUD regularly appears on the
/// monitor the user is not looking at. The pointer is the better guess at where
/// the user's attention is, so it goes first and `main` becomes the fallback,
/// which reproduces exactly the old behavior whenever the new information is
/// missing.
///
/// The choice itself is pure over plain `CGRect`s so it can be tested without a
/// screen (precedent: `VoiceSurfacePanelLayout`, `OutputDeliveryPolicy`).
/// Reading the live AppKit values is a second, deliberately tiny step —
/// `currentVisibleFrame()` at the bottom of this file — kept here rather than in
/// each controller so the two panels cannot drift into disagreeing about which
/// screen the user is on.
enum ScreenPlacement {

    /// One display, as the two rects that matter — and they are not
    /// interchangeable.
    ///
    /// `frame` is the whole display and is what the mouse is hit-tested
    /// against: a pointer up in the menu bar or down over the Dock is still on
    /// that screen. `visibleFrame` is the usable area and is what a panel is
    /// laid out inside. Hit-testing against `visibleFrame` would drop the
    /// pointer into "no screen" whenever it is over the menu bar — a place
    /// people leave the mouse constantly — and bounce the panel back to the
    /// built-in display every time.
    struct Screen {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    /// The usable rect to lay a panel out in: the screen under the pointer,
    /// falling back to `main`, falling back to the head of `screens`.
    ///
    /// Returns `nil` only when there are no screens at all. Both call sites
    /// already treat that as "leave the panel where it is", which is better
    /// than inventing a rect at the origin.
    ///
    /// The answer always comes from the screens passed in *now*: after a
    /// display is unplugged, `NSScreen.screens` loses it immediately while
    /// `NSEvent.mouseLocation` can still report the pointer inside the region
    /// that display used to occupy, so a stale pointer must fall through to
    /// `main` rather than resurrect a rect belonging to a display that is no
    /// longer attached.
    ///
    /// Ties (mirrored displays report overlapping frames) go to the first match
    /// in order. Any answer is defensible; an answer that changes from call to
    /// call is not, because it would make the panel flicker between two screens
    /// while the pointer holds still.
    static func visibleFrame(
        mouseAt mouse: CGPoint,
        screens: [Screen],
        main: Screen?
    ) -> CGRect? {
        if let under = screens.first(where: { $0.frame.contains(mouse) }) {
            return under.visibleFrame
        }
        return (main ?? screens.first)?.visibleFrame
    }
}

// MARK: - The AppKit side

@MainActor
extension ScreenPlacement {

    /// `visibleFrame(mouseAt:screens:main:)` fed with what AppKit reports right
    /// now. The single call both `OverlayController` and `ReviewPanelController`
    /// make, so 「Review 面板同理」 stays true by construction rather than by
    /// someone remembering to change two files.
    ///
    /// Read fresh on every presentation rather than cached: that is what lets an
    /// already-open panel follow the pointer onto another display, and what
    /// makes an unplugged display correct itself on the next show.
    static func currentVisibleFrame() -> CGRect? {
        visibleFrame(
            mouseAt: NSEvent.mouseLocation,
            screens: NSScreen.screens.map(\.placement),
            main: NSScreen.main?.placement
        )
    }
}

private extension NSScreen {
    var placement: ScreenPlacement.Screen {
        ScreenPlacement.Screen(frame: frame, visibleFrame: visibleFrame)
    }
}
