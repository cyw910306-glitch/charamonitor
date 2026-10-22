import AppKit

/// Original characters, set 2 (OriginalInfo and OriginalFrames in CharaCore): hand-drawn frames.json art on the shared
/// 34x20 canvas, facing right, with the seven CPU poses plus hungry, eat and a signature special move ("extras").
/// A class so the images render once, on first use.
final class OriginalCharacterSet2: PaletteCharacter {
    let id: String
    let displayName: String
    /// The signature move shown by `.special`, for the picker preview.
    let specialName: String
    /// One line for the preview page.
    let blurb: String
    /// RGBA frames in DogPose order, 34x20: pass as `custom:` to DogSpriteCache for the menu bar.
    let poseRGBA: [[[UInt8]]]
    let extraRGBA: [ExtraMotion: [[UInt8]]]
    let outline: PixelColor
    let palette: [String: String]
    private let json: String
    private lazy var poseImages: [[NSImage]] = poseRGBA.map { $0.map { BarArt.adaptive($0, outline: outline) } }
    private lazy var extraImages: [ExtraMotion: [NSImage]] = extraRGBA.mapValues { $0.map { BarArt.adaptive($0, outline: outline) } }

    var imageSize: NSSize { NSSize(width: FrameArt.width, height: FrameArt.height) }
    var specialTitle: String? { specialName }
    var previewBlurb: String? { blurb }
    func frames(for pose: DogPose) -> [NSImage] { poseImages[pose.rawValue] }
    func frames(forExtra motion: ExtraMotion) -> [NSImage]? { extraImages[motion] }

    /// Wiring: `OriginalCatalog.all = OriginalCharacterSet2.all` (CharacterKit.swift).
    static let all: [OriginalCharacterSet2] = OriginalInfo.all.map {
        OriginalCharacterSet2(id: $0.id, displayName: $0.displayName, specialName: $0.specialName, blurb: $0.blurb, json: $0.json)
    }

    static func named(_ id: String) -> OriginalCharacterSet2? { all.first { $0.id == id } }

    func recolored(_ palette: [String: String]) -> any AnimatedCharacter {
        OriginalCharacterSet2(id: id, displayName: displayName, specialName: specialName, blurb: blurb, json: json, palette: palette)
    }

    /// `palette`: 꾸미기 colours in place of the drawn ones (CharacterColors).
    init(id: String, displayName: String, specialName: String, blurb: String, json: String, palette: [String: String]? = nil) {
        let art = OriginalFrames(json: json, palette: palette)
        self.palette = art.palette
        self.json = json
        self.id = id
        self.displayName = displayName
        self.specialName = specialName
        self.blurb = blurb
        poseRGBA = art.poseRGBA
        extraRGBA = art.extraRGBA
        outline = art.outline
    }
}
