import Foundation

/// Everything that moves between cat frames. Legs, bob, head offsets and the panting flags come from the dog's
/// gait keyframes (DogPose.rigs), so a cat and a dog run in step.
struct CatRig {
    enum Mode { case stand, lying, atBowl }
    enum Tail { case up, wave, flow, low, wrap }
    enum Eyes { case open, closed, tired, happy }
    enum Bowl { case none, empty, full }

    var gait = FrameRig()
    var mode = Mode.stand
    var tail = Tail.up
    var eyes = Eyes.open
    var mouthOpen = false
    var bowl = Bowl.none
    var glyph = 0          // "?" over the head: 0 none, 1 low, 2 high
    var crumbs = false
    var dip = 0            // head lower by this many px (sniffing, chewing)

    static func rigs(_ pose: DogPose) -> [CatRig] {
        pose.rigs.map { r in
            var c = CatRig(gait: r)
            switch pose {
            case .lying: c.mode = .lying; c.eyes = .closed; c.tail = .wrap
            case .slowWalk, .walk, .fastWalk: c.tail = r.tail == .wag ? .wave : .up
            case .run, .sprint: c.tail = .flow
            case .exhausted: c.tail = .low; c.eyes = .tired
            }
            return c
        }
    }

    /// 4 frames each. hungry: sniffs the empty bowl twice, then looks up and meows with a "?".
    /// eat: head in a full bowl, chewing up and down, crumbs flying, tail swaying.
    static func rigs(_ motion: ExtraMotion) -> [CatRig]? {
        let frames: [CatRig]
        switch motion {
        case .hungry:
            frames = [
                CatRig(mode: .atBowl, tail: .low, bowl: .empty),
                CatRig(mode: .atBowl, tail: .low, bowl: .empty, dip: 1),
                CatRig(mode: .stand, tail: .low, eyes: .tired, mouthOpen: true, bowl: .empty, glyph: 1),
                CatRig(mode: .stand, tail: .wave, eyes: .tired, bowl: .empty, glyph: 2),
            ]
        case .eat:
            frames = (0..<4).map { i in
                CatRig(mode: .atBowl, tail: i < 2 ? .up : .wave, eyes: .happy, bowl: .full, crumbs: i % 2 == 1, dip: i % 2)
            }
        case .special:
            return nil
        }
        return frames.enumerated().map { i, r in
            var r = r
            r.gait.frame = i
            return r
        }
    }
}

/// Composes one cat frame: far legs, tail, torso, near legs, head and ears back to front, the bowl, the outline,
/// then effects. Coat patterns are decided here, per pixel, as a CatTone.
struct CatPainter {
    static let ground = DogSpriteCache.canvasHeight - 2

    enum Zone { case coat, back, belly, chest, muzzle, chin, face, forehead, paw, leg, tail, tailTip, ear }

    let p: CatProfile
    let len: Int, legLen: Int
    var rows: [(rump: Int, chest: Int)]

    init(_ profile: CatProfile) {
        p = profile
        switch profile.build {
        case .small: len = 11; rows = [(1, 1), (0, 0), (0, 0), (1, 1)]
        case .medium: len = 12; rows = [(1, 1), (0, 0), (0, 0), (1, 1)]
        case .large: len = 13; rows = [(2, 1), (0, 0), (0, 0), (0, 0), (1, 2)]
        }
        if profile.has(.chubby) { rows.insert((0, 0), at: rows.count - 1) }   // a deeper, rounder body
        legLen = profile.shortLegs ? 2 : (profile.has(.silverBack) ? 5 : 4)
    }

    var bodyH: Int { rows.count }

    func paint(_ rig: CatRig, into g: inout CatGrid, originX x0: Int) {
        let head: (x: Int, y: Int)
        switch rig.mode {
        case .lying: head = paintLying(rig, &g, x0)
        case .stand, .atBowl: head = paintStanding(rig, &g, x0)
        }
        g.drawOutline()
        if rig.gait.sweat { sweat(&g, head: head, phase: rig.gait.frame) }
        if rig.mode == .lying { sleepZ(&g, head: head, phase: rig.gait.frame) }
        if rig.glyph > 0 { glyph(&g, CatStamps.question, at: (head.x + 12, head.y - 2 - rig.glyph), .mark) }
        if rig.crumbs {
            for (dx, dy) in [(-1, -5), (7, -4)] { effect(&g, x0 + len + 2 + dx, Self.ground + dy, .food) }
        }
    }

    // MARK: Poses

    private func paintStanding(_ rig: CatRig, _ g: inout CatGrid, _ x0: Int) -> (x: Int, y: Int) {
        let r = rig.gait
        let bottom = Self.ground - legLen + r.bob
        let top = bottom - bodyH + 1
        let x1 = x0 + len - 1
        let frontHip = x1 - 3, backHip = x0 + 1

        leg(&g, hipX: frontHip - 1, hipY: bottom, r.frontFar, .farLeg)
        leg(&g, hipX: backHip + 1, hipY: bottom, r.backFar, .farLeg)
        tail(&g, rig.tail, root: (x0, top))
        torso(&g, x0: x0, top: top)
        leg(&g, hipX: frontHip, hipY: bottom, r.frontNear, .nearLeg)
        leg(&g, hipX: backHip, hipY: bottom, r.backNear, .nearLeg)

        let origin: (x: Int, y: Int)
        if rig.mode == .atBowl {
            origin = (x1 - (rig.bowl == .full ? 1 : 2), Self.ground - (rig.bowl == .full ? 9 : 10) + rig.dip)
        } else {
            origin = (x1 - 4 + r.headDX, top - 5 + r.headDY + (rig.glyph > 0 ? -1 : 0))
        }
        drawHead(&g, origin: origin, rig: rig)
        // In front of the head: eating, the bowl hides the mouth in the food.
        if rig.bowl != .none { bowl(&g, rig.bowl, x: x0 + len + 2) }
        return origin
    }

    /// Asleep as a loaf: a low round mound, head resting on the front paws, tail wrapped along the bottom.
    private func paintLying(_ rig: CatRig, _ g: inout CatGrid, _ x0: Int) -> (x: Int, y: Int) {
        let ground = Self.ground
        let l = len + 1, x1 = x0 + l - 1
        let top = ground - 4 + (p.build == .large ? -1 : 0)
        for y in top...ground {
            let inset = y == top ? 2 : (y == top + 1 ? 1 : 0)
            for x in (x0 + inset)...(x1 - inset) {
                let zone: Zone = x >= x1 - 2 && y > top ? .chest : (y <= top + 2 ? .back : (y == ground ? .belly : .coat))
                g.put(x, y, .body, tone(zone, x - x0, y - top))
            }
        }
        if rig.gait.breath > 0 { for x in (x0 + 3)...(x1 - 4) { g.put(x, top - 1, .body, tone(.back, x - x0, 0)) } }
        // Front paws tucked under the chin.
        for x in (x1 - 1)...(x1 + 1) { g.put(x, ground, .nearLeg, tone(.paw, 0, 0)) }
        // Tail: round the rump and along the bottom, a line on the fur above so it reads as its own shape.
        let tailLen: Int
        switch p.tail {
        case .short: tailLen = 2
        case .long: tailLen = l - 3
        case .fluffy: tailLen = l - 2
        }
        g.put(x0 - 1, ground - 1, .tail, tone(.tail, 1, 1))
        g.put(x0 - 1, ground, .tail, tone(.tail, 2, 2))
        for i in 0..<tailLen {
            let x = x0 + i
            let tip = i >= tailLen - 2
            g.put(x, ground, .tail, tone(tip ? .tailTip : .tail, i, i + 3))
            if p.tail == .fluffy { g.put(x, ground - 1, .tail, tone(tip ? .tailTip : .tail, i, i + 3)) }
            let above = p.tail == .fluffy ? ground - 2 : ground - 1
            if g[x, above].part == .body { g[x, above].ink = .line }
        }
        let origin = (x: x1 - 6, y: ground - 8)
        drawHead(&g, origin: origin, rig: rig)
        return origin
    }

    // MARK: Parts

    private func torso(_ g: inout CatGrid, x0: Int, top: Int) {
        let x1 = x0 + len - 1
        for (r, inset) in rows.enumerated() {
            let y = top + r
            for x in (x0 + inset.rump)...(x1 - inset.chest) {
                let c = x - x0
                let zone: Zone
                if c >= len - 4 && r >= 1 { zone = .chest }
                else if r == rows.count - 1 { zone = .belly }
                else if r <= 1 || (r == 2 && rows.count > 4) { zone = .back }
                else { zone = .coat }
                let silver = p.has(.silverBack) && r == 0 && c < len - 3
                g.put(x, y, .body, tone(zone, c, r), silver ? .silver : .none)
            }
        }
        if p.fluffy {   // tufts that break the outline: chest ruff notches, a fuzzy belly line, the back of the thighs
            for y in stride(from: top + 1, through: top + bodyH - 1, by: 2) {
                g.put(x1 + 1, y, .body, tone(.chest, len, y - top), .ruff)
                g.put(x0 - 1, y, .body, tone(.coat, 0, y - top), .ruff)
            }
            for x in stride(from: x0 + 2, to: x1 - 2, by: 2) { g.put(x, top + bodyH, .body, tone(.belly, x - x0, bodyH), .ruff) }
        }
    }

    private func leg(_ g: inout CatGrid, hipX: Int, hipY: Int, _ pose: LegPose, _ part: CatPart) {
        let legW = 2
        let scale = Double(legLen + 1) / 5
        let dx = Int((Double(pose.dx) * scale).rounded())
        let lift = min(pose.lift, max(0, legLen - 1))
        let footY = max(hipY + 1, Self.ground - lift)
        let footX = hipX + dx
        let kneeY = (hipY + footY + 1) / 2
        let kneeX = Int((Double(hipX + footX) / 2).rounded()) + pose.knee
        var cells: [(x: Int, y: Int, zone: Zone)] = []
        var prev: Int?
        for y in hipY...footY {
            let x = y <= kneeY ? lerp(hipX, kneeX, y - hipY, kneeY - hipY) : lerp(kneeX, footX, y - kneeY, footY - kneeY)
            let lo = min(x, prev ?? x), hi = max(x, prev ?? x) + legW - 1
            let zone: Zone = y == footY ? .paw : .leg
            for xx in lo...hi { cells.append((xx, y, zone)) }
            prev = x
        }
        // Crossing a leg on the same side: outline the one behind where they touch, so it reads as two legs.
        for c in cells {
            for (nx, ny) in [(c.x - 1, c.y), (c.x + 1, c.y), (c.x, c.y + 1)] where g[nx, ny].part == part {
                if !cells.contains(where: { $0.x == nx && $0.y == ny }) { g.put(nx, ny, .outline) }
            }
        }
        for c in cells { g.put(c.x, c.y, part, tone(c.zone, c.x - hipX, c.y - hipY)) }
    }

    private func tail(_ g: inout CatGrid, _ pose: CatRig.Tail, root: (x: Int, y: Int)) {
        let s = CatStamps.tail(p.tail, pose)
        for (y, row) in s.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                // Rings count from the root (bottom of the stamp) so they stay put as the tip moves.
                let along = s.rows.count - 1 - y
                g.put(root.x - s.anchor.x + x, root.y - s.anchor.y + y, .tail, tone(ch == "T" ? .tailTip : .tail, x, along))
            }
        }
    }

    private func drawHead(_ g: inout CatGrid, origin o: (x: Int, y: Int), rig: CatRig) {
        let flat = p.has(.flatFace)
        let ears = CatStamps.ears(p.ears, small: flat)
        stamp(&g, ears.far, at: (o.x + ears.farAt.x, o.y + ears.farAt.y), .farEar, far: true)
        let head = flat ? CatStamps.flatHead : CatStamps.head
        if p.fluffy { for c in CatStamps.ruff { g.put(o.x + c.x, o.y + c.y, .head, tone(.chest, 0, 0), .ruff) } }
        if p.has(.chubby) { for c in CatStamps.cheeks { g.put(o.x + c.x, o.y + c.y, .head, tone(.coat, 0, 0)) } }
        for (y, row) in head.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                var zone = Zone.coat, ink = CatInk.none
                switch ch {
                case "s": zone = .forehead
                case "f": zone = .face
                case "m": zone = .muzzle
                case "k": zone = .chin
                case "o": zone = .muzzle; if rig.mouthOpen || rig.gait.tongue { ink = .tongueDark }
                case "n": zone = .muzzle; ink = .nose
                case "w": zone = .muzzle; ink = .line
                case "e", "g":   // eye, top row
                    zone = .face
                    switch rig.eyes {
                    case .open: ink = ch == "e" ? .pupil : .glint
                    case .tired, .happy: ink = .line
                    case .closed: break
                    }
                case "i":        // eye, bottom row
                    zone = .face
                    switch rig.eyes {
                    case .open, .tired: ink = .iris
                    case .closed: ink = .line
                    case .happy: break
                    }
                default: break
                }
                if y == 0, ink == .none, p.has(.silverBack) { ink = .silver }
                g.put(o.x + x, o.y + y, .head, tone(zone, x, y), ink)
            }
        }
        stamp(&g, ears.near, at: (o.x + ears.nearAt.x, o.y + ears.nearAt.y), .ear, far: false)
        if p.has(.lynxTufts) {   // 2 px dark tufts on both ear tips
            for tip in [(ears.nearAt.x, ears.nearAt.y), (ears.farAt.x + 2, ears.farAt.y)] {
                for dy in 1...2 { g.put(o.x + tip.0, o.y + tip.1 - dy, .ear, tone(.ear, 0, 0), .line) }
            }
        }
        if rig.gait.tongue, let m = mouth(head) {
            let t = (x: o.x + m.x, y: o.y + m.y + 1)
            g.put(t.x, t.y, .head, .base, .tongue)
            if rig.gait.frame % 2 == 0 { g.put(t.x + 1, t.y, .head, .base, .tongue) } else { g.put(t.x, t.y + 1, .head, .base, .tongue) }
        }
    }

    private func mouth(_ head: [String]) -> (x: Int, y: Int)? {
        for (y, row) in head.enumerated() { if let x = Array(row).firstIndex(of: "o") { return (x, y) } }
        return nil
    }

    private func stamp(_ g: inout CatGrid, _ rows: [String], at p0: (x: Int, y: Int), _ part: CatPart, far: Bool) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                let t = tone(.ear, far ? 1 : 0, y)
                g.put(p0.x + x, p0.y + y, part, t, ch == "p" ? .pink : .none)
            }
        }
    }

    private func bowl(_ g: inout CatGrid, _ kind: CatRig.Bowl, x: Int) {
        let s = kind == .full ? CatStamps.bowlFull : CatStamps.bowlEmpty
        let y0 = Self.ground - s.count + 1
        for (y, row) in s.enumerated() {
            for (dx, ch) in row.enumerated() where ch != "." {
                let ink: CatInk
                switch ch {
                case "l": ink = .bowlLight
                case "d": ink = .bowlDark
                case "f": ink = .food
                case "F": ink = .foodDark
                default: ink = .bowl
                }
                let cx = x + dx, cy = y0 + y
                // A line where the rim meets the cat, so the face reads as dipping behind it.
                if y == 0 || g[cx, cy - 1].part != .prop, g.isSolid(cx, cy - 1), g[cx, cy - 1].part != .prop { g[cx, cy - 1].ink = .line }
                g.put(cx, cy, .prop, .base, ink)
            }
        }
    }

    // MARK: Pattern

    /// Coat color of one fur cell. `lx`, `ly`: position inside the part (body column and row, tail pixels from
    /// the root, head stamp column and row), so stripes and patches move with it.
    func tone(_ zone: Zone, _ lx: Int, _ ly: Int) -> CatTone {
        if zone == .tailTip, p.has(.lynxTufts) { return .acc }   // a light tail tip
        switch p.coat {
        case .solid:
            return .base
        case .tabby:
            switch zone {
            case .chest, .belly, .muzzle, .chin: return .acc
            case .back: return lx % 3 == 1 && lx < len - 3 ? .sec : .base
            case .forehead, .tailTip: return .sec
            case .tail: return ly % 3 == 1 ? .sec : .base
            case .leg: return ly == 1 ? .sec : .base
            default: return .base
            }
        case .calico:
            switch zone {
            case .back, .coat: return lx <= 3 && ly <= 2 ? .acc : (lx >= 5 && lx <= 8 && ly <= 1 ? .sec : .base)
            case .forehead: return .sec
            case .ear: return lx == 0 ? .sec : .acc
            case .tail: return ly >= 2 ? .sec : .base
            case .tailTip: return .acc
            default: return .base
            }
        case .tuxedo:
            return [.chest, .belly, .muzzle, .chin, .paw].contains(zone) ? .sec : .base
        case .bicolor:
            return [.chest, .belly, .muzzle, .chin, .paw, .leg].contains(zone) ? .sec : .base
        case .pointed:
            return [.face, .muzzle, .chin, .ear, .paw, .leg, .tail, .tailTip].contains(zone) ? .sec : .base
        }
    }

    // MARK: Effects

    private func sweat(_ g: inout CatGrid, head o: (x: Int, y: Int), phase: Int) {
        let drops: [[(Int, Int)]] = [[(-1, -2)], [(-2, -3)], [(-3, -3), (2, -4)], [(-4, -2), (1, -5)], [(0, -5)], [(-1, -3)]]
        for (dx, dy) in drops[phase % drops.count] {
            let x = o.x + dx, y = o.y + dy
            guard g[x, y].part == .none, g[x, y + 1].part == .none else { continue }
            effect(&g, x, y, .sweat)
            effect(&g, x, y + 1, .sweatDark)
        }
    }

    private func sleepZ(_ g: inout CatGrid, head o: (x: Int, y: Int), phase: Int) {
        let z = phase >= 2 ? DogStamps.zBig : DogStamps.zSmall
        let x0 = o.x + 10 + phase, w = z.rows[0].count
        let below = (0..<g.height).first { y in (x0 - 1...x0 + w).contains { g[$0, y].part != .none } } ?? g.height
        let y0 = min(o.y - 3 - phase * 2, below - z.rows.count - 1)
        guard y0 >= 0 else { return }
        for (y, row) in z.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." { effect(&g, x0 + x, y0 + y, .zz) }
        }
    }

    private func glyph(_ g: inout CatGrid, _ rows: [String], at p0: (x: Int, y: Int), _ ink: CatInk) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." { effect(&g, p0.x + x, max(0, p0.y) + y, ink) }
        }
    }

    private func effect(_ g: inout CatGrid, _ x: Int, _ y: Int, _ ink: CatInk) {
        if g[x, y].part == .none { g.put(x, y, .fx, .base, ink) }
    }

    private func lerp(_ a: Int, _ b: Int, _ i: Int, _ n: Int) -> Int {
        n <= 0 ? b : a + Int((Double((b - a) * i) / Double(n)).rounded())
    }
}

/// Hand-drawn cat parts. Head faces right in three-quarter view, both eyes showing.
/// h skull, s forehead (tabby stripes), f around the eyes, m muzzle, k chin, n nose, w mouth line, o mouth (opens),
/// e/g eye top (g = glint), i eye bottom (iris). Ears: x fur, p pink inside. Tails: t fur, T tip.
enum CatStamps {
    static let head = [
        "..hhshshh...",
        ".hhhhshhhhh.",
        "hhhhhhhhhhhh",
        "hhhhfegffegh",
        "hhhhfiiffiih",
        "hhhhhfmnmfhh",
        ".hhhhhwowhh.",
        "...hhhkkkh..",
    ]
    /// The Persian's flat face: nose up on the eye line, a vertical face front, a rounder head.
    static let flatHead = [
        "..hhhhhhhh..",
        ".hhhhhhhhhhh",
        "hhhhhhhhhhhh",
        "hhhhfegffegh",
        "hhhhfiinfiih",
        "hhhhhfmwmfhh",
        "hhhhhhmommhh",
        ".hhhhhkkkhh.",
    ]
    /// Fluffy cats add a ruff that breaks the outline: alternating tufts down the back of the head and notches
    /// under the chin (CatPainter.drawHead).
    static let ruff: [(x: Int, y: Int)] = [(-1, 3), (-2, 4), (-1, 5), (-2, 6), (-1, 7), (1, 8), (3, 8), (5, 8)]
    /// Chubby cheeks that bulge past the neck (British Shorthair).
    static let cheeks: [(x: Int, y: Int)] = [(-1, 3), (-1, 4), (-1, 5), (-1, 6), (0, 6), (0, 7), (1, 7), (2, 7), (10, 7), (11, 6)]

    struct Ears { let near: [String], nearAt: (x: Int, y: Int), far: [String], farAt: (x: Int, y: Int) }

    static func ears(_ style: CatEars, small: Bool = false) -> Ears {
        if small, style == .pointy {   // shorter and set wider apart
            return Ears(near: ["x..", "xpx"], nearAt: (0, -1), far: ["..x", "xpx"], farAt: (8, -1))
        }
        switch style {
        case .pointy: return Ears(near: ["x..", "xp.", "xpx"], nearAt: (1, -2), far: ["..x", ".px", "xpx"], farAt: (7, -2))
        case .folded: return Ears(near: ["xxx", ".xp"], nearAt: (2, -1), far: ["xxx", "px."], farAt: (6, -1))
        }
    }

    static func tail(_ style: CatTail, _ pose: CatRig.Tail) -> Stamp {
        switch (style, pose) {
        case (.long, .up): return Stamp((2, 6), [".TT", "T..", "t..", "t..", "t..", ".t.", "..t"])
        case (.long, .wave): return Stamp((2, 6), ["TT.", ".t.", "t..", "t..", "t..", ".t.", "..t"])
        case (.long, .flow): return Stamp((5, 2), ["TT....", "..ttt.", ".....t"])
        case (.long, .low): return Stamp((1, 0), [".t", "t.", "t.", "T."])
        case (.short, .up), (.short, .wave): return Stamp((2, 2), ["TT.", "ttt", ".tt"])   // stubby and thick
        case (.short, _): return Stamp((2, 1), ["TTt", ".tt"])
        case (.fluffy, .up): return Stamp((3, 6), [".TT.", "TTt.", "tt..", "tt..", "tt..", ".ttt", "..tt"])
        case (.fluffy, .wave): return Stamp((3, 6), ["TT..", "Ttt.", ".tt.", "tt..", "tt..", ".ttt", "..tt"])
        case (.fluffy, .flow): return Stamp((5, 2), ["TTT...", "TTttt.", "..tttt"])
        case (.fluffy, .low): return Stamp((2, 0), [".tt", "tt.", "tt.", "TT."])
        case (_, .wrap): return Stamp((0, 0), ["t"])
        }
    }

    static let bowlEmpty = ["ldddddl", "bbbbbbb", ".bbbbb."]
    static let bowlFull = [".fFfFf.", "lfffffl", "bbbbbbb", ".bbbbb."]
    static let question = ["qq.", "..q", ".q.", "...", ".q."]
}
