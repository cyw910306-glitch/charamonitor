import Foundation

/// Extra motions for every dog (Jelly and all breeds) through the procedural rig, on the shared 34 x 20 canvas:
/// hungry = nose down sniffing around an empty bowl, eat = head in a full bowl, tail wagging.
/// The dog keeps the horizontal spot it has in the normal poses unless the bowl would leave the canvas.
public enum DogExtras {
    /// Seconds per frame for `motion`.
    public static func frameDuration(_ motion: ExtraMotion) -> TimeInterval { motion == .eat ? 0.2 : 0.38 }

    /// The BuiltinExtras.dog shape: `BuiltinExtras.dog = DogExtras.byMotion`.
    public static func byMotion(_ profile: DogProfile) -> [ExtraMotion: [[UInt8]]] {
        [.hungry: rgba(profile, .hungry), .eat: rgba(profile, .eat)]
    }

    /// RGBA frames on the shared canvas (4 per motion, none for `special`).
    public static func rgba(_ profile: DogProfile, _ motion: ExtraMotion) -> [[UInt8]] {
        guard motion != .special else { return [] }
        let w = SpriteCanvas.width
        let painter = DogPainter(profile)
        let palette = DogPalette(profile)
        let l = layout(profile, painter)
        return zip(steps(motion), grids(painter, motion)).map { step, g in
            var out = g.rgba(palette, x0: l.x0, outWidth: w)
            Bowl.draw(full: motion == .eat, into: &out, x: l.bowlX - l.x0, crumbs: motion == .eat ? step.fx : 0)
            if motion == .hungry, step.fx > 0, let n = noseCell(g) { sniff(&out, nose: (n.x - l.x0, n.y), phase: step.fx) }
            if step.ask, let n = noseCell(g) { ask(&out, x: n.x - l.x0 + 1, y: max(1, n.y - 8)) }
            return out
        }
    }

    /// Where the bowl and the canvas window sit on the painter's scratch grid, and how wide dog plus bowl are.
    public static func layout(_ profile: DogProfile, _ painter: DogPainter? = nil) -> (x0: Int, bowlX: Int, width: Int) {
        let painter = painter ?? DogPainter(profile)
        let w = SpriteCanvas.width
        // Bowl spot: under the nose of the eating head with no sideways shift, the same for hungry and eat.
        let nose = noseCell(paint(painter, rig(Step(dx: 0, noseY: eatNoseY)))) ?? (x: 40, y: eatNoseY)
        let bowlX = nose.x - 3   // the nose over the bowl's middle, eyes stay clear of it
        // Measured over hungry and eat together, so switching between them never moves the dog.
        let boxes = (grids(painter, .hungry) + grids(painter, .eat)).compactMap(\.bounds)
        let lo = min(boxes.map(\.minX).min() ?? bowlX, bowlX)
        let hi = max(boxes.map(\.maxX).max() ?? bowlX, bowlX + Bowl.width - 1)
        // Keep the dog's spot from the normal poses when dog and bowl fit there with a clear column each side;
        // otherwise centre dog plus bowl (long dogs shift a few px for these frames).
        let span = DogRenderer.union(DogRenderer.grids(profile))
        var x0 = span.map { $0.minX - (w - ($0.maxX - $0.minX + 1)) / 2 } ?? 12
        if lo < x0 + 1 || hi > x0 + w - 2 { x0 = lo - (w - (hi - lo + 1)) / 2 }
        return (x0, bowlX, hi - lo + 1)
    }

    private static func grids(_ painter: DogPainter, _ motion: ExtraMotion) -> [ArtGrid] {
        steps(motion).enumerated().map { i, step in
            var r = rig(step)
            r.frame = i
            return paint(painter, r)
        }
    }

    // MARK: Keyframes

    /// Nose rows: hungry hovers just over the rim, eat dips under the food line.
    private static let eatNoseY = 14

    private struct Step {
        public var dx: Int
        public var noseY: Int
        public var tail = TailPose.rest
        public var lids = false
        public var fx = 0   // sniff puff (hungry) or crumb (eat) phase, 0 = none
        public var ask = false   // a "?" over the raised head: hungry reads apart from eat at 1x
    }

    private static func steps(_ motion: ExtraMotion) -> [Step] {
        switch motion {
        case .hungry:
            // Head up at the empty bowl with a "?", nose into it, look up sad again, sniff the floor behind it.
            // Two of four frames head up (eat is always head down): the contrast that reads at 1x.
            return [Step(dx: 0, noseY: 10, tail: .down, lids: true, ask: true), Step(dx: 0, noseY: 14, tail: .down, fx: 2),
                    Step(dx: 0, noseY: 11, tail: .down, lids: true, ask: true), Step(dx: -3, noseY: 15, tail: .down, fx: 1)]
        case .eat:
            return [Step(dx: 0, noseY: 14, tail: .wag), Step(dx: 0, noseY: 13, tail: .rest, lids: true, fx: 1),
                    Step(dx: 0, noseY: 14, tail: .wag), Step(dx: 0, noseY: 13, tail: .rest, lids: true, fx: 2)]
        case .special:
            return []
        }
    }

    /// Standing still, legs planted, head lowered until the nose reaches `noseY`.
    private static func rig(_ s: Step) -> FrameRig {
        FrameRig(headDX: s.dx, headDY: s.noseY, tail: s.tail, earDY: 1, tired: s.lids)
    }

    /// `rig.headDY` carries the wanted nose row; this finds the real head drop for that row and paints.
    private static func paint(_ painter: DogPainter, _ wanted: FrameRig) -> ArtGrid {
        var r = wanted
        r.headDY = 0
        let flat = grid(painter, r)
        let drop = noseCell(flat).map { wanted.headDY - $0.y } ?? 0
        r.headDY = drop
        return drop == 0 ? flat : grid(painter, r)
    }

    private static func grid(_ painter: DogPainter, _ r: FrameRig) -> ArtGrid {
        var g = ArtGrid(width: SpriteCanvas.width + 24, height: SpriteCanvas.height)
        painter.paint(r, into: &g, originX: 20)   // same origin as DogRenderer.grids
        return g
    }

    private static func noseCell(_ g: ArtGrid) -> (x: Int, y: Int)? {
        for y in 0..<g.height { for x in stride(from: g.width - 1, through: 0, by: -1) where g[x, y].ink == .nose { return (x, y) } }
        return nil
    }

    /// A white "?" with a dark rim, left edge at `x`, top at `y`, only on clear pixels.
    private static func ask(_ out: inout [UInt8], x: Int, y: Int) {
        let mark = ["qq.", "..q", ".q.", "...", ".q."]
        let fill = PixelColor(hex: "#FFFFFF"), rim = PixelColor(hex: "#3A3440")
        let pts = mark.enumerated().flatMap { dy, row in row.enumerated().compactMap { dx, c in c == "q" ? (x + dx, y + dy) : nil } }
        for (px, py) in pts {
            for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] where !pts.contains(where: { $0 == (nx, ny) }) {
                ExtraImages.putIfClear(&out, nx, ny, rim)
            }
        }
        for (px, py) in pts { ExtraImages.putIfClear(&out, px, py, fill) }
    }

    /// Two tiny air puffs ahead of the nose while sniffing.
    private static func sniff(_ out: inout [UInt8], nose: (x: Int, y: Int), phase: Int) {
        let dots = phase == 1 ? [(2, -1), (3, -2)] : [(2, -2), (4, -3)]
        for (dx, dy) in dots { ExtraImages.putIfClear(&out, nose.x + dx, nose.y + dy, Bowl.puff) }
    }
}

/// A side-view pet bowl, drawn over the dog's muzzle so the head reads as inside it.
public enum Bowl {
    public static let width = 7
    public static let puff = PixelColor(hex: "#B9C3CF")

    private static let empty = [
        "ooooooo",
        "oIIIIIo",
        "oLPPPpo",
        ".oPPpo.",
        "..ooo..",
    ]
    private static let full = [
        "..ooo..",
        ".oKKko.",
        "oKkKKKo",
        "oKKKkKo",
        "oLPPPpo",
        ".oPPpo.",
        "..ooo..",
    ]
    private static let colors: [Character: PixelColor] = [
        "o": PixelColor(hex: "#1E4C86"),   // outline, dark blue so the bowl never melts into a brown dog
        "I": PixelColor(hex: "#2A5D9C"),   // the empty inside
        "P": PixelColor(hex: "#4E9BE6"),
        "p": PixelColor(hex: "#3279C6"),
        "L": PixelColor(hex: "#9CCDF7"),
        "K": PixelColor(hex: "#C98A47"),   // kibble
        "k": PixelColor(hex: "#8E5A2B"),
    ]

    /// Bottom row on the canvas's last row (the outline row under the paws), left edge at column `x`.
    public static func draw(full isFull: Bool, into out: inout [UInt8], x: Int, crumbs: Int) {
        let rows = isFull ? full : empty
        let top = SpriteCanvas.height - rows.count
        for (dy, row) in rows.enumerated() {
            for (dx, ch) in row.enumerated() {
                if let c = colors[ch] { ExtraImages.put(&out, x + dx, top + dy, c) }
            }
        }
        // A kibble hops out of the bowl while chewing.
        if crumbs > 0 { ExtraImages.putIfClear(&out, x + (crumbs == 1 ? 6 : 0), top - (crumbs == 1 ? 1 : 2), colors["K"]!) }
    }
}

/// Shared pixel helpers for extra motion frames (34 x 20 RGBA, alpha 0 or 255).
public enum ExtraImages {
    public static func put(_ out: inout [UInt8], _ x: Int, _ y: Int, _ c: PixelColor) {
        let w = SpriteCanvas.width, h = SpriteCanvas.height
        guard x >= 0, y >= 0, x < w, y < h else { return }
        let i = (y * w + x) * 4
        out[i] = c.r; out[i + 1] = c.g; out[i + 2] = c.b; out[i + 3] = 255
    }

    public static func putIfClear(_ out: inout [UInt8], _ x: Int, _ y: Int, _ c: PixelColor) {
        let w = SpriteCanvas.width, h = SpriteCanvas.height
        guard x >= 0, y >= 0, x < w, y < h, out[(y * w + x) * 4 + 3] == 0 else { return }
        put(&out, x, y, c)
    }
}
