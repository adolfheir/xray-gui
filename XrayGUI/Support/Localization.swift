import Foundation

/// The user-selectable UI language for XrayGUI.
///
/// English UI strings are used as the lookup *keys* throughout the app, so the
/// `.en` table maps each key to itself and `.zhHans` maps each to a natural
/// Simplified-Chinese translation. `.system` defers to the OS language by using
/// the main bundle's standard localization resolution.
enum AppLanguage: String, CaseIterable, Codable {
    /// Follow the macOS system language (uses `Bundle.main`).
    case system
    /// Force English.
    case en
    /// Force Simplified Chinese.
    case zhHans = "zh-Hans"

    /// A human-readable label for this language, shown in pickers.
    var displayName: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .zhHans: return "简体中文"
        }
    }
}

/// Runtime-switchable localization backed by `.strings` tables.
///
/// The manager resolves a string against the bundle that matches `current`:
/// - `.system` uses `Bundle.main` (the OS picks the localization).
/// - `.en` / `.zhHans` load the matching `.lproj` sub-bundle so the language can
///   be switched at runtime without an app restart.
///
/// Lookups always fall back gracefully to the key itself (which is the English
/// source string), so a missing translation degrades to readable English rather
/// than an opaque identifier.
///
/// This type is `Foundation`-only and has no UI or app-state dependencies.
final class LocalizationManager {

    /// The shared, process-wide instance.
    static let shared = LocalizationManager()

    /// `UserDefaults` key under which the selected language is persisted.
    private static let defaultsKey = "appLanguage"

    /// Sentinel returned by `localizedString(forKey:value:table:)` when a key is
    /// missing; lets us detect misses and fall back to the key (English).
    private static let missingMarker = "\u{0}__XRAYGUI_LOCALIZATION_MISSING__\u{0}"

    /// Serializes access to mutable state across threads.
    private let lock = NSLock()

    /// Backing store for `current`.
    private var _current: AppLanguage

    /// The bundle used for explicit (`.en` / `.zhHans`) selections. `nil` when the
    /// current language is `.system` (in which case `Bundle.main` is used).
    private var languageBundle: Bundle?

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let initial = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        _current = initial
        languageBundle = Self.loadBundle(for: initial)
    }

    /// The currently active language.
    ///
    /// Setting this persists the choice to `UserDefaults` and reloads the backing
    /// `.lproj` bundle so subsequent `string(_:)` lookups use the new language.
    var current: AppLanguage {
        get {
            lock.lock(); defer { lock.unlock() }
            return _current
        }
        set {
            lock.lock()
            _current = newValue
            languageBundle = Self.loadBundle(for: newValue)
            // Persist inside the lock so the stored value can never disagree with the
            // in-memory state observed by a concurrent reader.
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey)
            lock.unlock()
        }
    }

    /// Looks up `key` in the active language's table.
    ///
    /// - Parameter key: The English source string used as the lookup key.
    /// - Returns: The localized value, or `key` itself if no translation exists.
    func string(_ key: String) -> String {
        lock.lock()
        let bundle = languageBundle ?? Bundle.main
        lock.unlock()

        let value = bundle.localizedString(
            forKey: key,
            value: Self.missingMarker,
            table: nil
        )
        return value == Self.missingMarker ? key : value
    }

    /// Loads and caches the `.lproj` bundle for an explicit language selection.
    ///
    /// Returns `nil` for `.system` (callers then use `Bundle.main`) and also `nil`
    /// when the requested `.lproj` cannot be located, again falling back to the
    /// main bundle.
    private static func loadBundle(for language: AppLanguage) -> Bundle? {
        switch language {
        case .system:
            return nil
        case .en, .zhHans:
            guard
                let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                let bundle = Bundle(path: path)
            else {
                return nil
            }
            return bundle
        }
    }
}

extension String {
    /// The localized value of this string, treating `self` as the English key.
    var localized: String {
        LocalizationManager.shared.string(self)
    }

    /// The localized, `String(format:)`-interpolated value of this string.
    ///
    /// Use for keys containing format specifiers, e.g.
    /// `"Imported %d node(s)".localized(count)`.
    func localized(_ args: CVarArg...) -> String {
        String(format: localized, arguments: args)
    }
}
