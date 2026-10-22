import Foundation

/// Composes one frame of one profile into an ArtGrid: legs, tail, torso, head and ears back to front,
/// then the outline, and finally effects (sweat, sleeping z).
public struct DogPainter {
    public static let ground = SpriteCanvas.height - 2   // paws stand on this row; the outline sits below

    public let profile: DogProfile
    public let m: BuildMetrics
    public let head: HeadStamp

    public init(_ profile: DogProfile) {
        self.profile = profile
        m = BuildMetrics(profile.build, fluffy: profile.fluffy)
        head = profile.isTeddy ? DogStamps.teddyHead : DogStamps.head(profile.snout, fluffy: profile.fluffy)
    }

    private var tailOnBack: Bool { profile.tail == .curly || profile.tail == .fluffy }

    public func paint(_ rig: FrameRig, into g: inout ArtGrid, originX x0: Int) {
        let h = rig.lying ? paintLying(rig, &g, x0) : paintStanding(rig, &g, x0)
        if rig.lying { g.drawHaunchLine() }
        g.drawOutline()
        // Effects go last and only on empty pixels, so they never cut into the dog or its outline.
        if rig.sweat { sweat(&g, head: h, phase: rig.frame) }
        if rig.lying { sleepZ(&g, head: h, phase: rig.frame) }
    }

    // MARK: Poses

    /// Returns the head's stamp origin, for effects.
    private func paintStanding(_ rig: FrameRig, _ g: inout ArtGrid, _ x0: Int) -> (x: Int, y: Int) {
        let bottom = Self.ground - m.legLen + rig.bob
        let top = bottom - m.bodyH + 1
        let x1 = x0 + m.bodyLen - 1
        let frontHip = x1 - m.legW, backHip = x0 + 1

        // Far hips sit a pixel toward the belly, so each far leg shows as its own sliver beside the near one.
        leg(&g, hipX: frontHip - 1, hipY: bottom, rig.frontFar, .farLeg)
        leg(&g, hipX: backHip + 1, hipY: bottom, rig.backFar, .farLeg)
        if !tailOnBack { tail(&g, rig.tail, root: (x0, top + 1)) }
        torso(&g, x0: x0, top: top)
        if tailOnBack { tail(&g, rig.tail, root: (x0 + 1, top)) }
        leg(&g, hipX: frontHip, hipY: bottom, rig.frontNear, .nearLeg)
        leg(&g, hipX: backHip, hipY: bottom, rig.backNear, .nearLeg)
        // Teddy: the near shoulder's top row is chest too, so the bib keeps a second row when the head droops.
        if profile.isTeddy {
            for x in frontHip..<(frontHip + m.legW) where g[x, bottom].part == .nearLeg { g[x, bottom].zone = .chest }
        }

        // Teddy heads sit up on a short neck so the bib shows; standing ears need that headroom instead.
        // Panting droops the head a pixel, and the big teddy head would bury the bib, so its neck grows to match.
        let neck = profile.isTeddy ? (rig.tired ? 2 : 1) : 0
        let origin = headOrigin(at: (x1 + m.headOffset.x + rig.headDX, top + m.headOffset.y + rig.headDY - neck))
        drawHead(&g, origin: origin, rig: rig, asleep: false)
        return origin
    }

    /// Asleep on the belly: a low loaf, round haunch, paws forward, chin resting on them.
    private func paintLying(_ rig: FrameRig, _ g: inout ArtGrid, _ x0: Int) -> (x: Int, y: Int) {
        let ground = Self.ground
        let len = m.bodyLen - 1
        let top = ground - max(4, m.bodyH - 1) + 1
        let x1 = x0 + len - 1

        for x in (x1 - 1)...(x1 + 3) { g.put(x, ground - 1, .farLeg, x >= x1 + 2 ? .paw : .coat) }
        tail(&g, .down, root: (x0 + 1, ground - 1))
        for y in top...ground {
            let inset = y == top ? 2 : (y == top + 1 ? 1 : 0)
            for x in (x0 + inset)...(x1 - inset) {
                let zone: ArtZone = x >= x1 - 2 && y > top ? .chest : (y <= top + 1 ? .back : .coat)
                g.put(x, y, .body, zone)
            }
        }
        if rig.breath > 0 {
            for x in (x0 + 3)...(x1 - 3) { g.put(x, top - 1, .body, .back) }
        }
        // Haunch one row above the back line, hind paw tucked forward.
        let hx1 = x0 + max(4, len / 3 + 1)
        for y in (top - 1)...ground {
            let inset = y == top - 1 ? 1 : 0
            for x in (x0 + 1 + inset)...(hx1 - inset) { g.put(x, y, .nearLeg, .coat) }
        }
        for x in hx1...(hx1 + 2) { g.put(x, ground, .nearLeg, .paw) }
        for x in (x1 - 2)...(x1 + 3) { g.put(x, ground, .nearLeg, x >= x1 + 2 ? .paw : .coat) }

        let origin = (x: x1 - 2, y: ground - 1 - head.stamp.rows.count)
        drawHead(&g, origin: origin, rig: rig, asleep: true)
        return origin
    }

    // MARK: Parts

    private func torso(_ g: inout ArtGrid, x0: Int, top: Int) {
        let len = m.bodyLen, x1 = x0 + len - 1
        for (r, inset) in m.rows.enumerated() {
            let y = top + r
            let last = r == m.rows.count - 1
            for x in (x0 + inset.rump)...(x1 - inset.chest) {
                let c = x - x0
                let zone: ArtZone
                if c >= len - 3 && r >= 1 { zone = .chest }
                else if last { zone = profile.fluffy ? .coat : .belly }   // a fluffy coat hides the underside
                else if r < (m.bodyH >= 6 ? 3 : 2) && c >= 1 && c <= len - 4 { zone = .back }
                else { zone = .coat }
                g.put(x, y, .body, zone)
            }
        }
        // Brisket: the chest pushes forward a pixel under the chin.
        for y in (top + 2)...(top + m.bodyH - 2) { g.put(x1 + 1, y, .body, .chest) }
        if profile.pattern == .spots {
            // Two patches: middle of the back and the rump.
            let mid = x0 + len / 2 - 1
            for (dx, dy) in [(0, 0), (1, 0), (2, 0), (0, 1), (1, 1), (2, 1), (1, 2)] where g[mid + dx, top + dy].part == .body {
                g[mid + dx, top + dy].zone = .spot
            }
            for (dx, dy) in [(1, 0), (0, 1), (1, 1), (2, 1)] where g[x0 + dx, top + dy].part == .body {
                g[x0 + dx, top + dy].zone = .spot
            }
        }
    }

    private func leg(_ g: inout ArtGrid, hipX: Int, hipY: Int, _ pose: LegPose, _ part: ArtPart) {
        let legW = part == .farLeg ? max(2, m.legW - 1) : m.legW
        let scale = Double(m.legLen + 1) / 5
        let dx = Int((Double(pose.dx) * scale).rounded())
        let lift = min(pose.lift, max(0, m.legLen - 1))
        let footY = max(hipY + 1, Self.ground - lift)
        let footX = hipX + dx
        let kneeY = (hipY + footY + 1) / 2
        let kneeX = Int((Double(hipX + footX) / 2).rounded()) + pose.knee
        let pawRows = m.legLen >= 4 ? 2 : 1
        var cells: [(x: Int, y: Int, zone: ArtZone)] = []
        var prev: Int?
        for y in hipY...footY {
            let x = y <= kneeY ? lerp(hipX, kneeX, y - hipY, kneeY - hipY) : lerp(kneeX, footX, y - kneeY, footY - kneeY)
            let lo = min(x, prev ?? x), hi = max(x, prev ?? x) + legW - 1
            let zone: ArtZone = y > footY - pawRows ? .paw : .coat
            for xx in lo...hi { cells.append((xx, y, zone)) }
            prev = x
        }
        if footY == Self.ground && part == .nearLeg {
            cells.append((footX + legW, footY, .paw))   // toes point forward
            if profile.fluffy { cells.append((footX - 1, footY, .paw)) }   // and a fluffy paw puffs out behind
        }
        // Crossing a leg on the same side: outline the one behind where they touch, so it reads as two legs, not a blob.
        for c in cells {
            for (nx, ny) in [(c.x - 1, c.y), (c.x + 1, c.y), (c.x, c.y + 1)] where g[nx, ny].part == part {
                if !cells.contains(where: { $0.x == nx && $0.y == ny }) { g.put(nx, ny, .outline) }
            }
        }
        for c in cells { g.put(c.x, c.y, part, c.zone) }
    }

    private func tail(_ g: inout ArtGrid, _ pose: TailPose, root: (x: Int, y: Int)) {
        let s = DogStamps.tail(profile.tail, pose: pose)
        stamp(&g, s, at: root, .tail, .tail)
    }

    /// Stamp origin for a head whose anchor lands on `p`.
    private func headOrigin(at p: (x: Int, y: Int)) -> (x: Int, y: Int) {
        (p.x - head.stamp.anchor.x, p.y - head.stamp.anchor.y)
    }

    private func drawHead(_ g: inout ArtGrid, origin o: (x: Int, y: Int), rig: FrameRig, asleep: Bool) {
        let standing = profile.ears == .pointy || profile.ears == .folded
        let point = standing ? head.topEar : head.sideEar
        let earPoint = (x: o.x + point.x, y: o.y + point.y)
        let ear = DogStamps.ear(profile.ears, fluffy: profile.fluffy, flowing: rig.ears == .flow)
        let teddy = profile.isTeddy
        if teddy {
            // Mostly hidden behind the head, so it skips the ear lag and always stays above the eyes.
            stamp(&g, DogStamps.puffFar, at: (o.x + head.puffFar.x, o.y + head.puffFar.y), .farEar, .ear)
        } else if standing {
            stamp(&g, ear, at: (earPoint.x - 2, earPoint.y), .farEar, .ear)
        }
        for (y, row) in head.stamp.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                let cell: (ArtZone, ArtInk)
                switch ch {
                case "f": cell = (.face, .none)
                case "m": cell = (.muzzle, .none)
                case "k": cell = (.chin, .none)
                case "n": cell = (.muzzle, .nose)
                case "e": cell = asleep ? (.face, .none) : (.face, rig.tired ? .lid : .eye)
                case "g": cell = asleep ? (.face, .none) : (.face, rig.tired ? .lid : .glint)
                case "E": cell = asleep ? (.face, .lid) : (.face, .eye)
                default: cell = (.coat, .none)
                }
                g.put(o.x + x, o.y + y, .head, cell.0, cell.1)
            }
        }
        if teddy {
            stamp(&g, DogStamps.puffNear, at: (o.x + head.puffNear.x, o.y + head.puffNear.y + rig.earDY), .ear, .ear)
            g.drawEarLine()
        } else {
            stamp(&g, ear, at: earPoint, .ear, .ear)
        }
        if rig.tongue {
            // Hangs from the mouth corner and flaps: wide on even frames, long on odd ones.
            let t = (x: o.x + head.mouth.x, y: o.y + head.mouth.y)
            g.put(t.x, t.y, .head, .muzzle, .tongueDark)
            g.put(t.x, t.y + 1, .head, .muzzle, .tongue)
            if rig.frame % 2 == 0 { g.put(t.x - 1, t.y + 1, .head, .muzzle, .tongue) } else { g.put(t.x, t.y + 2, .head, .muzzle, .tongue) }
        }
    }

    private func sweat(_ g: inout ArtGrid, head o: (x: Int, y: Int), phase: Int) {
        // Drops fly up and back off the head. A drop is drawn whole or not at all.
        let drops: [[(Int, Int)]] = [[(-3, -2)], [(-4, -3)], [(-5, -4), (0, -3)], [(-6, -3), (-1, -5)], [(-2, -6)], [(-3, -3)]]
        for (dx, dy) in drops[phase % drops.count] {
            let x = o.x + dx, y = o.y + dy
            guard g[x, y].part == .none, g[x, y + 1].part == .none else { continue }
            effect(&g, x, y, .sweat)
            effect(&g, x, y + 1, .sweatDark)
        }
    }

    private func sleepZ(_ g: inout ArtGrid, head o: (x: Int, y: Int), phase: Int) {
        let z = phase >= 2 ? DogStamps.zBig : DogStamps.zSmall
        let x0 = o.x + 7 + phase, w = z.rows[0].count
        // Float with one clear pixel above whatever is below the glyph (head outline, far ear).
        let below = (0..<g.height).first { y in (x0 - 1...x0 + w).contains { g[$0, y].part != .none } } ?? g.height
        let y0 = min(o.y - 4 - phase * 2, below - z.rows.count - 1)
        guard y0 >= 0 else { return }
        for (y, row) in z.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." { effect(&g, x0 + x, y0 + y, .zz) }
        }
    }

    private func effect(_ g: inout ArtGrid, _ x: Int, _ y: Int, _ ink: ArtInk) {
        if g[x, y].part == .none { g.put(x, y, .fx, .coat, ink) }
    }

    private func stamp(_ g: inout ArtGrid, _ s: Stamp, at p: (x: Int, y: Int), _ part: ArtPart, _ zone: ArtZone) {
        for (y, row) in s.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                g.put(p.x - s.anchor.x + x, p.y - s.anchor.y + y, part, zone)
            }
        }
    }

    private func lerp(_ a: Int, _ b: Int, _ i: Int, _ n: Int) -> Int {
        n <= 0 ? b : a + Int((Double((b - a) * i) / Double(n)).rounded())
    }
}
