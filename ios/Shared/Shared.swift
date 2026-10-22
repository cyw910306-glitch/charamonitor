import ActivityKit
import CharaCore
import SwiftUI

/// What the app and its widgets share: the app group (the imported setup's Packs, Characters and Pictures, and the
/// chosen character) and how a character frame is drawn.
enum Shared {
    static let appGroup = "group.com.jelly.charamonitor"

    /// The app group's container; the app's own Application Support when there is none (an unsigned simulator build,
    /// or a profile without App Groups: then the app and its widgets each keep their own and never meet).
    static let root: URL = {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return group }
        #if DEBUG
        print("캐릭모니터: no app group \(appGroup); the widgets will not see imported packs or the chosen character")
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }()

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    static let chosenKey = "characterID"
    static var packs: URL { root.appendingPathComponent("Packs", isDirectory: true) }

    /// The built-in characters, then the packs the owner imported with a setup file. The packs hold only their walk
    /// (what the picker shows); `full` reads the rest when one is drawn.
    static func characters() -> [CharaArt] {
        CharaArt.builtIn + CharaArt.packs(in: packs, keys: [])
    }

    /// One imported pack by id: `keys` and the walk (see PackArt.init), or every frame when nil.
    static func pack(_ id: String, keys: Set<String>? = nil) -> CharaArt? {
        guard id.range(of: #"^pack-[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil,
              let pack = try? PackArt(folder: packs.appendingPathComponent(id, isDirectory: true), keys: keys) else { return nil }
        return CharaArt(pack: pack)
    }

    /// Every frame of `art`; itself when it is a built-in or its pack no longer reads.
    static func full(_ art: CharaArt) -> CharaArt {
        CharaArt.builtIn(art.id) == nil ? pack(art.id) ?? art : art
    }

    /// One character by id without reading every pack (a widget has little memory): a built-in, else that one
    /// imported pack with only the `keys` frames (CharaArt.keys), else the chosen built-in, else 젤리.
    static func art(_ id: String?, keys: Set<String>? = nil) -> CharaArt {
        if let art = CharaArt.builtIn(id) { return art }
        if let id, let art = pack(id, keys: keys) { return art }
        return CharaArt.builtIn(SharedState.chosenCharacterID) ?? CharaArt.builtIn(CharaArt.defaultID)!
    }

    /// The chosen character in `list`, or 젤리 when it is gone.
    static func chosen(in list: [CharaArt]) -> CharaArt {
        let id = defaults.string(forKey: chosenKey)
        return list.first { $0.id == id } ?? list.first { $0.id == CharaArt.defaultID } ?? list[0]
    }
}

/// A Live Activity: the chosen character on the Lock Screen and in the Dynamic Island, with a timer until `endDate`
/// (a 집중 타이머 run). It cannot play frames, so the app picks one still pose for each update.
struct CharaActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// DogPose raw value, and the ExtraMotion raw value shown instead when the character has it.
        var pose: Int
        var extra: String?
    }

    var characterID: String
    /// "집중 25분" and the like, already in the phone's language; empty means "집중 시간".
    var title: String
    var startDate: Date
    /// When focus ends; the activity goes stale then.
    var endDate: Date
}

/// One still frame of a character, crisp at any size (pixel art stays blocky). In dark mode the pixel art's dark
/// outline is lifted, as on the Mac's dark menu bar, so it does not vanish into black.
struct CharaFrame: View {
    let art: CharaArt
    var pose: DogPose = .walk
    var extra: ExtraMotion?
    var index = 0
    /// Pixels per point of the 34 x 20 canvas. Keep it small where the system limits image size (Live Activities).
    var scale = 8
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let frames = art.frames(pose, extra: extra)
        if !frames.isEmpty, let cg = art.image(lifted(frames[index % frames.count]), scale: scale) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(art.smooth ? .high : .none)
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel(Text(art.displayName))
        }
    }

    private func lifted(_ rgba: [UInt8]) -> [UInt8] {
        guard scheme == .dark, !art.smooth else { return rgba }
        let outline = BarArt.outlineColor(rgba, width: art.width, height: art.height)
        return BarArt.darkBarVariant(rgba, outline: outline, width: art.width, height: art.height)
    }
}
