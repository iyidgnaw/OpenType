import AppKit
import SwiftUI

/// The app's single accent palette, applied to navigation, mode selection,
/// the recording overlay, the floating panels and the menu bar icon.
enum AppAccent {
    static let primary = Color(red: 0.05, green: 0.45, blue: 0.98)
    static let secondary = Color(red: 0.34, green: 0.32, blue: 0.98)
    static let nsPrimary = NSColor(red: 0.05, green: 0.45, blue: 0.98, alpha: 1)
}
