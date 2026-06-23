import SwiftUI

/// User-selectable color appearance for the app UI.
///
/// `.system` defers to the macOS appearance; `.light` / `.dark` force a fixed
/// scheme. The selection is applied at runtime via `preferredColorScheme` on the
/// scene root views, so switching takes effect immediately across the main window
/// and the menu bar.
enum AppTheme: String, CaseIterable, Codable, Identifiable {
    /// Follow the macOS system appearance.
    case system
    /// Force the light appearance.
    case light
    /// Force the dark appearance.
    case dark

    var id: String { rawValue }

    /// Human-readable label for pickers (English source string, used as localization key).
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The SwiftUI color scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
