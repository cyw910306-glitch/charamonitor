// Shared contract. Every other file builds against these types.
// Change a type here only in the integration step, never from one builder alone.
import AppKit
import Foundation

// MARK: - System metrics (filled by Metrics/SystemMonitor.swift)

struct CPUStats: Equatable {
    var user: Double        // 0...1 of total machine capacity (user + nice)
    var system: Double      // 0...1
    var idle: Double        // 0...1
    var perCore: [Double]   // 0...1 busy fraction per logical core
    var usage: Double { min(1, max(0, user + system)) }
}

enum MemoryPressureLevel: String, Codable { case normal, warning, critical }

struct MemoryStats: Equatable {
    var total: UInt64         // bytes, hw.memsize
    var app: UInt64           // Activity Monitor "App Memory" (internal - purgeable)
    var wired: UInt64
    var compressed: UInt64    // compressor_page_count * page size
    var cachedFiles: UInt64   // external + purgeable
    var free: UInt64
    var swapUsed: UInt64
    var pressure: Double      // 0...1, 1 - kern.memorystatus_level/100
    var pressureLevel: MemoryPressureLevel
    var used: UInt64 { app + wired + compressed }
}

struct DiskStats: Equatable {
    var volumeName: String
    var total: UInt64
    var available: UInt64     // volumeAvailableCapacityForImportantUsage
    var used: UInt64 { total > available ? total - available : 0 }
}

struct BatteryStats: Equatable {
    var percent: Int              // 0...100
    var isCharging: Bool
    var isPluggedIn: Bool         // on AC power
    var isCharged: Bool
    var minutesRemaining: Int?    // to empty on battery, to full while charging; nil = calculating
    var cycleCount: Int?
    var healthPercent: Int?       // max capacity / design capacity
    var levelPrecise: Double? = nil       // 0...100 with decimals, raw current / raw max capacity (mAh)
    var healthPrecise: Double? = nil      // 0...100 with decimals, "성능 최대치"
    var temperatureCelsius: Double? = nil // AppleSmartBattery Temperature / 100
}

struct NetworkInterfaceStats: Equatable, Identifiable {
    var id: String { bsdName }
    var bsdName: String           // "en0"
    var displayName: String       // "Wi-Fi"
    var ipv4: String?
    var uploadBytesPerSec: Double
    var downloadBytesPerSec: Double
    var totalSent: UInt64
    var totalReceived: UInt64
}

struct NetworkStats: Equatable {
    var interfaces: [NetworkInterfaceStats]   // up, non-loopback, has IPv4 or traffic
    var uploadBytesPerSec: Double
    var downloadBytesPerSec: Double
}

struct SystemSnapshot: Equatable {
    var timestamp: Date
    var cpu: CPUStats
    var memory: MemoryStats
    var disk: DiskStats?
    var battery: BatteryStats?    // nil on desktops
    var network: NetworkStats
    var uptime: TimeInterval
    var thermalState: ProcessInfo.ThermalState
}

extension RGBColor {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}

// MARK: - App settings (persisted in UserDefaults, owned by App/)

/// Where every setting lives. `--render-dashboard` points it at a throwaway suite before anything reads it
/// (cfprefsd ignores HOME, so this is the only way a QA run cannot write the owner's preferences).
enum AppDefaults {
    /// The owner's preferences. Once an import replaced the setup (`SetupFile.replaced`) they take no more writes from
    /// this copy, so nothing it still holds in memory lands over the file's values before the restart.
    static let owner: UserDefaults = Guarded(suiteName: nil)!
    static var store: UserDefaults = owner

    private final class Guarded: UserDefaults {
        override func set(_ value: Any?, forKey key: String) { if !SetupFile.replaced { super.set(value, forKey: key) } }
        override func set(_ value: Int, forKey key: String) { if !SetupFile.replaced { super.set(value, forKey: key) } }
        override func set(_ value: Float, forKey key: String) { if !SetupFile.replaced { super.set(value, forKey: key) } }
        override func set(_ value: Double, forKey key: String) { if !SetupFile.replaced { super.set(value, forKey: key) } }
        override func set(_ value: Bool, forKey key: String) { if !SetupFile.replaced { super.set(value, forKey: key) } }
        override func set(_ url: URL?, forKey key: String) { if !SetupFile.replaced { super.set(url, forKey: key) } }
        override func removeObject(forKey key: String) { if !SetupFile.replaced { super.removeObject(forKey: key) } }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    @Published var profile: DogProfile { didSet { save(profile, "profile") } }
    /// Settings saved before this existed have no "character" key and load as the dog.
    @Published var character: SpriteCharacter { didSet { defaults.set(character.rawValue, forKey: "character") } }
    /// The saved custom character `character == .custom` means. Unknown ids show the dog.
    @Published var customCharacterID: String? { didSet { defaults.set(customCharacterID, forKey: "customCharacterID") } }
    /// CatCatalog id `character == .cat` means. Unknown ids show the dog.
    @Published var catID: String? { didSet { defaults.set(catID, forKey: "catID") } }
    /// OriginalCatalog id `character == .original` means. Unknown ids show the dog.
    @Published var originalID: String? { didSet { defaults.set(originalID, forKey: "originalID") } }
    @Published var showCPUPercent: Bool { didSet { defaults.set(showCPUPercent, forKey: "showCPUPercent") } }
    /// 내 Claude without a Keychain token: the user agreed to use whatever account this Mac's Claude Code is signed into.
    @Published var claudeUseCLILogin: Bool { didSet { defaults.set(claudeUseCLILogin, forKey: "claudeUseCLILogin") } }
    /// 내 Claude's second turn that looks at the render and fixes the frames.
    @Published var claudeRefine: Bool { didSet { defaults.set(claudeRefine, forKey: "claudeRefine") } }
    /// 자동 다듬기: the creator has this Mac's AI draw the poses without a picture, which sends the photos to it. Off
    /// until the owner turns it on in 설정; a choice saved by an earlier build (on or off) stays.
    @Published var aiAutoRefine: Bool { didSet { defaults.set(aiAutoRefine, forKey: "aiAutoRefine") } }
    /// 꾸미기 colours of the originals: character id to part id (CharacterColors.parts) to colour. Missing: as drawn.
    @Published var characterColors: [String: [String: RGBColor]] { didSet { save(characterColors, "characterColors") } }
    /// 꾸미기 of a cat breed: its own profile once a colour changed, by cat id.
    @Published var catLooks: [String: CatProfile] { didSet { save(catLooks, "catLooks") } }
    /// 옷 입히기 by Wardrobe.key (a character id, "custom:<uuid>" or "dog"). Missing: nothing on.
    @Published var outfits: [String: Outfit] { didSet { save(outfits, "outfits") } }
    /// Built-in characters taken off 캐릭터 선택 ("목록에서 지우기"), by id. Restorable there.
    @Published var hiddenCharacters: [String] { didSet { save(hiddenCharacters, "hiddenCharacters") } }
    /// 그림 스타일 of every drawn character (RenderStyle); unknown or missing: 자동.
    @Published var renderStyle: RenderStyle { didSet { defaults.set(renderStyle.rawValue, forKey: "renderStyle") } }
    /// nil = no photo. Stored "" means the user removed it; never set means the bundled jelly.jpg.
    @Published var photoPath: String? { didSet { defaults.set(photoPath ?? "", forKey: "photoPath") } }
    /// 데스크톱 친구 꾸미기: the settings page's colours (AppPalette), how much the friends move (DesktopKit.reduceMotion),
    /// every friend's sounds at once, bigger settings text, and 자세히 open from the start.
    @Published var palette: AppPalette { didSet { defaults.set(palette.rawValue, forKey: "palette") } }
    @Published var motionLevel: MotionLevel { didSet { defaults.set(motionLevel.rawValue, forKey: "motionLevel") } }
    @Published var friendSounds: Bool { didSet { defaults.set(friendSounds, forKey: "friendSounds") } }
    @Published var settingsTextLarge: Bool { didSet { defaults.set(settingsTextLarge, forKey: "settingsTextLarge") } }
    @Published var expandDetails: Bool { didSet { defaults.set(expandDetails, forKey: "expandDetails") } }

    var dogName: String { profile.name.isEmpty ? L("내 캐릭터") : profile.name }
    /// Name of whoever is in the menu bar right now.
    var characterName: String {
        switch shownCharacter {
        case .dog: return dogName
        case .custom: return activeCustom?.displayName ?? dogName
        case .cat: return activeCat?.displayName ?? dogName
        case .original: return activeOriginal?.displayName ?? dogName
        }
    }

    /// The shown character's own 말투 and 울음소리 (a pack's pack.json, a custom character's choice); nil and [] for the rest.
    var shownVoice: (style: PersonaStyle?, cries: [String]) {
        switch shownCharacter {
        case .custom: return (activeCustom?.voice, activeCustom?.cries ?? [])
        case .original: return (activeOriginal?.voice, activeOriginal?.cries ?? [])
        default: return (nil, [])
        }
    }

    /// Hidden ids that still name a character here; 지운 캐릭터 다시 보기 counts only these (a retired character's id or a
    /// deleted pack's would bring nothing back).
    var restorableHidden: [String] {
        hiddenCharacters.filter { CatCatalog.character($0) != nil || OriginalCatalog.character($0) != nil }
    }

    /// The custom character to draw, or nil.
    var activeCustom: CustomCharacter? {
        guard character == .custom else { return nil }
        return CustomCharacterStore.shared.character(customCharacterID)
    }

    /// With its 꾸미기 colours.
    var activeCat: (any AnimatedCharacter)? {
        guard character == .cat, let cat = CatCatalog.character(catID), !hiddenCharacters.contains(cat.id) else { return nil }
        return CharacterColors.cat(cat, catLooks[cat.id])
    }

    /// With its 꾸미기 colours; a removed id or a pack that no longer loads shows the dog.
    var activeOriginal: (any AnimatedCharacter)? {
        guard character == .original, let c = OriginalCatalog.character(originalID), !hiddenCharacters.contains(c.id) else { return nil }
        return CharacterColors.apply(characterColors[c.id], to: c)
    }

    /// `character`, with one that cannot be shown (deleted, unknown id, hidden) standing in as the dog.
    var shownCharacter: SpriteCharacter {
        switch character {
        case .dog: return character
        case .custom: return activeCustom == nil ? .dog : .custom
        case .cat: return activeCat == nil ? .dog : .cat
        case .original: return activeOriginal == nil ? .dog : .original
        }
    }

    func useCustom(_ id: UUID) {
        customCharacterID = id.uuidString
        character = .custom
    }

    func useCat(_ id: String) {
        catID = id
        character = .cat
    }

    func useOriginal(_ id: String) {
        originalID = id
        character = .original
    }

    static var bundledPhotoPath: String? { Bundle.main.path(forResource: "jelly", ofType: "jpg") }

    /// Tests pass their own suite; the app uses `shared`.
    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        profile = (defaults.data(forKey: "profile")).flatMap { try? JSONDecoder().decode(DogProfile.self, from: $0) }
            ?? DogProfile.defaultDog
        character = defaults.string(forKey: "character").flatMap(SpriteCharacter.init(rawValue:)) ?? .dog
        customCharacterID = defaults.string(forKey: "customCharacterID")
        catID = defaults.string(forKey: "catID")
        originalID = defaults.string(forKey: "originalID")
        showCPUPercent = defaults.object(forKey: "showCPUPercent") as? Bool ?? true
        claudeUseCLILogin = defaults.object(forKey: "claudeUseCLILogin") as? Bool ?? false
        claudeRefine = defaults.object(forKey: "claudeRefine") as? Bool ?? true
        aiAutoRefine = defaults.object(forKey: "aiAutoRefine") as? Bool ?? false
        characterColors = defaults.data(forKey: "characterColors").flatMap { try? JSONDecoder().decode([String: [String: RGBColor]].self, from: $0) } ?? [:]
        catLooks = defaults.data(forKey: "catLooks").flatMap { try? JSONDecoder().decode([String: CatProfile].self, from: $0) } ?? [:]
        outfits = defaults.data(forKey: "outfits").flatMap { try? JSONDecoder().decode([String: Outfit].self, from: $0) } ?? [:]
        renderStyle = defaults.string(forKey: "renderStyle").flatMap(RenderStyle.init(rawValue:)) ?? .auto
        hiddenCharacters = defaults.data(forKey: "hiddenCharacters").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        palette = defaults.string(forKey: "palette").flatMap(AppPalette.init) ?? .strawberry
        motionLevel = defaults.string(forKey: "motionLevel").flatMap(MotionLevel.init) ?? .auto
        friendSounds = defaults.object(forKey: "friendSounds") as? Bool ?? true
        settingsTextLarge = defaults.bool(forKey: "settingsTextLarge")
        expandDetails = defaults.bool(forKey: "expandDetails")
        if let stored = defaults.string(forKey: "photoPath") {
            photoPath = stored.isEmpty ? nil : stored
        } else {
            photoPath = AppSettings.bundledPhotoPath
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
