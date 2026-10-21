import AppKit
import SwiftUI

/// What the 날씨 창문 draws: a crystal ball on a stand. Inside the glass, sky, ground and weather drawn in code and
/// seen through the ball's lens (OrbLens), the current character walking on the ground with a prop for the weather
/// (umbrella, knit hat, cloud balloon, little cloud, flashlight, sunglasses); over it the glass, then the stand's front
/// with its name plate. The props are pixel stamps placed at the character's head (PetWalker.anchor), so they fit any character.
/// Only the inside moves, as a pure function of the clock and only while WeatherWindow.animating; the stand and the
/// glass are WeatherOrbShell, outside the clock and the walker, so a step redraws neither.
struct WeatherSceneView: View {
    @ObservedObject var window: WeatherWindow
    @ObservedObject var service: WeatherService
    @StateObject private var walker = PetWalker()

    var body: some View {
        let size = WeatherFrame.size(window.sizeStep)
        let (c, r) = WeatherFrame.orb(size)
        let u = 2 * window.scale, d = size.width   // u: one art pixel
        let theme = window.theme
        let kind = service.scene().kind
        let temp = service.preview == nil ? service.current?.temperature : nil
        let december = window.seasonal && Calendar.current.component(.month, from: Date()) == 12
        let label = !window.showTemp ? nil : window.scale <= 0.5 ? temp.map { "\($0)°" } ?? kind.title : temp.map { "\($0)° \(kind.title)" } ?? kind.title
        ZStack(alignment: .topLeading) {
            WeatherOrbShell(c: c, r: r, u: u, d: d, theme: theme, label: label, december: december, front: false).equatable()
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !window.animating)) { tl in
                scene(s: 2 * r, u: u, now: tl.date)
            }
            .frame(width: 2 * r, height: 2 * r)
            .clipShape(Circle())
            .offset(x: c.x - r, y: c.y - r)
            WeatherOrbShell(c: c, r: r, u: u, d: d, theme: theme, label: label, december: december, front: true).equatable()
        }
        .frame(width: size.width, height: size.height)
        .onAppear { if walks { walker.start() } }
        .onChange(of: walks) { on in if on { walker.start() } else { walker.stop() } }
        .accessibilityHidden(true)   // WeatherHostView speaks for it
    }

    /// Lying at night and trembling in thunder stay put: the walker runs only for the walk pose.
    private var walks: Bool { window.animating && Self.pose(service.scene()) == .walk }

    static func pose(_ s: (kind: WeatherKind, night: Bool)) -> DogPose { s.kind == .thunder ? .exhausted : s.night ? .lying : .walk }

    /// The inside of the ball, an s x s square clipped round. The ground is flat here and bent by the lens, so the
    /// character's feet follow the bowed horizon.
    private func scene(s: CGFloat, u: CGFloat, now: Date) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        let still = !window.animating
        let (kind, night) = service.scene(now: now)
        let lens = OrbLens(s: s)
        let ground = s * 0.74
        let r = s / 2, dy = ground - r, walkRim = r * 0.86
        let half = (walkRim * walkRim - dy * dy).squareRoot()

        let cache = window.cache
        let sprite = cache?.imageSize ?? .zero
        let pose = Self.pose((kind, night))
        let walking = pose == .walk && !walker.paused && !still
        let all = cache?.frames(for: pose) ?? []
        let plays = (pose != .walk || walking) && !still
        let frames = walker.shown(plays ? all : Array(all.prefix(1)), flipped: walker.facingLeft && pose == .walk)
        let shake = kind == .thunder && !still ? sin(t * 50) * u * 0.5 : 0
        // Walks the flat chord, then stands where the lens puts that spot of ground (whole Retina pixels).
        let flat = r - half + CGFloat(walker.position) * max(0, 2 * half - sprite.width)
        let foot = lens(CGPoint(x: flat + sprite.width / 2, y: ground))
        let x = ((foot.x - sprite.width / 2 + shake) * 2).rounded() / 2
        // A click hops the character (and its prop) for 0.35 s.
        let hopAge = window.heartsAt.map { now.timeIntervalSince($0) } ?? 1
        let hop = !still && hopAge >= 0 && hopAge < 0.35 ? CGFloat(sin(hopAge / 0.35 * .pi)) * u * 4 : 0
        let top = ((foot.y - sprite.height - hop) * 2).rounded() / 2
        let anchor = walker.anchor(frames)
        let head = anchor.map { CGPoint(x: x + $0.x * sprite.width, y: top + $0.y * sprite.height) }
        let left = walker.facingLeft && pose == .walk
        let temp = service.preview == nil ? service.current?.temperature : nil
        let season = window.seasonal ? Calendar.current.component(.month, from: now) : nil
        let every = pose == .walk ? DogSpriteCache.frameDuration(for: .walk, cpu: 0.2) : DogSpriteCache.frameDuration(for: pose, cpu: 0.95)

        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in WeatherArt.back(ctx, s: s, u: u, kind: kind, night: night, t: t, ground: ground, lens: lens) }
            if let cache, !frames.isEmpty {
                FramesPlayer(frames: frames, size: sprite, every: every, smooth: cache.smooth)
                    .frame(width: sprite.width, height: sprite.height)
                    .offset(x: x, y: top)
            }
            if let head, let prop = WeatherProps.prop(kind, night: night, temp: temp) {
                let bob = still ? 0 : (sin(t * 2) * u).rounded()
                Image(decorative: prop.image, scale: 1).interpolation(.none).resizable()
                    .frame(width: CGFloat(prop.image.width) * u, height: CGFloat(prop.image.height) * u)
                    .scaleEffect(x: left && prop.faces ? -1 : 1, y: 1)
                    // Whole Retina pixels, like the character, so the stamp stays crisp.
                    .offset(x: ((head.x + (left && prop.faces ? -1 : 1) * prop.dx * u - CGFloat(prop.image.width) * u / 2) * 2).rounded() / 2,
                            y: ((head.y - CGFloat(prop.image.height) * u + prop.dy * u + (prop.bobs ? bob : 0)) * 2).rounded() / 2)
            }
            Canvas { ctx, _ in
                WeatherArt.front(ctx, s: s, u: u, kind: kind, night: night, t: t, ground: ground, still: still, season: season,
                                 beam: kind == .fog && !night ? head.map { ($0, left) } : nil, lens: lens)
                if let at = window.heartsAt, let head {
                    WeatherArt.hearts(ctx, at: head, u: u, age: still ? 0.3 : max(0, now.timeIntervalSince(at)), reaction: WeatherArt.reaction(kind, asleep: pose == .lying))
                }
                if !still { WeatherArt.shimmer(ctx, s: s, t: t) }
            }
        }
        .frame(width: s, height: s, alignment: .topLeading)
    }
}

/// The still parts: behind the ball the stand's foot (`front` false), over it the glass and the stand's front. Equatable
/// on its inputs only, so the walker's steps and the clock's ticks skip it.
struct WeatherOrbShell: View, Equatable {
    let c: CGPoint, r: CGFloat, u: CGFloat, d: CGFloat
    let theme: WeatherTheme, label: String?, december: Bool, front: Bool

    var body: some View {
        Canvas { ctx, _ in
            if front {
                WeatherArt.glass(ctx, c: c, r: r, u: u, theme: theme)
                WeatherArt.standFront(ctx, c: c, r: r, u: u, d: d, theme: theme, label: label, december: december)
            } else {
                WeatherArt.standBack(ctx, c: c, r: r, u: u, theme: theme)
            }
        }
    }
}

/// The ball's glass as a lens: the scene is drawn flat in an s x s square and seen bent, the middle a little bigger
/// and the rim squeezed (barrel), so the horizon bows and things shrink and slow toward the glass.
struct OrbLens {
    let s: CGFloat
    static let k: CGFloat = 0.22

    /// A distance from the centre over the radius, bent: the centre and the rim stay put, the middle grows by 1 + k.
    /// Past the rim it carries on straight at the rim's slope, so a line that leaves the glass stays one.
    static func bend(_ rho: CGFloat) -> CGFloat {
        rho <= 1 ? rho * (1 + k - k * rho * rho) : 1 + (rho - 1) * (1 - 2 * k)
    }

    /// Where the flat point `p` shows through the glass.
    func callAsFunction(_ p: CGPoint) -> CGPoint {
        let f = scale(p), r = s / 2
        return CGPoint(x: r + (p.x - r) * f, y: r + (p.y - r) * f)
    }

    /// How much a small thing at the flat point `p` grows (over 1) or shrinks.
    func scale(_ p: CGPoint) -> CGFloat {
        let r = s / 2, rho = hypot(p.x - r, p.y - r) / r
        return rho > 0.0001 ? Self.bend(rho) / rho : 1 + Self.k
    }
}

/// The weather props: pixel stamps in PetRoomArt's palette, outlined like the 펫 키우기 pieces.
/// `dx`, `dy` (art px) move the stamp's bottom centre from the top of the head; `faces` mirrors it with the character.
enum WeatherProps {
    struct Prop {
        let image: CGImage
        var dx: CGFloat = 0, dy: CGFloat = 0
        var faces = false
        var bobs = false
    }

    static let umbrella = Prop(image: PetRoomArt.sprite([
        "....rrrrr....",
        "..rrrrrrrrr..",
        ".rrrwrrrwrrr.",
        "rrrrrrrrrrrrr",
        "RRR.RRRRR.RRR",
        "......T......",
        "......T......",
    ]).image, dy: 2, bobs: true)   // the handle rests on the head

    static let knitHat = Prop(image: PetRoomArt.sprite([
        "....w....",
        "...www...",
        "..lllll..",
        ".lllllll.",
        "lLlLlLlLl",
    ]).image, dy: 4)

    static let balloon = Prop(image: PetRoomArt.sprite([
        "..www...",
        ".wwwwww.",
        "wwwwwwww",
        "wwwwwwww",
        ".WWWWWW.",
        "...k....",
        "...k....",
        "...k....",
        "...k....",
        "...k....",
    ]).image, dx: 4, dy: 2, faces: true, bobs: true)

    static let littleCloud = Prop(image: PetRoomArt.sprite([
        "..NNN.....",
        ".NNNNN.NN.",
        "NNNNNNNNNN",
        ".nnnnnnnn.",
    ]).image, dy: -3, bobs: true)

    static let sunglasses = Prop(image: PetRoomArt.sprite([
        "wk.wk",
        "kk.kk",
    ]).image, dy: 6, faces: true)

    static let flashlight = Prop(image: PetRoomArt.sprite([
        "nnnny",
        "Nnnny",
    ]).image, dx: 5, dy: 9, faces: true)

    /// `temp` (°C) dresses a sunny day: sunglasses from 28°, a knit hat at 3° and below.
    static func prop(_ kind: WeatherKind, night: Bool, temp: Int? = nil) -> Prop? {
        if !night, kind == .clear || kind == .partly, let temp {
            if temp >= 28 { return sunglasses }
            if temp <= 3 { return knitHat }
        }
        switch kind {
        case .rain: return umbrella
        case .snow: return night ? nil : knitHat   // asleep, the head sits under the sprite's z, so a worn hat would float
        case .cloudy: return littleCloud
        case .partly: return night ? nil : balloon
        case .fog: return night ? nil : flashlight
        case .clear, .thunder: return nil
        }
    }
}

/// 받침 색: the stand's pastels (`ring` the turned body, `bolt` its gems, `sill` and `sillHi` the name plate).
/// `ink` is the outline and the plate's words, at least 4.5:1 on `sill`.
enum WeatherTheme: String, CaseIterable {
    case cream, strawberry, mint, lavender, sky

    var label: String {
        switch self {
        case .cream: return L("크림")
        case .strawberry: return L("딸기우유")
        case .mint: return L("민트")
        case .lavender: return L("라벤더")
        case .sky: return L("하늘")
        }
    }

    var hexes: (ring: String, bolt: String, sill: String, sillHi: String, ink: String) {
        switch self {
        case .cream: return ("#F3E2C0", "#E39BA8", "#E8B88A", "#F3CFA6", "#5A3E36")
        case .strawberry: return ("#FFD6E0", "#F59AB5", "#FFB3C7", "#FFD0DC", "#7A3B4E")
        case .mint: return ("#CDEFE0", "#7FC4A8", "#9ED9BF", "#C2EAD7", "#285447")
        case .lavender: return ("#E4DAF7", "#A88FDB", "#CDBDF0", "#E0D6F7", "#4E3F78")
        case .sky: return ("#D3EAFB", "#7FB7E3", "#A9D3F2", "#CBE5F8", "#2F4F6E")
        }
    }
}

/// The drawing itself. The inside of the ball is an s x s square (y down) seen through `lens`; the glass and the stand
/// are drawn about the ball's centre `c` and radius `r` in window points. Particles are placed by a hash of their
/// index, so nothing is stored.
enum WeatherArt {
    static func color(_ hex: String, _ opacity: Double = 1) -> Color { Color(nsColor: RGBColor(hex: hex).nsColor).opacity(opacity) }

    /// 0..<1, the same for the same `i` and `salt`.
    static func rnd(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43_758.5453
        return v - v.rounded(.down)
    }

    static func sky(_ kind: WeatherKind, night: Bool) -> (String, String) {
        if night { return kind == .thunder ? ("#141A30", "#2B3352") : ("#1E2A4E", "#3D4B7A") }
        switch kind {
        case .clear: return ("#7EC8F2", "#CDEEFF")
        case .partly: return ("#93C4E6", "#DCEFFA")
        case .cloudy: return ("#A6B3C3", "#D8DEE6")
        case .fog: return ("#C4CAD3", "#E9EBEF")
        case .rain: return ("#7A92AC", "#B5C4D3")
        case .snow: return ("#B6C6D8", "#EEF3F8")
        case .thunder: return ("#4C5670", "#7A8298")
        }
    }

    /// A circle of radius `m` at the flat point `p`, as the lens shows it.
    private static func dot(_ lens: OrbLens, _ p: CGPoint, _ m: CGFloat) -> CGRect {
        let q = lens(p), k = m * lens.scale(p)
        return CGRect(x: q.x - k, y: q.y - k, width: k * 2, height: k * 2)
    }

    /// The flat horizontal line at `y` from `x0` to `x1`, bent by the lens.
    private static func bentLine(_ lens: OrbLens, y: CGFloat, from x0: CGFloat, to x1: CGFloat, steps: Int = 16) -> Path {
        var p = Path()
        for i in 0...steps {
            let q = lens(CGPoint(x: x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps), y: y))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }

    static func back(_ ctx: GraphicsContext, s: CGFloat, u: CGFloat, kind: WeatherKind, night: Bool, t: Double, ground: CGFloat, lens: OrbLens) {
        let (top, bottom) = sky(kind, night: night)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: s, height: s)),
                 with: .linearGradient(Gradient(colors: [color(top), color(bottom)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: s)))
        let open = kind == .clear || kind == .partly
        if night {
            for i in 0..<(open ? 14 : 4) {
                let a = 0.35 + 0.65 * abs(sin(t * 1.3 + Double(i) * 1.7))
                let p = lens(CGPoint(x: rnd(i, 1) * s, y: rnd(i, 2) * s * 0.5))
                ctx.fill(Path(CGRect(x: p.x, y: p.y, width: u * 0.8, height: u * 0.8)), with: .color(.white.opacity(a)))
            }
            if open {   // a crescent: a full moon less a bite, on the sun's side, clear of the glass highlight
                let full = dot(lens, CGPoint(x: s * 0.68, y: s * 0.26), s * 0.085), m = full.width / 2
                ctx.fill(Path(ellipseIn: full.insetBy(dx: -m * 1.2, dy: -m * 1.2)),
                         with: .radialGradient(Gradient(colors: [color("#FFF3C4", 0.28), color("#FFF3C4", 0)]),
                                               center: CGPoint(x: full.midX, y: full.midY), startRadius: m * 0.8, endRadius: m * 2.2))
                var lit = ctx
                lit.clip(to: Path(ellipseIn: full.offsetBy(dx: m * 0.55, dy: -m * 0.15)), options: .inverse)
                lit.fill(Path(ellipseIn: full), with: .color(color("#FFF3C4")))
            }
        } else if open {
            let sun = dot(lens, CGPoint(x: s * 0.68, y: s * 0.28), s * (kind == .clear ? 0.09 : 0.075)), m = sun.width / 2
            ctx.fill(Path(ellipseIn: sun.insetBy(dx: -m * 1.2, dy: -m * 1.2)),
                     with: .radialGradient(Gradient(colors: [color("#FFF0B0", 0.7), color("#FFE38A", 0)]),
                                           center: CGPoint(x: sun.midX, y: sun.midY), startRadius: m * 0.8, endRadius: m * 2.2))
            ctx.fill(Path(ellipseIn: sun), with: .color(color("#FFD15C")))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.minX + m * 0.35, y: sun.minY + m * 0.3, width: m * 0.7, height: m * 0.5)), with: .color(color("#FFF1B8", 0.8)))
            if kind == .clear {   // 햇살 조각: little four-point glints that come and go
                for i in 0..<7 {
                    let k = max(0, sin(t * 1.6 + Double(i) * 2.1))
                    guard k > 0.05 else { continue }
                    let p = lens(CGPoint(x: (0.12 + 0.76 * rnd(i, 3)) * s, y: (0.1 + 0.5 * rnd(i, 4)) * s))
                    ctx.fill(glint(at: p, a: u * 2 * k), with: .color(color("#FFF6D0", k)))
                }
            }
        }
        let clouds: (count: Int, hex: String, opacity: Double) = switch kind {
        case .partly: (2, "#FFFFFF", 0.95)
        case .cloudy: (3, "#EEF1F5", 0.95)
        case .rain: (3, "#8E9AAA", 1)
        case .thunder: (3, "#5E6577", 1)
        case .snow: (2, "#E3E8EF", 1)
        case .clear, .fog: (0, "#FFFFFF", 0)
        }
        for i in 0..<clouds.count {
            let w = s * (0.36 + 0.12 * rnd(i, 5))
            let span = s + w
            let x = (rnd(i, 6) * span + t * s * 0.012 * (1 + Double(i) * 0.4)).truncatingRemainder(dividingBy: span) - w
            let mid = CGPoint(x: x + w / 2, y: s * (0.16 + 0.12 * Double(i)) + w * 0.25)
            let q = lens(mid), k = w * lens.scale(mid)
            cloud(ctx, at: CGPoint(x: q.x - k / 2, y: q.y - k * 0.25), w: k, color: color(clouds.hex, night ? clouds.opacity * 0.5 : clouds.opacity))
        }
        // Ground: grass, wet grass with a puddle, or snow, up to the bowed horizon.
        let g: String = switch (kind, night) {
        case (.snow, false): "#F4F7FB"
        case (.snow, true): "#B8C2D8"
        case (.rain, false), (.thunder, false): "#86A97A"
        case (_, false): "#9FCF82"
        case (_, true): "#46604F"
        }
        let edge = bentLine(lens, y: ground - u, from: -s * 0.1, to: s * 1.1, steps: 24)
        var land = edge
        land.addLine(to: CGPoint(x: s * 1.2, y: s * 1.2))
        land.addLine(to: CGPoint(x: -s * 0.2, y: s * 1.2))
        land.closeSubpath()
        ctx.fill(land, with: .color(color(g)))
        // A darker band lower down: the ground curving away inside the ball.
        ctx.fill(land, with: .linearGradient(Gradient(colors: [.black.opacity(0), .black.opacity(night ? 0.18 : 0.12)]),
                                             startPoint: CGPoint(x: 0, y: ground), endPoint: CGPoint(x: 0, y: s)))
        ctx.stroke(edge, with: .color(.black.opacity(0.08)), lineWidth: u)
        if kind == .rain || kind == .thunder {
            let mid = CGPoint(x: s * 0.34, y: ground + s * 0.06), q = lens(mid), k = lens.scale(mid)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - s * 0.15 * k, y: q.y - s * 0.022 * k, width: s * 0.3 * k, height: s * 0.045 * k)),
                     with: .color(color("#A9C8E0", night ? 0.5 : 0.9)))
        }
    }

    /// A four-point star of reach `a` at `p`.
    static func glint(at p: CGPoint, a: CGFloat) -> Path {
        var star = Path()
        star.move(to: CGPoint(x: p.x, y: p.y - a)); star.addLine(to: CGPoint(x: p.x + a * 0.3, y: p.y - a * 0.3))
        star.addLine(to: CGPoint(x: p.x + a, y: p.y)); star.addLine(to: CGPoint(x: p.x + a * 0.3, y: p.y + a * 0.3))
        star.addLine(to: CGPoint(x: p.x, y: p.y + a)); star.addLine(to: CGPoint(x: p.x - a * 0.3, y: p.y + a * 0.3))
        star.addLine(to: CGPoint(x: p.x - a, y: p.y)); star.addLine(to: CGPoint(x: p.x - a * 0.3, y: p.y - a * 0.3))
        star.closeSubpath()
        return star
    }

    static func cloud(_ ctx: GraphicsContext, at p: CGPoint, w: CGFloat, color: Color) {
        var c = Path()
        c.addEllipse(in: CGRect(x: p.x, y: p.y + w * 0.18, width: w * 0.5, height: w * 0.32))
        c.addEllipse(in: CGRect(x: p.x + w * 0.22, y: p.y, width: w * 0.46, height: w * 0.42))
        c.addEllipse(in: CGRect(x: p.x + w * 0.5, y: p.y + w * 0.14, width: w * 0.5, height: w * 0.34))
        c.addRoundedRect(in: CGRect(x: p.x + w * 0.1, y: p.y + w * 0.24, width: w * 0.8, height: w * 0.24), cornerSize: CGSize(width: w * 0.1, height: w * 0.1))
        ctx.fill(c, with: .color(color))
    }

    /// In front of the character: rain and ripples, snow, fog bands, the flashlight's beam, lightning, then the motes
    /// that drift about inside the glass.
    static func front(_ ctx: GraphicsContext, s: CGFloat, u: CGFloat, kind: WeatherKind, night: Bool, t: Double, ground: CGFloat,
                      still: Bool, season: Int? = nil, beam: (CGPoint, Bool)?, lens: OrbLens) {
        switch kind {
        case .rain, .thunder:
            var drops = Path()
            for i in 0..<(kind == .thunder ? 30 : 24) {
                let fall = ground + s * 0.05
                let y = (t * Double(s) * (1 + 0.5 * rnd(i, 7)) + rnd(i, 8) * Double(fall)).truncatingRemainder(dividingBy: Double(fall)) - Double(u * 4)
                let x = rnd(i, 9) * s * 1.1
                drops.move(to: lens(CGPoint(x: x, y: y))); drops.addLine(to: lens(CGPoint(x: x - u * 1.2, y: y + u * 4)))
            }
            ctx.stroke(drops, with: .color(color("#DCEBFA", 0.85)), lineWidth: u * 0.6)
            for i in 0..<3 {
                let cycle = t * 0.7 + rnd(i, 10)
                let phase = cycle - cycle.rounded(.down)
                let mid = CGPoint(x: (0.2 + 0.6 * rnd(i + Int(cycle) * 7, 11)) * s, y: ground + u * (3 + CGFloat(i % 2) * 3))
                let q = lens(mid), w = u * (2 + 9 * phase) * lens.scale(mid)
                ctx.stroke(Path(ellipseIn: CGRect(x: q.x - w / 2, y: q.y, width: w, height: w * 0.3)),
                           with: .color(.white.opacity((1 - phase) * 0.7)), lineWidth: u * 0.5)
            }
        case .snow:
            for i in 0..<28 {
                let y = (t * Double(s) * (0.1 + 0.08 * rnd(i, 12)) + rnd(i, 13) * Double(ground)).truncatingRemainder(dividingBy: Double(ground))
                let x = rnd(i, 14) * s + sin(t * 1.1 + Double(i)) * u * 3, k = u * (0.8 + 0.6 * rnd(i, 15))
                let q = lens(CGPoint(x: x, y: y))
                ctx.fill(Path(CGRect(x: q.x, y: q.y, width: k, height: k)), with: .color(.white.opacity(0.95)))
            }
        case .fog:
            if let (head, left) = beam {
                var cone = Path()
                let from = CGPoint(x: head.x + (left ? -1 : 1) * u * 7, y: head.y + u * 7)
                cone.move(to: from)
                cone.addLine(to: CGPoint(x: from.x + (left ? -1 : 1) * s * 0.4, y: from.y - s * 0.1))
                cone.addLine(to: CGPoint(x: from.x + (left ? -1 : 1) * s * 0.4, y: from.y + s * 0.12))
                cone.closeSubpath()
                ctx.fill(cone, with: .color(color("#FFF1A8", 0.35)))
            }
            for i in 0..<3 {
                let y = s * (0.42 + 0.14 * CGFloat(i)), x = CGFloat(sin(t * 0.25 + Double(i) * 2)) * s * 0.12 - s * 0.1
                ctx.stroke(bentLine(lens, y: y, from: x, to: x + s * 1.2, steps: 12), with: .color(.white.opacity(night ? 0.2 : 0.42)),
                           style: StrokeStyle(lineWidth: s * 0.06, lineCap: .round))
            }
        case .clear, .partly, .cloudy:
            // 계절 장식: petals in March and April, leaves in October and November, drifting down with a sway.
            guard let season, [3, 4, 10, 11].contains(season) else { break }
            let leaves = season >= 10
            for i in 0..<10 {
                let y = (t * Double(s) * (0.06 + 0.03 * rnd(i, 17)) + rnd(i, 18) * Double(ground)).truncatingRemainder(dividingBy: Double(ground))
                let x = rnd(i, 19) * s + sin(t * 0.9 + Double(i)) * u * 5
                var p = ctx
                let q = lens(CGPoint(x: x, y: y))
                p.translateBy(x: q.x, y: q.y)
                if leaves {
                    p.rotate(by: .radians(sin(t + Double(i))))
                    p.fill(Path(CGRect(x: -u, y: -u, width: u * 2, height: u * 2)), with: .color(color(i % 2 == 0 ? "#F2A65A" : "#E2763F")))
                } else {
                    p.fill(Path(ellipseIn: CGRect(x: -u, y: -u * 0.75, width: u * 2, height: u * 1.5)), with: .color(color("#FFC4D6")))
                }
            }
        }
        motes(ctx, s: s, u: u, kind: kind, night: night, t: t, lens: lens)
        guard kind == .thunder, !still else { return }
        let period = 4.5, k = (t / period).rounded(.down), ph = t - k * period
        guard ph < 0.35 else { return }
        ctx.fill(Path(CGRect(x: 0, y: 0, width: s, height: s)), with: .color(.white.opacity((0.35 - ph) / 0.35 * 0.55)))
        let x0 = (0.3 + 0.4 * rnd(Int(k), 16)) * s
        var bolt = Path()
        bolt.move(to: lens(CGPoint(x: x0, y: s * 0.14)))
        bolt.addLine(to: lens(CGPoint(x: x0 - s * 0.05, y: s * 0.28)))
        bolt.addLine(to: lens(CGPoint(x: x0 + s * 0.02, y: s * 0.3)))
        bolt.addLine(to: lens(CGPoint(x: x0 - s * 0.04, y: s * 0.46)))
        ctx.stroke(bolt, with: .color(color("#FFE45C")), style: StrokeStyle(lineWidth: u * 1.2, lineCap: .round, lineJoin: .round))
    }

    /// 구슬 속 반짝이: a few motes circling slowly inside the glass like a settling snow globe, tinted for the sky
    /// (gold in the sun, pale blue in the rain and at night). None in fog, where the bands are enough, nor on a clear
    /// day, whose sun glints already fill the sky.
    static func motes(_ ctx: GraphicsContext, s: CGFloat, u: CGFloat, kind: WeatherKind, night: Bool, t: Double, lens: OrbLens) {
        guard kind != .fog, kind != .clear || night else { return }
        let hex: String = switch (kind, night) {
        case (_, true): "#DDE6FF"
        case (.clear, _), (.partly, _): "#FFF2B0"
        case (.rain, _): "#E3F1FF"
        case (.thunder, _): "#FFE45C"
        case (.cloudy, _), (.snow, _), (.fog, _): "#FFFFFF"
        }
        let r = s / 2
        for i in 0..<6 {
            let a = t * 0.12 * (0.6 + rnd(i, 21)) + rnd(i, 22) * 2 * .pi, rho = r * (0.3 + 0.5 * rnd(i, 23))
            let p = lens(CGPoint(x: r + CGFloat(cos(a)) * rho, y: r * 0.9 + CGFloat(sin(a)) * rho * 0.6 + CGFloat(sin(t * 0.8 + Double(i))) * u * 2))
            let k = 0.4 + 0.6 * abs(sin(t * 1.5 + Double(i) * 1.9))
            ctx.fill(glint(at: p, a: u * 1.3), with: .color(color(hex, 0.75 * k)))
        }
    }

    /// 반짝임: every 9 s a soft band of light sweeps across the glass.
    static func shimmer(_ ctx: GraphicsContext, s: CGFloat, t: Double) {
        let ph = t.truncatingRemainder(dividingBy: 9) / 1.4
        guard ph < 1 else { return }
        var c = ctx
        c.translateBy(x: -s * 0.3 + CGFloat(ph) * s * 1.6, y: 0)
        c.rotate(by: .degrees(22))
        let band = CGRect(x: -s * 0.09, y: -s * 0.5, width: s * 0.18, height: s * 2)
        c.fill(Path(band), with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0)]),
                                                 startPoint: CGPoint(x: band.minX, y: 0), endPoint: CGPoint(x: band.maxX, y: 0)))
    }

    static let star = PetRoomArt.sprite([".y.", "yYy", ".y."]).image

    /// Points round the ellipse in `e` from `a0` to `a1` degrees (y down: 90 is the front, 270 the back).
    static func arc(_ e: CGRect, _ a0: Double, _ a1: Double, into p: inout Path, steps: Int = 24) {
        for i in 0...steps {
            let a = (a0 + (a1 - a0) * Double(i) / Double(steps)) * .pi / 180
            let q = CGPoint(x: e.midX + e.width / 2 * CGFloat(cos(a)), y: e.midY + e.height / 2 * CGFloat(sin(a)))
            if i == 0 && p.isEmpty { p.move(to: q) } else { p.addLine(to: q) }
        }
    }

    /// A turned piece between two ellipses, `top` above `bottom`: over the top's back, down the side, round the
    /// bottom's front.
    static func turned(_ top: CGRect, _ bottom: CGRect) -> Path {
        var p = Path()
        arc(top, 180, 360, into: &p)
        arc(bottom, 0, 180, into: &p)
        p.closeSubpath()
        return p
    }

    /// Fills `path` in `hex` and rounds it like a lathe-turned piece: lit on the left, in shade on the right.
    static func shade(_ ctx: GraphicsContext, _ path: Path, hex: String) {
        let b = path.boundingRect
        ctx.fill(path, with: .color(color(hex)))
        ctx.fill(path, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(0.35), location: 0), .init(color: .white.opacity(0.6), location: 0.2),
            .init(color: .white.opacity(0), location: 0.42), .init(color: .black.opacity(0), location: 0.58),
            .init(color: .black.opacity(0.24), location: 1),
        ]), startPoint: CGPoint(x: b.minX, y: b.midY), endPoint: CGPoint(x: b.maxX, y: b.midY)))
    }

    /// The stand's ellipses about the ball (c, r): the collar the ball sits in, the neck's foot, and the foot's top and bottom.
    static func standRings(c: CGPoint, r: CGFloat) -> (collar: CGRect, neck: CGRect, footTop: CGRect, footBottom: CGRect) {
        func e(_ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect { CGRect(x: c.x - r * rx, y: c.y + r * (y - ry), width: r * rx * 2, height: r * ry * 2) }
        return (e(0.78, 0.56, 0.13), e(1.06, 0.66, 0.15), e(1.06, 0.84, 0.19), e(1.22, 0.84, 0.19))
    }

    /// Behind the ball: its soft contact shadow and the stand's wide foot in the theme, three gems round its front.
    static func standBack(_ ctx: GraphicsContext, c: CGPoint, r: CGFloat, u: CGFloat, theme: WeatherTheme = .cream) {
        let hex = theme.hexes, ink = color(hex.ink)
        let rings = standRings(c: c, r: r)
        var shadow = ctx
        shadow.translateBy(x: c.x, y: c.y + r * 1.4)
        shadow.scaleBy(x: 1, y: 0.13)
        shadow.fill(Path(ellipseIn: CGRect(x: -r * 1.02, y: -r * 1.02, width: r * 2.04, height: r * 2.04)),
                    with: .radialGradient(Gradient(colors: [.black.opacity(0.34), .black.opacity(0.14), .black.opacity(0)]),
                                          center: .zero, startRadius: 0, endRadius: r * 1.02))
        let foot = turned(rings.footTop, rings.footBottom)
        shade(ctx, foot, hex: hex.ring)
        ctx.fill(Path(ellipseIn: rings.footTop), with: .color(color(hex.ring)))
        ctx.fill(Path(ellipseIn: rings.footTop), with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .white.opacity(0.15)]),
                                                                        startPoint: CGPoint(x: rings.footTop.minX, y: rings.footTop.minY),
                                                                        endPoint: CGPoint(x: rings.footTop.maxX, y: rings.footTop.maxY)))
        var rim = Path()
        arc(rings.footTop, 180, 0, into: &rim)
        ctx.stroke(rim, with: .color(ink.opacity(0.3)), lineWidth: u * 0.5)
        ctx.stroke(foot, with: .color(ink.opacity(0.7)), lineWidth: u * 0.5)
        // Gems on the foot's band: the old frame's heart bolts, set in a row.
        for k in [-0.55, 0, 0.55] as [CGFloat] {
            let x = c.x + k * r, rx = rings.footTop.width / 2
            let y = rings.footTop.midY + rings.footTop.height / 2 * (1 - (k * r / rx) * (k * r / rx)).squareRoot() + r * 0.085
            ctx.draw(Text("♥").font(.system(size: u * 3.4, weight: .black)).foregroundColor(color(hex.bolt)), at: CGPoint(x: x, y: y))
            ctx.fill(Path(ellipseIn: CGRect(x: x - u * 0.9, y: y - u * 1.1, width: u * 0.7, height: u * 0.5)), with: .color(.white.opacity(0.8)))
        }
    }

    /// The glass over the scene: thicker toward the rim and away from the light (top left), light gathered in the far
    /// side, a rim light, the room's highlights and a thin outline in the theme's ink, so the ball reads as one solid
    /// thing on any desktop.
    static func glass(_ ctx: GraphicsContext, c: CGPoint, r: CGFloat, u: CGFloat, theme: WeatherTheme = .cream) {
        let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), ball = Path(ellipseIn: box)
        ctx.fill(ball, with: .radialGradient(Gradient(stops: [.init(color: .black.opacity(0), location: 0.6), .init(color: .black.opacity(0.3), location: 1)]),
                                             center: CGPoint(x: c.x - r * 0.18, y: c.y - r * 0.22), startRadius: 0, endRadius: r * 1.22))
        // Caustic: light through the ball gathers in a crescent at the bottom right.
        var caustic = ctx
        caustic.clip(to: ball)
        caustic.clip(to: Path(ellipseIn: box.offsetBy(dx: -r * 0.1, dy: -r * 0.08)), options: .inverse)
        caustic.fill(ball, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.55)]),
                                                 startPoint: c, endPoint: CGPoint(x: c.x + r * 0.7, y: c.y + r * 0.7)))
        ctx.stroke(Path(ellipseIn: box.insetBy(dx: u * 0.8, dy: u * 0.8)),
                   with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0.95), location: 0), .init(color: .white.opacity(0.08), location: 0.45),
                                                          .init(color: .white.opacity(0.08), location: 0.6), .init(color: .white.opacity(0.6), location: 1)]),
                                         startPoint: CGPoint(x: box.minX, y: box.minY), endPoint: CGPoint(x: box.maxX, y: box.maxY)),
                   lineWidth: u * 1.4)
        // The room's window, soft and big at the top left, with a sharp spark and a second small one below it.
        var spec = ctx
        spec.translateBy(x: c.x - r * 0.38, y: c.y - r * 0.5)
        spec.rotate(by: .degrees(-34))
        let e = CGRect(x: -r * 0.34, y: -r * 0.16, width: r * 0.68, height: r * 0.32)
        spec.fill(Path(ellipseIn: e), with: .linearGradient(Gradient(colors: [.white.opacity(0.8), .white.opacity(0.04)]),
                                                            startPoint: CGPoint(x: 0, y: e.minY), endPoint: CGPoint(x: 0, y: e.maxY)))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.68, y: c.y - r * 0.16, width: r * 0.1, height: r * 0.1)), with: .color(.white.opacity(0.85)))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.62, y: c.y + r * 0.0, width: r * 0.05, height: r * 0.05)), with: .color(.white.opacity(0.7)))
        var side = Path()
        arc(box.insetBy(dx: r * 0.12, dy: r * 0.12), -40, -8, into: &side, steps: 8)
        ctx.stroke(side, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: u * 1.2, lineCap: .round))
        ctx.stroke(Path(ellipseIn: box.insetBy(dx: u * 0.25, dy: u * 0.25)), with: .color(color(theme.hexes.ink, 0.6)), lineWidth: u * 0.5)
    }

    /// In front of the ball: the stand's neck rising round the glass, its rim, and the name plate ("18° 비") in the
    /// theme's ink. `december` sets a little star on top of the ball.
    static func standFront(_ ctx: GraphicsContext, c: CGPoint, r: CGFloat, u: CGFloat, d: CGFloat, theme: WeatherTheme = .cream,
                           label: String?, december: Bool = false) {
        let hex = theme.hexes, ink = color(hex.ink)
        let rings = standRings(c: c, r: r)
        // Only the cup's front shows: its opening lies inside the ball's outline, so the back rim is hidden behind the glass.
        var neck = Path()
        arc(rings.collar, 0, 180, into: &neck)
        arc(rings.neck, 180, 0, into: &neck)
        neck.closeSubpath()
        // Where the ball meets the lip, a short contact shadow on the glass, just above the front rim.
        var contact = ctx
        contact.clip(to: Path(CGRect(x: rings.collar.minX, y: rings.collar.midY, width: rings.collar.width, height: rings.collar.height)))
        contact.fill(Path(ellipseIn: rings.collar), with: .linearGradient(Gradient(colors: [.black.opacity(0), .black.opacity(0.25)]),
                                                                          startPoint: CGPoint(x: c.x, y: rings.collar.midY), endPoint: CGPoint(x: c.x, y: rings.collar.maxY)))
        shade(ctx, neck, hex: hex.ring)
        ctx.stroke(neck, with: .color(ink.opacity(0.7)), lineWidth: u * 0.5)
        var lip = Path()
        arc(rings.collar, 180, 0, into: &lip)
        ctx.stroke(lip, with: .color(.white.opacity(0.7)), lineWidth: u * 1.3)
        ctx.stroke(lip, with: .color(ink.opacity(0.7)), lineWidth: u * 0.5)

        let size = max(8, d * 0.06)
        let text = label.map { ctx.resolve(Text($0).font(.system(size: size, weight: .heavy, design: .rounded)).foregroundColor(color(hex.ink))) }
        let measured = text?.measure(in: CGSize(width: d, height: d)) ?? .zero
        let w = min(max(measured.width + size, r * 0.6), r * 1.3), h = max(r * 0.2, measured.height + 2)
        let plate = CGRect(x: c.x - w / 2, y: c.y + r * 1.06 - h / 2, width: w, height: h)
        ctx.fill(Path(roundedRect: plate, cornerRadius: min(h / 2, u * 2)), with: .color(color(hex.sill)))
        ctx.fill(Path(roundedRect: CGRect(x: plate.minX + u, y: plate.minY + u * 0.6, width: plate.width - u * 2, height: max(u * 0.8, h * 0.18)),
                      cornerRadius: u * 0.5), with: .color(color(hex.sillHi)))
        ctx.stroke(Path(roundedRect: plate, cornerRadius: min(h / 2, u * 2)), with: .color(ink), lineWidth: u * 0.5)
        if let text { ctx.draw(text, at: CGPoint(x: plate.midX, y: plate.midY + 0.5)) }

        if december {
            let k = CGFloat(star.width) * u
            ctx.draw(Image(decorative: star, scale: 1).interpolation(.none), in: CGRect(x: c.x - k / 2, y: c.y - r - k / 2 + u, width: k, height: k))
        }
    }

    /// What a click floats up for this sky: three marks and their colour. Asleep, little z's.
    static func reaction(_ kind: WeatherKind, asleep: Bool) -> (marks: [String], hex: String) {
        if asleep { return (["z", "Z", "z"], "#B7C4F5") }
        let m: [String] = switch kind {
        case .clear: ["♥", "✦", "♥"]
        case .partly, .cloudy: ["♥", "☁\u{FE0E}", "♥"]
        case .rain: ["♪", "♥", "♪"]
        case .snow: ["❄\u{FE0E}", "♥", "❄\u{FE0E}"]
        case .fog: ["♥", "?", "♥"]
        case .thunder: ["!", "♥", "!"]
        }
        return (m, "#F07C9A")
    }

    /// A click: three marks float up from the head and fade within 1.2 s.
    static func hearts(_ ctx: GraphicsContext, at head: CGPoint, u: CGFloat, age: TimeInterval,
                       reaction: (marks: [String], hex: String) = (["♥", "♥", "♥"], "#F07C9A")) {
        guard age < 1.2 else { return }
        for (i, mark) in reaction.marks.enumerated() {
            let p = CGPoint(x: head.x + CGFloat(i - 1) * u * 5, y: head.y - u * (4 + CGFloat(i % 2) * 2) - CGFloat(age) * u * 10)
            ctx.draw(Text(mark).font(.system(size: u * 5, weight: .heavy, design: .rounded)).foregroundColor(color(reaction.hex, 1 - age / 1.2)), at: p)
        }
    }
}
