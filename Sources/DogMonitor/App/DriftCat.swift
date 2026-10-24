#if !MAS
import AppKit

/// What the cat's front paw does in one drawing.
enum PawPose: Equatable {
    case none
    /// Up and winding, 0...1 of the catch window gone.
    case up(Double)
    /// Down on the window, with the bump lines.
    case down
    /// Caught: lifted a little, a "!" over its head.
    case caught
}

/// The cat's drawing: one of the built-in cat's own frames, with our paw drawn over it (the frames have no paw-up pose).
/// Room above and in front for the paw. Faces right; facing left is the same drawing mirrored. Pure drawing, so the QA
/// sheets and the panel draw the same.
enum DriftCatArt {
    /// Art pixels per point of `cache`.
    static func unit(_ cache: DogSpriteCache) -> CGFloat { cache.imageSize.width / CGFloat(DogSpriteCache.canvasWidth) }

    static func size(_ cache: DogSpriteCache) -> CGSize {
        let u = unit(cache)
        return CGSize(width: cache.imageSize.width + 6 * u, height: cache.imageSize.height + 6 * u)
    }

    static func draw(_ frame: NSImage, cache: DogSpriteCache, coat: CatProfile?, paw: PawPose, facingLeft: Bool, in bounds: CGRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let u = unit(cache), sprite = cache.imageSize
        ctx.saveGraphicsState()
        if facingLeft {
            let t = NSAffineTransform()
            t.translateX(by: bounds.maxX + bounds.minX, yBy: 0)
            t.scaleX(by: -1, yBy: 1)
            t.concat()
        }
        let lift: CGFloat = paw == .caught ? 3 * u : 0
        let base = CGPoint(x: bounds.minX, y: bounds.minY + lift)
        ctx.imageInterpolation = cache.smooth ? .high : .none
        frame.draw(in: CGRect(origin: base, size: sprite))
        let fill = coat.map { color($0.baseColor) } ?? NSColor(white: 0.6, alpha: 1)
        let line = coat.map { color($0.baseColor).blended(withFraction: 0.65, of: .black) ?? .black } ?? .black
        let bean = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.62, alpha: 1)
        // The chest: where the front leg leaves the body (the frames are 34 x 20, the head top-right, about 14 high).
        let shoulder = CGPoint(x: base.x + sprite.width - 5 * u, y: base.y + 6 * u)
        switch paw {
        case .none:
            break
        case .up(let p):
            // Up and back a little as the window runs out: the wind-up before the swat.
            let pad = CGPoint(x: base.x + sprite.width + 1 * u - 1.5 * u * CGFloat(p), y: base.y + 12 * u + 3 * u * CGFloat(p))
            leg(from: shoulder, to: pad, fill: fill, line: line, u: u)
            drawPaw(at: pad, fill: fill, line: line, bean: bean, u: u, beansUp: true)
        case .down:
            let pad = CGPoint(x: base.x + sprite.width + 0.5 * u, y: base.y + 2.2 * u)
            leg(from: shoulder, to: pad, fill: fill, line: line, u: u)
            drawPaw(at: pad, fill: fill, line: line, bean: bean, u: u, beansUp: false)
            line.setStroke()
            for (dx, dy, ex, ey) in [(-2.5, 2.5, -4.5, 4.5), (0.0, 3.5, 0.0, 6.0), (2.5, 2.5, 4.5, 4.5)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                let p = NSBezierPath()
                p.lineWidth = max(1, u * 0.8)
                p.lineCapStyle = .round
                p.move(to: CGPoint(x: pad.x + dx * u, y: pad.y + dy * u))
                p.line(to: CGPoint(x: pad.x + ex * u, y: pad.y + ey * u))
                p.stroke()
            }
        case .caught:
            // "!" over the head, in its own red.
            let x = base.x + sprite.width - 4 * u, top = base.y + 22 * u
            NSColor(srgbRed: 0.86, green: 0.22, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: top - 5 * u, width: 2 * u, height: 5 * u), xRadius: u, yRadius: u).fill()
            NSBezierPath(ovalIn: CGRect(x: x, y: top - 8 * u, width: 2 * u, height: 2 * u)).fill()
        }
        ctx.restoreGraphicsState()
    }

    private static func leg(from a: CGPoint, to b: CGPoint, fill: NSColor, line: NSColor, u: CGFloat) {
        for (c, w) in [(line, 3.6 * u), (fill, 2.0 * u)] {
            let p = NSBezierPath()
            p.lineWidth = w
            p.lineCapStyle = .round
            p.move(to: a)
            p.line(to: b)
            c.setStroke()
            p.stroke()
        }
    }

    private static func drawPaw(at c: CGPoint, fill: NSColor, line: NSColor, bean: NSColor, u: CGFloat, beansUp: Bool) {
        let r = CGRect(x: c.x - 2.3 * u, y: c.y - 2 * u, width: 4.6 * u, height: 4 * u)
        let pad = NSBezierPath(roundedRect: r, xRadius: 2 * u, yRadius: 2 * u)
        fill.setFill(); pad.fill()
        line.setStroke(); pad.lineWidth = max(1, 0.8 * u); pad.stroke()
        guard beansUp else { return }
        bean.setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - 1 * u, y: c.y - 1.4 * u, width: 2 * u, height: 1.5 * u)).fill()
        for dx in [-1.4, 0.0, 1.4] as [CGFloat] {
            NSBezierPath(ovalIn: CGRect(x: c.x + dx * u - 0.5 * u, y: c.y + 0.5 * u, width: 1 * u, height: 1 * u)).fill()
        }
    }

    private static func color(_ c: RGBColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// One drawing as an image (the QA sheets).
    static func image(_ cache: DogSpriteCache, pose: DogPose, coat: CatProfile?, paw: PawPose, facingLeft: Bool = false) -> NSImage {
        let s = size(cache)
        let frame = cache.frames(for: pose).first ?? NSImage(size: cache.imageSize)
        return NSImage(size: s, flipped: false) { r in
            draw(frame, cache: cache, coat: coat, paw: paw, facingLeft: facingLeft, in: r)
            return true
        }
    }
}

/// The 딴짓 지킴이 cat on the screen: a see-through panel that never takes a click, and a HotspotPanel over it that takes
/// the catch. Plays along the bottom of the screen (평소엔 놀기) or waits out of sight, and runs in for a confirmed nudge.
final class DriftCat {
    static let shared = DriftCat()

    private enum Mode: Equatable { case hidden, playing, running, raised, landed, caught, leaving }

    private var panel: NSPanel?
    private let view = DriftCatView()
    private let hot = HotspotPanel()
    private var timer: Timer?
    private var mode: Mode = .hidden
    private var cache: DogSpriteCache?
    private var cacheKey = ""
    private var play = PawPlay()
    private var pos = CGPoint.zero
    private var from = CGPoint.zero, to = CGPoint.zero
    private var legStart = Date(), legSeconds: TimeInterval = 1
    private var facingLeft = false
    private var frameIndex = 0, frameClock: TimeInterval = 0
    private var lastTick = Date()
    /// 평소엔 놀기: walking (vx) or sitting until `restUntil`.
    private var vx: CGFloat = 36
    private var restUntil: Date?
    private var nextRest = Date().addingTimeInterval(8)
    private var holdUntil: Date?

    private init() {
        hot.onMouse = { [weak self] e in if e.type == .leftMouseDown { self?.grab() } }
    }

    /// The switches changed: show, hide or redraw.
    func update() {
        guard !HotspotPanel.qaInert else { return }
        let c = DriftCenter.shared
        let wanted = c.cat && c.wanted && c.catPlays
        switch mode {
        case .running, .raised, .landed, .caught, .leaving: return   // a nudge in progress finishes first
        case .hidden: if wanted { refreshCache(); startPlaying() }
        case .playing: if !wanted { hide() } else { refreshCache(); draw() }
        }
    }

    private func refreshCache() {
        let c = DriftCenter.shared
        let key = c.coat.rawValue + "@" + c.catSize.rawValue
        guard key != cacheKey, let ch = c.coat.character else { return }
        cacheKey = key
        cache = DogSpriteCache(ch, pixelSize: c.catSize.pixelSize, outfit: .some(nil))
    }

    private var size: CGSize { cache.map(DriftCatArt.size) ?? CGSize(width: 80, height: 60) }

    /// The screen the cat runs to: the drift window's, else the main one.
    private var onScreen: NSScreen?
    private var screen: CGRect { (onScreen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero }

    private func startPlaying() {
        let vf = screen
        pos = CGPoint(x: vf.minX + vf.width * 0.3, y: vf.minY)
        mode = .playing
        arm()
        draw()
    }

    /// A confirmed nudge with 발로 닫기: run onto the drift window and lift the paw.
    func pounce(on sample: DriftSample, seconds: TimeInterval) {
        guard !HotspotPanel.qaInert else { return }
        refreshCache()
        let found = Self.window(of: sample.app)
        if let found { onScreen = NSScreen.screens.first { $0.frame.intersects(found) } ?? onScreen }
        let target = found ?? CGRect(x: screen.midX - 300, y: screen.midY - 200, width: 600, height: 400)
        let s = size, vf = screen
        to = CGPoint(x: min(max(target.minX + target.width * 0.68, vf.minX), vf.maxX - s.width),
                     y: min(target.maxY - 6, vf.maxY - s.height))
        if mode == .hidden || mode == .leaving {
            let left = to.x - vf.minX < vf.maxX - to.x
            pos = CGPoint(x: left ? vf.minX - s.width : vf.maxX, y: to.y)
        }
        go(to: to, then: .running)
        play = PawPlay(window: seconds)
        play.run()
        arm()
        draw()
    }

    /// Off the screen (or back to playing): the nudge is over.
    func leave() {
        guard mode != .hidden, mode != .playing, mode != .leaving else { return }
        play.leave()
        let vf = screen
        let left = pos.x - vf.minX < vf.maxX - pos.x
        if DriftCenter.shared.cat && DriftCenter.shared.catPlays {
            go(to: CGPoint(x: min(max(pos.x, vf.minX + 20), vf.maxX - size.width - 20), y: vf.minY), then: .leaving)
        } else {
            go(to: CGPoint(x: left ? vf.minX - size.width - 4 : vf.maxX + 4, y: pos.y), then: .leaving)
        }
    }

    private func go(to point: CGPoint, then m: Mode) {
        from = pos
        to = point
        legStart = Date()
        let distance = hypot(to.x - from.x, to.y - from.y)
        legSeconds = DesktopKit.reduceMotion ? 0.15 : max(0.35, Double(distance) / 1100)
        facingLeft = to.x < from.x
        mode = m
    }

    private func grab() {
        guard mode == .running || mode == .raised, play.grab(at: Date()) else { return }
        mode = .caught
        holdUntil = Date().addingTimeInterval(DesktopKit.reduceMotion ? 0.4 : 1.0)
        draw()
        DriftCenter.shared.caught()
    }

    private func arm() {
        guard timer == nil else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = Date(), dt = min(0.1, now.timeIntervalSince(lastTick))
        lastTick = now
        frameClock += dt
        switch mode {
        case .hidden:
            timer?.invalidate(); timer = nil
            return
        case .playing:
            wander(now: now, dt: dt)
        case .running, .leaving:
            let t = min(1, now.timeIntervalSince(legStart) / legSeconds)
            pos = CGPoint(x: from.x + (to.x - from.x) * CGFloat(t), y: from.y + (to.y - from.y) * CGFloat(t))
            if t >= 1 {
                if mode == .running {
                    mode = .raised
                    play.arrive(at: now)
                    facingLeft = false
                } else if DriftCenter.shared.cat && DriftCenter.shared.catPlays {
                    mode = .playing
                } else {
                    hide(); return
                }
            }
        case .raised:
            if play.tick(at: now) {
                mode = .landed
                holdUntil = now.addingTimeInterval(DesktopKit.reduceMotion ? 0.3 : 0.7)
                DriftCenter.shared.slam()
            }
        case .landed, .caught:
            if let h = holdUntil, now >= h { holdUntil = nil; leave() }
        }
        draw()
    }

    /// 평소엔 놀기: a slow walk along the bottom, now and then a sit.
    private func wander(now: Date, dt: TimeInterval) {
        let vf = screen
        if let r = restUntil {
            if now >= r { restUntil = nil; nextRest = now.addingTimeInterval(.random(in: 10...25)) }
            return
        }
        if now >= nextRest { restUntil = now.addingTimeInterval(.random(in: 5...12)); return }
        pos.x += vx * CGFloat(dt)
        pos.y = vf.minY
        if pos.x < vf.minX + 20 { pos.x = vf.minX + 20; vx = abs(vx) }
        if pos.x > vf.maxX - size.width - 20 { pos.x = vf.maxX - size.width - 20; vx = -abs(vx) }
        facingLeft = vx < 0
    }

    private func draw() {
        guard let cache else { return }
        let pose: DogPose, paw: PawPose
        switch mode {
        case .playing: pose = restUntil != nil ? .lying : .slowWalk; paw = .none
        case .running, .leaving: pose = .run; paw = .none
        case .raised: pose = .walk; paw = .up(play.progress(at: Date()))
        case .landed: pose = .walk; paw = .down
        case .caught: pose = .walk; paw = .caught
        case .hidden: return
        }
        let frames = cache.frames(for: pose)
        let still = DesktopKit.reduceMotion || paw != .none
        let every = DogSpriteCache.frameDuration(for: pose, cpu: 0.3)
        if frameClock >= every { frameClock = 0; frameIndex += 1 }
        let frame = frames.isEmpty ? NSImage(size: cache.imageSize) : frames[still ? 0 : frameIndex % frames.count]
        let s = size
        let p = panel ?? makePanel()
        panel = p
        view.set(frame: frame, cache: cache, coat: DriftCenter.shared.coat.profile, paw: paw, facingLeft: facingLeft)
        let rect = CGRect(origin: pos, size: s)
        if p.frame != rect { p.setFrame(rect, display: false) }
        if !p.isVisible { p.orderFrontRegardless() }
        // The catch takes clicks only while there is something to catch; playing, the cat lets every click through.
        if mode == .running || mode == .raised {
            hot.place(rect, HotspotShape(drawn: CGRect(origin: .zero, size: s)), level: NSWindow.Level(p.level.rawValue + 1))
        } else {
            hot.hide()
        }
    }

    private func hide() {
        mode = .hidden
        play.leave()
        panel?.orderOut(nil)
        hot.hide()
        timer?.invalidate(); timer = nil
        cache = nil; cacheKey = ""
        onScreen = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = view
        return p
    }

    /// The front window of `bundleID`'s app: its bounds only (CGWindowList, no Screen Recording needed).
    static func window(of bundleID: String) -> CGRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty, let primary = NSScreen.screens.first?.frame.height,
              let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return raw.lazy.compactMap { ListedWindow($0, primaryHeight: primary) }
            .first { pids.contains($0.pid) && $0.layer == 0 && $0.frame.width >= 200 && $0.frame.height >= 120 && $0.alpha > 0 }?.frame
    }
}

/// Draws the cat's current drawing.
private final class DriftCatView: NSView {
    private var frame0: NSImage?
    private var cache: DogSpriteCache?
    private var coat: CatProfile?
    private var paw: PawPose = .none
    private var facingLeft = false

    func set(frame: NSImage, cache: DogSpriteCache, coat: CatProfile?, paw: PawPose, facingLeft: Bool) {
        guard frame !== frame0 || paw != self.paw || facingLeft != self.facingLeft || coat != self.coat else { return }
        frame0 = frame; self.cache = cache; self.coat = coat; self.paw = paw; self.facingLeft = facingLeft
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let frame0, let cache else { return }
        DriftCatArt.draw(frame0, cache: cache, coat: coat, paw: paw, facingLeft: facingLeft, in: bounds)
    }
}
#endif
