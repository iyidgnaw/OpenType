import MarkdownUI
import SwiftUI

/// The one place assistant-authored text is rendered in this app (spec:
/// `docs/superpowers/specs/2026-08-13-hud-morph-result-surface-design.md` §3).
/// Ask answers and Agent results come back as GitHub-flavored Markdown —
/// headings, lists, tables, fenced code — so every surface that shows them
/// (the unified voice surface's result card, the Q&A tab thread, the Agent tab
/// thread) renders through this wrapper instead of a bare `Text`. User-spoken
/// text stays plain: it is transcribed speech, not Markdown, and running it
/// through a Markdown parser would mangle stray `*`/`#` characters.
///
/// Styling starts from MarkdownUI's `Theme.gitHub` (already light/dark aware —
/// every color in it is defined as a `light:`/`dark:` pair) with the body text
/// style overridden so it (a) inherits the app's `.primary` foreground rather
/// than GitHub's own near-black/near-white, (b) paints no opaque background,
/// which would otherwise punch a solid rectangle through the `.regularMaterial`
/// of the floating card, and (c) uses the caller's font size instead of
/// GitHub's 16pt web default, which is far too large for a HUD card or a chat
/// bubble.
///
/// Selection is enabled here; containers that cannot host selectable text (a
/// tappable row, say) should simply not use this view.
struct AssistantMarkdownView: View {
    let markdown: String
    let fontSize: CGFloat

    init(markdown: String, fontSize: CGFloat = 12.5) {
        self.markdown = markdown
        self.fontSize = fontSize
    }

    var body: some View {
        Markdown(markdown)
            .markdownTheme(Self.theme(fontSize: fontSize))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func theme(fontSize: CGFloat) -> Theme {
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(fontSize)
            }
    }
}
