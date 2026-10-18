import AppKit
import SwiftUI

/// What the 날씨 창문 draws: sky, ground and weather drawn in code, the current character walking on the ground with a
/// prop for the weather (umbrella, knit hat, cloud balloon, little cloud, flashlight), then the round frame and sill.
/// The props are pixel stamps placed at the character's head (PetWalker.anchor), so they fit any character.
/// Everything moves as a pure function of the clock, and only while WeatherWindow.animating.
struct WeatherSceneView: View {
    @ObservedObject var window: WeatherWindow
    @ObservedObject var service: WeatherService
    @StateObject private var walker = PetWalker()

    var body: some View {
        let size = WeatherFrame.size(window.sizeStep)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !window.animating)) { tl in
            scene(size: size, now: tl.date)
        }
        .frame(width: size.width, height: size.height)
        .onAppear { if walks { walker.start() } }
        .onChange(of: walks) { on in if on { walker.start() } else { walker.stop() } }
        .accessibilityHidden(true)   // WeatherHostView speaks for it
    }

    /// Lying at night and trembling in thunder stay put: the walker runs only for the walk pose.
    private var walks: Bool { window.animating && Self.pose(service.scene()) == .walk }

    static func pose(_ s: (kind: WeatherKind, night: Bool)) -> DogPose { s.kind == .thunder ? .exhausted : s.night ? .lying : .walk }

    private func scene(size: CGSize, now: Date) -> some View {
        let d = size.width, u = 2 * window.scale   // u: one art pixel
        let t = now.timeIntervalSinceReferenceDate
        let still = !window.animating
        let (kind, night) = service.scene(now: now)
        let ring = d * 0.06
        let ground = d * 0.8
        let r = d / 2 - ring, dy = ground - d / 2
        let half = (r * r - dy * dy).squareRoot()

        let cache = window.cache
        let sprite = cache?.imageSize ?? .zero
        let pose = Self.pose((kind, night))
        let walking = pose == .walk && !walker.paused && !still
        let all = cache?.frames(for: pose) ?? []
        let plays = (pose != .walk || walking) && !still
        let frames = walker.shown(plays ? all : Array(all.prefix(1)), flipped: walker.facingLeft && pose == .walk)
        let shake = kind == .thunder && !still ? sin(t * 50) * u * 0.5 : 0
        let x = d / 2 - half + CGFloat(walker.position) * max(0, 2 * half - sprite.width) + shake
        let top = ground - sprite.height
        let anchor = walker.anchor(frames)
        let head = anchor.map { CGPoint(x: x + $0.x * sprite.width, y: top + $0.y * sprite.height) }
        let left = walker.facingLeft && pose == .walk
        let every = pose == .walk ? DogSpriteCache.frameDuration(for: .walk, cpu: 0.2) : DogSpriteCache.frameDuration(for: pose, cpu: 0.95)

        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in WeatherArt.back(ctx, d: d, u: u, kind: kind, night: night, t: t, ground: ground) }
                if let cache, !frames.isEmpty {
                    FramesPlayer(frames: frames, size: sprite, every: every, smooth: cache.smooth)
                        .frame(width: sprite.width, height: sprite.height)
                        .offset(x: x, y: top)
                }
                if let head, let prop = WeatherProps.prop(kind, night: night) {
                    let bob = still ? 0 : (sin(t * 2) * u).rounded()
                    Image(decorative: prop.image, scale: 1).interpolation(.none).resizable()
                        .frame(width: CGFloat(prop.image.width) * u, height: CGFloat(prop.image.height) * u)
                        .scaleEffect(x: left && prop.faces ? -1 : 1, y: 1)
                        .offset(x: head.x + (left && prop.faces ? -1 : 1) * prop.dx * u - CGFloat(prop.image.width) * u / 2,
                                y: head.y - CGFloat(prop.image.height) * u + prop.dy * u + (prop.bobs ? bob : 0))
                }
                Canvas { ctx, _ in
                    WeatherArt.front(ctx, d: d, u: u, kind: kind, night: night, t: t, ground: ground, still: still,
                                     beam: kind == .fog && !night ? head.map { ($0, left) } : nil)
                }
            }
            .frame(width: d, height: d)
            .clipShape(Circle().inset(by: ring * 0.5))
            Canvas { ctx, _ in
                WeatherArt.frame(ctx, d: d, u: u, ring: ring)
                if let at = window.heartsAt, let head {
                    WeatherArt.hearts(ctx, at: head, u: u, age: still ? 0.3 : max(0, now.timeIntervalSince(at)))
                }
            }
        }
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

    static let flashlight = Prop(image: PetRoomArt.sprite([
        "nnnny",
        "Nnnny",
    ]).image, dx: 5, dy: 9, faces: true)

    static func prop(_ kind: WeatherKind, night: Bool) -> Prop? {
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

/// The drawing itself, in a d x d square (y down). Particles are placed by a hash of their index, so nothing is stored.
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

    static func back(_ ctx: GraphicsContext, d: CGFloat, u: CGFloat, kind: WeatherKind, night: Bool, t: Double, ground: CGFloat) {
        let (top, bottom) = sky(kind, night: night)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: d, height: d)),
                 with: .linearGradient(Gradient(colors: [color(top), color(bottom)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: d)))
        let open = kind == .clear || kind == .partly
        if night {
            for i in 0..<(open ? 14 : 4) {
                let a = 0.35 + 0.65 * abs(sin(t * 1.3 + Double(i) * 1.7))
                ctx.fill(Path(CGRect(x: rnd(i, 1) * d, y: rnd(i, 2) * d * 0.5, width: u * 0.8, height: u * 0.8)), with: .color(.white.opacity(a)))
            }
            if open {   // a crescent: a full moon less a bite
                let c = CGPoint(x: d * 0.3, y: d * 0.26), m = d * 0.08
                var lit = ctx
                lit.clip(to: Path(ellipseIn: CGRect(x: c.x - m * 0.45, y: c.y - m * 1.15, width: m * 2, height: m * 2)), options: .inverse)
                lit.fill(Path(ellipseIn: CGRect(x: c.x - m, y: c.y - m, width: m * 2, height: m * 2)), with: .color(color("#FFF3C4")))
            }
        } else if open {
            let c = CGPoint(x: d * 0.7, y: d * 0.27), s = d * (kind == .clear ? 0.085 : 0.07)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - s * 1.8, y: c.y - s * 1.8, width: s * 3.6, height: s * 3.6)), with: .color(color("#FFE38A", 0.3)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2)), with: .color(color("#FFD15C")))
            if kind == .clear {   // 햇살 조각: little four-point glints that come and go
                for i in 0..<7 {
                    let k = max(0, sin(t * 1.6 + Double(i) * 2.1))
                    guard k > 0.05 else { continue }
                    let p = CGPoint(x: (0.12 + 0.76 * rnd(i, 3)) * d, y: (0.1 + 0.5 * rnd(i, 4)) * d), a = u * 2 * k
                    var star = Path()
                    star.move(to: CGPoint(x: p.x, y: p.y - a)); star.addLine(to: CGPoint(x: p.x + a * 0.3, y: p.y - a * 0.3))
                    star.addLine(to: CGPoint(x: p.x + a, y: p.y)); star.addLine(to: CGPoint(x: p.x + a * 0.3, y: p.y + a * 0.3))
                    star.addLine(to: CGPoint(x: p.x, y: p.y + a)); star.addLine(to: CGPoint(x: p.x - a * 0.3, y: p.y + a * 0.3))
                    star.addLine(to: CGPoint(x: p.x - a, y: p.y)); star.addLine(to: CGPoint(x: p.x - a * 0.3, y: p.y - a * 0.3))
                    star.closeSubpath()
                    ctx.fill(star, with: .color(color("#FFF6D0", k)))
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
            let w = d * (0.34 + 0.12 * rnd(i, 5))
            let span = d + w
            let x = (rnd(i, 6) * span + t * d * 0.012 * (1 + Double(i) * 0.4)).truncatingRemainder(dividingBy: span) - w
            cloud(ctx, at: CGPoint(x: x, y: d * (0.12 + 0.11 * Double(i))), w: w,
                  color: color(clouds.hex, night ? clouds.opacity * 0.5 : clouds.opacity))
        }
        // Ground: grass, wet grass with a puddle, or snow.
        let g: String = switch (kind, night) {
        case (.snow, false): "#F4F7FB"
        case (.snow, true): "#B8C2D8"
        case (.rain, false), (.thunder, false): "#86A97A"
        case (_, false): "#9FCF82"
        case (_, true): "#46604F"
        }
        ctx.fill(Path(CGRect(x: 0, y: ground - u, width: d, height: d - ground + u)), with: .color(color(g)))
        ctx.fill(Path(CGRect(x: 0, y: ground - u, width: d, height: u)), with: .color(.black.opacity(0.08)))
        if kind == .rain || kind == .thunder {
            ctx.fill(Path(ellipseIn: CGRect(x: d * 0.18, y: ground + d * 0.04, width: d * 0.3, height: d * 0.045)), with: .color(color("#A9C8E0", night ? 0.5 : 0.9)))
        }
    }

    static func cloud(_ ctx: GraphicsContext, at p: CGPoint, w: CGFloat, color: Color) {
        var c = Path()
        c.addEllipse(in: CGRect(x: p.x, y: p.y + w * 0.18, width: w * 0.5, height: w * 0.32))
        c.addEllipse(in: CGRect(x: p.x + w * 0.22, y: p.y, width: w * 0.46, height: w * 0.42))
        c.addEllipse(in: CGRect(x: p.x + w * 0.5, y: p.y + w * 0.14, width: w * 0.5, height: w * 0.34))
        c.addRoundedRect(in: CGRect(x: p.x + w * 0.1, y: p.y + w * 0.24, width: w * 0.8, height: w * 0.24), cornerSize: CGSize(width: w * 0.1, height: w * 0.1))
        ctx.fill(c, with: .color(color))
    }

    /// In front of the character: rain and ripples, snow, fog bands, the flashlight's beam, lightning.
    static func front(_ ctx: GraphicsContext, d: CGFloat, u: CGFloat, kind: WeatherKind, night: Bool, t: Double, ground: CGFloat,
                      still: Bool, beam: (CGPoint, Bool)?) {
        switch kind {
        case .rain, .thunder:
            var drops = Path()
            for i in 0..<(kind == .thunder ? 30 : 24) {
                let fall = ground + d * 0.05
                let y = (t * Double(d) * (1 + 0.5 * rnd(i, 7)) + rnd(i, 8) * Double(fall)).truncatingRemainder(dividingBy: Double(fall)) - Double(u * 4)
                let x = rnd(i, 9) * d * 1.1
                drops.move(to: CGPoint(x: x, y: y)); drops.addLine(to: CGPoint(x: x - u * 1.2, y: y + u * 4))
            }
            ctx.stroke(drops, with: .color(color("#DCEBFA", 0.85)), lineWidth: u * 0.6)
            for i in 0..<3 {
                let cycle = t * 0.7 + rnd(i, 10)
                let phase = cycle - cycle.rounded(.down)
                let cx = (0.15 + 0.7 * rnd(i + Int(cycle) * 7, 11)) * d, w = u * (2 + 9 * phase)
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - w / 2, y: ground + u * (3 + CGFloat(i % 2) * 3), width: w, height: w * 0.3)),
                           with: .color(.white.opacity((1 - phase) * 0.7)), lineWidth: u * 0.5)
            }
        case .snow:
            for i in 0..<28 {
                let y = (t * Double(d) * (0.1 + 0.08 * rnd(i, 12)) + rnd(i, 13) * Double(ground)).truncatingRemainder(dividingBy: Double(ground))
                let x = rnd(i, 14) * d + sin(t * 1.1 + Double(i)) * u * 3, s = u * (0.8 + 0.6 * rnd(i, 15))
                ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(0.95)))
            }
        case .fog:
            if let (head, left) = beam {
                var cone = Path()
                let from = CGPoint(x: head.x + (left ? -1 : 1) * u * 7, y: head.y + u * 7)
                cone.move(to: from)
                cone.addLine(to: CGPoint(x: from.x + (left ? -1 : 1) * d * 0.4, y: from.y - d * 0.1))
                cone.addLine(to: CGPoint(x: from.x + (left ? -1 : 1) * d * 0.4, y: from.y + d * 0.12))
                cone.closeSubpath()
                ctx.fill(cone, with: .color(color("#FFF1A8", 0.35)))
            }
            for i in 0..<3 {
                let y = d * (0.42 + 0.14 * CGFloat(i)), x = CGFloat(sin(t * 0.25 + Double(i) * 2)) * d * 0.12 - d * 0.1
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: d * 1.2, height: d * 0.06), cornerRadius: d * 0.03),
                         with: .color(.white.opacity(night ? 0.2 : 0.42)))
            }
        case .clear, .partly, .cloudy:
            break
        }
        guard kind == .thunder, !still else { return }
        let period = 4.5, k = (t / period).rounded(.down), ph = t - k * period
        guard ph < 0.35 else { return }
        ctx.fill(Path(CGRect(x: 0, y: 0, width: d, height: d)), with: .color(.white.opacity((0.35 - ph) / 0.35 * 0.55)))
        let x0 = (0.25 + 0.5 * rnd(Int(k), 16)) * d
        var bolt = Path()
        bolt.move(to: CGPoint(x: x0, y: d * 0.12))
        bolt.addLine(to: CGPoint(x: x0 - d * 0.05, y: d * 0.26))
        bolt.addLine(to: CGPoint(x: x0 + d * 0.02, y: d * 0.28))
        bolt.addLine(to: CGPoint(x: x0 - d * 0.04, y: d * 0.44))
        ctx.stroke(bolt, with: .color(color("#FFE45C")), style: StrokeStyle(lineWidth: u * 1.2, lineCap: .round, lineJoin: .round))
    }

    /// The round frame, its glass glint and the sill.
    static func frame(_ ctx: GraphicsContext, d: CGFloat, u: CGFloat, ring: CGFloat) {
        let outline = color("#5A3E36")
        let circle = { (inset: CGFloat) in Path(ellipseIn: CGRect(x: inset, y: inset, width: d - inset * 2, height: d - inset * 2)) }
        ctx.stroke(circle(ring / 2), with: .color(color("#F3E2C0")), lineWidth: ring)
        ctx.stroke(circle(u * 0.25), with: .color(outline), lineWidth: u * 0.5)
        ctx.stroke(circle(ring), with: .color(outline), lineWidth: u * 0.5)
        for a in stride(from: 45.0, to: 360, by: 90) {   // four little bolts in the frame
            let rad = a * .pi / 180, rr = d / 2 - ring / 2
            let p = CGPoint(x: d / 2 + CGFloat(cos(rad)) * rr, y: d / 2 + CGFloat(sin(rad)) * rr)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - u * 0.8, y: p.y - u * 0.8, width: u * 1.6, height: u * 1.6)), with: .color(color("#C9A97A")))
        }
        var glint = Path()
        glint.addArc(center: CGPoint(x: d / 2, y: d / 2), radius: d / 2 - ring - u * 2.5, startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
        ctx.stroke(glint, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: u, lineCap: .round))
        let sill = CGRect(x: d * 0.18, y: d * 0.95, width: d * 0.64, height: d * 0.11)
        ctx.fill(Path(roundedRect: sill, cornerRadius: u * 1.5), with: .color(color("#C98E5E")))
        ctx.fill(Path(CGRect(x: sill.minX + u, y: sill.minY + u, width: sill.width - u * 2, height: u)), with: .color(color("#E0AE7E")))
        ctx.stroke(Path(roundedRect: sill, cornerRadius: u * 1.5), with: .color(outline), lineWidth: u * 0.5)
    }

    /// A click: three hearts float up from the head and fade within 1.2 s.
    static func hearts(_ ctx: GraphicsContext, at head: CGPoint, u: CGFloat, age: TimeInterval) {
        guard age < 1.2 else { return }
        for i in 0..<3 {
            let p = CGPoint(x: head.x + CGFloat(i - 1) * u * 5, y: head.y - u * (4 + CGFloat(i % 2) * 2) - CGFloat(age) * u * 10)
            ctx.draw(Text("♥").font(.system(size: u * 5, weight: .bold)).foregroundColor(color("#F07C9A", 1 - age / 1.2)), at: p)
        }
    }
}
