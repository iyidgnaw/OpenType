import Foundation

/// Splices a voice-driven correction's replacement text back into a larger
/// string at a specific span, for Review mode's correction flow
/// (`ReviewPanelController`, sidecar `POST /transcribe/correct`).
///
/// The offsets are UTF-16 code-unit based (`NSRange`, as returned by
/// `NSTextView.selectedRange()`), not `String.Index`/grapheme-cluster based —
/// deliberately, since that's exactly the representation both `NSString`
/// (Swift/AppKit) and a plain JS string (the sidecar side, `String.slice`)
/// use, so the same raw integer offsets sent over the wire mean the same
/// thing on both ends with no re-encoding step that could introduce an
/// off-by-N bug for any text containing characters outside the Basic
/// Multilingual Plane's single-UTF-16-unit range.
enum TextSpanCorrection {
    /// Returns `text` with the UTF-16 range `range` replaced by
    /// `replacement`. `range` must be within bounds of `text`'s UTF-16
    /// representation (as it always is when sourced from
    /// `NSTextView.selectedRange()` on the same string) — out-of-bounds
    /// ranges are a programmer error, not a recoverable input, so this
    /// mirrors `NSString.replacingCharacters(in:with:)`'s own contract
    /// rather than adding a redundant bounds check the caller already owns.
    static func apply(
        replacement: String,
        to text: String,
        range: NSRange
    ) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}
