import CharaCore
import SwiftUI

/// The Mac app's warm colours (web/index.html): apricot and cream by day, cocoa by night.
enum Palette {
    static let bg = Color(light: 0xF5EDE6, dark: 0x211915)
    static let card = Color(light: 0xFFFBF7, dark: 0x2C221D)
    static let ink = Color(light: 0x3B2C26, dark: 0xF5EDE6)
    static let muted = Color(light: 0x7A665B, dark: 0xBFAE9F)
    static let line = Color(light: 0xE8DACD, dark: 0x40322B)
    static let accent = Color(light: 0xB98A62, dark: 0xD8B290)
    static let soft = Color(light: 0xEFE1D3, dark: 0x3A2D26)
    static let apricot = Color(light: 0xD8B290, dark: 0xD8B290)
    /// The website's primary button: cocoa on cream by day, apricot by night, and the text on it.
    static let primary = Color(light: 0x3B2C26, dark: 0xD8B290)
    static let onPrimary = Color(light: 0xF5EDE6, dark: 0x2A1F1A)
    /// The meadow under the character.
    static let ground = Color(light: 0xE6D3BF, dark: 0x45362D)
    static let sky = Color(light: 0xFBF4EC, dark: 0x2A201B)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

extension View {
    /// A soft cream card with a hairline, like the website's.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: Palette.ink.opacity(0.06), radius: 12, y: 6)
    }
}

/// One frame of a character, with its extra moments (Shared's CharaFrame plays poses only).
struct FrameImage: View {
    let art: CharaArt
    var pose: DogPose = .walk
    var extra: ExtraMotion?
    var index = 0
    /// Redrawn many times a second (the stage, the focus dial): each frame's image is made once and kept.
    var playing = false

    var body: some View {
        let scale = art.smooth ? 8 : max(1, art.width / SpriteCanvas.width)
        if let cg = image(scale: scale) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(art.smooth ? .high : .none)
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    private func image(scale: Int) -> CGImage? {
        if playing {
            let images = art.cachedImages(pose, extra: extra, scale: scale)
            return images.isEmpty ? nil : images[index % images.count]
        }
        let frames = art.frames(pose, extra: extra)
        return frames.isEmpty ? nil : art.image(frames[index % frames.count], scale: scale)
    }
}
