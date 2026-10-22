import CoreGraphics
import Foundation

/// Moments outside the CPU poses.
public enum ExtraMotion: String, CaseIterable, Codable {
    case hungry /*배터리 부족: 먹을 것 찾기*/, eat /*충전 중: 먹기*/, special /*특수 기술*/

    public var label: String {
        switch self {
        case .hungry: return L("배고파서 먹을 걸 찾는 중")
        case .eat: return L("충전하며 냠냠")
        case .special: return L("특수 기술!")
        }
    }
    // When each one plays: SituationEngine (Metrics/SituationEngine.swift), driven by StatusItemController.
}

/// Hand-drawn pixel frames, shared by the originals and local packs: the art-only part (the Mac adds its images).
public enum BarArt {
    /// Dark-bar outline tone: the art's own dark outline vanishes on a #2A2A2A bar.
    public static let darkBarOutline: [UInt8] = [0x8C, 0x86, 0xA8]

    /// The outline colour: the commonest colour on the silhouette's edge (pixels touching transparency) of `frame`.
    /// Read from the art, since not every character keys its outline "o".
    public static func outlineColor(_ frame: [UInt8], width w: Int = FrameArt.width, height h: Int = FrameArt.height) -> PixelColor {
        func clear(_ x: Int, _ y: Int) -> Bool { x < 0 || y < 0 || x >= w || y >= h || frame[(y * w + x) * 4 + 3] == 0 }
        var counts: [UInt32: Int] = [:]
        for y in 0..<h {
            for x in 0..<w where !clear(x, y) && (clear(x - 1, y) || clear(x + 1, y) || clear(x, y - 1) || clear(x, y + 1)) {
                let i = (y * w + x) * 4
                counts[UInt32(frame[i]) << 16 | UInt32(frame[i + 1]) << 8 | UInt32(frame[i + 2]), default: 0] += 1
            }
        }
        let k = counts.max { $0.value < $1.value }?.key ?? 0
        return PixelColor(r: UInt8(k >> 16 & 0xFF), g: UInt8(k >> 8 & 0xFF), b: UInt8(k & 0xFF))
    }

    /// `rgba` with every outline pixel that touches transparency lifted to `darkBarOutline`. Interior pixels of the
    /// same colour (eyes, mouth) stay dark.
    public static func darkBarVariant(_ rgba: [UInt8], outline: PixelColor, width w: Int = FrameArt.width, height h: Int = FrameArt.height) -> [UInt8] {
        var out = rgba
        func clear(_ x: Int, _ y: Int) -> Bool { x < 0 || y < 0 || x >= w || y >= h || rgba[(y * w + x) * 4 + 3] == 0 }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard rgba[i + 3] != 0, rgba[i] == outline.r, rgba[i + 1] == outline.g, rgba[i + 2] == outline.b,
                      clear(x - 1, y) || clear(x + 1, y) || clear(x, y - 1) || clear(x, y + 1) else { continue }
                out[i] = darkBarOutline[0]; out[i + 1] = darkBarOutline[1]; out[i + 2] = darkBarOutline[2]
            }
        }
        return out
    }

    /// `cg` shrunk to `w` x `h` by halving steps, then one last step, each at high quality (no aliasing on big ratios).
    public static func downsample(_ cg: CGImage, width w: Int, height h: Int) -> CGImage? {
        var src = cg
        while true {
            let half = src.width > w * 2
            let tw = half ? src.width / 2 : w, th = half ? src.height / 2 : h
            guard let ctx = DogRenderer.context(width: tw, height: th) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: tw, height: th))
            guard let next = ctx.makeImage() else { return nil }
            if !half { return next }
            src = next
        }
    }
}
