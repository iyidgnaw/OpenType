import AppKit
import Combine
import SwiftUI

@main
struct OpenTypeApp: App {
    @NSApplicationDelegateAdaptor(OpenTypeAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class OpenTypeAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var didFinishLaunching = false
    /// The real, resizable app window from Part A of the menubar split
    /// (settings/History/Memory/Agent Task List — everything that's not
    /// mode-switching). Created lazily on first request rather than at
    /// launch, and kept around (not released on close) so re-opening it
    /// doesn't lose SwiftUI state like scroll position or an in-progress
    /// Settings edit.
    private var mainWindowController: MainWindowController?
    /// When the status item was last clicked. Clicking it activates the app as
    /// a side effect of showing the popover, and that activation must not be
    /// mistaken for a Dock-icon click / Cmd-Tab (see `handleReactivation`).
    /// A timestamp rather than a flag so it can never get stuck set: if the
    /// activation notification never arrives, the window simply expires.
    private var lastStatusItemClick: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pinned light, in dark mode too. The 2026-08 design is a light system
        // — a paper canvas with white cards and one accent — and the palette
        // carries meaning that inverting destroys: an orange warning tint at 5%
        // over white is a hint, the same tint over near-black is invisible, and
        // "success is neutral, colour means something wants you" only reads on
        // a light ground.
        //
        // Pinning rather than dropping the adaptive colours is deliberate. Half
        // the app would otherwise stay adaptive through `.textBackgroundColor`,
        // `.ultraThinMaterial` and every `Color.primary` opacity, so a dark-mode
        // user got light cards on a dark canvas with black-on-black hairlines —
        // which is what this replaced. One appearance for every window and
        // panel is the only version that is coherent.
        //
        // A real dark palette is a design deliverable, not a colour flip; when
        // one exists, this line is what it replaces.
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.setActivationPolicy(.accessory)
        restoreMainWindowIfItWasOpen()
        configurePopover()
        configureStatusItem()
        observeStatusPresentation()

        model.onOpenMainWindowRequested = { [weak self] in
            self?.showMainWindow()
        }

        model.start()
        model.refreshPermissionStatus()
        didFinishLaunching = true

        // Opening the app should produce visible feedback even though OpenType
        // is an accessory app with no Dock window.
        DispatchQueue.main.async { [weak self] in
            self?.showPopover()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        // Coming back from System Settings is exactly how a `.requiresApproval`
        // login item gets cleared, and the Settings page's own `.task` does not
        // re-run for a window that never disappeared — so reactivation is the
        // one moment 开机自启 has to be re-read outside that page.
        model.refreshLaunchAtLogin()
        handleReactivation()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        handleReactivation()
        return true
    }

    /// Single entry point for "the user brought OpenType to the front".
    ///
    /// macOS 26 does not consistently call `applicationShouldHandleReopen` for
    /// LSUIElement apps, so `applicationDidBecomeActive` has to stay a fallback
    /// path here — but it fires for *every* activation, including the one the
    /// status item triggers itself, so it can't blindly present a surface.
    /// The three cases that reach this:
    ///
    /// 1. Status item click — the popover is already being shown by
    ///    `togglePopover`; do nothing else, and above all never surface the
    ///    main window.
    /// 2. Dock icon click / Cmd-Tab / notification click while the main window
    ///    is open — behave like a normal app: bring that window forward, no
    ///    popover.
    /// 3. Reopen with no main window (the app is accessory-only) — the popover
    ///    is the only user-facing surface, so show it.
    private func handleReactivation() {
        if let clickedAt = lastStatusItemClick,
           Date().timeIntervalSince(clickedAt) < 1.0 {
            return
        }

        if let window = mainWindowController?.window,
           window.isVisible || window.isMiniaturized {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        showPopover()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopSidecar()
    }

    private func configureStatusItem() {
        let autosaveName = "OpenType"
        let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: preferredPositionKey) == nil {
            // Lower values stay closer to the system controls on the right.
            // This keeps OpenType out from under the MacBook camera housing on
            // first launch while preserving any later Command-drag position.
            UserDefaults.standard.set(260, forKey: preferredPositionKey)
        }

        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        item.autosaveName = autosaveName
        item.isVisible = true

        guard let button = item.button else {
            statusItem = item
            return
        }

        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        statusItem = item
        // Tooltip and accessibility label are set per state by
        // `updateStatusIcon`, not once here: the icon is a mask now, so the
        // words are the only place the state exists as text.
        updateStatusIcon(
            for: model.state,
            mode: model.configuration.selectedMode
        )
    }

    /// Alfred-style split (Part A): the popover is now just the compact mode
    /// switcher (`MenuBarPopoverView`), not the full-featured `RootView` it
    /// used to host. Settings/History/Memory/Agent history all moved to
    /// `mainWindowController`'s real window instead, opened from this view's
    /// gear button. 300pt wide per the redesign handoff (§05) — the mode cards
    /// that needed 320 are one row of three cells now, and the space went to
    /// the 进行中 / 最近 sections instead.
    /// Reopens the main window if it was open when the app last quit.
    ///
    /// Standard macOS behaviour, and the app did not have it: because the app
    /// is `.accessory`, quitting with the window open and relaunching left the
    /// user with only a menu-bar icon and no sign of where their window went.
    /// Restoring it is also what makes an update-and-relaunch cycle
    /// non-disruptive — the window comes back where it was rather than
    /// requiring a trip through the popover.
    private func restoreMainWindowIfItWasOpen() {
        guard UserDefaults.standard.bool(forKey: Self.mainWindowOpenKey) else { return }
        showMainWindow()
    }

    static let mainWindowOpenKey = "mainWindowWasOpen"

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 384)
        popover.delegate = self
        // `NSApp.appearance` does not reach a popover's own window, so in dark
        // mode the popover drew a light chrome around content whose `.primary`
        // still resolved to white — white text on a white sheet, everything
        // unreadable except the one label sitting on the accent fill. Set here
        // as well, so the two halves agree.
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(model: model) { [weak self] in
                self?.showMainWindow()
                self?.popover.performClose(nil)
            }
        )
    }

    /// Opening the real window promotes OpenType to a regular app for as long
    /// as that window is up, so it gets a Dock icon and is reachable via
    /// Cmd-Tab like anything else with a window. `windowWillClose` demotes it
    /// back to `.accessory` (menu-bar-only, no Dock icon).
    private func showMainWindow() {
        let controller: MainWindowController
        if let existing = mainWindowController {
            controller = existing
        } else {
            controller = MainWindowController(model: model)
            controller.onWindowWillClose = {
                UserDefaults.standard.set(false, forKey: Self.mainWindowOpenKey)
                // Deferred: the window is still on screen during
                // `windowWillClose`, and flipping the policy mid-close can
                // leave a stale Dock icon behind.
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            mainWindowController = controller
        }

        NSApp.setActivationPolicy(.regular)
        UserDefaults.standard.set(true, forKey: Self.mainWindowOpenKey)
        controller.show()
    }

    private func observeStatusPresentation() {
        Publishers.CombineLatest3(
            model.$state.removeDuplicates(),
            model.$runningAgentRunCount.removeDuplicates(),
            model.configuration.$selectedMode.removeDuplicates()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] state, runningAgentCount, mode in
                self?.updateStatusIcon(
                    for: state,
                    runningAgentCount: runningAgentCount,
                    mode: mode
                )
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(
        for state: ProcessingState,
        runningAgentCount: Int = 0,
        mode: InputMode
    ) {
        guard let button = statusItem?.button else { return }
        button.image = MenuBarStatusIcon.image(
            for: state,
            runningAgentCount: runningAgentCount,
            mode: mode
        )
        // The image is a template — AppKit throws its colour away and re-fills
        // the mask — so the button's tint is the only route left for the one
        // accent the HIG allows, and `nil` is what hands every other state back
        // to the standard treatment: adapting to a light or dark menu bar, and
        // inverting while the popover is open.
        button.contentTintColor = MenuBarStatusIcon.tint(for: state)

        let description = MenuBarStatusIcon.accessibilityDescription(
            for: state,
            mode: mode,
            runningAgentCount: runningAgentCount
        )
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    @objc private func togglePopover() {
        lastStatusItemClick = Date()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
        // No `NSApp.activate` here (there used to be one): activating the
        // *application* raises every one of its windows, not just the
        // popover, which is what dragged an already-open main window to the
        // front on every status-item click — exactly the "above all never
        // surface the main window" rule `handleReactivation` documents two
        // cases above, just violated from the other direction. A status-item
        // popover doesn't need it: `NSStatusBarButton` delivers its click
        // regardless of app-activation state, and `NSPopover` (`.transient`
        // here) owns its own key-window and outside-click handling
        // independently of whether the *application* is active — the same
        // reason a normal menu extra's menu works without ever activating its
        // app. `makeKey()` alone is enough for the popover's buttons and
        // Escape-to-dismiss to work.
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// The real, resizable app window from Part A of the Alfred-style menubar
/// split. Distinct from `OverlayController`/`ReviewPanelController`'s borderless
/// `.nonactivatingPanel`s (transient HUD-style feedback) — this is a normal
/// titled window with standard close/miniaturize/resize chrome, since it
/// hosts content (Settings, History, Memory panel, Agent Task List) the user
/// is meant to sit in front of and interact with at length, not glance at
/// and dismiss. While it's open OpenType runs as a regular (Dock-icon,
/// Cmd-Tab-able) app — see `OpenTypeAppDelegate.showMainWindow` — and drops
/// back to accessory-only when it closes, via `onWindowWillClose`.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    var onWindowWillClose: (() -> Void)?

    init(model: AppModel) {
        // Scaled to the screen this window is opening on, not a fixed
        // 1120×720 — see `MainWindowSizing`. `window.center()` below then
        // places this rect on the same screen (`NSScreen.main`) it was sized
        // against.
        let defaultSize = MainWindowSizing.currentDefaultContentSize()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenType"
        // The sidebar runs up under the traffic lights and supplies its own
        // 52pt header strip, so a titlebar of its own would be a second one.
        // The name is in the sidebar's brand row; repeating it in chrome above
        // that row says it twice and costs the height of a list row.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 460, height: 480)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: RootView(model: model)
        )
        // Assigning `contentViewController` is what actually decides the
        // window's size here: `NSHostingController`'s root view is
        // `SidebarShell`'s `GeometryReader`, which has no natural size of its
        // own to report back, so AppKit's post-assignment layout pass
        // collapsed the window to `RootView`'s `.frame(minWidth:minHeight:)`
        // floor — 460×480, the width `SidebarShell` calls "narrow" — instead
        // of leaving the `defaultSize` this window was created with alone.
        // That collapse is bug 2 itself: a freshly opened window showing only
        // the icon rail and the list, not three columns. Reasserting the size
        // (and only then centring, so the centring math sees the real size
        // rather than the collapsed one) is what makes the explicit
        // `contentRect` above actually stick.
        window.setContentSize(defaultSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowWillClose?()
    }
}

/// The status-bar icon: a **template image**, so the state is carried by the
/// shape and nothing else.
///
/// This used to be a coloured rounded square with a white mode glyph knocked
/// out of it, `isTemplate = false`, and the fill colour was the only thing
/// saying what the app was doing (`docs/reviews/2026-08-15-product-review.md`
/// §12). That is three faults in one: a menu bar extra is supposed to be a
/// template so the system can invert it for a dark menu bar and for an open
/// menu; a colour-blind user got one flat square in every state; and an opaque
/// square drawn as-is over a translucent menu bar sat on the wallpaper rather
/// than in the bar. The measurement that settles it: rasterise the old icon and
/// keep only its alpha channel — what a template image actually is — and idle,
/// listening and processing came out *byte-identical*, because the square
/// covered the whole canvas and the white glyph was opaque on top of it.
///
/// So the mapping below spends the one glyph it has on whichever question is
/// live. **At rest the icon shows the mode** — `InputMode.symbol`, the same
/// shape as that mode's card in the popover, which is the standing product
/// decision that the menu bar answers "what will the next press do" without
/// opening anything. **Once something is happening the state takes the glyph
/// over**, because "what is it doing right now" is then the only question worth
/// 18 points, and an answer that still depended on remembering the mode would
/// not be one.
///
/// Deliberate groupings, and why they are not a loss: `transcribing` /
/// `transforming` / `inserting` share one "working" mark (a few hundred
/// milliseconds each, no user action depends on which, and three legible
/// variants of "busy" do not exist at this size); `success` / `copied` share
/// one; `idle` / `modeChanged` share one because a mode announcement *is* the
/// mode. Everything else is distinct, and
/// `Tests/OpenTypeTests/MenuBarStatusIconTests.swift` both pins the mapping and
/// compares the rendered masks, so "distinguishable" is measured rather than
/// asserted.
enum MenuBarStatusIcon {
    /// Menu bar extras are laid out in an 18pt square (`squareLength`), and the
    /// glyph is composed into a canvas of exactly that rather than handed
    /// through at its own size, so a wide symbol (`waveform`) and a tall one
    /// (`exclamationmark.triangle.fill`) occupy the same box.
    private static let canvas = NSSize(width: 18, height: 18)

    /// The whole product requirement, as a pure function: state (plus the mode,
    /// which only the two at-rest cases read) to an SF Symbol name.
    ///
    /// The `switch` has **no `default:`** on purpose. A new `ProcessingState`
    /// case then fails to build here instead of quietly inheriting some other
    /// state's shape, which is a stronger guard than any test could be — a test
    /// cannot enumerate a case that does not exist yet.
    static func symbolName(for state: ProcessingState, mode: InputMode) -> String {
        switch state {
        case .idle, .modeChanged:
            return mode.symbol
        case .listening:
            // Not `mic.fill`, which is transcribe's *mode* glyph: reusing it
            // would make idle and recording the same picture in the mode people
            // record in most. A waveform is also the more honest mark — it says
            // sound is arriving, not that a microphone exists.
            return "waveform"
        case .transcribing, .transforming, .inserting:
            // Three dots rather than the spec's suggested gear: a gear in a menu
            // bar reads as settings. Enclosed rather than bare, which was the
            // first attempt — a bare `ellipsis` is a third the optical weight of
            // every other glyph here, so the icon appeared to vanish for the
            // second it was working and come back when it finished.
            return "ellipsis.circle"
        case .success, .copied:
            return "checkmark"
        case .dispatched:
            return "paperplane.fill"
        case .cancelled:
            // `ProcessingState.symbol` uses `circle.slash` for this, which the
            // overlay can afford and the menu bar cannot — a slashed circle at
            // 18pt is a smudge. The two surfaces are allowed to differ here
            // because only one of them is 18 points wide.
            return "xmark"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    /// The single HIG-sanctioned exception to a monochrome menu bar: an accent
    /// while a recording is actually in progress. Everything else returns `nil`,
    /// which is what keeps the mask under the system's own treatment.
    ///
    /// It is `AppAccent.nsPrimary` rather than a recording red because the
    /// product has exactly one accent (the six-way theme picker was deleted),
    /// and because the tint is no longer carrying information — the waveform
    /// already said "listening" to someone who cannot see the colour at all.
    static func tint(for state: ProcessingState) -> NSColor? {
        switch state {
        case .listening:
            return AppAccent.nsPrimary
        case .idle, .modeChanged, .transcribing, .transforming, .inserting,
             .success, .copied, .dispatched, .cancelled, .failure:
            return nil
        }
    }

    /// The same information as the shape, in words — for VoiceOver and for the
    /// tooltip, which are now the only place it exists as text. Both halves are
    /// always named, since the glyph only ever draws one of them.
    static func accessibilityDescription(
        for state: ProcessingState,
        mode: InputMode,
        runningAgentCount: Int = 0
    ) -> String {
        let status = OpenTypeL10n.text(
            "OpenType — \(mode.title) · \(state.title)",
            english: "OpenType — \(mode.title) · \(state.title)"
        )
        guard runningAgentCount > 0 else { return status }
        // The badge lost its numeral in the move to a mask (see
        // `drawRunningAgentBadge`), so this sentence is where the count went.
        return OpenTypeL10n.text(
            "\(status) · \(runningAgentCount) 个 Agent 任务进行中",
            english: runningAgentCount == 1
                ? "\(status) · 1 Agent task running"
                : "\(status) · \(runningAgentCount) Agent tasks running"
        )
    }

    static func image(
        for state: ProcessingState,
        runningAgentCount: Int = 0,
        mode: InputMode = .transcribe
    ) -> NSImage {
        let symbol = NSImage(
            systemSymbolName: symbolName(for: state, mode: mode),
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            // Regular weight, not the semibold the old icon needed to stay
            // legible against its own coloured fill. Standing on the menu bar
            // itself, the glyph should match the system's extras rather than
            // shout over them.
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        )
        let isBadged = runningAgentCount > 0

        // A drawing handler rather than a fixed 2× bitmap: the handler is asked
        // to draw at whatever scale the display in front of the user needs, so
        // the glyph stays crisp on a non-Retina external monitor instead of
        // being a downsampled 36px sprite.
        let image = NSImage(size: canvas, flipped: false) { _ in
            guard let symbol else { return true }
            symbol.draw(in: glyphRect(for: symbol))
            if isBadged {
                drawRunningAgentBadge()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(
            for: state,
            mode: mode,
            runningAgentCount: runningAgentCount
        )
        return image
    }

    /// Fits `symbol` into the canvas at its own aspect ratio, centred, never
    /// enlarged. Scaling down matters for the wide glyphs — `waveform` is
    /// noticeably wider than tall at a given point size — which would otherwise
    /// be the only ones clipped by the 18pt box.
    ///
    /// The badge does not move or shrink it. An earlier version laid a badged
    /// glyph out in a smaller box anchored away from the corner, which made the
    /// whole icon lurch down and left the moment a background task started —
    /// motion in the menu bar that says nothing about the task.
    private static func glyphRect(for symbol: NSImage) -> NSRect {
        let box = NSRect(origin: .zero, size: canvas)
        let size = symbol.size
        guard size.width > 0, size.height > 0 else { return box }

        let scale = min(box.width / size.width, box.height / size.height, 1)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: box.midX - drawn.width / 2,
            y: box.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// "At least one Agent task is running" — a dot in the top-right corner.
    ///
    /// It **lost its count** in the move to a template image, and that is an
    /// improvement rather than a concession: the old numeral was a 9.5pt font in
    /// a 36px sprite, i.e. under 5 points on screen and unreadable even in
    /// colour, and a mask has no second colour to print it in — it would have
    /// had to be a hole punched in a 5pt dot. The number now lives in the
    /// tooltip and the VoiceOver label, where it can actually be read; the menu
    /// bar keeps the part a glance can take in, which is that something is
    /// running at all. The detail was always in the popover's 进行中 section.
    private static func drawRunningAgentBadge() {
        let diameter: CGFloat = 5
        let rect = NSRect(
            x: canvas.width - diameter,
            y: canvas.height - diameter,
            width: diameter,
            height: diameter
        )
        // Saved and restored around the `.clear` below, which is a context-wide
        // setting: leaving it changed would apply to whatever AppKit draws next
        // into the same context.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Clear a ring first. Two opaque shapes that touch merge into one blob
        // in a mask, and there is no outline colour available to separate them
        // with — so the separation has to be an absence.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: rect.insetBy(dx: -1.2, dy: -1.2)).fill()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        // The colour is discarded — a template image keeps only alpha — so black
        // here is the conventional placeholder, not a palette choice.
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}
