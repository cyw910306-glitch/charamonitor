import CoreGraphics
import simd

/// A small cloth lying on the desktop, seen from above: a grid of points joined by distance constraints (structural,
/// shear and bending), moved with Verlet steps. x and y are across the desktop in points, z the height above it.
/// The floor (z = 0) has friction: a resting point stays where it is unless pushed hard, so folds and wrinkles stay
/// after the hand lets go. Grab any point (an edge lifts and folds over; the middle slides and bunches), drag, let go
/// with a throw. Step it every frame and stop once `isSettled`. API like Dangle. Pure.
struct ClothSheet {
    typealias P = SIMD3<Double>

    let cols: Int, rows: Int
    /// Rest distance between neighbours.
    let spacing: Double
    /// The flat cloth with its first point at the origin, row by row (row 0 at the bottom).
    let rest: [P]
    /// Bending strength 0...1 (RugSoftness): low folds and crumples easily.
    var bend: Double
    /// Points pulled down per second squared.
    var gravity = 1600.0
    /// A point on the floor that would slide less than this (points per step) stays put: friction keeps the wrinkles.
    var grip = 0.6
    /// Sliding points keep this much of their sideways speed each step on the floor.
    var slide = 0.82
    /// The cloth stays inside this (the screen's visible frame, in the same points).
    var walls: CGRect
    static let iterations = 6
    static let maxThrow = 2500.0
    /// A link buckles once pushed shorter than this share of its length; the solver's own jitter stays under it.
    static let buckle = 0.96

    private(set) var points: [P]
    private var previous: [P]
    private var links: [(a: Int, b: Int, length: Double, bend: Bool)] = []
    /// How high each point is held up by a buckle under it (the last step's arches): a floor with the same friction.
    private var support: [Double]
    private(set) var held: Int?
    private var hand = P(0, 0, 0)
    private var quiet = 0

    /// A flat sheet whose bottom-left corner is at `origin`.
    init(cols: Int = 16, rows: Int = 11, spacing: Double = 17, bend: Double = 0.4, origin: CGPoint = .zero, walls: CGRect) {
        self.cols = max(2, cols); self.rows = max(2, rows); self.spacing = spacing; self.bend = bend; self.walls = walls
        var r: [P] = []
        for y in 0..<self.rows { for x in 0..<self.cols { r.append(P(Double(x) * spacing, Double(y) * spacing, 0)) } }
        rest = r
        points = r.map { $0 + P(Double(origin.x), Double(origin.y), 0) }
        previous = points
        support = Array(repeating: 0, count: r.count)
        let c = self.cols
        func link(_ a: Int, _ b: Int, bend: Bool) { links.append((a, b, simd_length(r[a] - r[b]), bend)) }
        for y in 0..<self.rows {
            for x in 0..<c {
                let i = y * c + x
                if x + 1 < c { link(i, i + 1, bend: false) }
                if y + 1 < self.rows { link(i, i + c, bend: false) }
                if x + 1 < c, y + 1 < self.rows { link(i, i + c + 1, bend: false); link(i + 1, i + c, bend: false) }   // shear
                if x + 2 < c { link(i, i + 2, bend: true) }
                if y + 2 < self.rows { link(i, i + 2 * c, bend: true) }
            }
        }
    }

    func index(_ x: Int, _ y: Int) -> Int { y * cols + x }
    var size: CGSize { CGSize(width: Double(cols - 1) * spacing, height: Double(rows - 1) * spacing) }
    var isSettled: Bool { held == nil && quiet >= 30 }

    /// Takes the point nearest `p` (across the desktop) when one is within a spacing and a half.
    mutating func grab(at p: CGPoint) -> Bool {
        let q = P(Double(p.x), Double(p.y), 0)
        guard let i = points.indices.min(by: { flat($0, q) < flat($1, q) }), flat(i, q) <= spacing * 1.5 else { return false }
        held = i
        hand = points[i]
        quiet = 0
        return true
    }

    /// Moves the held point toward `p`. An edge point is lifted (the cloth folds over); a middle one slides along the floor.
    mutating func drag(to p: CGPoint) {
        guard let i = held else { return }
        let x = i % cols, y = i / cols, edge = x == 0 || y == 0 || x == cols - 1 || y == rows - 1
        hand = P(Double(p.x), Double(p.y), edge ? spacing * 2 : 0)
        quiet = 0
    }

    /// Lets go; `velocity` (points per second across) throws the held point.
    mutating func release(velocity v: CGVector = .zero, dt: Double = 1.0 / 120) {
        guard let i = held else { return }
        held = nil
        let s = hypot(Double(v.dx), Double(v.dy)), k = s > Self.maxThrow ? Self.maxThrow / s : 1
        previous[i] = points[i] - P(Double(v.dx) * k * dt, Double(v.dy) * k * dt, 0)
    }

    /// Advances `dt` seconds (capped at 0.1) in fixed 1/120 s steps.
    mutating func step(dt: Double) {
        var left = min(0.1, max(0, dt))
        while left > 1e-9 {
            let h = min(left, 1.0 / 120); left -= h
            substep(h)
        }
    }

    private mutating func substep(_ h: Double) {
        var moved = 0.0
        for i in points.indices where i != held {
            var v = (points[i] - previous[i]) * 0.99
            if points[i].z <= support[i] + 0.01 {   // on the floor or a buckle: static friction, then sliding friction
                let side = hypot(v.x, v.y)
                if side < grip { v.x = 0; v.y = 0 } else { v.x *= slide; v.y *= slide }
            }
            previous[i] = points[i]
            points[i] += v + P(0, 0, -gravity * h * h)
            moved = max(moved, simd_length(v))
        }
        if let i = held {   // the hand pulls its point along, not teleporting it
            previous[i] = points[i]
            points[i] += (hand - points[i]) * 0.5
            moved = max(moved, simd_length(points[i] - previous[i]))
        }
        for i in support.indices { support[i] = 0 }
        for _ in 0..<Self.iterations { solve() }
        tether()
        let lo = P(Double(walls.minX), Double(walls.minY), 0), hi = P(Double(walls.maxX), Double(walls.maxY), spacing * Double(max(cols, rows)))
        for i in points.indices { points[i] = simd_clamp(points[i], lo, hi) }
        quiet = moved < 0.02 ? quiet + 1 : 0
    }

    private mutating func solve() {
        for l in links {
            let d = points[l.b] - points[l.a], len = simd_length(d)
            guard len > 1e-6 else { continue }
            let k = l.bend ? bend : 1
            if !l.bend, case let across = hypot(d.x, d.y), case let slack = l.length * Self.buckle, across < slack {
                // Pushed together across the desktop it buckles up instead of passing through itself: the wrinkles.
                // A floor under both ends at the height of the arch, not a push: raising them again changes nothing,
                // so a bunched rug comes to rest (an additive nudge pumped energy in every pass and never settled).
                // ponytail: a height floor, not real self-collision; enough for one sheet seen from above.
                let arch = 0.5 * (slack * slack - across * across).squareRoot()
                if l.a != held { support[l.a] = max(support[l.a], arch); points[l.a].z = max(points[l.a].z, arch) }
                if l.b != held { support[l.b] = max(support[l.b], arch); points[l.b].z = max(points[l.b].z, arch) }
            }
            let fix = d * ((len - l.length) / len) * 0.5 * k
            switch held {
            case l.a: points[l.b] -= fix * 2
            case l.b: points[l.a] += fix * 2
            default: points[l.a] += fix; points[l.b] -= fix
            }
        }
    }

    /// While held, no point is farther from the hand's point than it is across the flat cloth: a few constraint passes
    /// cannot carry a pull across the whole grid, and without this the far side stretched like gum (long-range tethers).
    private mutating func tether() {
        guard let h = held else { return }
        let anchor = points[h], home = rest[h]
        for i in points.indices where i != h {
            let most = simd_length(rest[i] - home) * 1.02, d = points[i] - anchor, len = simd_length(d)
            if len > most, len > 1e-9 { points[i] = anchor + d * (most / len) }
        }
    }

    private func flat(_ i: Int, _ q: P) -> Double { hypot(points[i].x - q.x, points[i].y - q.y) }

    /// Puts every point at `to` (velocity zero): smoothing out, or 동작 줄이기's flat rug.
    mutating func place(_ to: [P]) {
        guard to.count == points.count else { return }
        points = to; previous = to; held = nil; quiet = 0
        for i in support.indices { support[i] = 0 }
    }

    /// The smoothing out: each point eased from `from` to the flat sheet at `origin`, `progress` 0...1 (ease-out). Pure.
    static func flatten(from: [P], rest: [P], to origin: CGPoint, progress: Double) -> [P] {
        let u = min(1, max(0, progress)), e = 1 - (1 - u) * (1 - u) * (1 - u)
        let o = P(Double(origin.x), Double(origin.y), 0)
        return zip(from, rest).map { a, r in a + (r + o - a) * e }
    }

    /// Per-point normals from the neighbours (the shading of folds). Up is +z; a point folded face down points down.
    func normals() -> [P] {
        points.indices.map { i in
            let x = i % cols, y = i / cols
            let tx = points[index(min(cols - 1, x + 1), y)] - points[index(max(0, x - 1), y)]
            let ty = points[index(x, min(rows - 1, y + 1))] - points[index(x, max(0, y - 1))]
            let n = simd_cross(tx, ty), l = simd_length(n)
            return l > 1e-9 ? n / l : P(0, 0, 1)
        }
    }

    /// Whether `p` (across the desktop) is on the cloth as seen from above: inside any of its triangles.
    func covers(_ p: CGPoint) -> Bool {
        let q = SIMD2(Double(p.x), Double(p.y))
        func inside(_ a: Int, _ b: Int, _ c: Int) -> Bool {
            let A = SIMD2(points[a].x, points[a].y), B = SIMD2(points[b].x, points[b].y), C = SIMD2(points[c].x, points[c].y)
            func side(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { (v.x - u.x) * (q.y - u.y) - (v.y - u.y) * (q.x - u.x) }
            let s1 = side(A, B), s2 = side(B, C), s3 = side(C, A)
            return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0)
        }
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let i = index(x, y)
                if inside(i, i + 1, i + cols + 1) || inside(i, i + cols + 1, i + cols) { return true }
            }
        }
        return false
    }

    /// What `covers` says yes to, as a path (y up, moved by `offset`): every triangle wound counter-clockwise, so a fold
    /// lying face down adds to the shape under the nonzero rule instead of cutting a hole in it.
    func outline(offset: CGVector = .zero) -> CGPath {
        let path = CGMutablePath()
        func tri(_ a: Int, _ b: Int, _ c: Int) {
            var q = [a, b, c].map { CGPoint(x: CGFloat(points[$0].x) + offset.dx, y: CGFloat(points[$0].y) + offset.dy) }
            let area = (q[1].x - q[0].x) * (q[2].y - q[0].y) - (q[2].x - q[0].x) * (q[1].y - q[0].y)
            if area < 0 { q.swapAt(1, 2) }
            path.addLines(between: q)
            path.closeSubpath()
        }
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let i = index(x, y)
                tri(i, i + 1, i + cols + 1)
                tri(i, i + cols + 1, i + cols)
            }
        }
        return path
    }

    /// Triangles as point indices, counter-clockwise from above for the flat sheet.
    var triangles: [Int32] {
        var t: [Int32] = []
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let i = Int32(index(x, y)), c = Int32(cols)
                t += [i, i + 1, i + c + 1, i, i + c + 1, i + c]
            }
        }
        return t
    }

    /// The longest a link has stretched over its rest length (tests: the constraints hold).
    var worstStretch: Double {
        links.filter { !$0.bend }.map { simd_length(points[$0.b] - points[$0.a]) / $0.length }.max() ?? 1
    }
}
