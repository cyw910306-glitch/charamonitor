import AppKit
import AVFoundation
import Combine

/// Shared pieces for the 데스크톱 친구 (커서 친구, 대롱대롱 친구, 날씨 창문). Everything but `reduceMotion` is pure and tested
/// (DesktopTests). Coordinates are screen points with y up, like NSWindow frames.
enum DesktopKit {
    /// No speed growth, tilt, wind or idle motion, a still pose only: 꾸미기 > 움직임 잔잔하게, or 자동 with macOS
    /// 손쉬운 사용 > 동작 줄이기 on. 통통 keeps full motion either way.
    static var reduceMotion: Bool {
        switch AppSettings.shared.motionLevel {
        case .calm: return true
        case .bouncy: return false   // ponytail: the same motion as 자동 for now; livelier idle play can come later
        case .auto: return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
    /// Fires when 동작 줄이기 (or another display option) or 꾸미기 > 움직임 changes; re-read `reduceMotion` then.
    static var displayOptionsChanged: AnyPublisher<Void, Never> {
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification).map { _ in () },
            // @Published sends before the value is stored: hop once so `reduceMotion` reads the new level.
            AppSettings.shared.$motionLevel.dropFirst().map { _ in () }.receive(on: DispatchQueue.main))
            .eraseToAnyPublisher()
    }
    /// "춤춰 줘", "응원해 줘", a focus well done: every desktop friend joins in (커서 친구, 대롱대롱 친구, 풀밭 친구들).
    static let celebrate = PassthroughSubject<PoseCard, Never>()
}

/// 꾸미기 > 움직임 (AppSettings.motionLevel). Raw values are saved; never rename one.
enum MotionLevel: String, CaseIterable {
    case auto, calm, bouncy

    var label: String {
        switch self {
        case .auto: return L("자동")
        case .calm: return L("잔잔하게")
        case .bouncy: return L("통통")
        }
    }
}

/// One frame's alpha mask, for click-through on transparent pixels: the window takes the mouse only over the drawing.
struct AlphaHit: Equatable {
    let width: Int, height: Int
    /// Row-major, top row first, 0...255.
    let alpha: [UInt8]

    /// Pixels at or above this alpha (0...1) count as the drawing.
    static let threshold = 0.3

    init(width: Int, height: Int, alpha: [UInt8]) {
        precondition(alpha.count == width * height)
        self.width = width; self.height = height; self.alpha = alpha
    }

    /// The image's alpha at its own pixel size (nil for an empty image). Build once per frame, not per tick.
    init?(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return nil }
        var a = [UInt8](repeating: 0, count: cg.width * cg.height)
        let drawn = a.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))   // the context's memory is top row first
            return true
        }
        guard drawn else { return nil }
        self.init(width: cg.width, height: cg.height, alpha: a)
    }

    /// Whether `point` (in a view of `size`, y up, the frame stretched over it) lands on the drawing.
    func hits(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { return false }
        let x = Int(point.x / size.width * CGFloat(width))
        let y = Int((1 - point.y / size.height) * CGFloat(height))
        return Double(alpha[min(height - 1, y) * width + min(width - 1, x)]) >= Self.threshold * 255
    }
}

/// Turns mouse down/move/up into one single click, a double click or a drag. Feed it events and `poll` it once
/// `pollAt` has passed: a single click is only sure when no second click came within `doubleWindow`.
struct ClickRecognizer {
    enum Gesture: Equatable {
        case single(CGPoint), double(CGPoint)
        case dragBegan(CGPoint), dragged(CGPoint)
        /// `velocity` in points per second at release, zero when the hand stopped before letting go (a drop, not a throw).
        case dragEnded(CGPoint, velocity: CGVector)
    }

    static let doubleWindow: TimeInterval = 0.28
    /// Moving this far with the button down makes it a drag.
    static let slop: CGFloat = 4
    /// Held still this long before release: no throw.
    static let throwStale: TimeInterval = 0.1

    private var down: (p: CGPoint, t: TimeInterval)?
    private var pending: (p: CGPoint, t: TimeInterval)?   // a first click waiting for its pair
    private var second = false
    private var dragging = false
    private var last: (p: CGPoint, t: TimeInterval)?
    private var velocity = CGVector.zero

    /// When to call `poll` to get a waiting single click (nil: nothing waits).
    var pollAt: TimeInterval? { pending.map { $0.t + Self.doubleWindow } }

    /// A press; returns the earlier single click when its window ran out before anyone polled.
    mutating func mouseDown(_ p: CGPoint, at t: TimeInterval) -> [Gesture] {
        let late = poll(at: t)
        second = pending != nil
        down = (p, t); last = (p, t); velocity = .zero; dragging = false
        return late
    }

    mutating func mouseMoved(_ p: CGPoint, at t: TimeInterval) -> [Gesture] {
        guard let d = down else { return [] }
        if let l = last, t > l.t { velocity = CGVector(dx: (p.x - l.p.x) / (t - l.t), dy: (p.y - l.p.y) / (t - l.t)) }
        last = (p, t)
        if dragging { return [.dragged(p)] }
        guard hypot(p.x - d.p.x, p.y - d.p.y) > Self.slop else { return [] }
        dragging = true; pending = nil; second = false
        return [.dragBegan(d.p), .dragged(p)]
    }

    mutating func mouseUp(_ p: CGPoint, at t: TimeInterval) -> [Gesture] {
        guard down != nil else { return [] }
        down = nil
        if dragging {
            dragging = false
            let fresh = last.map { t - $0.t <= Self.throwStale } ?? false
            return [.dragEnded(p, velocity: fresh ? velocity : .zero)]
        }
        if second { second = false; pending = nil; return [.double(p)] }
        pending = (p, t)
        return []
    }

    /// The waiting single click once its double-click window is over.
    mutating func poll(at t: TimeInterval) -> [Gesture] {
        guard let w = pending, down == nil, t - w.t > Self.doubleWindow else { return [] }
        pending = nil
        return [.single(w.p)]
    }

    /// A menu opens mid-press and swallows the release: a drag ends where it is (no throw), a press or a click still
    /// waiting for its pair is dropped, and the next press starts clean. Feed what it returns like any other gesture.
    mutating func cancel(at p: CGPoint) -> [Gesture] {
        defer { self = ClickRecognizer() }
        return dragging ? [.dragEnded(p, velocity: .zero)] : []
    }
}

/// What a friend's hotspot takes clicks on, in the hotspot's own points (y up): the frame's drawn pixels where it is
/// drawn (the whole box with no mask), or a free `outline`, plus `extra` boxes, all moved by `transform`.
struct HotspotShape: Equatable {
    var hit: AlphaHit?
    var drawn: CGRect = .zero
    /// Facing left: the frame drawn mirrored.
    var flipped = false
    var outline: CGPath?
    var extra: [CGRect] = []
    var transform = CGAffineTransform.identity

    /// One rect per run of drawn pixels in a row: the same pixels `AlphaHit.hits` says yes to.
    var path: CGPath {
        let p = CGMutablePath()
        if let outline {
            p.addPath(outline, transform: transform)
        } else if let hit, hit.width > 0, hit.height > 0 {
            let cw = drawn.width / CGFloat(hit.width), ch = drawn.height / CGFloat(hit.height)
            let on = UInt8(min(255, (AlphaHit.threshold * 255).rounded(.up)))
            for y in 0..<hit.height {
                var x = 0
                while x < hit.width {
                    guard hit.alpha[y * hit.width + x] >= on else { x += 1; continue }
                    let start = x
                    while x < hit.width, hit.alpha[y * hit.width + x] >= on { x += 1 }
                    let lo = flipped ? hit.width - x : start
                    p.addRect(CGRect(x: drawn.minX + CGFloat(lo) * cw, y: drawn.maxY - CGFloat(y + 1) * ch,
                                     width: CGFloat(x - start) * cw, height: ch), transform: transform)
                }
            }
        } else if !drawn.isEmpty {
            p.addRect(drawn, transform: transform)
        }
        for r in extra { p.addRect(r, transform: transform) }
        return p
    }
}

/// A friend's own little see-through window that takes its clicks, the way a real element takes its own click. The
/// drawing panels let every click through for good (`ignoresMouseEvents` set once, never toggled, no hover watching):
/// this one sits over the friend, moved with it each time it is drawn, and fills only its `HotspotShape` at alpha 1/255.
/// Its `ignoresMouseEvents` is never set, so the window server sends a click on a clear pixel on to the window below.
/// A drag past `growAfter` grows it over the whole screen one level up, so the press never slips off a friend that
/// moves under the cursor; the release (or a menu that took it) puts it back.
final class HotspotPanel: NSPanel {
    /// Points the press moves before the hotspot covers the screen.
    static let growAfter: CGFloat = 5
    /// Low enough to be invisible, enough for the window server to count the pixel as the window's.
    static let alpha: CGFloat = 1.0 / 255
    /// QA renders and tests: hotspots are never put on the screen, so none takes a real click.
    static var qaInert = false

    /// Every press, drag, release, right click and move over it, as AppKit sends them.
    var onMouse: ((NSEvent) -> Void)?
    private(set) var grown = false
    private(set) var shape: HotspotShape?
    private let fill = CAShapeLayer()
    private var home = (frame: CGRect.zero, level: NSWindow.Level.floating)
    private var downAt: CGPoint?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        sharingType = .none   // nothing to see
        let v = HotspotView()
        v.wantsLayer = true
        fill.fillColor = NSColor(white: 1, alpha: Self.alpha).cgColor
        fill.actions = ["path": NSNull(), "hidden": NSNull()]
        v.layer?.addSublayer(fill)
        contentView = v
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Over the friend now: `frame` in screen points, `shape` in its own. Only what changed is sent on, and nothing
    /// moves while it is grown for a drag. Shown again, it comes in front of its level, or just over window `above`.
    func place(_ frame: CGRect, _ shape: HotspotShape, level: NSWindow.Level, above: Int? = nil) {
        home = (frame, level)
        if grown, NSEvent.pressedMouseButtons & 1 == 0 { shrink() }   // a release it never saw
        guard !grown else { return }
        if self.frame != frame { setFrame(frame, display: false) }
        if self.level != level { self.level = level }
        if shape != self.shape { self.shape = shape; fill.path = shape.path }
        if !isVisible, !Self.qaInert { if let above { order(.above, relativeTo: above) } else { orderFrontRegardless() } }
    }

    /// The friend is gone or hidden: nothing left to click.
    func hide() {
        shrink()
        downAt = nil
        if isVisible { orderOut(nil) }
    }

    /// A press moved far enough from where it went down to grow.
    static func grows(from a: CGPoint, to b: CGPoint) -> Bool { hypot(b.x - a.x, b.y - a.y) >= growAfter }

    override func sendEvent(_ e: NSEvent) {
        let at = convertPoint(toScreen: e.locationInWindow)
        switch e.type {
        case .leftMouseDown: downAt = at
        case .leftMouseDragged: if !grown, let d = downAt, Self.grows(from: d, to: at) { grow(at: at) }
        default: break
        }
        switch e.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .mouseMoved, .mouseEntered, .mouseExited: onMouse?(e)
        default: super.sendEvent(e)
        }
        switch e.type {
        case .leftMouseUp, .rightMouseDown: downAt = nil; shrink()
        case .leftMouseDown where NSEvent.pressedMouseButtons & 1 == 0 && e.modifierFlags.contains(.control):
            downAt = nil; shrink()   // control click: its menu took the release
        default: break
        }
    }

    private func grow(at p: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? self.screen else { return }
        grown = true
        fill.isHidden = true
        contentView?.layer?.backgroundColor = NSColor(white: 1, alpha: Self.alpha).cgColor
        level = NSWindow.Level(home.level.rawValue + 1)
        setFrame(screen.visibleFrame, display: false)
    }

    private func shrink() {
        guard grown else { return }
        grown = false
        contentView?.layer?.backgroundColor = nil
        fill.isHidden = false
        level = home.level
        setFrame(home.frame, display: false)
    }
}

/// Takes the first click (the panel never becomes key) and the moves while over it; the panel hands them on.
private final class HotspotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The right click (or control click) on every 데스크톱 친구: the friend's own items, then 오늘의 운세 ▸, 데스크톱 친구 ▸
/// (the quick on/off, 집중) and 설정 열기. Built fresh each time, so no menu is popped from two places or hung under two parents.
enum FriendMenu {
    /// Opens the dashboard on 설정. Set by StatusItemController.
    static var openSettings: (() -> Void)?
    /// A friend's menu is up. It runs its own loop while timers keep ticking, so the 커서 친구 holds still meanwhile.
    private(set) static var isOpen = false

    /// An item that runs `run`; the item keeps its action alive.
    static func item(_ title: String, on: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        let a = MenuAction(run)
        item.target = a
        item.representedObject = a
        item.state = on ? .on : .off
        return item
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    /// Each friend on or off, then 집중 시작 / 그만하기 and 놀이 ▸. Also fills the menu bar's 데스크톱 친구 submenu.
    static func desktopItems() -> [NSMenuItem] {
        let focus = FocusCenter.shared
        return DesktopFriends.toggles.map { t in item(t.title, on: t.isOn()) { t.set(!t.isOn()) } } + [
            .separator(),
        ] + sponsorItems + [
            item(focus.running ? L("집중 그만하기") : L("집중 시작")) { if focus.running { focus.stop() } else { focus.start() } },
            item(L("숨 고르기 (30초)")) { BreathCenter.shared.open() },
            submenu(L("놀이"), playItems()),
            item(L("포스트잇 붙이기")) { StickyBoard.shared.addNote() },
        ] + SocialBus.menuItems() + RemoteMeet.menuItems() + OfficeCenter.menuItems()
    }

    /// 후원 친구 지금 보기 (the direct build only).
    private static var sponsorItems: [NSMenuItem] {
        #if MAS
        []
        #else
        [item(L("후원 친구 지금 보기")) { SponsorCenter.shared.showNow() }]
        #endif
    }

    /// 놀이 ▸: 놀이 모드 (the keyboard one) and its star games, then the click games. Each game adds its own items here.
    static func playItems() -> [NSMenuItem] {
        [item(PlayMode.shared.isPlaying ? L("놀이 그만하기") : L("놀이 모드 시작")) {
            if PlayMode.shared.isPlaying { PlayMode.shared.end() } else { PlayMode.shared.start() }
        },
         item(L("별 줍기")) { StarGame.shared.start(duel: false) },
         item(L("2인 대결")) { StarGame.shared.start(duel: true) },
         .separator()] + ClickGames.menuItems() + [.separator(), Lunch.menuItem(), GroupDraw.menuItem()] + SeasonPanel.menuItems()
    }

    static func build(_ own: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        own.forEach(menu.addItem)
        if !own.isEmpty { menu.addItem(.separator()) }
        menu.addItem(submenu(L("오늘의 운세"), Fortune.menuItems()))
        menu.addItem(submenu(L("데스크톱 친구"), desktopItems()))
        menu.addItem(item(L("설정 열기")) { openSettings?() })
        return menu
    }

    /// Shows the menu at `event` and returns once it is closed. A 퀵물어보기 bubble over the friend closes first.
    static func pop(_ own: [NSMenuItem], with event: NSEvent, for view: NSView) {
        MainActor.assumeIsolated { FriendQuickAsk.shared.close() }
        isOpen = true
        defer { isOpen = false }
        NSMenu.popUpContextMenu(build(own), with: event, for: view)
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    /// After the menu has fully let go: a 치우기 or the 다른 도시 검색 dialog then runs with FriendMenu.isOpen false
    /// and the friend's press already ended.
    @objc func fire() { DispatchQueue.main.async(execute: run) }
}

/// A friend hanging from `anchor` on a springy string: a damped spring pendulum. Drag it (`grab`/`drag`),
/// let go with a throw (`release`), blow on it (`wind`). Step it every frame; stop the timer once `isSettled`.
struct Dangle {
    var anchor: CGPoint
    var restLength: CGFloat
    /// Spring and gravity per unit mass: it hangs `gravity / stiffness` below `restLength`.
    var stiffness: CGFloat = 60
    var gravity: CGFloat = 900
    /// Velocity lost per second (1/s); higher settles sooner.
    var damping: CGFloat = 1.8
    /// The string never gets longer than this many rest lengths.
    var maxStretch: CGFloat = 2.5
    /// A string that does not stretch: it swings on a fixed radius (`hangLength`) like a swing ride, no bounce.
    var taut = false
    static let maxThrow: CGFloat = 3000

    private(set) var position: CGPoint
    private(set) var velocity = CGVector.zero
    private(set) var held = false

    init(anchor: CGPoint, restLength: CGFloat) {
        self.anchor = anchor
        self.restLength = restLength
        position = .zero
        position = equilibrium
    }

    /// String length when it hangs still: rest plus the sag, but never past the longest string (a short string pins there).
    var hangLength: CGFloat { min(restLength + gravity / stiffness, restLength * maxStretch) }
    /// Where it rests with no wind.
    var equilibrium: CGPoint { CGPoint(x: anchor.x, y: anchor.y - hangLength) }
    /// Swing angle from straight down in radians, positive when it swings right (rotate the sprite by it).
    var angle: CGFloat { atan2(position.x - anchor.x, anchor.y - position.y) }
    /// String length over the hanging length (1 = hanging still): squash and stretch the sprite by it.
    var stretch: CGFloat { hypot(position.x - anchor.x, position.y - anchor.y) / hangLength }
    var isSettled: Bool {
        !held && hypot(velocity.dx, velocity.dy) < 2 && hypot(position.x - equilibrium.x, position.y - equilibrium.y) < 0.5
    }

    mutating func grab(at p: CGPoint) { held = true; drag(to: p) }
    mutating func drag(to p: CGPoint) { guard held else { return }; position = limited(p); velocity = .zero }
    /// Lets go; `velocity` from ClickRecognizer.dragEnded throws it.
    mutating func release(velocity v: CGVector = .zero) {
        held = false
        let s = hypot(v.dx, v.dy), k = s > Self.maxThrow ? Self.maxThrow / s : 1
        velocity = CGVector(dx: v.dx * k, dy: v.dy * k)
    }

    /// A push while it hangs free (a cursor brushing past, a cheer): adds `v`, the speed capped at `maxThrow`.
    mutating func nudge(_ v: CGVector) {
        guard !held else { return }
        release(velocity: CGVector(dx: velocity.dx + v.dx, dy: velocity.dy + v.dy))
    }

    /// A knock from a neighbour: moved by `d`, its velocity now `v`. Nothing while held.
    mutating func bump(by d: CGVector, velocity v: CGVector) {
        guard !held else { return }
        position = limited(CGPoint(x: position.x + d.dx, y: position.y + d.dy))
        velocity = v
        if taut { onCircle() }
    }

    /// Advances `dt` seconds (capped at 0.1). `wind`: sideways push in points per second squared, + to the right.
    mutating func step(dt: TimeInterval, wind: CGFloat = 0) {
        guard !held else { return }
        var left = min(0.1, max(0, dt))
        while left > 0 {   // fixed small steps: stable for any frame rate
            let h = CGFloat(min(left, 1.0 / 240)); left -= Double(h)
            let dx = position.x - anchor.x, dy = position.y - anchor.y
            let len = max(0.001, hypot(dx, dy))
            let pull = taut ? 0 : -stiffness * (len - restLength) / len
            velocity.dx += (pull * dx + wind - damping * velocity.dx) * h
            velocity.dy += (pull * dy - gravity - damping * velocity.dy) * h
            position = limited(CGPoint(x: position.x + velocity.dx * h, y: position.y + velocity.dy * h))
            if taut { onCircle() }
        }
    }

    /// Taut: back on the circle of `hangLength` round the anchor, the speed along the string gone.
    private mutating func onCircle() {
        let dx = position.x - anchor.x, dy = position.y - anchor.y, len = max(0.001, hypot(dx, dy))
        let ux = dx / len, uy = dy / len, r = hangLength
        position = CGPoint(x: anchor.x + ux * r, y: anchor.y + uy * r)
        let out = velocity.dx * ux + velocity.dy * uy
        velocity.dx -= out * ux; velocity.dy -= out * uy
    }

    /// Keeps `p` within the longest string; at the limit the outward speed goes.
    private mutating func limited(_ p: CGPoint) -> CGPoint {
        let dx = p.x - anchor.x, dy = p.y - anchor.y, len = hypot(dx, dy), most = restLength * maxStretch
        guard len > most else { return p }
        let ux = dx / len, uy = dy / len
        let out = velocity.dx * ux + velocity.dy * uy
        if out > 0 { velocity.dx -= out * ux; velocity.dy -= out * uy }
        return CGPoint(x: anchor.x + ux * most, y: anchor.y + uy * most)
    }
}

/// A thrown friend in flight: gravity, bounces off the side walls and ceiling, and lands on the floor or on a ledge
/// (the front window's top) when it comes down onto it. `position` is the bottom middle of the drawing; the caller
/// insets `walls` by the drawing's size (x range for that middle, maxY for the feet). Step it until `isSettled`.
struct Fling {
    var position: CGPoint
    var velocity: CGVector
    var walls: CGRect
    var ledge: (minX: CGFloat, maxX: CGFloat, y: CGFloat)?
    var gravity: CGFloat = 2400   // the same as the 커서 친구's drop
    /// Share of the vertical speed kept at a bounce, and of the sideways speed at each floor hit.
    var restitution: CGFloat = 0.45
    var friction: CGFloat = 0.7
    /// Slower than this off the floor it stops bouncing and rests.
    static let rest: CGFloat = 120

    /// Hits that bounced it back (floor, ledge, walls, ceiling).
    private(set) var bounces = 0
    private(set) var landedOnLedge = false
    /// Tumble angle in radians, + clockwise when it flies right; eases back upright while it slides.
    private(set) var spin: CGFloat = 0
    /// The hardest floor or ledge hit (its vertical speed), for the landing reaction.
    private(set) var impact: CGFloat = 0

    init(at p: CGPoint, velocity v: CGVector, walls: CGRect, ledge: (minX: CGFloat, maxX: CGFloat, y: CGFloat)? = nil) {
        let s = hypot(v.dx, v.dy), k = s > Dangle.maxThrow ? Dangle.maxThrow / s : 1
        position = p
        velocity = CGVector(dx: v.dx * k, dy: v.dy * k)
        self.walls = walls
        self.ledge = ledge
    }

    private func onLedge(_ x: CGFloat) -> Bool { ledge.map { x >= $0.minX && x <= $0.maxX } ?? false }
    /// Lying on the floor or the ledge, no vertical speed.
    private var resting: Bool {
        velocity.dy == 0 && (position.y == walls.minY || onLedge(position.x) && position.y == ledge?.y)
    }
    var isSettled: Bool { resting && abs(velocity.dx) < 30 && abs(spin) < 0.05 }

    /// Advances `dt` seconds (capped at 0.1) in fixed small steps.
    mutating func step(dt: TimeInterval) {
        var left = min(0.1, max(0, dt))
        while left > 0 {
            let h = CGFloat(min(left, 1.0 / 240)); left -= Double(h)
            if resting {
                // Slides to a stop and gets back on its feet.
                velocity.dx -= (velocity.dx < 0 ? -1 : 1) * min(abs(velocity.dx), 1500 * h)
                position.x = min(max(position.x + velocity.dx * h, walls.minX), walls.maxX)
                spin *= exp(-12 * h)
                continue
            }
            velocity.dy -= gravity * h
            let was = position
            position.x += velocity.dx * h
            position.y += velocity.dy * h
            spin = remainder(spin + velocity.dx * h * 0.004, 2 * .pi)
            if position.x < walls.minX || position.x > walls.maxX {
                position.x = min(max(position.x, walls.minX), walls.maxX)
                velocity.dx *= -0.5
                bounces += 1
            }
            if position.y > walls.maxY, velocity.dy > 0 {
                position.y = walls.maxY
                velocity.dy *= -0.5
                bounces += 1
            }
            // Coming down onto the ledge from above, or onto the floor.
            if let l = ledge, velocity.dy < 0, was.y >= l.y, position.y < l.y, onLedge(position.x), l.y > walls.minY {
                hit(at: l.y, ledge: true)
            } else if position.y <= walls.minY {
                hit(at: walls.minY, ledge: false)
            }
        }
    }

    private mutating func hit(at y: CGFloat, ledge: Bool) {
        position.y = y
        landedOnLedge = ledge
        impact = max(impact, abs(velocity.dy))
        velocity.dx *= friction
        velocity.dy = -velocity.dy * restitution
        if velocity.dy < Self.rest { velocity.dy = 0 } else { bounces += 1 }
    }
}

/// 창에 매달기: a friend tied by a rubber band to a spot on another app's window. Within `length` the band is slack and
/// the friend falls, or stands on the window's top edge (`floor`); past it the band pulls back, so a friend pulled away
/// and let go springs back and bounces. `position` is the bottom middle of the drawing, like Fling's. Fixed steps.
struct RubberBand {
    static let length: CGFloat = 48
    static let step: TimeInterval = 1.0 / 60
    /// At most this much time is caught up per call (a stall does not fire it off).
    static let maxLag: TimeInterval = 0.125
    static let maxSpeed: CGFloat = 2400
    /// Share of the speed kept bouncing off the window's top edge.
    static let bounce: CGFloat = 0.7
    /// A let-go is held to this much speed each way.
    static let release = CGVector(dx: 650, dy: 850)
    /// Pulled farther than `length` × this, the band lets go.
    static let snapAt: CGFloat = 4

    // The knobs to tune by hand: the band's pull per point past `length`, its damping while stretched, gravity.
    var stiffness: CGFloat = 80
    var damping: CGFloat = 4
    var gravity: CGFloat = 2400

    var anchor: CGPoint
    /// The window's top edge it stands on; nil hanging by a side.
    var floor: (minX: CGFloat, maxX: CGFloat, y: CGFloat)?
    var position: CGPoint
    var velocity = CGVector.zero
    private var lag: TimeInterval = 0
    /// Hits on the floor that bounced it back up.
    private(set) var bounces = 0

    init(anchor: CGPoint, floor: (minX: CGFloat, maxX: CGFloat, y: CGFloat)?, position: CGPoint) {
        self.anchor = anchor; self.floor = floor; self.position = position
    }

    private var distance: CGFloat { hypot(position.x - anchor.x, position.y - anchor.y) }
    var stretch: CGFloat { max(0, distance - Self.length) }
    var snapped: Bool { distance > Self.length * Self.snapAt }
    /// On the window's top edge, not going up.
    var standing: Bool {
        guard let f = floor else { return false }
        return position.y == f.y && position.x >= f.minX && position.x <= f.maxX && velocity.dy <= 0
    }
    /// Still: standing, or hanging where the band holds it up.
    var isSettled: Bool {
        hypot(velocity.dx, velocity.dy) < 8 && (standing || abs(stretch - gravity / stiffness) < 3)
    }

    /// Let go with `v`, held to `release`.
    mutating func release(_ v: CGVector) {
        velocity = CGVector(dx: min(max(v.dx, -Self.release.dx), Self.release.dx), dy: min(max(v.dy, -Self.release.dy), Self.release.dy))
        lag = 0
    }

    /// The window moved: everything moves with it.
    mutating func follow(_ a: CGPoint, floor f: (minX: CGFloat, maxX: CGFloat, y: CGFloat)?) {
        position.x += a.x - anchor.x; position.y += a.y - anchor.y
        anchor = a
        floor = f
    }

    mutating func step(dt: TimeInterval) {
        lag = min(Self.maxLag, lag + max(0, dt))
        while lag >= Self.step - 1e-9 {
            lag -= Self.step
            let h = CGFloat(Self.step), on = standing
            if !on { velocity.dy -= gravity * h }
            let dx = position.x - anchor.x, dy = position.y - anchor.y, d = hypot(dx, dy)
            if d > Self.length {
                let pull = stiffness * (d - Self.length) * h, k = exp(-damping * h)
                velocity.dx = (velocity.dx - dx / d * pull) * k
                velocity.dy = (velocity.dy - dy / d * pull) * k
            }
            if on { velocity.dx *= exp(-8 * h); velocity.dy = max(0, velocity.dy) }
            let s = hypot(velocity.dx, velocity.dy)
            if s > Self.maxSpeed { velocity.dx *= Self.maxSpeed / s; velocity.dy *= Self.maxSpeed / s }
            let was = position
            position.x += velocity.dx * h
            position.y += velocity.dy * h
            if let f = floor, velocity.dy < 0, was.y >= f.y, position.y < f.y, position.x >= f.minX, position.x <= f.maxX {
                position.y = f.y
                velocity.dy = -velocity.dy * Self.bounce
                if velocity.dy < 60 { velocity.dy = 0 } else { bounces += 1 }
            }
        }
    }
}

/// What a friend does when it is clicked: a pose (gait), a little move (`pose`) and a mark over its head.
enum Reaction: String, CaseIterable {
    case hearts, jump, spin, blush, surprised, giggle, sneeze, dizzy, pout
    /// 빵빠레: a 후원 선물 (SponsorGifts), among the everyday ones once it is open.
    case party

    /// The everyday ones, picked at random; `dizzy` and `pout` come from clicking again and again (ClickCombo).
    static let cute: [Reaction] = [.hearts, .jump, .spin, .blush, .surprised, .giggle, .sneeze]
    /// `cute`, and 빵빠레 once that gift is open.
    static var everyday: [Reaction] { cute + (SponsorGifts.shared.isOpen(.party) ? [.party] : []) }

    /// It turns about its middle (the others about their feet).
    var spins: Bool { self == .spin || self == .party }

    var duration: TimeInterval {
        switch self {
        case .jump: 0.9
        case .spin, .surprised: 1.0
        case .hearts, .giggle, .sneeze: 1.2
        case .party: 1.3
        case .blush: 1.4
        case .dizzy, .pout: 2.2
        }
    }

    /// Its pose; a friend without it shows its happy one (eat), then walk.
    var gait: BuddyGait {
        switch self {
        case .hearts, .giggle, .blush, .party: .special
        case .jump, .spin, .surprised, .sneeze: .stand
        case .dizzy: .dizzy
        case .pout: .sulk
        }
    }

    /// What pops over its head, if anything.
    var mark: (text: String, color: NSColor)? {
        switch self {
        case .hearts: ("♥", .systemPink)
        case .surprised: ("!", .systemOrange)
        case .blush: ("///", .systemPink)
        case .giggle: ("♪", .systemPurple)
        case .sneeze: (L("에취!"), .systemTeal)
        case .dizzy: ("@", .systemIndigo)
        case .pout: (L("흥!"), .systemRed)
        case .party: ("🎉", .systemYellow)
        case .jump, .spin: nil
        }
    }

    /// The move `t` seconds in: `lift` as a share of its height, a turn in radians, and a squash. Flat when still or done.
    func pose(_ t: TimeInterval, still: Bool) -> (lift: CGFloat, angle: CGFloat, sx: CGFloat, sy: CGFloat) {
        guard !still, t >= 0, t < duration else { return (0, 0, 1, 1) }
        func arc(_ over: TimeInterval) -> CGFloat {   // one hop over the first `over` seconds, 0...1
            guard t < over else { return 0 }
            let u = CGFloat(t / over)
            return 4 * u * (1 - u)
        }
        let deg = CGFloat.pi / 180
        switch self {
        case .hearts: return (arc(0.4) * 0.15, 0, 1, 1)
        case .jump: return (arc(0.6) * 0.6, 0, 1, 1)
        case .spin: return t < 0.6 ? (arc(0.6) * 0.15, 2 * .pi * CGFloat(t / 0.6), 1, 1) : (0, 0, 1, 1)
        case .surprised: return (arc(0.3) * 0.25, 0, t < 0.3 ? 0.94 : 1, t < 0.3 ? 1.08 : 1)
        case .giggle: return (0, 4 * deg * CGFloat(sin(t * 40)), 1, 1)
        case .blush: return (0, 3 * deg * CGFloat(sin(t * 8)), 1, 0.97)
        case .dizzy: return (0, 8 * deg * CGFloat(sin(t * 6)), 1, 1)
        case .sneeze:
            if t < 0.5 { let u = CGFloat(t / 0.5); return (0, 0, 1 + 0.05 * u, 1 - 0.15 * u) }   // 에... gathering
            let v = max(0, 1 - CGFloat((t - 0.5) / 0.3))   // 취! a jolt that fades
            return (0, 0, 1 + 0.1 * v, 1 - 0.1 * v)
        case .pout: return (0, 0, 1, 1)
        case .party: return (arc(0.5) * 0.35, t < 0.5 ? 2 * .pi * CGFloat(t / 0.5) : 0, 1, 1)   // up with one spin
        }
    }
}

/// Clicks in a row: each within `gap` of the last counts up. The third makes it dizzy, the fifth makes it pout and
/// starts over; the rest are a random cute reaction.
struct ClickCombo {
    static let gap: TimeInterval = 0.7
    private(set) var count = 0
    private var last: TimeInterval = -10

    mutating func click(at t: TimeInterval, pick: ([Reaction]) -> Reaction = { LinePick.pick("buddy.react", $0) }) -> Reaction {
        count = t - last <= Self.gap ? count + 1 : 1
        last = t
        if count == 3 { return .dizzy }
        if count >= 5 { count = 0; return .pout }
        return pick(Reaction.everyday)
    }
}

/// A little mark (♥, !, 에취!) rising over a friend's head and fading out.
enum FriendMark {
    /// QA renders only: the mark stays put, fully shown (offscreen renders skip animations).
    static var qa = false
    /// Layers named so: QA clears the last one before the next render.
    static let name = "friendMark"

    /// Over `rect` (the drawing, in `layer`'s coordinates), fading in and out within 0.9 s; no rise when `still`.
    static func pop(_ text: String, color: NSColor, over rect: CGRect, in layer: CALayer, still: Bool, scale: CGFloat) {
        let fs = max(10, rect.height * 0.35)
        let m = CATextLayer()
        m.name = name
        m.string = text
        m.fontSize = fs
        m.foregroundColor = color.cgColor
        m.alignmentMode = .center
        m.contentsScale = scale
        let w = fs * max(1, CGFloat(text.count) * 0.8)
        m.frame = CGRect(x: rect.midX - w / 2, y: rect.maxY - fs, width: w, height: fs * 1.2)
        layer.addSublayer(m)
        if qa { return }
        m.opacity = 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        let group = CAAnimationGroup()
        group.duration = 0.9
        if still {
            group.animations = [fade]
        } else {
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.byValue = min((layer.bounds.maxY - rect.maxY) * 0.9, rect.height * 0.8)   // a whole-screen panel: just over the head
            group.animations = [fade, rise]
        }
        m.add(group, forKey: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { m.removeFromSuperlayer() }
    }
}

/// The cursor's speed and how often it shakes: fast left-right reversals within `window`.
struct CursorMotion {
    static let window: TimeInterval = 0.8
    /// Only reversals faster than this sideways count as shaking.
    static let shakeSpeed: CGFloat = 900
    /// This many reversals within `window` = being shaken.
    static let shakeFlips = 4
    static let maxSpeed: CGFloat = 6000

    /// Points per second from the last two samples, capped at `maxSpeed`.
    private(set) var speed: CGFloat = 0
    private(set) var velocity = CGVector.zero
    private var last: (p: CGPoint, t: TimeInterval)?
    private var side = 0
    private var flips: [TimeInterval] = []

    /// Fast reversals within `window` of the last sample.
    var directionChanges: Int { flips.count }
    var isShaking: Bool { flips.count >= Self.shakeFlips }

    /// One cursor sample; `t` monotonic seconds (systemUptime).
    mutating func feed(_ p: CGPoint, at t: TimeInterval) {
        defer { last = (p, t) }
        guard let l = last, t > l.t else { return }
        let dt = CGFloat(t - l.t)
        velocity = CGVector(dx: (p.x - l.p.x) / dt, dy: (p.y - l.p.y) / dt)
        speed = min(Self.maxSpeed, hypot(velocity.dx, velocity.dy))
        flips.removeAll { t - $0 > Self.window }
        guard abs(velocity.dx) > Self.shakeSpeed else { return }
        let now = velocity.dx > 0 ? 1 : -1
        if side != 0, now != side { flips.append(t) }
        side = now
    }

    /// Forget the shaking (after reacting to it).
    mutating func reset() { flips = []; side = 0 }
}

/// A small glass chime made in memory: no sound files. Each 대롱대롱 친구 rings its own note of one pentatonic scale,
/// so several at once still sound together.
enum ChimeSound {
    /// (frequency ratio to the note, loudness, decay per second). Our own bell-like overtones.
    typealias Partial = (ratio: Double, amp: Double, decay: Double)
    static let partials: [Partial] = [(1, 1, 2.4), (2.4, 0.42, 4.2), (4.1, 0.2, 7), (6.8, 0.08, 11)]
    /// A major pentatonic from E6, one per hanging slot.
    static let notes: [Double] = [1318.5, 1480, 1661.2, 1975.5, 2217.5]
    static let sampleRate = 44_100
    static let seconds = 1.6

    /// A mono 16-bit PCM WAV of decaying sine partials, with a 2 ms fade-in against the click.
    static func make(freq: Double, partials: [Partial] = partials, seconds: Double = seconds, sampleRate: Int = sampleRate) -> Data {
        let n = max(0, Int(seconds * Double(sampleRate)))
        let total = partials.reduce(0) { $0 + $1.amp }
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            var v = 0.0
            for p in partials { v += p.amp * exp(-p.decay * t) * sin(2 * .pi * freq * p.ratio * t) }
            let s = Int16(max(-1, min(1, v / max(total, 1) * min(1, t / 0.002))) * 30_000)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return wav(pcm, sampleRate: sampleRate)
    }

    /// `pcm` (mono 16-bit little-endian samples) with its WAV header.
    static func wav(_ pcm: Data, sampleRate: Int) -> Data {
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)   // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        return wav + pcm
    }

    private static var players: [Int: AVAudioPlayer] = [:]
    private static var lastRing: TimeInterval = 0

    /// Rings note `index` (wrapped) at `volume` 0...1, at most every 0.15 s and never while the bubble is muted (meetings)
    /// or 꾸미기 > 효과음 is off.
    static func play(_ index: Int, volume: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard volume > 0, AppSettings.shared.friendSounds, now - lastRing >= 0.15, !SpeechBubbleCenter.shared.isMuted() else { return }
        lastRing = now
        let i = ((index % notes.count) + notes.count) % notes.count
        if players[i] == nil { players[i] = try? AVAudioPlayer(data: make(freq: notes[i])) }
        guard let p = players[i] else { return }
        p.volume = Float(min(1, volume))
        p.currentTime = 0
        p.play()
    }
}
