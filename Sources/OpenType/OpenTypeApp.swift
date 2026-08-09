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
        // macOS 26 does not consistently call applicationShouldHandleReopen
        // for LSUIElement apps. Reopening OpenType does make it active, so this
        // is the reliable path for presenting its only user-facing window.
        guard didFinishLaunching else { return }
        showPopover()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPopover()
        return true
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
            colorTheme: model.configuration.colorTheme
        )
    }

    /// Alfred-style split (Part A): the popover is now just the compact mode
    /// switcher (`MenuBarPopoverView`), not the full-featured `RootView` it
    /// used to host. Settings/History/Memory/Agent history all moved to
    /// `mainWindowController`'s real window instead, opened from this view's
    /// gear button.
    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 264, height: 246)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(model: model) { [weak self] in
                self?.showMainWindow()
                self?.popover.performClose(nil)
            }
        )
    }

    private func showMainWindow() {
        let controller = mainWindowController ?? MainWindowController(model: model)
        mainWindowController = controller
        controller.show()
    }

    private func observeStatusPresentation() {
        Publishers.CombineLatest3(
            model.$state.removeDuplicates(),
            model.configuration.$colorTheme.removeDuplicates(),
            model.$runningAgentRunCount.removeDuplicates()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] state, colorTheme, runningAgentCount in
                self?.updateStatusIcon(
                    for: state,
                    colorTheme: colorTheme,
                    runningAgentCount: runningAgentCount
                )
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(
        for state: ProcessingState,
        colorTheme: AppColorTheme,
        runningAgentCount: Int = 0
    ) {
        guard let button = statusItem?.button else { return }
        button.image = MenuBarStatusIcon.image(
            for: state,
            colorTheme: colorTheme,
            runningAgentCount: runningAgentCount
        )
    }

    @objc private func togglePopover() {
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
/// and dismiss. OpenType stays an accessory app (no Dock icon) throughout;
/// showing this window doesn't change that.
@MainActor
final class MainWindowController: NSWindowController {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MenuBarStatusIcon {
    static func image(
        for state: ProcessingState,
        colorTheme: AppColorTheme = .ocean,
        runningAgentCount: Int = 0
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
        drawPixels(for: state, colorTheme: colorTheme)
        if runningAgentCount > 0 {
            drawRunningAgentBadge(count: runningAgentCount)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        image.isTemplate = false
        image.accessibilityDescription = "OpenType"
        return image
    }

    private static func drawPixels(
        for state: ProcessingState,
        colorTheme: AppColorTheme
    ) {
        let rect = NSRect(x: 0, y: 0, width: 36, height: 36)
        backgroundColor(for: state, colorTheme: colorTheme).setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: 1, dy: 1),
            xRadius: 10,
            yRadius: 10
        ).fill()

        NSColor.white.setFill()
        let heights: [CGFloat] = [12, 22, 30, 20, 12]
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2.8
        let totalWidth = CGFloat(heights.count) * barWidth
            + CGFloat(heights.count - 1) * gap
        let startX = rect.midX - totalWidth / 2

        for (index, height) in heights.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + gap)
            let bar = NSRect(
                x: x,
                y: rect.midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(
                roundedRect: bar,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
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
