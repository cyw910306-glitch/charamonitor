import Foundation

/// A user-facing string that is built as a String (alerts, menus, notifications, bubbles, status lines).
/// SwiftUI `Text("…")` literals are LocalizedStringKey already; everything else goes through here.
/// The development language is Korean: the Korean source text is the key, and
/// Contents/Resources/en.lproj/Localizable.strings (made by tools/i18n/merge.py) holds the English.
/// Interpolations become format keys the same way Text does (`\(n)개` -> `%lld개`, a String -> `%@`),
/// and tools/i18n/extract.py reads those keys straight from the compiler.
/// Logs, prompts sent to the AI, stored keys and file names stay plain strings.
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: localizationBundle)
}

/// Where L looks up its English. Tests point it at a bundle holding only en.lproj, to run the app's text in English.
public var localizationBundle: Bundle = .main

