import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class ContextBridge {
    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// System Settings › General › Login Items.
    ///
    /// The jump `.requiresApproval` needs: once the user has disabled our login
    /// item there, `SMAppService.register()` is accepted and does nothing, so
    /// the only honest thing the app can offer is the pane where it can be
    /// turned back on.
    func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func capture() -> CapturedContext {
        let application = NSWorkspace.shared.frontmostApplication
        return CapturedContext(
            selectedText: selectedText(),
            applicationName: application?.localizedName ?? "Unknown app",
            bundleIdentifier: application?.bundleIdentifier
        )
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func insert(_ text: String) async throws {
        guard accessibilityGranted else {
            requestAccessibilityPermission()
            throw OpenTypeError.accessibilityRequired
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKey(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 350_000_000)

        snapshot.restore(to: pasteboard)
    }

    /// Selects the run of `text` sitting immediately before the caret in the
    /// focused field, so that a following `insert(_:)` *replaces* it.
    ///
    /// The undo behind D-1's 「撤销并删除该词条」 needs to put the delivered text
    /// back, and delivery/correction both write through `insert(_:)`, which is
    /// Cmd+V: it replaces a selection and otherwise lands at the caret. Right
    /// after a delivery nothing is selected, so pasting without this would
    /// *append* the restored sentence to the one already there — the one
    /// outcome worse than leaving the mis-transcription alone. Selecting first
    /// keeps a single write-back route rather than adding a second one that
    /// edits text some other way.
    ///
    /// Every condition below is a refusal to guess, because the cost of a wrong
    /// guess is the user's own text: nothing may already be selected (that
    /// selection is theirs, not ours), the field's value must still *end* at
    /// the caret with exactly the characters we delivered, and the AX read must
    /// succeed outright. `false` means the caller should leave the text alone
    /// and say so — many apps (Electron, web fields) do not expose a usable
    /// `AXValue`, and there the honest answer is that the paste cannot be
    /// undone rather than a paste somewhere unintended.
    ///
    /// Ranges here are UTF-16 offsets, which is what `AXSelectedTextRange`
    /// means on every AppKit-backed field — hence `NSString` rather than
    /// `String.Index` arithmetic.
    func selectTextEndingAtCaret(_ text: String) -> Bool {
        guard accessibilityGranted,
              let element = focusedElement(),
              !text.isEmpty else { return false }

        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectionValue
        ) == .success,
            let selectionValue,
            CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return false }

        var caret = CFRange()
        guard AXValueGetValue(
            unsafeBitCast(selectionValue, to: AXValue.self),
            .cfRange,
            &caret
        ), caret.length == 0 else { return false }

        var fieldValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &fieldValue
        ) == .success,
            let contents = fieldValue as? String else { return false }

        let delivered = (text as NSString).length
        let start = caret.location - delivered
        guard start >= 0,
              caret.location <= (contents as NSString).length,
              (contents as NSString).substring(
                with: NSRange(location: start, length: delivered)
              ) == text else { return false }

        var target = CFRange(location: start, length: delivered)
        guard let range = AXValueCreate(.cfRange, &target) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            range
        ) == .success
    }

    private func selectedText() -> String? {
        guard accessibilityGranted,
              let focusedElement = focusedElement() else { return nil }
        var selectedValue: CFTypeRef?
        let selectionError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard
            selectionError == .success,
            let selected = selectedValue as? String,
            !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selected
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard error == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
            ),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
            )
        else { return }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
