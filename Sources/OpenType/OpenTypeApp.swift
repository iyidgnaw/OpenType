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
        NSApp.setActivationPolicy(.accessory)
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
        button.toolTip = "OpenType"
        button.setAccessibilityLabel("OpenType")
        statusItem = item
        updateStatusIcon(
            for: model.state,
            colorTheme: model.configuration.colorTheme,
            mode: model.configuration.selectedMode
        )
    }

    /// Alfred-style split (Part A): the popover is now just the compact mode
    /// switcher (`MenuBarPopoverView`), not the full-featured `RootView` it
    /// used to host. Settings/History/Memory/Agent history all moved to
    /// `mainWindowController`'s real window instead, opened from this view's
    /// gear button. Widened/heightened from the original 264x246 (see
    /// `MenuBarPopoverView`'s own sizing note) so the now vertically-stacked
    /// mode cards have room and don't wrap their subtitle text.
    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 340)
        popover.delegate = self
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
        controller.show()
    }

    private func observeStatusPresentation() {
        Publishers.CombineLatest4(
            model.$state.removeDuplicates(),
            model.configuration.$colorTheme.removeDuplicates(),
            model.$runningAgentRunCount.removeDuplicates(),
            model.configuration.$selectedMode.removeDuplicates()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] state, colorTheme, runningAgentCount, mode in
                self?.updateStatusIcon(
                    for: state,
                    colorTheme: colorTheme,
                    runningAgentCount: runningAgentCount,
                    mode: mode
                )
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(
        for state: ProcessingState,
        colorTheme: AppColorTheme,
        runningAgentCount: Int = 0,
        mode: InputMode
    ) {
        guard let button = statusItem?.button else { return }
        button.image = MenuBarStatusIcon.image(
            for: state,
            colorTheme: colorTheme,
            runningAgentCount: runningAgentCount,
            mode: mode
        )
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
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// The real, resizable app window from Part A of the Alfred-style menubar
/// split. Distinct from `OverlayController`/`AskPanelController`'s borderless
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenType"
        window.minSize = NSSize(width: 420, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(
            rootView: RootView(model: model)
        )
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

enum MenuBarStatusIcon {
    /// Per the product owner: the menu bar icon itself should say which mode
    /// is active, glanceable without opening the popover — not just a
    /// generic "OpenType is here" mark. One SF Symbol per mode, matching
    /// `InputMode.symbol` (`Models.swift`) so the glyph here and the glyph on
    /// that mode's card in the popover are always the same shape.
    private static func glyphName(for mode: InputMode) -> String {
        mode.symbol
    }

    static func image(
        for state: ProcessingState,
        colorTheme: AppColorTheme = .ocean,
        runningAgentCount: Int = 0,
        mode: InputMode = .transcribe
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let pixelWidth = 36
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelWidth,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return NSImage(size: size)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        drawPixels(for: state, colorTheme: colorTheme, mode: mode)
        if runningAgentCount > 0 {
            drawRunningAgentBadge(count: runningAgentCount)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        image.isTemplate = false
        image.accessibilityDescription = OpenTypeL10n.text(
            "OpenType — \(mode.title)",
            english: "OpenType — \(mode.title)"
        )
        return image
    }

    private static func drawPixels(
        for state: ProcessingState,
        colorTheme: AppColorTheme,
        mode: InputMode
    ) {
        let rect = NSRect(x: 0, y: 0, width: 36, height: 36)
        backgroundColor(for: state, colorTheme: colorTheme).setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: 1, dy: 1),
            xRadius: 10,
            yRadius: 10
        ).fill()

        drawModeGlyph(mode, in: rect)
    }

    /// Renders `mode`'s SF Symbol in white, centered in `rect`. SF Symbols
    /// draw as multicolor/hierarchical by default; `.paletteColors([.white])`
    /// forces a flat white render so it reads clearly against the colored
    /// background regardless of which symbol a given mode uses.
    private static func drawModeGlyph(_ mode: InputMode, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 16,
            weight: .semibold
        ).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

        guard
            let symbol = NSImage(
                systemSymbolName: glyphName(for: mode),
                accessibilityDescription: nil
            )?.withSymbolConfiguration(configuration)
        else {
            return
        }

        let symbolSize = symbol.size
        let drawRect = NSRect(
            x: rect.midX - symbolSize.width / 2,
            y: rect.midY - symbolSize.height / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        symbol.draw(in: drawRect)
    }

    /// Lightweight "N Agent tasks running" indicator (Part B, requirement 3):
    /// a small filled dot in the icon's top-right corner, with the count
    /// inside once it's more than a single task. Deliberately minimal —
    /// this is meant to be glanceable, not a second status surface; the real
    /// detail lives in the Task List panel (`AgentTaskLogView`) in the main
    /// app window.
    private static func drawRunningAgentBadge(count: Int) {
        let badgeDiameter: CGFloat = 15
        let badgeRect = NSRect(
            x: 36 - badgeDiameter - 1,
            y: 36 - badgeDiameter - 1,
            width: badgeDiameter,
            height: badgeDiameter
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.4, dy: -1.4)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let text = count > 9 ? "9+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedText.size()
        attributedText.draw(
            at: NSPoint(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2
            )
        )
    }

    static func backgroundColor(
        for state: ProcessingState,
        colorTheme: AppColorTheme
    ) -> NSColor {
        switch state {
        case .listening:
            return .systemRed
        case .transcribing, .transforming, .inserting:
            return .systemPurple
        case .failure:
            return .systemOrange
        default:
            return colorTheme.nsAccent
        }
    }
}
