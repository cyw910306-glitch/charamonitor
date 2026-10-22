// CharaCore (the characters' art, packs, voice and setup file checks, shared with the iPhone app) is visible to every
// file of the Mac app through this one import, so the moved types read as before. L and localizationBundle live there.
@_exported import CharaCore
import Foundation

/// Ours, not QuickDraw's (ApplicationServices has an RGBColor too; a type in this module wins the lookup).
typealias RGBColor = CharaCore.RGBColor

/// The locale for dates and prices next to those strings: English while the app runs in English
/// (en.lproj picked and present), Korean otherwise, so tests and the Korean app read as before.
let appIsEnglish = Bundle.main.preferredLocalizations.first == "en"
    && Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil
let appLocale = Locale(identifier: appIsEnglish ? "en_US" : "ko_KR")
