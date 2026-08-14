import AppKit
import SwiftUI

@MainActor
private final class ReviewPanelPresentation: ObservableObject {
    /// Initial text only, set once by `show(...)`. After that, the live
    /// `NSTextView` owned by this controller (captured via
    /// `onTextViewReady` below) is the sole source of truth for the current
    /// text — this deliberately does *not* get updated on every keystroke or
    /// mirror corrections back into itself, because a SwiftUI diff cycle
    /// that then re-pushed a stale `text` value into the `NSTextView` (e.g.
    /// triggered by an unrelated `@Published` change like `isCorrecting`)
    /// would clobber whatever the user just typed. See `ReviewPanelController`.
    @Published var text = ""
    @Published var isCorrecting = false
    @Published var correctionHint: String?
}

/// Where the Review panel sits inside a chosen screen's usable area: centred.
///
/// Deliberately *not* `VoiceSurfacePanelLayout`, which anchors the HUD 54pt up
/// from the bottom edge so it can morph in place. The two panels are laid out
/// differently on purpose — the HUD is a peripheral status surface, Review is a
/// modal editing surface you are meant to look straight at — and one shared
/// layout that just forwarded to the other would quietly slide the Review panel
/// down to the bottom of the screen.
///
/// A pure namespace enum for the same reason `VoiceSurfacePanelLayout` is one:
/// with the arithmetic inline in `ReviewPanelController.position(_:)` there was
/// no assertion any test could make about it, so 「Review 面板同理」 (P2-10)
/// rested entirely on someone remembering.
enum ReviewPanelLayout {
    static func frame(for size: CGSize, visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// A floating panel for Review mode (`TranscribeVariant.review`): stashes a
/// transcription for the user to read, edit, or voice-correct before
/// committing it into the originally-focused field. Follows the same
/// `NSPanel` + `.nonactivatingPanel` + `canBecomeKey` pattern
/// `OverlayController` already establishes in this
/// codebase (so the underlying target app stays frontmost the whole time,
/// which is what lets the eventual commit's `ContextBridge.insert(...)`
/// still land in the field the user had focused when they started
/// dictating), but is a genuinely different, more complex interaction: it
/// needs live, editable text with real text-selection tracking, not a
/// read-only display.
///
/// Text-ownership design: the panel wraps a real `NSTextView`
/// (`ReviewTextView`, an `NSViewRepresentable`) rather than SwiftUI's
/// `TextEditor`, for two reasons — `TextEditor`'s selection-range binding
/// API needs macOS 14 (this app targets macOS 13), and `NSTextView` gives
/// direct, synchronous access to `selectedRange()`, which
/// `AppModel.hotKeyPressed()` needs to read *before* it decides whether a
/// second hotkey press means "start a correction for the current selection"
/// or "select nothing was chosen, tell the user." `AppModel` never mutates
/// `NSTextView`'s content through SwiftUI state — all reads
/// (`currentText()`/`currentSelection()`) and writes (`applyCorrection`) go
/// straight through the stored `textView` reference, sidestepping any
/// SwiftUI-diff-vs-live-typing race entirely.
@MainActor
final class ReviewPanelController {
    private let panelSize = NSSize(width: 460, height: 340)
    private let presentation = ReviewPanelPresentation()
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private weak var textView: NSTextView?

    /// Fired when the user commits (Enter button / Cmd+Return) — the caller
    /// (`AppModel`) reads the final text back via `currentText()` and is
    /// responsible for delivery, history, and audit logging, then calls
    /// `hide()` (indirectly, by clearing its own `reviewPanelState`).
    var onCommit: (() -> Void)?
    /// Fired when the user cancels (Escape / Cancel button / click outside).
    var onCancel: (() -> Void)?

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Retained strongly (in addition to the panel's own `contentView`
    /// reference) and rebuilt on every `show(...)` — see `show(...)` for why.
    private var hostingView: NSHostingView<ReviewPanelView>?

    private func makeHostingView() -> NSHostingView<ReviewPanelView> {
        NSHostingView(
            rootView: ReviewPanelView(
                presentation: presentation,
                onTextViewReady: { [weak self] textView in
                    self?.textView = textView
                },
                onCommit: { [weak self] in self?.onCommit?() },
                onCancel: { [weak self] in self?.onCancel?() }
            )
        )
    }

    func show(originalTranscript: String) {
        presentation.text = originalTranscript
        presentation.isCorrecting = false
        presentation.correctionHint = nil

        let panel = panel ?? makePanel()

        // Rebuild the hosting view on every show. `hide()` nils the weak
        // `textView` but leaves the cached panel intact; if we reused a single
        // lazily-built hosting view, SwiftUI would run only `updateNSView` (a
        // deliberate no-op) on re-show instead of `makeNSView`, so
        // `onTextViewReady` would never re-fire and `textView` would stay nil
        // for the whole second (and every subsequent) session — killing
        // voice-correction and diverging `currentText()` from the visible,
        // committed text (P0-3). A fresh hosting view forces `makeNSView` to
        // run again, binding a live `NSTextView` seeded with the CURRENT
        // `presentation.text` (just set to `originalTranscript` above).
        let hostingView = makeHostingView()
        self.hostingView = hostingView
        panel.contentView = hostingView

        position(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installClickOutsideMonitor()

        // The hosting view/NSTextView is created lazily on first layout; by
        // the time this dispatched block runs, `textView` (set via
        // `onTextViewReady`) is populated, so focus can be handed to it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = self.textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    func hide() {
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
        textView = nil
    }

    /// The authoritative current text, including any manual edits or applied
    /// corrections. Falls back to the last-known `presentation.text` only if
    /// the `NSTextView` has already been torn down (e.g. called after `hide()`).
    func currentText() -> String {
        textView?.string ?? presentation.text
    }

    /// The panel's current text selection, in UTF-16 code units
    /// (`NSTextView.selectedRange()`'s native representation — see
    /// `TextSpanCorrection`'s doc comment for why this is exactly the
    /// representation the sidecar's `/transcribe/correct` endpoint expects).
    /// `nil` when the panel has no text view yet, or the selection is empty
    /// (a bare caret, not an actual span to correct).
    func currentSelection() -> (range: NSRange, substring: String)? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        let text = textView.string as NSString
        guard range.location >= 0, range.location + range.length <= text.length else {
            return nil
        }
        return (range, text.substring(with: range))
    }

    /// Locks editing and shows the "correcting…" indicator while a
    /// `/transcribe/correct` round is in flight, so the user can't edit out
    /// from under a correction that's about to splice text back in.
    func beginCorrecting() {
        presentation.isCorrecting = true
        textView?.isEditable = false
    }

    func endCorrecting() {
        presentation.isCorrecting = false
        textView?.isEditable = true
    }

    /// Splices `replacement` into the text view at `range` (via
    /// `TextSpanCorrection`), re-selects the newly-inserted replacement so a
    /// follow-up correction round can immediately target it again, and
    /// returns the resulting full text for the caller to record in the audit
    /// chain.
    @discardableResult
    func applyCorrection(_ replacement: String, in range: NSRange) -> String {
        guard let textView else { return presentation.text }
        let updated = TextSpanCorrection.apply(
            replacement: replacement,
            to: textView.string,
            range: range
        )
        textView.string = updated
        let newSelection = NSRange(location: range.location, length: (replacement as NSString).length)
        textView.setSelectedRange(newSelection)
        textView.scrollRangeToVisible(newSelection)
        presentation.text = updated
        return updated
    }

    /// Brief, transient hint shown in the panel (e.g. "select text first") —
    /// distinct from `isCorrecting`, which gates editing during an actual
    /// in-flight correction call.
    func showHint(_ text: String) {
        presentation.correctionHint = text
        let token = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.presentation.correctionHint == token else { return }
            self.presentation.correctionHint = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableFloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A panel is its own window and does not inherit `NSApp.appearance`,
        // so without this it kept the system's dark palette while the rest of
        // the app was pinned light — the same split that made the menu bar
        // popover draw white text on a white sheet.
        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.hidesOnDeactivate = false
        // The content view is (re)assigned by `show(...)` on every session —
        // see that method for why the hosting view must be rebuilt each time.
        return panel
    }

    /// Centres the panel on whichever display the pointer is on, falling back to
    /// `NSScreen.main` (P2-10 — 「Review 面板同理」, see `ScreenPlacement`).
    /// Voice-correcting a transcript while working on an external display must
    /// not throw the editable panel onto the built-in screen.
    private func position(_ panel: NSPanel) {
        guard let frame = ScreenPlacement.currentVisibleFrame() else { return }
        panel.setFrame(
            ReviewPanelLayout.frame(for: panelSize, visibleFrame: frame),
            display: false
        )
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let clickLocation = NSEvent.mouseLocation
            guard !panel.frame.contains(clickLocation) else { return }
            self.onCancel?()
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
        clickOutsideMonitor = nil
    }
}

/// See `OverlayController.swift`'s identical type for why `canBecomeKey`
/// must be overridden: a `.nonactivatingPanel` normally can't become key,
/// which would swallow the keyboard input this panel's text editing and
/// Escape/Cmd+Return shortcuts depend on.
private final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ReviewPanelView: View {
    @ObservedObject var presentation: ReviewPanelPresentation
    let onTextViewReady: (NSTextView) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ReviewTextView(
                presentation: presentation,
                onTextViewReady: onTextViewReady
            )
            .frame(minHeight: 140, maxHeight: .infinity)
            .padding(8)
            .background(
                DS.Colour.card.opacity(0.5),
                in: RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.inset, style: .continuous)
                    .strokeBorder(DS.Colour.border, lineWidth: 0.75)
            )

            footerHint

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(cancelTitle)
                        .font(DS.Text.caption())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            DS.Colour.card,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Colour.border, lineWidth: 0.75)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer(minLength: 0)

                Button(action: onCommit) {
                    Text(commitTitle)
                        .font(DS.Text.caption())
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            DS.Colour.accent,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.45), lineWidth: 0.75)
        )
        .tint(DS.Colour.accent)
        .environment(\.locale, OpenTypeL10n.locale)
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colour.accent)
            Text(OpenTypeL10n.text("复核", english: "Review"))
                .font(DS.Text.body(.semibold))
            if presentation.isCorrecting {
                Spacer(minLength: 8)
                ProgressView()
                    .controlSize(.small)
                Text(OpenTypeL10n.text("正在修改…", english: "Correcting…"))
                    .font(DS.Text.caption())
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 8)
            }
        }
    }

    private var footerHint: some View {
        Text(presentation.correctionHint ?? defaultHint)
            .font(DS.Text.caption())
            .foregroundStyle(
                presentation.correctionHint == nil
                    ? Color.secondary
                    : DS.Colour.warningText
            )
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var defaultHint: String {
        OpenTypeL10n.text(
            "选中一段文字后按快捷键说出修改指令，只会替换选中部分；全选可整体重写",
            english: "Select text, then use the shortcut to speak a correction — only the selection changes; select all for a full rewrite"
        )
    }

    private var commitTitle: String {
        OpenTypeL10n.text("写入 (⌘↩)", english: "Insert (⌘Return)")
    }

    private var cancelTitle: String {
        OpenTypeL10n.text("取消 (Esc)", english: "Cancel (Esc)")
    }
}

/// Thin `NSViewRepresentable` wrapper around a plain, editable `NSTextView`
/// inside an `NSScrollView`. Deliberately does *not* try to keep
/// `presentation.text` synced with every keystroke via the SwiftUI update
/// cycle (`updateNSView` never overwrites the live `NSTextView.string`) — see
/// `ReviewPanelController`'s doc comment for why that two-way sync would be a
/// bug, not a convenience, here.
private struct ReviewTextView: NSViewRepresentable {
    @ObservedObject var presentation: ReviewPanelPresentation
    let onTextViewReady: (NSTextView) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.string = presentation.text
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.allowsUndo = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        onTextViewReady(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Intentionally does not touch `textView.string` here -- see the
        // type's doc comment. Only non-content, purely cosmetic state (none
        // currently needed) would belong in this method.
    }
}
