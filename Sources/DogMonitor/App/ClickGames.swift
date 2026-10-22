import AppKit
import Combine
import QuartzCore

// MARK: Rules (pure)

/// 숨바꼭질's three rounds: when the one now began, how long each took, when its hint is due. Pure (ClickGamesTests).
struct HideRounds: Equatable {
    static let count = 3
    static let hintAfter: TimeInterval = 15
    /// Seconds each round took, in order.
    private(set) var times: [TimeInterval] = []
    private(set) var startedAt: TimeInterval

    init(at t: TimeInterval) { startedAt = t }

    /// The round now, from 0.
    var round: Int { times.count }
    var isOver: Bool { times.count >= Self.count }
    var hintAt: TimeInterval { startedAt + Self.hintAfter }
    var total: TimeInterval { times.reduce(0, +) }

    /// The next round starts at `t`.
    mutating func begin(at t: TimeInterval) { startedAt = t }

    /// Found at `t`: that round's seconds (nil once all three are done).
    mutating func found(at t: TimeInterval) -> TimeInterval? {
        guard !isOver else { return nil }
        times.append(max(0, t - startedAt))
        return times.last
    }
}

/// Where 숨바꼭질's friend hides: behind an edge (PlayPhysics.platforms: the solid bottom is the Dock's top, the rest
/// are the visible parts of window tops), only its top `peek` showing over it.
enum HideSpots {
    static let peek: CGFloat = 0.4

    /// The edges a friend `size` big fits behind: wide enough, with room for its head under `top` (the menu bar).
    static func usable(_ edges: [PlayPlatform], size: CGSize, top: CGFloat) -> [PlayPlatform] {
        edges.filter { $0.maxX - $0.minX >= size.width * 1.5 && $0.y + size.height * peek <= top }
    }

    /// The next spot: never the `last` edge while there is another, a window two times in three when there is one,
    /// and `x` (its middle) inside the edge. `random(n)` is 0..<n, `unit()` 0...1.
    static func pick(_ edges: [PlayPlatform], size: CGSize, last: PlayPlatform?,
                     random: (Int) -> Int = { Int.random(in: 0..<$0) }, unit: () -> CGFloat = { .random(in: 0...1) }) -> (edge: PlayPlatform, x: CGFloat)? {
        let fresh = edges.filter { $0 != last }
        let pool = fresh.isEmpty ? edges : fresh
        let windows = pool.filter { !$0.solid }
        let from = !windows.isEmpty && (windows.count == pool.count || random(3) < 2) ? windows : pool
        guard !from.isEmpty else { return nil }
        let e = from[min(from.count - 1, max(0, random(from.count)))]
        let lo = e.minX + size.width / 2, hi = max(lo, e.maxX - size.width / 2)
        return (e, lo + (hi - lo) * min(1, max(0, unit())))
    }
}

/// 두더지잡기's pace: 30 seconds, pops coming quicker and staying up shorter as it goes, more of them up at once.
enum MoleRules {
    static let length: TimeInterval = 30

    private static func progress(_ t: TimeInterval) -> Double { min(1, max(0, t / length)) }
    /// Seconds to the next pop `t` seconds in: 0.9 at first, 0.45 at the end.
    static func gap(_ t: TimeInterval) -> TimeInterval { 0.9 - 0.45 * progress(t) }
    /// How long one stays up: 1.4 s, down to 0.75.
    static func up(_ t: TimeInterval) -> TimeInterval { 1.4 - 0.65 * progress(t) }
    /// At most this many up at once: 1, 2 from 10 s, 3 from 20 s.
    static func most(_ t: TimeInterval) -> Int { 1 + min(2, max(0, Int(t / 10))) }

    /// A middle across `lo...hi` for one `width` wide, clear of the ones up at `taken`; nil when a few tries find none.
    static func spot(lo: CGFloat, hi: CGFloat, width: CGFloat, taken: [CGFloat], unit: () -> CGFloat = { .random(in: 0...1) }) -> CGFloat? {
        let a = lo + width / 2, b = hi - width / 2
        guard b >= a else { return nil }
        for _ in 0..<8 {
            let x = a + (b - a) * min(1, max(0, unit()))
            if taken.allSatisfy({ abs($0 - x) >= width * 1.3 }) { return x }
        }
        return nil
    }
}

/// 두더지잡기's points and the best so far.
struct MoleScore: Equatable {
    private(set) var score = 0
    private(set) var best: Int

    init(best: Int) { self.best = max(0, best) }

    mutating func bonk() { score += 1 }
    /// The game is over: true when it beat the best, which it now is.
    mutating func finish() -> Bool {
        guard score > best else { return false }
        best = score
        return true
    }
}

/// 공놀이: a goal is the ball coming to rest on the 러그, and the fetcher picks it up once it touches it.
enum BallRules {
    /// The ball's bottom middle `feet` lies on `rug` (its top edge too: the ball can rest on it).
    static func goal(_ feet: CGPoint, rug: CGRect?) -> Bool {
        guard let r = rug else { return false }
        return feet.x >= r.minX && feet.x <= r.maxX && feet.y >= r.minY && feet.y <= r.maxY + 1
    }

    /// The fetcher (its drawing `body`) touches the ball, middle `ball`, `radius` round.
    static func reaches(_ body: CGRect, ball: CGPoint, radius: CGFloat) -> Bool {
        body.insetBy(dx: -radius, dy: -radius).contains(ball)
    }
}

// MARK: The games

/// "놀이" click games, played with the mouse only (no keys, no focus, no permission): 숨바꼭질, 공놀이, 두더지잡기.
/// One at a time, and never with 놀이 모드. Nothing exists or ticks while none is on; in one, a frame timer only while
/// something moves (the ball), everything else is one-shot timers and Core Animation. Screen sleep, a session switch
/// or a display change ends it; so does 그만하기 in a game piece's right-click menu.
final class ClickGames: ObservableObject {
    static let shared = ClickGames()
    /// 두더지잡기's best score.
    static let moleBestKey = "games.moleBest"

    enum Kind: CaseIterable {
        case hide, ball, mole

        var title: String {
            switch self {
            case .hide: return L("숨바꼭질")
            case .ball: return L("공놀이")
            case .mole: return L("두더지잡기")
            }
        }
    }

    @Published private(set) var playing: Kind?
    private var game: ClickGame?
    private var bag: Set<AnyCancellable> = []

    func start(_ k: Kind) {
        stop()
        PlayMode.shared.end()
        playing = k
        let g: ClickGame = switch k {
        case .hide: HideAndSeek()
        case .ball: BallGame()
        case .mole: MoleGame()
        }
        game = g
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.screensDidSleepNotification)
            .merge(with: ws.publisher(for: NSWorkspace.sessionDidResignActiveNotification),
                   NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .sink { [weak self] _ in self?.stop() }
            .store(in: &bag)
        g.start()
    }

    func stop() {
        guard let g = game else { return }
        game = nil
        playing = nil
        bag = []
        g.stop()
    }

    func toggle(_ k: Kind) { if playing == k { stop() } else { start(k) } }

    /// 숨바꼭질, 공놀이, 두더지잡기 for a 놀이 menu: ticked while on; picking it again ends it.
    static func menuItems() -> [NSMenuItem] {
        Kind.allCases.map { k in FriendMenu.item(k.title, on: shared.playing == k) { shared.toggle(k) } }
    }

    /// A game piece's right click: 그만하기 (and the shared items).
    fileprivate static func menu(_ e: NSEvent, for view: NSView) {
        FriendMenu.pop([FriendMenu.item(L("그만하기")) { shared.stop() }], with: e, for: view)
    }

    /// A line over `anchor` (by the cursor or the menu bar icon when nil), in the character's 말투.
    fileprivate static func say(_ text: String, at anchor: CGPoint? = nil) {
        SpeechBubbleCenter.shared.say(text: AssistantModel.persona().dress(text), source: .system, repeats: true,
                                      anchor: anchor.map { a -> () -> CGPoint? in { a } }, asked: true)
    }
}

private protocol ClickGame: AnyObject {
    func start()
    /// Takes everything off the screen and gives the friend back. ClickGames calls it once.
    func stop()
}

private func after(_ seconds: TimeInterval, _ run: @escaping () -> Void) -> Timer {
    let t = Timer(timeInterval: seconds, repeats: false) { _ in run() }
    RunLoop.main.add(t, forMode: .common)
    return t
}

private func every(_ seconds: TimeInterval, _ run: @escaping () -> Void) -> Timer {
    let t = Timer(timeInterval: seconds, repeats: true) { _ in run() }
    t.tolerance = seconds * 0.1
    RunLoop.main.add(t, forMode: .common)
    return t
}

private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// A character's poses at one size.
private struct Look {
    let frames: [BuddyGait: [NSImage]]
    let size: CGSize
    let smooth: Bool

    init(character: String?, pixelSize: CGFloat) {
        let c = MeadowFriends.cache(character: character, pixelSize: pixelSize)
        frames = BuddyGait.frames(c).filter { !$0.value.isEmpty }
        size = c.imageSize
        smooth = c.smooth
    }

    /// Frame `i` of `g`, or of standing when it lacks that pose.
    func pose(_ g: BuddyGait, _ i: Int = 0) -> NSImage? {
        guard let set = frames[g] ?? frames[.stand] ?? frames[.walk] else { return nil }
        return set[i % set.count]
    }
}

/// One thing a game shows: a small see-through panel over the windows that never becomes key, its drawing in `art`
/// (anchored at its bottom middle) clipped to the panel. With `onMouse` it takes clicks over all of itself.
private final class GamePiece {
    let panel: GamePanel
    let art = CALayer()
    var view: NSView { panel.contentView ?? NSView() }
    var onMouse: ((NSEvent) -> Void)? {
        get { (panel.contentView as? GameView)?.onMouse }
        set { (panel.contentView as? GameView)?.onMouse = newValue }
    }

    init(onMouse: ((NSEvent) -> Void)? = nil) {
        panel = GamePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = onMouse == nil
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        let v = GameView()
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        v.onMouse = onMouse
        art.anchorPoint = CGPoint(x: 0.5, y: 0)
        art.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull(), "bounds": NSNull()]
        v.layer?.addSublayer(art)
        panel.contentView = v
    }

    /// The panel at `frame` (screen points), in front.
    func show(_ frame: CGRect) {
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func dress(_ image: NSImage?, size: CGSize, smooth: Bool, left: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.contents = image
        art.bounds = CGRect(origin: .zero, size: size)
        art.contentsScale = panel.screen?.backingScaleFactor ?? 2
        art.magnificationFilter = smooth ? .linear : .nearest
        art.setAffineTransform(left ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    /// Its drawing's feet at `y` in the panel; slid there over `seconds` (none under 동작 줄이기).
    func slide(to y: CGFloat, from: CGFloat? = nil, seconds: TimeInterval = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.position = CGPoint(x: panel.frame.width / 2, y: y)
        CATransaction.commit()
        guard let from, seconds > 0, !DesktopKit.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = from
        a.toValue = y
        a.duration = seconds
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        art.add(a, forKey: "slide")
    }

    /// A mark (!, @, 골!) over its drawing.
    func mark(_ text: String, _ color: NSColor, over rect: CGRect) {
        guard let layer = view.layer else { return }
        FriendMark.pop(text, color: color, over: rect, in: layer, still: DesktopKit.reduceMotion, scale: panel.backingScaleFactor)
    }

    func remove() { panel.orderOut(nil) }
}

private final class GamePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click and hands mouse events on.
private final class GameView: NSView {
    var onMouse: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouse?(event) }
    override func mouseDragged(with event: NSEvent) { onMouse?(event) }
    override func mouseUp(with event: NSEvent) { onMouse?(event) }
    override func rightMouseDown(with event: NSEvent) { onMouse?(event) }
}

/// A right or control click on a piece: its menu. True when it was one.
private func menuClick(_ e: NSEvent, _ piece: GamePiece) -> Bool {
    guard e.type == .rightMouseDown || e.type == .leftMouseDown && e.modifierFlags.contains(.control) else { return false }
    ClickGames.menu(e, for: piece.view)
    return true
}

// MARK: 숨바꼭질

/// The character (the 커서 친구, lent like 놀이 모드) hides behind a window's top edge or the Dock, its head peeking
/// over. 15 s on, a hint; a click on the peeking part finds it: it pops out surprised and the time shows. Three rounds.
/// A round left alone for 90 s ends the game.
// ponytail: no hiding in a desktop folder; Finder's icon positions and clicks on them need Finder automation or Accessibility, which we never ask for
private final class HideAndSeek: ClickGame {
    private let look = Look(character: nil, pixelSize: MotionStore.shared.buddySize.pixelSize)
    private lazy var piece = GamePiece { [weak self] in self?.mouse($0) }
    private var rounds = HideRounds(at: now())
    private var spot: (edge: PlayPlatform, x: CGFloat)?
    private var hidden = false
    private var timers: [Timer] = []

    func start() {
        _ = CursorBuddy.shared.lendForPlay()
        ClickGames.say(L("숨바꼭질 시작! 제가 어디 숨었는지 찾아 보세요"))
        hide()
    }

    func stop() {
        timers.forEach { $0.invalidate() }; timers = []
        piece.remove()
        CursorBuddy.shared.giveBackFromPlay(feet: spot.map { CGPoint(x: $0.x, y: $0.edge.y) } ?? NSEvent.mouseLocation)
    }

    private func hide() {
        let m = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main,
              let primary = NSScreen.screens.first?.frame.height else { ClickGames.shared.stop(); return }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let edges = PlayPhysics.platforms(raw.compactMap { ListedWindow($0, primaryHeight: primary) },
                                          me: ProcessInfo.processInfo.processIdentifier, screen: s.visibleFrame, rug: nil)
        guard let pick = HideSpots.pick(HideSpots.usable(edges, size: look.size, top: s.visibleFrame.maxY), size: look.size, last: spot?.edge)
        else { ClickGames.shared.stop(); return }
        spot = pick
        hidden = true
        let w = look.size.width, h = look.size.height, shows = ceil(h * HideSpots.peek)
        piece.show(CGRect(x: pick.x - w / 2, y: pick.edge.y, width: w, height: shows))
        piece.dress(look.pose(.stand), size: look.size, smooth: look.smooth, left: Bool.random())
        piece.slide(to: shows - h)   // only its head over the edge
        rounds.begin(at: now())
        timers.forEach { $0.invalidate() }
        timers = [after(HideRounds.hintAfter) { [weak self] in self?.hint() },
                  after(90) { ClickGames.say(L("못 찾겠다 꾀꼬리! 다음에 또 해요")); ClickGames.shared.stop() }]
    }

    private func hint() {
        guard hidden, let spot else { return }
        ClickGames.say(spot.edge.solid ? L("힌트: 화면 아래쪽 독 근처가 수상해요") : L("힌트: 어느 창 위쪽에서 꼼지락 소리가 나요"))
        guard !DesktopKit.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "position.y")   // a little wriggle
        a.byValue = 3
        a.duration = 0.12
        a.autoreverses = true
        a.repeatCount = 4
        piece.art.add(a, forKey: "wriggle")
    }

    private func mouse(_ e: NSEvent) {
        guard !menuClick(e, piece), e.type == .leftMouseDown, hidden, let spot, let secs = rounds.found(at: now()) else { return }
        hidden = false
        timers.forEach { $0.invalidate() }; timers = []
        // Found: out it pops, surprised, the whole of it over the edge.
        let w = look.size.width, h = look.size.height, was = piece.panel.frame.height - h
        piece.show(CGRect(x: spot.x - w / 2, y: spot.edge.y, width: w, height: ceil(h * 1.35)))
        piece.slide(to: 0, from: was, seconds: 0.25)
        let r = Reaction.surprised
        if let m = r.mark { piece.mark(m.text, m.color, over: CGRect(x: 0, y: 0, width: w, height: h)) }
        let head = CGPoint(x: spot.x, y: spot.edge.y + h)
        let time = String(format: "%.1f", secs)
        if rounds.isOver {
            let total = String(format: "%.1f", rounds.total), best = String(format: "%.1f", rounds.times.min() ?? secs)
            ClickGames.say(L("다 찾았어요! 세 번 합쳐 \(total)초, 가장 빨리 찾은 건 \(best)초예요"), at: head)
            timers = [after(2.5) { ClickGames.shared.stop() }]
        } else {
            ClickGames.say(L("들켰다! \(time)초 만에 찾았어요 (\(rounds.round)/\(HideRounds.count))"), at: head)
            timers = [after(2) { [weak self] in self?.hide() }]
        }
    }
}

// MARK: 공놀이

/// A ball by the character (the 커서 친구, lent). Drag it and let go to throw it (a click kicks it up); it flies like a
/// thrown friend (Fling), the character runs to fetch it once it stops and brings it back by the cursor. A ball that
/// comes to rest on the 러그 is a 골: a cheer from every desktop friend. A minute untouched ends the game.
private final class BallGame: ClickGame {
    private enum State { case rest, held, flying(Fling), fetching, carrying }

    private let look = Look(character: nil, pixelSize: MotionStore.shared.buddySize.pixelSize)
    private lazy var ball = GamePiece { [weak self] in self?.mouse($0) }
    private let runner = GamePiece()
    private var state = State.rest
    /// The runner's bottom middle, and the ball's middle (screen points).
    private var feet = CGPoint.zero, at = CGPoint.zero
    private var facingLeft = false
    private var clicks = ClickRecognizer()
    private var grab = CGVector.zero
    private var rug: CGRect?
    private var goals = 0, scored = false
    private var cheerUntil: TimeInterval = 0
    private var timer: Timer?, idle: Timer?
    private var lastTick: TimeInterval = 0
    private var frame = 0, clock: TimeInterval = 0
    private var still = DesktopKit.reduceMotion
    private var d: CGFloat { max(18, (look.size.height * 0.45).rounded()) }

    func start() {
        let was = CursorBuddy.shared.lendForPlay()
        let o = BuddyMath.target(cursor: NSEvent.mouseLocation, size: look.size)
        feet = was.map { CGPoint(x: $0.midX, y: $0.minY) } ?? CGPoint(x: o.x + look.size.width / 2, y: o.y)
        at = CGPoint(x: feet.x + look.size.width / 2 + d / 2, y: feet.y + d / 2)
        ball.dress(Self.art, size: CGSize(width: d, height: d), smooth: true)
        ball.art.anchorPoint = CGPoint(x: 0.5, y: 0.5)   // it rolls about its middle
        layout()
        let rugOn = DesktopRug.shared.footprint() != nil
        ClickGames.say(rugOn ? L("공을 끌어서 던져 주세요! 러그 위에 멈추면 골이에요") : L("공을 끌어서 던져 주세요! 제가 물어 올게요"))
        armIdle()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        idle?.invalidate(); idle = nil
        ball.remove()
        runner.remove()
        CursorBuddy.shared.giveBackFromPlay(feet: feet)
    }

    private func armIdle() {
        idle?.invalidate()
        idle = after(60) { ClickGames.say(L("공놀이 재밌었어요!")); ClickGames.shared.stop() }
    }

    // MARK: Mouse

    private func mouse(_ e: NSEvent) {
        guard !menuClick(e, ball) else { return }
        let p = NSEvent.mouseLocation, t = e.timestamp
        switch e.type {
        case .leftMouseDown:
            state = .held
            grab = CGVector(dx: at.x - p.x, dy: at.y - p.y)
            _ = clicks.mouseDown(p, at: t)
        case .leftMouseDragged:
            guard case .held = state else { break }
            at = CGPoint(x: p.x + grab.dx, y: p.y + grab.dy)
            _ = clicks.mouseMoved(p, at: t)
            layout()
        case .leftMouseUp:
            var g = clicks.mouseUp(p, at: t)
            if clicks.pollAt != nil { clicks = ClickRecognizer(); g = [.single(p)] }   // at once: a kick
            var v = CGVector.zero
            for x in g {
                if case .single = x { v = CGVector(dx: .random(in: -300...300), dy: 900) }
                if case .dragEnded(_, let fling) = x, hypot(fling.dx, fling.dy) >= BuddyMath.throwMin { v = fling }
            }
            if case .held = state { throwBall(v) }
        default: break
        }
        armIdle()
    }

    /// Off it goes at `v` (zero: it drops), within the screen it is on, onto the floor or the 러그's top.
    private func throwBall(_ v: CGVector) {
        guard let b = (NSScreen.screens.first { NSMouseInRect(at, $0.frame, false) } ?? NSScreen.main)?.visibleFrame else { return }
        rug = DesktopRug.shared.footprint()
        let walls = CGRect(x: b.minX + d / 2, y: b.minY, width: max(0, b.width - d), height: max(0, b.height - d))
        let ledge = rug.flatMap { r in r.maxY > b.minY ? (minX: r.minX, maxX: r.maxX, y: r.maxY) : nil }
        let start = CGPoint(x: min(max(at.x, walls.minX), walls.maxX), y: min(max(at.y - d / 2, walls.minY), walls.maxY))
        state = .flying(Fling(at: start, velocity: v, walls: walls, ledge: ledge))
        scored = false
        wake()
    }

    // MARK: Ticking

    private func wake() {
        guard timer == nil else { return }
        lastTick = now()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.003
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let t = now(), dt = min(0.05, max(0, t - lastTick))
        lastTick = t
        let size = look.size
        var running = false
        switch state {
        case .rest, .held:
            break
        case .flying(var f):
            f.step(dt: dt)
            at = CGPoint(x: f.position.x, y: f.position.y + d / 2)
            face(at.x - feet.x)
            if !still { ball.art.setAffineTransform(CGAffineTransform(rotationAngle: -f.spin * 3)) }
            if f.isSettled {
                state = .fetching
                if !scored, BallRules.goal(f.position, rug: rug) { goal() }
            } else {
                state = .flying(f)
            }
        case .fetching:
            running = true
            move(to: CGPoint(x: at.x, y: at.y - d / 2), speed: 600, dt: dt)
            if BallRules.reaches(CGRect(x: feet.x - size.width / 2, y: feet.y, width: size.width, height: size.height), ball: at, radius: d / 2) {
                state = .carrying
                ball.panel.orderFrontRegardless()   // in its mouth, in front of it
            }
        case .carrying:
            running = true
            let o = BuddyMath.target(cursor: NSEvent.mouseLocation, size: size)
            let to = CGPoint(x: o.x + size.width / 2, y: o.y)
            move(to: to, speed: 420, dt: dt)
            let dir: CGFloat = facingLeft ? -1 : 1
            at = CGPoint(x: feet.x + dir * size.width * 0.35, y: feet.y + size.height * 0.35)
            if feet == to {   // brought back: put down by its front paws
                state = .rest
                at = CGPoint(x: feet.x + dir * (size.width / 2 + d / 2), y: feet.y + d / 2)
                runner.mark("♥", .systemPink, over: CGRect(origin: .zero, size: size))
                armIdle()
            }
        }
        let per = running ? 0.07 : 0.12
        clock += dt
        if clock >= per { clock -= per; frame += 1 }
        layout(running: running)
        if case .rest = state, t >= cheerUntil { timer?.invalidate(); timer = nil }
        if case .held = state { timer?.invalidate(); timer = nil }
    }

    private func move(to p: CGPoint, speed: CGFloat, dt: TimeInterval) {
        let next = BuddyMath.step(from: feet, to: p, dt: dt, speed: speed)
        face(next.x - feet.x)
        feet = next
    }

    private func face(_ dx: CGFloat) { if dx < -0.5 { facingLeft = true } else if dx > 0.5 { facingLeft = false } }

    private func goal() {
        scored = true
        goals += 1
        cheerUntil = now() + 1.2
        ball.mark(L("골!"), .systemOrange, over: CGRect(x: 0, y: 0, width: d, height: d))
        ClickGames.say(L("골인! 벌써 \(goals)골이에요"), at: CGPoint(x: at.x, y: at.y + d / 2))
        DesktopKit.celebrate.send(.cheer)
    }

    private func layout(running: Bool = false) {
        let size = look.size
        let gait: BuddyGait = now() < cheerUntil ? .special : running ? (look.frames[.run] != nil ? .run : .walk) : .stand
        runner.show(CGRect(x: feet.x - size.width / 2, y: feet.y, width: size.width, height: ceil(size.height * 1.35)))
        runner.dress(look.pose(gait, still ? 0 : frame), size: size, smooth: look.smooth, left: facingLeft)
        runner.slide(to: 0)
        ball.show(CGRect(x: at.x - d / 2, y: at.y - d / 2, width: d, height: d))
        ball.slide(to: d / 2)
    }

    /// Our ball: pink and white halves with a dark outline, drawn in code.
    private static let art = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
        let c = r.insetBy(dx: 3, dy: 3)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: c).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: c).addClip()
        NSColor(red: 1, green: 0.49, blue: 0.62, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: c.minX, y: c.midY - c.height * 0.18, width: c.width, height: c.height * 0.36)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: c)
        ring.lineWidth = 4
        NSColor(white: 0.25, alpha: 1).setStroke()
        ring.stroke()
        return true
    }
}

// MARK: 두더지잡기

/// 30 seconds of 풀밭 친구들 (the character chosen now while those are off) popping up from the Dock's top at random
/// spots; a click bonks one (dizzy, @) for a point. The score, the best and the seconds left show at the top; click
/// that to stop. The best is kept.
private final class MoleGame: ClickGame {
    private final class Mole {
        let piece: GamePiece
        let look: Look
        let x: CGFloat
        var bonked = false
        init(piece: GamePiece, look: Look, x: CGFloat) { self.piece = piece; self.look = look; self.x = x }
    }

    private var looks: [Look] = []
    private var moles: [Mole] = []
    private var score = MoleScore(best: AppDefaults.store.integer(forKey: ClickGames.moleBestKey))
    private lazy var hud: GamePiece = GamePiece { [weak self] e in
        guard let self, !menuClick(e, self.hud), e.type == .leftMouseDown else { return }
        ClickGames.shared.stop()
    }
    private let text = CATextLayer()
    private var startedAt: TimeInterval = 0
    private var floor = CGRect.zero   // the Dock's top: x range and y
    private var timers: [Timer] = []
    private var over = false

    func start() {
        guard let s = NSScreen.screens.first else { ClickGames.shared.stop(); return }
        let v = s.visibleFrame
        floor = CGRect(x: s.frame.minX, y: v.minY, width: s.frame.width, height: 0)
        let meadow = MeadowStore.shared.prefs
        let who: [String?] = meadow.on ? meadow.slots.prefix(max(1, min(MeadowPrefs.maxCount, meadow.count))).map(\.character) : [nil]
        let target = s.frame.height / 10
        looks = who.map { c in
            let base = MeadowFriends.cache(character: c, pixelSize: 1).imageSize.height
            return Look(character: c, pixelSize: max(1, (target / max(1, base)).rounded()))
        }
        text.font = NSFont.systemFont(ofSize: 13)
        text.fontSize = 13
        text.foregroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        text.alignmentMode = .center
        text.contentsScale = s.backingScaleFactor
        hud.view.layer?.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        hud.view.layer?.cornerRadius = 10
        hud.view.layer?.addSublayer(text)
        startedAt = now()
        ClickGames.say(L("두더지잡기! 30초 동안 튀어나오는 친구를 콕 눌러요"))
        timers = [after(1) { [weak self] in self?.spawn() },
                  every(1) { [weak self] in self?.showScore() }]
        showScore()
    }

    func stop() {
        timers.forEach { $0.invalidate() }; timers = []
        moles.forEach { $0.piece.remove() }; moles = []
        hud.remove()
    }

    private var elapsed: TimeInterval { now() - startedAt }

    private func showScore() {
        let left = max(0, Int((MoleRules.length - elapsed).rounded(.up)))
        let line = over ? L("두더지잡기 \(score.score)점 · 최고 \(score.best)점")
                        : L("두더지잡기 \(score.score)점 · 최고 \(score.best)점 · \(left)초 · 누르면 그만")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.string = line
        let w = ceil((line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 28
        let top = NSScreen.screens.first?.visibleFrame.maxY ?? floor.maxY + 400
        hud.show(CGRect(x: floor.midX - w / 2, y: top - 40, width: w, height: 28))
        text.frame = CGRect(x: 0, y: 5, width: w, height: 18)
        CATransaction.commit()
    }

    private func spawn() {
        let t = elapsed
        guard t < MoleRules.length else { finish(); return }
        if let look = looks.randomElement(), moles.filter({ !$0.bonked }).count < MoleRules.most(t),
           let x = MoleRules.spot(lo: floor.minX, hi: floor.maxX, width: look.size.width, taken: moles.map(\.x)) {
            pop(look, at: x, for: MoleRules.up(t))
        }
        timers.append(after(MoleRules.gap(t)) { [weak self] in self?.spawn() })
        timers.removeAll { !$0.isValid }
    }

    private func pop(_ look: Look, at x: CGFloat, for seconds: TimeInterval) {
        let w = look.size.width, h = look.size.height
        let piece = GamePiece { _ in }
        let m = Mole(piece: piece, look: look, x: x)
        piece.onMouse = { [weak self, weak m] e in if let self, let m { self.mouse(e, m) } }
        moles.append(m)
        piece.show(CGRect(x: x - w / 2, y: floor.minY, width: w, height: h))
        piece.dress(look.pose(.stand), size: look.size, smooth: look.smooth, left: Bool.random())
        piece.slide(to: 0, from: -h, seconds: 0.15)   // up out of the Dock
        timers.append(after(seconds) { [weak self, weak m] in if let m, !m.bonked { self?.sink(m) } })
    }

    private func mouse(_ e: NSEvent, _ m: Mole) {
        guard !menuClick(e, m.piece), e.type == .leftMouseDown, !m.bonked, !over else { return }
        m.bonked = true
        score.bonk()
        m.piece.dress(m.look.pose(.dizzy), size: m.look.size, smooth: m.look.smooth)
        if let mk = Reaction.dizzy.mark { m.piece.mark(mk.text, mk.color, over: CGRect(x: 0, y: 0, width: m.look.size.width, height: m.look.size.height * 0.8)) }
        showScore()
        timers.append(after(0.6) { [weak self, weak m] in if let m { self?.sink(m) } })
    }

    /// Back down into the Dock, then gone.
    private func sink(_ m: Mole) {
        guard moles.contains(where: { $0 === m }) else { return }
        m.piece.slide(to: -m.look.size.height, from: 0, seconds: 0.15)
        timers.append(after(0.2) { [weak self, weak m] in
            guard let self, let m else { return }
            m.piece.remove()
            self.moles.removeAll { $0 === m }
        })
    }

    private func finish() {
        over = true
        timers.forEach { $0.invalidate() }; timers = []
        moles.forEach { $0.piece.remove() }; moles = []
        let beat = score.finish()
        if beat { AppDefaults.store.set(score.best, forKey: ClickGames.moleBestKey) }
        showScore()
        ClickGames.say(beat ? L("끝! \(score.score)점, 최고 기록이에요!") : L("끝! \(score.score)점이에요. 최고 기록은 \(score.best)점"))
        if beat { DesktopKit.celebrate.send(.cheer) }
        timers = [after(4) { ClickGames.shared.stop() }]
    }
}
