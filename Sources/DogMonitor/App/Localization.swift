import Foundation

/// A user-facing string that is built as a String (alerts, menus, notifications, bubbles, status lines).
/// SwiftUI `Text("…")` literals are LocalizedStringKey already; everything else goes through here.
/// The development language is Korean: the Korean source text is the key, and
/// Contents/Resources/en.lproj/Localizable.strings (made by tools/i18n/merge.py) holds the English.
/// Interpolations become format keys the same way Text does (`\(n)개` -> `%lld개`, a String -> `%@`),
/// and tools/i18n/extract.py reads those keys straight from the compiler.
/// Logs, prompts sent to the AI, stored keys and file names stay plain strings.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: localizationBundle)
}

/// Where L looks up its English. Tests point it at a bundle holding only en.lproj, to run the app's text in English.
var localizationBundle: Bundle = .main

/// The locale for dates and prices next to those strings: English while the app runs in English
/// (en.lproj picked and present), Korean otherwise, so tests and the Korean app read as before.
let appIsEnglish = Bundle.main.preferredLocalizations.first == "en"
    && Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil
let appLocale = Locale(identifier: appIsEnglish ? "en_US" : "ko_KR")
