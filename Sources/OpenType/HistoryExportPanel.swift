import AppKit

/// Bridges `HistoryExport`'s output onto disk via the standard "Save As"
/// panel.
///
/// Kept separate from `HistoryExport.swift` on purpose — that type is pure
/// (no filesystem, no `NSSavePanel`, see its own doc comment), which is what
/// makes its Markdown/JSON shape trivially testable. This is the one place
/// that takes the string it returns and asks the user where to put it.
enum HistoryExportPanel {
    enum Format: String {
        case markdown = "md"
        case json = "json"
    }

    @MainActor
    static func save(_ content: String, suggestedName: String, format: Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(format.rawValue)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
