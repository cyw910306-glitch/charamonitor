import Foundation

/// Which body part painted a cell.
enum ArtPart: UInt8 { case none, outline, farLeg, farEar, body, tail, nearLeg, head, ear, fx }

/// Coat region, used by patterns to pick base or secondary color.
enum ArtZone: UInt8 { case coat, back, belly, chest, chin, muzzle, face, paw, ear, tail, spot }

/// Fixed colors that ignore the coat.
enum ArtInk: UInt8 { case none, line, eye, glint, lid, nose, tongue, tongueDark, sweat, sweatDark, zz }

struct ArtCell {
    var part = ArtPart.none
    var zone = ArtZone.coat
    var ink = ArtInk.none
}

/// Semantic pixel canvas for one frame. Colors are applied last, so shading and
/// outlines can look at the finished shape.
struct ArtGrid {
    let width: Int, height: Int
    private(set) var cells: [ArtCell]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: ArtCell(), count: width * height)
    }

    subscript(x: Int, y: Int) -> ArtCell {
        get { x >= 0 && y >= 0 && x < width && y < height ? cells[y * width + x] : ArtCell() }
        set { if x >= 0 && y >= 0 && x < width && y < height { cells[y * width + x] = newValue } }
    }

    mutating func put(_ x: Int, _ y: Int, _ part: ArtPart, _ zone: ArtZone = .coat, _ ink: ArtInk = .none) {
        self[x, y] = ArtCell(part: part, zone: zone, ink: ink)
    }

    /// Fur, paws, tongue: everything that gets an outline. Effects (sweat, z) do not.
    func isSolid(_ x: Int, _ y: Int) -> Bool {
        let p = self[x, y].part
        return p != .none && p != .outline && p != .fx
    }

    /// Lying pose: a dark line where the body meets the front edge of the haunch, so the thigh reads.
    mutating func drawHaunchLine() {
        let snapshot = self
        for y in 0..<height {
            for x in 0..<width where snapshot[x, y].part == .body && snapshot[x, y].ink == .none {
                let near = [snapshot[x - 1, y], snapshot[x + 1, y], snapshot[x, y - 1], snapshot[x, y + 1]]
                if near.contains(where: { $0.part == .nearLeg }) { self[x, y].ink = .line }
            }
        }
    }

    /// Teddy ear puff, drawn after the body: a dark line on the fur just behind and below it, so the puff
    /// always reads as its own round shape over the neck (its edge there gets a light rim, see DogPalette).
    /// Over the white chest the line goes on the ear's own edge instead, so the bib keeps its pixels.
    mutating func drawEarLine() {
        let snapshot = self
        for y in 0..<height {
            for x in 0..<width where snapshot[x, y].part == .ear {
                for (nx, ny) in [(x - 1, y), (x, y + 1)] {
                    let n = snapshot[nx, ny].part
                    guard isSolid(nx, ny), n != .ear, n != .head, n != .farEar else { continue }
                    if snapshot[nx, ny].zone == .chest { self[x, y].ink = .line } else { self[nx, ny].ink = .line }
                }
            }
        }
    }

    /// 1 px outline around every solid pixel (4-neighbour, so corners come out rounded).
    mutating func drawOutline() {
        var marks: [Int] = []
        for y in 0..<height {
            for x in 0..<width where self[x, y].part == .none {
                if isSolid(x - 1, y) || isSolid(x + 1, y) || isSolid(x, y - 1) || isSolid(x, y + 1) {
                    marks.append(y * width + x)
                }
            }
        }
        for i in marks { cells[i] = ArtCell(part: .outline) }
    }

    /// Bounding box of the dog and its outline (effects excluded), or nil when empty.
    var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var r: (Int, Int, Int, Int)?
        for y in 0..<height {
            for x in 0..<width where self[x, y].part != .none && self[x, y].part != .fx {
                if let b = r { r = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y)) } else { r = (x, x, y, y) }
            }
        }
        return r.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
    }

    /// RGBA bytes (alpha 0 or 255, so premultiplied is the same) for columns `x0 ..< x0 + outWidth`.
    func rgba(_ palette: DogPalette, x0: Int, outWidth: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outWidth * height * 4)
        for y in 0..<height {
            for ox in 0..<outWidth {
                let x = x0 + ox
                let c = self[x, y]
                guard c.part != .none else { continue }
                let color = palette.color(c, above: self[x, y - 1].part, below: self[x, y + 1].part,
                                          left: self[x - 1, y].part, right: self[x + 1, y].part)
                let i = (y * outWidth + ox) * 4
                out[i] = color.r; out[i + 1] = color.g; out[i + 2] = color.b; out[i + 3] = 255
            }
        }
        return out
    }
}
