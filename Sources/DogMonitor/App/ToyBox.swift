import AppKit
import Combine
import QuartzCore

// MARK: Settings

/// A toy in the 장난감 상자. Raw values are saved; never rename one. 구름 쿠션 is a 후원 선물 (SponsorGifts), a 쿠션 in every way.
enum ToyKind: String, Codable, CaseIterable {
    case trampoline, ball, cushion, slide, cloud

    var label: String {
        switch self {
        case .trampoline: return L("트램펄린")
        case .ball: return L("공")
        case .cushion: return L("쿠션")
        case .slide: return L("미끄럼틀")
        case .cloud: return L("구름 쿠션")
        }
    }

    /// Its drawing's size, points.
    var size: CGSize {
        switch self {
        case .trampoline: return CGSize(width: 96, height: 46)
        case .ball: return CGSize(width: 34, height: 34)
        case .cushion: return CGSize(width: 78, height: 30)
        case .slide: return CGSize(width: 104, height: 78)
        case .cloud: return CGSize(width: 84, height: 32)
        }
    }

    /// What there is to stand on, as shares of the drawing: across `from...to` at height `y`. The 공 rolls instead.
    private var top: (from: CGFloat, to: CGFloat, y: CGFloat)? {
        switch self {
        case .trampoline: return (0.06, 0.94, 0.72)
        case .cushion: return (0.08, 0.92, 0.8)
        case .cloud: return (0.1, 0.9, 0.78)
        case .slide: return (0.03, 0.37, 0.84)   // the deck at the top of the ladder
        case .ball: return nil
        }
    }

    /// For a toy drawn in `f` (screen points): a box from its floor up to what there is to stand on (its maxY).
    func stand(in f: CGRect) -> CGRect? {
        top.map { CGRect(x: f.minX + f.width * $0.from, y: f.minY, width: f.width * ($0.to - $0.from), height: f.height * $0.y) }
    }

    /// Where a friend `w` wide puts its feet to use it: on top in the middle, at the top of the 미끄럼틀's chute, or
    /// beside the 공 on the side it comes from (`fromX`).
    func spot(in f: CGRect, width w: CGFloat, fromX: CGFloat) -> CGPoint {
        if self == .slide { return Self.chute(f).top }
        guard let s = stand(in: f) else { return CGPoint(x: fromX < f.midX ? f.minX - w * 0.4 : f.maxX + w * 0.4, y: f.minY) }
        return CGPoint(x: s.midX, y: s.maxY)
    }

    /// 미끄럼틀: the chute's top surface, from the deck down to the right (screen points).
    static func chute(_ f: CGRect) -> (top: CGPoint, bottom: CGPoint) {
        (CGPoint(x: f.minX + f.width * 0.35, y: f.minY + f.height * 0.84), CGPoint(x: f.minX + f.width * 0.92, y: f.minY + f.height * 0.16))
    }
}

/// One toy out: what it is and where its bottom middle rests, as shares (0...1) of the main screen's visible frame.
struct Toy: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: ToyKind
    var x: Double
    var y: Double

    /// Shares outside 0...1 (or not numbers) are pulled back in.
    init(id: UUID = UUID(), kind: ToyKind, x: Double, y: Double) {
        self.id = id; self.kind = kind; self.x = Self.share(x); self.y = Self.share(y)
    }

    /// Drawn at `f` (screen points) within `r`.
    init(id: UUID = UUID(), kind: ToyKind, frame f: CGRect, in r: CGRect) {
        self.init(id: id, kind: kind, x: r.width > 0 ? Double((f.midX - r.minX) / r.width) : 0.5,
                  y: r.height > 0 ? Double((f.minY - r.minY) / r.height) : 0)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(), kind: try c.decode(ToyKind.self, forKey: .kind),
                  x: (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? 0.5, y: (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? 0)
    }

    /// Its drawing's frame in `r`, kept wholly inside (pinned to the bottom left when `r` is smaller than it).
    func frame(in r: CGRect) -> CGRect {
        let s = kind.size
        let mid = r.minX + min(max(CGFloat(x) * r.width, s.width / 2), max(s.width / 2, r.width - s.width / 2))
        let bottom = r.minY + min(max(CGFloat(y) * r.height, 0), max(0, r.height - s.height))
        return CGRect(x: mid - s.width / 2, y: bottom, width: s.width, height: s.height)
    }

    private static func share(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0.5 }
}

struct ToyPrefs: Codable, Equatable {
    var on = false
    var toys: [Toy] = []

    static let maxCount = 6

    func has(_ kind: ToyKind) -> Bool { toys.contains { $0.kind == kind } }

    /// One more of `kind` along the bottom of the screen; false when the box is empty (6 out already).
    @discardableResult
    mutating func add(_ kind: ToyKind) -> Bool {
        guard toys.count < Self.maxCount else { return false }
        toys.append(Toy(kind: kind, x: 0.12 + 0.15 * Double(toys.count), y: 0))
        return true
    }
}

extension ToyPrefs {
    /// Settings from before a field existed keep the rest; a toy this version does not know is left in the box.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? false
        let list = (try? c.decodeIfPresent([Maybe<Toy>].self, forKey: .toys)) ?? nil
        toys = Array((list ?? []).compactMap(\.value).prefix(Self.maxCount))
    }

    private struct Maybe<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

final class ToyStore: ObservableObject {
    static let shared = ToyStore()
    static let key = "desktopToys"

    private let defaults: UserDefaults
    @Published var prefs: ToyPrefs {
        didSet { if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key) } }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        prefs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ToyPrefs.self, from: $0) } ?? ToyPrefs()
    }
}

/// How the toys move things, pure (ToyBoxTests).
enum ToyPhysics {
    /// 트램펄린 in 놀이 모드: up at least this fast (about 430 pt, near three jumps), more after a longer fall.
    static let superJump: CGFloat = 1500, maxLaunch: CGFloat = 2200
    /// 미끄럼틀: across, points per second.
    static let slide: CGFloat = 300
    /// The 공 slows by this much a second.
    static let drag: CGFloat = 260

    /// Up speed off the 트램펄린 after landing at `vy` (down is negative).
    static func launch(fall vy: CGFloat) -> CGFloat { min(maxLaunch, superJump + max(0, -vy) * 0.4) }

    /// 쿠션: a soft landing, a little bounce back after a hard fall only.
    static func cushion(fall vy: CGFloat) -> CGFloat { -vy > 700 ? min(400, -vy * 0.25) : 0 }

    /// The chute's height under `x`, nil off it (past its bottom the player falls the last bit).
    static func chute(_ f: CGRect, x: CGFloat) -> CGFloat? {
        let c = ToyKind.chute(f)
        guard x >= c.top.x, x < c.bottom.x else { return nil }
        return c.top.y + (c.bottom.y - c.top.y) * (x - c.top.x) / (c.bottom.x - c.top.x)
    }

    /// One frame of the 공 rolling at `vx` between `lo` and `hi` (its middle): it slows and bounces off the ends.
    static func roll(x: CGFloat, vx: CGFloat, dt: TimeInterval, lo: CGFloat, hi: CGFloat) -> (x: CGFloat, vx: CGFloat) {
        let t = CGFloat(max(0, dt))
        var v = vx.magnitude <= drag * t ? 0 : vx - (vx > 0 ? 1 : -1) * drag * t
        var nx = x + v * t
        if nx < lo { nx = lo; v = abs(v) * 0.6 } else if nx > hi { nx = hi; v = -abs(v) * 0.6 }
        return (nx, v)
    }

    /// How far a kick at `v` rolls before it stops (walls aside).
    static func rollDistance(_ v: CGFloat) -> CGFloat { v * v / (2 * drag) }
}

// MARK: The toys

/// "장난감 상자" (데스크톱 친구): up to 6 toys on the desktop (트램펄린, 공, 쿠션, 미끄럼틀), each a small panel at the
/// 러그's level, behind every window, back where they were after a restart. Drag one to move it, click it to play it
/// (the 공 rolls away), right-click for 치우기. Idle, the 커서 친구 and the 복제 친구 now and then go and use one; in
/// 놀이 모드 the 트램펄린 throws the player high, the 쿠션 lands soft and the 미끄럼틀 carries it down. Nothing ticks
/// but a rolling 공. 동작 줄이기: no squash, and the 공 stays put.
final class ToyBox {
    static let shared = ToyBox()

    fileprivate final class Item {
        let id: UUID, kind: ToyKind
        let panel: ToyPanel
        let art = CALayer()
        var spin: CGFloat = 0

        init(id: UUID, kind: ToyKind, panel: ToyPanel) { self.id = id; self.kind = kind; self.panel = panel }
    }

    private var items: [Item] = []
    private var bag: Set<AnyCancellable> = []
    private var started = false
    /// 공 on the move, by id: their speed across.
    private var rolling: [UUID: CGFloat] = [:]
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var press: (id: UUID, grab: CGVector, moved: Bool)?
    /// Each player's speed down on the last frame in the air, for the landing.
    private var fall: [CGFloat] = [0, 0]

    private var store: ToyStore { .shared }
    private var enabled: Bool { store.prefs.on && !store.prefs.toys.isEmpty }
    /// The menu bar's screen, as the 러그 and the 복제 친구.
    private var area: CGRect? { NSScreen.screens.first?.visibleFrame }

    func start() {
        guard !started else { return }
        started = true
        // The 러그 orders its panel front on its own changes: the toys come back over it (the same level).
        ToyStore.shared.objectWillChange
            .merge(with: RugStore.shared.objectWillChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        PlayMode.shared.didStart
            .sink { [weak self] in self?.joinPlay() }
            .store(in: &bag)
        refresh()
    }

    /// A toy within `reach` of screen point `p` that shows (not behind a window, not being moved), for an idle friend.
    func pick(near p: CGPoint, reach: CGFloat) -> (id: UUID, kind: ToyKind, frame: CGRect)? {
        guard enabled else { return nil }
        let free = items.filter { i in
            let f = i.panel.frame
            return i.panel.occlusionState.contains(.visible) && rolling[i.id] == nil && press?.id != i.id && hypot(f.midX - p.x, f.minY - p.y) <= reach
        }
        return free.randomElement().map { ($0.id, $0.kind, $0.panel.frame) }
    }

    /// Where that toy is drawn on screen; nil once it is put away.
    func frame(of id: UUID) -> CGRect? { items.first { $0.id == id }?.panel.frame }

    /// A friend used it: the 트램펄린 and the 쿠션 squash, the 공 rolls away toward `dir` (+1 right).
    func played(_ id: UUID, dir: CGFloat) {
        guard let i = items.first(where: { $0.id == id }) else { return }
        switch i.kind {
        case .trampoline, .cushion, .cloud: squash(i)
        case .ball: kick(i, vx: dir * 320)
        case .slide: break
        }
    }

    // MARK: Building

    private func refresh() {
        guard enabled, let r = area else {
            items.forEach { $0.panel.orderOut(nil) }
            items = []; rolling = [:]; press = nil
            timer?.invalidate(); timer = nil
            return
        }
        let toys = store.prefs.toys, ids = Set(toys.map(\.id))
        for i in items where !ids.contains(i.id) { i.panel.orderOut(nil); rolling[i.id] = nil }
        items.removeAll { !ids.contains($0.id) }
        for t in toys {
            let i = items.first { $0.id == t.id } ?? make(t)
            if rolling[t.id] == nil, press?.id != t.id { i.panel.setFrame(t.frame(in: r), display: false) }
            i.panel.orderFrontRegardless()
        }
    }

    private func make(_ t: Toy) -> Item {
        let p = ToyPanel(contentRect: CGRect(origin: .zero, size: t.kind.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)   // the 러그's, under the 복제 친구 (+2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        let i = Item(id: t.id, kind: t.kind, panel: p)
        let v = ToyView(frame: CGRect(origin: .zero, size: t.kind.size))
        v.wantsLayer = true
        v.onMouse = { [weak self, weak i] e in if let i { self?.mouse(e, i) } }
        p.contentView = v
        i.art.contents = ToyArt.image(t.kind)
        i.art.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2
        i.art.bounds = v.bounds
        i.art.anchorPoint = t.kind == .ball ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: 0.5, y: 0)   // the 공 turns about its middle, the rest squash onto the floor
        i.art.position = t.kind == .ball ? CGPoint(x: v.bounds.midX, y: v.bounds.midY) : CGPoint(x: v.bounds.midX, y: 0)
        i.art.actions = ["transform": NSNull(), "contents": NSNull()]
        v.layer?.addSublayer(i.art)
        items.append(i)
        return i
    }

    private func save(_ i: Item) {
        guard let r = area, let k = store.prefs.toys.firstIndex(where: { $0.id == i.id }) else { return }
        let t = Toy(id: i.id, kind: i.kind, frame: i.panel.frame, in: r)
        if t != store.prefs.toys[k] { store.prefs.toys[k] = t }
    }

    // MARK: Moving

    private func squash(_ i: Item) {
        guard !DesktopKit.reduceMotion else { return }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [(1, 1), (1.08, 0.72), (0.97, 1.08), (1, 1)].map { NSValue(caTransform3D: CATransform3DMakeScale($0.0, $0.1, 1)) }
        a.keyTimes = [0, 0.3, 0.65, 1]
        a.duration = 0.35
        i.art.add(a, forKey: "squash")
    }

    private func kick(_ i: Item, vx: CGFloat) {
        guard !DesktopKit.reduceMotion, vx != 0 else { return }
        rolling[i.id] = vx
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.003
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Only while a 공 rolls.
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, now - lastTick))
        lastTick = now
        guard let r = area else { rolling = [:]; timer?.invalidate(); timer = nil; return }
        for (id, vx) in rolling {
            guard let i = items.first(where: { $0.id == id }) else { rolling[id] = nil; continue }
            let f = i.panel.frame
            let step = ToyPhysics.roll(x: f.midX, vx: vx, dt: dt, lo: r.minX + f.width / 2, hi: r.maxX - f.width / 2)
            i.panel.setFrameOrigin(CGPoint(x: step.x - f.width / 2, y: f.minY))
            i.spin -= (step.x - f.midX) / (f.width / 2)   // rolling right turns it clockwise
            i.art.setAffineTransform(CGAffineTransform(rotationAngle: i.spin))
            if step.vx == 0 { rolling[id] = nil; save(i) } else { rolling[id] = step.vx }
        }
        if rolling.isEmpty { timer?.invalidate(); timer = nil }
    }

    // MARK: Mouse

    fileprivate func mouse(_ e: NSEvent, _ i: Item) {
        let p = NSEvent.mouseLocation, o = i.panel.frame.origin
        switch e.type {
        case .rightMouseDown: menu(e, i)
        case .leftMouseDown where e.modifierFlags.contains(.control): menu(e, i)
        case .leftMouseDown:
            rolling[i.id] = nil
            press = (i.id, CGVector(dx: o.x - p.x, dy: o.y - p.y), false)
        case .leftMouseDragged:
            guard var pr = press, pr.id == i.id, let r = area else { return }
            let s = i.panel.frame.size
            i.panel.setFrameOrigin(CGPoint(x: min(max(p.x + pr.grab.dx, r.minX), max(r.minX, r.maxX - s.width)),
                                           y: min(max(p.y + pr.grab.dy, r.minY), max(r.minY, r.maxY - s.height))))
            pr.moved = true
            press = pr
        case .leftMouseUp:
            guard let pr = press, pr.id == i.id else { return }
            press = nil
            if pr.moved { save(i) } else { played(i.id, dir: p.x < i.panel.frame.midX ? 1 : -1) }   // a tap on its left kicks it right
        default: break
        }
    }

    private func menu(_ e: NSEvent, _ i: Item) {
        press = nil
        guard let v = i.panel.contentView else { return }
        let id = i.id
        FriendMenu.pop([
            FriendMenu.item(L("치우기")) { ToyStore.shared.prefs.toys.removeAll { $0.id == id } },
            FriendMenu.item(L("장난감 모두 정리하기")) { ToyStore.shared.prefs.toys = [] },
        ], with: e, for: v)
    }

    // MARK: 놀이 모드

    /// A session started: the toys' tops are edges, and they answer the players.
    private func joinPlay() {
        guard enabled else { return }
        let play = PlayMode.shared
        fall = [0, 0]
        play.under.append { [weak self] in self?.items.compactMap { $0.kind.stand(in: $0.panel.frame) } ?? [] }
        play.onEvent.append { [weak self] e, n in if e == .landed { self?.landed(n) } }
        play.onStep.append { [weak self] dt in self?.step(dt) }
    }

    /// Down on a toy: the 트램펄린 throws it up high, the 쿠션 takes the fall.
    private func landed(_ n: Int) {
        let play = PlayMode.shared
        guard let b = play.body(n), let i = items.first(where: { i in
            i.kind.stand(in: i.panel.frame).map { abs($0.maxY - b.y) < 0.5 && b.x >= $0.minX && b.x <= $0.maxX } == true
        }) else { return }
        let v = fall[n]
        let up = i.kind == .trampoline ? ToyPhysics.launch(fall: v) : i.kind == .cushion || i.kind == .cloud ? ToyPhysics.cushion(fall: v) : 0
        if up > 0 { play.update(n) { $0.vy = up; $0.onGround = false; $0.jumps = 1 } }   // the 2단 점프 is still there
        squash(i)
    }

    /// Every frame of a session: the 미끄럼틀 carries a player on its chute down to the right; walking into the 공 kicks it.
    private func step(_ dt: TimeInterval) {
        let play = PlayMode.shared
        for n in 0..<2 {
            guard let b = play.body(n) else { continue }
            if !b.onGround { fall[n] = b.vy }
            for i in items {
                let f = i.panel.frame
                switch i.kind {
                case .slide:
                    guard b.vy <= 0, let y = ToyPhysics.chute(f, x: b.x), b.y <= y + 6, b.y >= y - 12 else { continue }
                    let x = b.x + ToyPhysics.slide * CGFloat(dt)
                    play.update(n) { $0.x = x; $0.y = ToyPhysics.chute(f, x: x) ?? $0.y; $0.vy = 0; $0.onGround = false; $0.jumps = 0; $0.facingLeft = false }
                case .ball:
                    guard rolling[i.id] == nil, play.player(n)?.intersects(f) == true else { continue }
                    kick(i, vx: (b.x < f.midX ? 1 : -1) * 380)
                default: continue
                }
            }
        }
    }
}

/// Never key, never main: moving a toy never takes the focus from the app in front.
private final class ToyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// ponytail: the whole small panel takes the mouse (a 공's corners too); an AlphaHit check if that ever gets in the way
private final class ToyView: NSView {
    var onMouse: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouse?(event) }
    override func mouseDragged(with event: NSEvent) { onMouse?(event) }
    override func mouseUp(with event: NSEvent) { onMouse?(event) }
    override func rightMouseDown(with event: NSEvent) { onMouse?(event) }
}

// MARK: Drawing

/// The toys, drawn with Core Graphics in the app's pastels with a soft plum outline.
enum ToyArt {
    static func image(_ kind: ToyKind) -> NSImage {
        NSImage(size: kind.size, flipped: false) { r in
            switch kind {
            case .trampoline: trampoline(r)
            case .ball: ball(r)
            case .cushion: cushion(r)
            case .slide: slide(r)
            case .cloud: cloud(r)
            }
            return true
        }
    }

    private static let ink = rgb(92, 70, 92)
    private static let line: CGFloat = 1.5

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    private static func paint(_ p: NSBezierPath, _ fill: NSColor, outline: Bool = true) {
        fill.setFill()
        p.fill()
        guard outline else { return }
        ink.setStroke()
        p.lineWidth = line
        p.lineJoinStyle = .round
        p.stroke()
    }

    private static func trampoline(_ r: CGRect) {
        let w = r.width, h = r.height
        for fx in [0.16, 0.5, 0.84] as [CGFloat] {
            paint(NSBezierPath(roundedRect: CGRect(x: w * fx - 2.5, y: 1, width: 5, height: h * 0.6), xRadius: 2.5, yRadius: 2.5), rgb(168, 139, 240))
        }
        paint(NSBezierPath(ovalIn: CGRect(x: 2, y: h * 0.5, width: w - 4, height: h * 0.42)), rgb(255, 158, 192))
        paint(NSBezierPath(ovalIn: CGRect(x: 11, y: h * 0.57, width: w - 22, height: h * 0.26)), rgb(108, 91, 167), outline: false)
        rgb(255, 255, 255, 0.35).setFill()
        NSBezierPath(ovalIn: CGRect(x: w * 0.3, y: h * 0.72, width: w * 0.2, height: h * 0.06)).fill()
        // The springs: white dots round the front of the rim.
        NSColor.white.setFill()
        for k in 0..<7 {
            let a = CGFloat.pi * (1.12 + 0.76 * CGFloat(k) / 6)
            let c = CGPoint(x: w / 2 + cos(a) * (w / 2 - 6), y: h * 0.71 + sin(a) * (h * 0.21 - 2.5))
            NSBezierPath(ovalIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)).fill()
        }
    }

    private static func ball(_ r: CGRect) {
        let o = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
        let c = CGPoint(x: r.midX, y: r.midY)
        NSColor.white.setFill()
        o.fill()
        NSGraphicsContext.saveGraphicsState()
        o.addClip()
        for (k, color) in [rgb(255, 126, 168), rgb(242, 194, 48), rgb(90, 174, 245)].enumerated() {
            let wedge = NSBezierPath()
            wedge.move(to: c)
            wedge.appendArc(withCenter: c, radius: r.width, startAngle: CGFloat(k) * 120 + 30, endAngle: CGFloat(k) * 120 + 90)
            wedge.close()
            color.setFill()
            wedge.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
        rgb(255, 255, 255, 0.7).setFill()
        NSBezierPath(ovalIn: CGRect(x: r.width * 0.22, y: r.height * 0.6, width: r.width * 0.2, height: r.height * 0.13)).fill()
        ink.setStroke()
        o.lineWidth = line
        o.stroke()
    }

    private static func cushion(_ r: CGRect) {
        let w = r.width, h = r.height
        let body = CGRect(x: 4, y: 2, width: w - 8, height: h * 0.8 - 2)
        for (x, y) in [(body.minX, body.minY), (body.maxX, body.minY), (body.minX, body.maxY), (body.maxX, body.maxY)] {   // tassels
            paint(NSBezierPath(ovalIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), rgb(242, 194, 48))
        }
        paint(NSBezierPath(roundedRect: body, xRadius: 11, yRadius: 11), rgb(255, 179, 199))
        let seam = NSBezierPath(roundedRect: body.insetBy(dx: 4, dy: 3.5), xRadius: 8, yRadius: 8)
        seam.setLineDash([3, 2.5], count: 2, phase: 0)
        seam.lineWidth = 1
        rgb(255, 255, 255, 0.75).setStroke()
        seam.stroke()
        rgb(230, 120, 150).setFill()
        NSBezierPath(ovalIn: CGRect(x: body.midX - 3, y: body.midY - 3, width: 6, height: 6)).fill()
    }

    /// 구름 쿠션: three soft white bumps on a flat base, outlined in sky blue, with a rosy cheek.
    private static func cloud(_ r: CGRect) {
        let w = r.width, h = r.height, sky = rgb(90, 174, 245)
        let p = NSBezierPath(roundedRect: CGRect(x: 3, y: 2, width: w - 6, height: h * 0.5), xRadius: h * 0.25, yRadius: h * 0.25)
        for (cx, rad) in [(0.3, 0.3), (0.52, 0.38), (0.73, 0.28)] as [(CGFloat, CGFloat)] {
            p.append(NSBezierPath(ovalIn: CGRect(x: w * cx - h * rad * 1.3, y: h * 0.78 - h * rad * 2, width: h * rad * 2.6, height: h * rad * 2)))
        }
        NSColor.white.setFill()
        p.fill()
        // One outline round the whole puff: stroke it, then fill again so the inner seams go.
        sky.setStroke()
        p.lineWidth = line * 2
        p.stroke()
        NSColor.white.setFill()
        p.fill()
        rgb(255, 179, 199, 0.8).setFill()
        NSBezierPath(ovalIn: CGRect(x: w * 0.62, y: h * 0.28, width: 7, height: 4)).fill()
        rgb(220, 236, 252).setFill()
        NSBezierPath(roundedRect: CGRect(x: w * 0.2, y: 5, width: w * 0.6, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }

    private static func slide(_ r: CGRect) {
        let w = r.width, h = r.height
        let mint = rgb(79, 201, 142)
        let chute = ToyKind.chute(r)
        // A leg under the middle of the chute.
        let mid = CGPoint(x: (chute.top.x + chute.bottom.x) / 2, y: (chute.top.y + chute.bottom.y) / 2)
        paint(NSBezierPath(rect: CGRect(x: mid.x - 2, y: 1, width: 4, height: mid.y - 1)), mint)
        for fx in [0.07, 0.3] as [CGFloat] {   // ladder rails, then the rungs
            paint(NSBezierPath(roundedRect: CGRect(x: w * fx - 2, y: 1, width: 4, height: h * 0.84), xRadius: 2, yRadius: 2), mint)
        }
        for k in 0..<4 {
            paint(NSBezierPath(rect: CGRect(x: w * 0.07, y: h * (0.14 + 0.16 * CGFloat(k)), width: w * 0.23, height: 3)), mint)
        }
        let band = NSBezierPath()
        band.move(to: CGPoint(x: chute.top.x - 2, y: chute.top.y))
        band.line(to: chute.bottom)
        band.curve(to: CGPoint(x: w - 2, y: h * 0.12), controlPoint1: CGPoint(x: chute.bottom.x + 3, y: chute.bottom.y - 2),
                   controlPoint2: CGPoint(x: w - 5, y: h * 0.12))
        band.line(to: CGPoint(x: w - 2, y: h * 0.04))
        band.curve(to: CGPoint(x: chute.bottom.x - 4, y: chute.bottom.y - 9), controlPoint1: CGPoint(x: w - 8, y: h * 0.04),
                   controlPoint2: CGPoint(x: chute.bottom.x, y: chute.bottom.y - 9))
        band.line(to: CGPoint(x: chute.top.x - 2, y: chute.top.y - 10))
        band.close()
        paint(band, rgb(255, 201, 74))
        let shine = NSBezierPath()
        shine.move(to: CGPoint(x: chute.top.x + 4, y: chute.top.y - 4))
        shine.line(to: CGPoint(x: chute.bottom.x - 4, y: chute.bottom.y - 4))
        shine.lineWidth = 1.5
        shine.lineCapStyle = .round
        rgb(255, 255, 255, 0.6).setStroke()
        shine.stroke()
        paint(NSBezierPath(roundedRect: CGRect(x: w * 0.03, y: h * 0.78, width: w * 0.34, height: h * 0.06), xRadius: 2, yRadius: 2), rgb(168, 139, 240))
    }
}
