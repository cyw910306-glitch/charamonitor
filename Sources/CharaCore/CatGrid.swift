import Foundation

/// Which part painted a cell, back to front. `prop` is the food bowl, `fx` effects (z, sweat, crumbs, "?").
public enum CatPart: UInt8 { case none, outline, farLeg, farEar, tail, body, nearLeg, head, ear, prop, fx }
/// Which coat color a fur cell takes; the painter decides it from the coat pattern.
public enum CatTone: UInt8 { case base, sec, acc }
/// Fixed colors that ignore the coat.
public enum CatInk: UInt8 {
    case none, line, pupil, iris, glint, nose, pink, tongue, tongueDark, sweat, sweatDark, zz, mark
    case bowl, bowlDark, bowlLight, food, foodDark
    case ruff     // fluffy fur tufts: a shade of the cell's own tone, so a ruff shows on a white coat
    case silver   // the Russian Blue's back line
}

public struct CatCell {
    public var part = CatPart.none
    public var tone = CatTone.base
    public var ink = CatInk.none
}

/// Semantic pixel canvas for one cat frame; colors are applied last (CatPalette) so shading sees the finished shape.
public struct CatGrid {
    public let width: Int, height: Int
    public private(set) var cells: [CatCell]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: CatCell(), count: width * height)
    }

    public subscript(x: Int, y: Int) -> CatCell {
        get { x >= 0 && y >= 0 && x < width && y < height ? cells[y * width + x] : CatCell() }
        set { if x >= 0 && y >= 0 && x < width && y < height { cells[y * width + x] = newValue } }
    }

    public mutating func put(_ x: Int, _ y: Int, _ part: CatPart, _ tone: CatTone = .base, _ ink: CatInk = .none) {
        self[x, y] = CatCell(part: part, tone: tone, ink: ink)
    }

    public func isSolid(_ x: Int, _ y: Int) -> Bool {
        let p = self[x, y].part
        return p != .none && p != .outline && p != .fx
    }

    /// 1 px outline around every solid pixel (4-neighbour, so corners come out rounded).
    public mutating func drawOutline() {
        var marks: [Int] = []
        for y in 0..<height {
            for x in 0..<width where self[x, y].part == .none || self[x, y].part == .fx {
                if isSolid(x - 1, y) || isSolid(x + 1, y) || isSolid(x, y - 1) || isSolid(x, y + 1) { marks.append(y * width + x) }
            }
        }
        for i in marks { cells[i] = CatCell(part: .outline) }
    }

    /// Bounding box of the cat, bowl and outline (effects excluded), or nil when empty.
    public var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var r: (Int, Int, Int, Int)?
        for y in 0..<height {
            for x in 0..<width where self[x, y].part != .none && self[x, y].part != .fx {
                if let b = r { r = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y)) } else { r = (x, x, y, y) }
            }
        }
        return r.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
    }

    /// RGBA bytes (alpha 0 or 255) for columns `x0 ..< x0 + outWidth`.
    public func rgba(_ palette: CatPalette, x0: Int, outWidth: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outWidth * height * 4)
        for y in 0..<height {
            for ox in 0..<outWidth {
                let x = x0 + ox
                guard self[x, y].part != .none else { continue }
                let c = palette.color(self, x, y)
                let i = (y * outWidth + ox) * 4
                out[i] = c.r; out[i + 1] = c.g; out[i + 2] = c.b; out[i + 3] = 255
            }
        }
        return out
    }
}
