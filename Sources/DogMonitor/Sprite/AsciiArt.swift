import Foundation

/// Characters drawn as ASCII frames on the dog's 34 x 20 canvas, one character per art pixel (FrameArt,
/// the bundled originals): same size, facing right, so switching characters never moves the menu bar item.
enum AsciiArt {
    /// One frame (rows top to bottom) as RGBA bytes on the shared canvas. Unknown characters stay transparent.
    static func rgba(_ frame: String, _ palette: [Character: PixelColor]) -> [UInt8] {
        let w = DogSpriteCache.canvasWidth, h = DogSpriteCache.canvasHeight
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for (y, row) in frame.split(separator: "\n").prefix(h).enumerated() {
            for (x, ch) in row.prefix(w).enumerated() {
                guard let c = palette[ch] else { continue }
                let i = (y * w + x) * 4
                out[i] = c.r; out[i + 1] = c.g; out[i + 2] = c.b; out[i + 3] = 255
            }
        }
        return out
    }
}
