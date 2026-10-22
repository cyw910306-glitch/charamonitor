import AppKit
import Combine

/// Where the buddy goes. Screen coordinates (y up); `origin` is the window's bottom-left corner.
enum BuddyMath {
    /// The window's top-left sits this far right of and below the cursor hot spot.
    static let gap: CGFloat = 14
    /// Walking pace in points per second; constant speed is what makes it lag behind like oneko.
    static let speed: CGFloat = 260
    /// Running pace, used once the cursor got `runStart` ahead (it moved fast) until the buddy arrives.
    static let runSpeed: CGFloat = 900
    static let runStart: CGFloat = 140
    /// Closer than this the buddy has arrived.
    static let arrive: CGFloat = 1

    /// Whether the buddy runs this tick: from when the cursor is far ahead until it arrives.
    static func runs(distance: CGFloat, wasRunning: Bool) -> Bool {
        distance > runStart || wasRunning && distance > arrive
    }

    /// At rest with the charger in it eats; otherwise (and on a Mac without a battery) it sleeps.
    static func eats(_ battery: BatteryStats?) -> Bool { battery.map { $0.isPluggedIn || $0.isCharging } ?? false }

    /// Resting origin: lower right of the cursor.
    static func target(cursor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: cursor.x + gap, y: cursor.y - gap - size.height)
    }

    /// Moves `from` toward `to` by at most speed * dt.
    static func step(from: CGPoint, to: CGPoint, dt: TimeInterval, speed: CGFloat = speed) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let d = (dx * dx + dy * dy).squareRoot()
        let max = speed * CGFloat(dt)
        if d <= max || d <= arrive { return to }
        return CGPoint(x: from.x + dx / d * max, y: from.y + dy / d * max)
    }

    static func clamp(_ origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, bounds.minX), bounds.maxX - size.width),
                y: min(max(origin.y, bounds.minY), bounds.maxY - size.height))
    }

    /// Final origin on screen: clamped to `bounds`, and never over the hot spot. Near the bottom-right corner,
    /// where clamping would push it onto the cursor, it jumps to the upper left of the cursor instead.
    static func place(_ origin: CGPoint, size: CGSize, cursor: CGPoint, in bounds: CGRect) -> CGPoint {
        var p = clamp(origin, size: size, in: bounds)
        if covers(p, size: size, cursor: cursor) {
            // Mid-chase overlap: drop just below the cursor.
            p = clamp(CGPoint(x: p.x, y: cursor.y - gap - size.height), size: size, in: bounds)
        }
        if covers(p, size: size, cursor: cursor) {
            p = clamp(CGPoint(x: cursor.x - gap - size.width, y: cursor.y + gap), size: size, in: bounds)
        }
        return p
    }

    static func covers(_ origin: CGPoint, size: CGSize, cursor: CGPoint) -> Bool {
        CGRect(origin: origin, size: size).insetBy(dx: -2, dy: -2).contains(cursor)
    }

    /// How big it grows at cursor `speed` (pt/s): 1 up to 500, `max` from 2500, a smoothstep between.
    static func boost(speed: CGFloat, max top: CGFloat) -> CGFloat {
        let x = min(1, Swift.max(0, (speed - 500) / 2000))
        return 1 + (top - 1) * x * x * (3 - 2 * x)
    }

    /// `cur` eased toward `to` over `dt`: grows at once (about 0.2 s), shrinks back within about 0.35 s.
    static func ease(_ cur: CGFloat, to: CGFloat, dt: TimeInterval) -> CGFloat {
        let tau = to > cur ? 0.06 : 0.075
        return cur + (to - cur) * CGFloat(1 - exp(-Swift.max(0, dt) / tau))
    }

    /// Parked by the cursor, it waits until the cursor is farther off than it is big, so the pointer can rest on it.
    static func leaves(distance: CGFloat, size: CGSize) -> Bool { distance > hypot(size.width, size.height) + 2 * gap }

    /// Seconds to the next 혼자 놀기: 1 to 2 minutes (`random` 0...1), twice that during work hours.
    static func playGap(working: Bool, random: Double) -> TimeInterval { (60 + 60 * random) * (working ? 2 : 1) }

    /// Lean and stretch at speed `k` (0...1) running `dir` (+1 right): up to 12 degrees into the run, longer and flatter.
    static func lean(k: CGFloat, dir: CGFloat) -> (angle: CGFloat, sx: CGFloat, sy: CGFloat) {
        (-dir * 12 * .pi / 180 * k, 1 + 0.15 * k, 1 - 0.10 * k)
    }

    /// Rotation and scale about `pivot` (in a layer of `size` whose anchor point is `anchor`).
    static func transform(angle: CGFloat, sx: CGFloat, sy: CGFloat, pivot: CGPoint, anchor: CGPoint, size: CGSize) -> CGAffineTransform {
        let px = pivot.x - anchor.x * size.width, py = pivot.y - anchor.y * size.height
        return CGAffineTransform(translationX: px, y: py).rotated(by: angle).scaledBy(x: sx, y: sy).translatedBy(x: -px, y: -py)
    }

    /// Where it sits on the top edge of `window` (screen points, y up), as near `x` as fits: nil when the window
    /// is too narrow, off the screen, or its top leaves no room under the menu bar (`bounds` = the visible frame).
    static func perch(on window: CGRect, x: CGFloat, size: CGSize, in bounds: CGRect) -> CGPoint? {
        let lo = Swift.max(window.minX, bounds.minX), hi = min(window.maxX, bounds.maxX) - size.width
        guard hi - lo >= size.width / 2, window.maxY >= bounds.minY, window.maxY + size.height <= bounds.maxY else { return nil }
        return CGPoint(x: min(Swift.max(x, lo), hi), y: window.maxY - 2)
    }

    /// Pressed and held (꾸욱) before a throw: it squashes down to gather itself, from 0.12 s in, fully by 0.5 s.
    static func windup(held: TimeInterval) -> (sx: CGFloat, sy: CGFloat) {
        let u = CGFloat(min(1, max(0, (held - 0.12) / 0.38))), e = u * u * (3 - 2 * u)
        return (1 + 0.18 * e, 1 - 0.22 * e)
    }

    /// Slower than this at release it is put down, not thrown (points per second).
    static let throwMin: CGFloat = 500
    /// A long press let go without a drag: it hops this fast (points per second), about 120 pt up.
    static let hopSpeed: CGFloat = 750

    /// Where the string takes hold: the top middle of the drawing at `origin`, but never above the cursor, so a
    /// drag that pressed inside the drawing swings down from the side instead of flipping over the top.
    static func grip(origin: CGPoint, size: CGSize, cursor: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + size.width / 2, y: min(cursor.y - 1, origin.y + size.height))
    }
}

/// 깜짝 이벤트 "나비 쫓기": a butterfly drifts in over the buddy, it runs after it and hops, the butterfly gets away
/// up high, the buddy sulks. Pure timeline; `t` is seconds since the story began.
struct ButterflyStory {
    enum Phase { case approach, chase, hop, escape, sulk, done }
    static let approach: TimeInterval = 2.5, chase: TimeInterval = 2, jump: TimeInterval = 0.45,
               escape: TimeInterval = 1.5, sulk: TimeInterval = 2.5

    /// Where it flies in from, and the spot over the buddy's head it flies to first.
    let from: CGPoint, spot: CGPoint
    /// It keeps flying this way: +1 right, -1 left.
    var away: CGFloat { spot.x >= from.x ? 1 : -1 }

    static func phase(_ t: TimeInterval) -> Phase {
        var t = t
        for (p, d) in [(Phase.approach, approach), (.chase, chase), (.hop, jump), (.escape, escape), (.sulk, sulk)] {
            if t < d { return p }
            t -= d
        }
        return .done
    }

    /// The butterfly's center at `t`, nil once it got away.
    func butterfly(_ t: TimeInterval) -> CGPoint? {
        let wobble = CGFloat(sin(t * 9)) * 5
        let end = CGPoint(x: spot.x + away * 140, y: spot.y + 10)
        switch Self.phase(t) {
        case .approach:
            let u = CGFloat(t / Self.approach), e = u * u * (3 - 2 * u)
            return CGPoint(x: from.x + (spot.x - from.x) * e, y: from.y + (spot.y - from.y) * e + wobble)
        case .chase:
            let u = CGFloat((t - Self.approach) / Self.chase)
            return CGPoint(x: spot.x + (end.x - spot.x) * u, y: spot.y + 10 * u + wobble)
        case .hop:
            return CGPoint(x: end.x, y: end.y + wobble)
        case .escape:
            let u = CGFloat((t - Self.approach - Self.chase - Self.jump) / Self.escape)
            return CGPoint(x: end.x + away * 80 * u, y: end.y + 220 * u + wobble)
        case .sulk, .done:
            return nil
        }
    }

    /// The hop's height at `t` as a share of the buddy's height (0 outside the hop).
    static func lift(_ t: TimeInterval) -> CGFloat {
        guard phase(t) == .hop else { return 0 }
        let u = CGFloat((t - approach - chase) / jump)
        return 4 * u * (1 - u) * 0.8
    }
}

/// A desktop friend's poses (커서 친구, and its reactions).
enum BuddyGait {
    case walk, run, sleep, eat, stand, special, dizzy, sulk, study

    /// Each pose's frames from `cache`; a pose the character lacks comes back empty.
    static func frames(_ cache: DogSpriteCache) -> [BuddyGait: [NSImage]] {
        let lying = cache.frames(for: .lying), walk = cache.frames(for: .walk)
        return [
            .walk: walk,
            .run: cache.frames(for: .run),
            .sleep: lying,
            .stand: Array(walk.prefix(1)),
            .eat: cache.frames(forExtra: .eat) ?? [],   // food for animals, a meal for people
            .special: cache.frames(forExtra: .special) ?? [],
            .dizzy: cache.frames(for: .exhausted),
            .sulk: cache.frames(forExtra: .hungry) ?? lying,
            .study: Array(walk.prefix(1)),
        ]
    }
}

/// "커서 친구": the current character follows the mouse in a floating window that only takes clicks on its drawing.
/// macOS does not let an app replace the system cursor, so this is the oneko way.
/// Walks after the cursor, runs when the cursor got far ahead (bigger, leaning, with speed lines when the mouse is fast);
/// once there it waits until the cursor goes farther than it is big, so it can be clicked (a cute Reaction each time,
/// dizzy and then a pout when clicked again and again), option clicked (퀵물어보기), held down (꾸욱: it squashes, and
/// hops when let go), dragged (it hangs and swings, then drops, or flies off in an arc when flung, bounces and walks
/// back) or right clicked (its menu, FriendMenu: 퀵물어보기, AI 비서, a copy on the desktop: DesktopClones). At rest it eats while
/// charging, plays now and then, sits on the front window's top edge, chases a butterfly; it naps after 90 s without
/// input and gets dizzy when shaken. 30 fps only while something moves, the rest pose's own pace otherwise,
/// nothing while off or the screens sleep. 동작 줄이기: no growing, swinging or idle play, still poses.
final class CursorBuddy {
    static let shared = CursorBuddy()
    /// The AI 비서, from its menu. Set by StatusItemController.
    var openAssistant: (() -> Void)?

    private var window: NSWindow?
    private let view = BuddyView(frame: .zero)
    private let sprite = SpriteView(frame: .zero)
    private let lines = CAShapeLayer()   // speed lines
    /// 집중 중: a low pink desk with an open book in front of it (our own shapes over its standing pose).
    private let desk = CAShapeLayer(), book = CAShapeLayer()
    private var butterfly: NSWindow?
    /// What it carries or kicks (맥과 같이 놀기), in a window of its own; `propped` it showed this tick.
    private var prop: NSWindow?
    private let propLayer = CALayer()
    private var propped = false
    private var carried: CGImage?
    private var sweatAt: TimeInterval = 0
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var bag: Set<AnyCancellable> = []
    private var started = false

    /// What it does besides following the cursor.
    private enum Mode {
        case follow
        /// One pose in place until then (반가워하기, 혼자 놀기, 어질어질).
        case act(BuddyGait, until: TimeInterval)
        /// Hanging from the cursor: held by the hand (a drag) or clinging on by itself until `until`.
        case hang(Dangle, byHand: Bool, until: TimeInterval)
        case drop(vy: CGFloat, landY: CGFloat)
        /// On the top edge of this window (screen points), last looked at `checked`.
        case perch(CGRect, checked: TimeInterval)
        case story(ButterflyStory, start: TimeInterval)
        /// Thrown (or hopping after a long press): flying until it lands.
        case fly(Fling)
        /// Clicked: reacting in place since `start`.
        case react(Reaction, start: TimeInterval)
        /// Off to a 장난감 (장난감 상자), then using it since `since`.
        case toy(UUID, ToyKind, since: TimeInterval?)
        /// 다운로드 배달: running to `to` (its feet there) with the file's icon over its head, then putting it down.
        case deliver(to: CGPoint, dropped: TimeInterval?)
        /// 휴지통: kicking a bundle that lies at `from` (its lower left, screen points) off the screen, `dir` +1 right.
        case kick(start: TimeInterval, dir: CGFloat, from: CGPoint)
        /// 바쁜 맥: pushing this window's side (nil: no room by it, it sweats in place), last looked at `checked`.
        case push(CGRect?, checked: TimeInterval)
    }

    private var look: SpriteLook?
    private var pixelSize: CGFloat = 0
    private var frames: [BuddyGait: (right: [NSImage], left: [NSImage])] = [:]
    private var size = CGSize(width: 68, height: 40)
    private let batterySampler = BatterySampler()   // reads at most every 10 s on its own
    private var smooth = false
    private var hits: [ObjectIdentifier: AlphaHit] = [:]

    private var mode = Mode.follow
    private var position = CGPoint.zero   // bottom-left of the drawing at its current scale
    private var lastTick = ProcessInfo.processInfo.systemUptime   // monotonic: a clock change cannot fling it
    private var frame = 0, frameClock: TimeInterval = 0
    private var facingLeft = false
    private var running = false
    private var parked = false
    private var scale: CGFloat = 1
    private var showing: [NSImage] = []
    private var asleep = false
    private var motion = CursorMotion()
    private var clicks = ClickRecognizer()
    private var combo = ClickCombo()
    private var lastCursor = CGPoint.zero
    private var stillSince: TimeInterval = 0   // the cursor last moved
    private var landed: TimeInterval = -1      // a drop landed: squashed for a moment
    private var dizzyAfter: TimeInterval = 0, clingAfter: TimeInterval = 0, perchAfter: TimeInterval = 0
    private var playAt: TimeInterval = 0, storyAt: TimeInterval = 0, toyAt: TimeInterval = 0
    /// The 트램펄린 bounce it is on (the mat dips once each); -1 before the toy is first played.
    private var toyBeat = -1
    private var idle: (read: TimeInterval, seconds: TimeInterval) = (-10, 0)
    private var reperch = false   // dropping off a window that moved
    /// A left press on the drawing started then (꾸욱 wind-up), until it is dragged or let go.
    private var pressAt: TimeInterval?
    /// 동작 줄이기: it still follows, in one still pose per gait.
    private var still = DesktopKit.reduceMotion
    /// The drawing's rect on screen at the last layout (bubbles over its head point here).
    private var drawn = CGRect.zero

    /// Lent to 놀이 모드: out of sight until the session gives it back.
    private var playing = false
    /// Where it comes back from a session: its feet there, then it walks after the cursor.
    private var resumeAt: CGPoint?
    private var enabled: Bool { MotionStore.shared.cursorBuddy && !asleep && !playing }
    private static let napAfter: TimeInterval = 90
    /// QA renders only (DesktopQA): the window stays see-through (alpha 0), so nothing shows on the developer's screen.
    static var qaHidden = false

    /// Call once at launch. Follows the toggle and the selected character on its own.
    func start() {
        guard !started else { return }
        started = true
        AppSettings.shared.objectWillChange
            .merge(with: CustomCharacterStore.shared.objectWillChange, MotionStore.shared.objectWillChange)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        let nc = NSWorkspace.shared.notificationCenter
        for (name, sleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                              (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            nc.publisher(for: name).sink { [weak self] _ in self?.asleep = sleep; self?.refresh() }.store(in: &bag)
        }
        DesktopKit.displayOptionsChanged
            .sink { [weak self] in self?.still = DesktopKit.reduceMotion }
            .store(in: &bag)
        DesktopKit.celebrate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.celebrate() }
            .store(in: &bag)
        refresh()
    }

    /// The top middle of the drawing on screen while it is out; nil while off.
    func head() -> CGPoint? {
        guard timer != nil, window?.isVisible == true, drawn.width > 0 else { return nil }
        return CGPoint(x: drawn.midX, y: drawn.maxY)
    }

    /// 다운로드 배달 (MacReactions): off to the lower right of its screen with `icon` over its head, then back to the
    /// cursor. False while it is off, held, thrown or on another errand.
    // ponytail: the Dock's Downloads stack has no position without Accessibility; the lower right stands in for it
    func deliver(_ icon: NSImage) -> Bool {
        guard errandFree, let b = screen?.visibleFrame else { return false }
        var r = CGRect(x: 0, y: 0, width: 64, height: 64)
        carried = icon.cgImage(forProposedRect: &r, context: nil, hints: nil)
        endStory()
        mode = .deliver(to: CGPoint(x: b.maxX - size.width / 2 - 6, y: b.minY), dropped: nil)
        parked = false
        schedule(1.0 / 30)
        return true
    }

    /// 휴지통 (MacReactions): kicks a little bundle off the screen, toward the nearer side. False as for `deliver`.
    func kickTrash() -> Bool {
        guard errandFree, let b = screen?.visibleFrame else { return false }
        endStory()
        let dir: CGFloat = drawn.midX >= b.midX ? 1 : -1
        facingLeft = dir < 0
        mode = .kick(start: ProcessInfo.processInfo.systemUptime, dir: dir,
                     from: CGPoint(x: dir > 0 ? drawn.maxX : drawn.minX - bundleSide, y: drawn.minY))
        parked = true
        schedule(1.0 / 30)
        return true
    }

    /// Out and on its feet (or sitting, pushing, watching the butterfly): free for an errand.
    private var errandFree: Bool {
        guard timer != nil, window?.isVisible == true, drawn.width > 0 else { return false }
        switch mode { case .follow, .act, .react, .perch, .push, .story: return true; default: return false }
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(CGPoint(x: drawn.midX, y: drawn.midY), $0.frame, false) } ?? NSScreen.main
    }

    private var bundleSide: CGFloat { 7 * max(1.5, pixelSize) * 1.4 }

    /// Its feet (the drawing's bottom middle) on screen while it is out, for the 복제 친구 기차놀이; nil while off.
    func feet() -> CGPoint? {
        guard timer != nil, window?.isVisible == true, drawn.width > 0 else { return nil }
        return CGPoint(x: drawn.midX, y: drawn.minY)
    }

    /// 놀이 모드 takes it: hidden, and where its drawing was (nil while it is off: the session starts at the cursor).
    func lendForPlay() -> CGRect? {
        let was = timer != nil && window?.isVisible == true ? drawn : nil
        playing = true
        refresh()
        return was
    }

    /// The session is over: back out with its feet at `feet` if it is on, following the cursor again from there.
    func giveBackFromPlay(feet: CGPoint) {
        guard playing else { return }
        playing = false
        resumeAt = feet
        refresh()
        resumeAt = nil
    }

    /// 춤춰 줘·응원해 줘·a focus well done: its special moment in place, with a heart (10 s with 단체 춤).
    private func celebrate() {
        guard timer != nil else { return }
        switch mode { case .follow, .act, .perch, .react: break; default: return }   // not mid-swing or mid-fall
        cheer(until: ProcessInfo.processInfo.systemUptime + (GroupDance.on ? GroupDance.length : 2.5))   // 단체 춤: as long as the others
        schedule(1.0 / 30)
    }

    private func refresh() {
        guard enabled else { stop(); return }
        let now = SpriteLook(AppSettings.shared)
        let px = MotionStore.shared.buddySize.pixelSize
        if now != look || px != pixelSize {
            look = now
            pixelSize = px
            let cache = DogSpriteCache(now, pixelSize: px)
            let old = size
            size = cache.imageSize
            if timer != nil { position.x -= (size.width - old.width) / 2 }   // a new size grows about its bottom middle
            smooth = cache.smooth
            frames = BuddyGait.frames(cache).filter { !$0.value.isEmpty }.mapValues { ($0, $0.map(Self.mirrored)) }
            hits = [:]
            showing = []
        }
        if window == nil { makeWindow() }
        if timer == nil {
            let t = ProcessInfo.processInfo.systemUptime
            position = resumeAt.map { CGPoint(x: $0.x - size.width / 2, y: $0.y) } ?? BuddyMath.target(cursor: NSEvent.mouseLocation, size: size)
            resumeAt = nil
            lastTick = t
            stillSince = t
            playAt = t + BuddyMath.playGap(working: false, random: .random(in: 0...1))
            storyAt = t + .random(in: 180...360)
            window?.orderFrontRegardless()
            tick()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        interval = 0
        mode = .follow
        pressAt = nil
        scale = 1
        window?.orderOut(nil)
        butterfly?.orderOut(nil)
        prop?.orderOut(nil)
        carried = nil
    }

    private func makeWindow() {
        // A non-activating panel: clicking the buddy never takes the focus from the app in front.
        let w = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        if Self.qaHidden { w.alphaValue = 0 }
        w.ignoresMouseEvents = true
        w.level = .floating   // above normal windows, below the menu bar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isExcludedFromWindowsMenu = true
        w.isReleasedWhenClosed = false
        view.wantsLayer = true
        view.addSubview(sprite)
        lines.fillColor = nil
        lines.strokeColor = NSColor(white: 0.55, alpha: 0.9).cgColor
        lines.lineCap = .round
        lines.opacity = 0
        lines.zPosition = -1
        view.layer?.addSublayer(lines)
        desk.fillColor = NSColor(red: 0.98, green: 0.66, blue: 0.74, alpha: 1).cgColor
        desk.strokeColor = NSColor(red: 0.78, green: 0.42, blue: 0.52, alpha: 1).cgColor
        book.fillColor = NSColor.white.cgColor
        book.strokeColor = NSColor(red: 0.35, green: 0.45, blue: 0.75, alpha: 1).cgColor
        for l in [desk, book] { l.isHidden = true; view.layer?.addSublayer(l) }   // after the sprite: in front of it
        view.onMouse = { [weak self] in self?.mouse($0) }
        w.contentView = view
        window = w
    }

    /// QA renders only: it running right at boost `k` (0...1 of 빠르게 움직이면) as `layout` draws it, dizzy, squashed
    /// for a throw (`windup`) or tumbling at angle `fly`; no timer.
    /// Needs the QA's own MotionStore with 커서 친구 on. Returns the view whose layer holds the drawing.
    func qaPose(k: CGFloat, dizzy: Bool = false, windup: Bool = false, fly: CGFloat? = nil) -> NSView {
        refresh()
        timer?.invalidate(); timer = nil; interval = 0
        scale = 1 + k * (MotionStore.shared.buddyBoost.maxScale - 1)
        facingLeft = false
        let box = CGSize(width: size.width * scale, height: size.height * scale)
        let gait: BuddyGait = dizzy ? .dizzy : fly != nil ? .run : k == 0 ? .walk : k > 0.7 && has(.special) ? .special : .run
        let squash = BuddyMath.windup(held: 0.5)
        let turn = fly.map { (-$0, CGFloat(1), CGFloat(1)) } ?? (windup ? (0, squash.sx, squash.sy) : k > 0 ? BuddyMath.lean(k: k, dir: 1) : (0, 1, 1))
        layout(origin: CGPoint(x: -4000, y: -4000), box: box, turn: turn, pivot: fly == nil ? 0 : 0.5, lines: k)
        showing = frames[gait]?.right ?? []
        sprite.setFrames(showing, smooth: smooth)
        return view
    }

    /// QA renders only: reacting with `r`, `t` seconds in, its mark shown (FriendMark.qa), lifted over the spot it
    /// rose off (the window reaches down to it, as when clicked).
    func qaPose(reaction r: Reaction, at t: TimeInterval) -> NSView {
        _ = qaPose(k: 0)
        view.layer?.sublayers?.filter { $0.name == FriendMark.name }.forEach { $0.removeFromSuperlayer() }
        let box = size, p = r.pose(t, still: false)
        layout(origin: CGPoint(x: -4000, y: -4000), box: box, turn: (p.angle, p.sx, p.sy), pivot: r == .spin ? 0.5 : 0, lines: 0,
               rise: max(0, p.lift * box.height))
        showing = (frames[r.gait] ?? frames[r.gait == .special ? .eat : .walk] ?? frames[.walk]).map { r == .pout ? $0.left : $0.right } ?? []
        sprite.setFrames(showing, smooth: smooth)
        if let m = r.mark { mark(m.text, m.color) }
        return view
    }

    private func schedule(_ every: TimeInterval) {
        guard every != interval else { return }
        timer?.invalidate()
        interval = every
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = every * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func has(_ g: BuddyGait) -> Bool { frames[g] != nil }
    private func face(_ dx: CGFloat) { if dx < -0.5 { facingLeft = true } else if dx > 0.5 { facingLeft = false } }

    private func tick() {
        guard !FriendMenu.isOpen else { return }   // its menu is up: wait there instead of chasing the cursor into it
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - lastTick)
        let dt = min(0.1, elapsed)
        lastTick = now
        propped = false
        let cursor = NSEvent.mouseLocation
        motion.feed(cursor, at: now)
        let cursorMoved = cursor != lastCursor
        if cursorMoved { lastCursor = cursor; stillSince = now }
        for g in clicks.poll(at: now) { handle(g) }
        let play = MotionStore.shared.buddyPlay

        // Grows with the cursor's speed (not while hanging), eases back when it slows.
        let top = still ? 1 : MotionStore.shared.buddyBoost.maxScale
        var hanging = false   // or flying, or on an errand: no growing
        switch mode { case .hang, .fly, .deliver, .kick, .push: hanging = true; default: break }
        if pressAt != nil, NSEvent.pressedMouseButtons & 1 == 0 { pressAt = nil }   // a release we never saw
        scale = BuddyMath.ease(scale, to: hanging ? 1 : BuddyMath.boost(speed: motion.speed, max: top), dt: dt)
        if abs(scale - 1) < 0.005 { scale = 1 }
        let k = top > 1 ? min(1, max(0, (scale - 1) / (top - 1))) : 0
        let box = CGSize(width: size.width * scale, height: size.height * scale)

        // NSMouseInRect: edge-inclusive, so the top row of a display still counts as on it.
        let bounds = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // The cursor went to another display: start the chase from that display's edge, not across the gap.
        let slack = bounds.insetBy(dx: -(box.width + BuddyMath.gap), dy: -(box.height + BuddyMath.gap))
        // A thrown one keeps its own walls (the screen it was thrown on), one on an errand its own screen.
        switch mode {
        case .fly, .deliver, .kick: break
        default: if !slack.contains(position) { position = BuddyMath.clamp(position, size: box, in: bounds) }
        }

        // Shaken hard while just following: dizzy for a moment.
        if motion.isShaking, MotionStore.shared.buddyBoost != .off, now >= dizzyAfter, case .follow = mode {
            dizzyAfter = now + 30
            motion.reset()
            mode = .act(.dizzy, until: now + 2.5)
            sayDizzy()
        }

        var gait = BuddyGait.stand
        var moving = false, busy = false, sitting = false
        var origin = position
        var rise: CGFloat = 0   // a reaction's lift: the spot it rose off keeps taking clicks
        var turn: (angle: CGFloat, sx: CGFloat, sy: CGFloat) = (0, 1, 1)
        var pivot: CGFloat = 0   // the turn's pivot as a share of the height: the head when hanging, the middle when tumbling, else the feet

        switch mode {
        case .follow:
            let target = BuddyMath.target(cursor: cursor, size: box)
            let d = hypot(target.x - position.x, target.y - position.y)
            if parked { parked = !BuddyMath.leaves(distance: d, size: box) }
            if !parked {
                running = BuddyMath.runs(distance: d, wasRunning: running)
                let next = BuddyMath.step(from: position, to: target, dt: dt, speed: running ? BuddyMath.runSpeed : BuddyMath.speed)
                face(next.x - position.x)
                moving = next != position
                position = next
                if next == target {   // caught up: waits here until the cursor goes off again
                    parked = true
                    if running, play, !still, now >= clingAfter, Double.random(in: 0..<1) < 0.3 { hang(byHand: false, cursor: cursor, now: now) }
                    running = false
                }
            }
            // Parked, the pointer may rest on it; on the way it never covers the hot spot.
            origin = parked ? BuddyMath.clamp(position, size: box, in: bounds) : BuddyMath.place(position, size: box, cursor: cursor, in: bounds)
            if moving {
                gait = running ? (k > 0.7 && has(.special) ? .special : .run) : .walk   // 신남 모드 at top speed
                if k > 0 { turn = BuddyMath.lean(k: k, dir: facingLeft ? -1 : 1) }
            } else {
                let napping = idleSeconds(now) >= Self.napAfter
                gait = has(.eat) && BuddyMath.eats(batterySampler.sample()) ? .eat : napping ? .sleep : .stand
                if FocusCenter.shared.session?.paused == false { gait = .study }   // 집중 중: at its desk, no naps
                // 바쁜 맥: off to push the front window once the cursor rests. 꾸욱 held down is not idle.
                if parked, MacReactions.shared.busy, !napping, pressAt == nil, now - stillSince >= 5 { mode = .push(frontWindow(), checked: now) }
                else if parked, play, !still, !napping, pressAt == nil, now - stillSince >= 3 { idleLife(now: now, box: box, bounds: bounds) }
            }

        case .act(let g, let until):
            gait = g
            origin = BuddyMath.clamp(position, size: box, in: bounds)
            if now >= until { mode = .follow; parked = true }

        case .hang(var dg, let byHand, let until):
            busy = true
            dg.anchor = cursor
            if !still { dg.step(dt: dt) }
            let p = still ? dg.equilibrium : dg.position
            position = CGPoint(x: p.x - box.width / 2, y: p.y - box.height)
            origin = position
            if !still {
                let s = min(1.25, max(0.85, dg.stretch))
                turn = (dg.angle, 1 / s, s)
                pivot = 1
            }
            face(dg.velocity.dx)
            gait = .walk
            moving = true
            // Clinging on, it lets go after a while or when the cursor gets too fast for it.
            if !byHand, now >= until || motion.speed > 3500 { mode = .follow; parked = false; running = true }
            else { mode = .hang(dg, byHand: byHand, until: until) }

        case .drop(let vy, let landY):
            busy = true
            let v = vy - 2400 * CGFloat(dt), floor = max(landY, bounds.minY)
            position.y += v * CGFloat(dt)
            if still || position.y <= floor {
                position.y = floor
                landed = now
                mode = .follow
                parked = true
                if reperch, let win = frontWindow(), BuddyMath.perch(on: win, x: position.x, size: box, in: bounds) != nil {
                    mode = .perch(win, checked: now)   // fell off a moved window: climbs back up on it
                }
                reperch = false
            } else {
                mode = .drop(vy: v, landY: landY)
            }
            origin = BuddyMath.clamp(position, size: box, in: bounds)
            gait = .walk

        case .perch(let win, let checked):
            if cursorMoved || !play { mode = .follow; parked = false; perchAfter = now + 60; break }
            if idleSeconds(now) >= Self.napAfter { gait = .sleep; break }   // naps up there, no window checks while nobody is around
            if now - checked >= 5 {
                if frontWindow() != win {   // moved, resized, closed or another window came to the front: falls off
                    mode = .drop(vy: 0, landY: position.y - box.height * 2)
                    reperch = true
                    break
                }
                mode = .perch(win, checked: now)
            }
            guard let spot = BuddyMath.perch(on: win, x: position.x, size: box, in: bounds) else { mode = .follow; parked = false; break }
            let d = hypot(spot.x - position.x, spot.y - position.y)
            let next = BuddyMath.step(from: position, to: spot, dt: dt, speed: d > BuddyMath.runStart ? BuddyMath.runSpeed : BuddyMath.speed)
            face(next.x - position.x)
            moving = next != position
            position = next
            origin = position
            gait = moving ? (d > BuddyMath.runStart ? .run : .walk) : .walk
            sitting = !moving   // legs swinging over the edge

        case .story(let st, let start):
            if cursorMoved || !play { endStory(); parked = false; break }
            busy = true
            let t = now - start
            let bug = st.butterfly(t)
            switch ButterflyStory.phase(t) {
            case .approach, .escape:
                if let bug { face(bug.x - (position.x + box.width / 2)) }
            case .chase:
                if let bug {
                    let next = BuddyMath.step(from: position, to: CGPoint(x: bug.x - box.width / 2, y: position.y), dt: dt, speed: BuddyMath.speed * 1.6)
                    face(next.x - position.x)
                    moving = next != position
                    position = next
                    gait = .run
                }
            case .hop:
                gait = has(.special) ? .special : .run
            case .sulk:
                gait = .sulk
            case .done:
                endStory()
                parked = true
            }
            position = BuddyMath.clamp(position, size: box, in: bounds)
            origin = CGPoint(x: position.x, y: position.y + ButterflyStory.lift(t) * box.height)
            showButterfly(bug, t: t)

        case .fly(var f):
            busy = true
            moving = true
            f.step(dt: dt)
            position = CGPoint(x: f.position.x - box.width / 2, y: f.position.y)
            origin = position
            face(f.velocity.dx)
            gait = .run
            if !still { turn = (-f.spin, 1, 1); pivot = 0.5 }
            if f.isSettled { land(f, now: now) } else { mode = .fly(f) }

        case .toy(let id, let kind, let since):
            if cursorMoved || !play { mode = .follow; parked = false; break }
            guard let f = ToyBox.shared.frame(of: id) else { mode = .follow; parked = false; break }
            let feet = kind.spot(in: f, width: box.width, fromX: position.x + box.width / 2)
            let spot = CGPoint(x: feet.x - box.width / 2, y: feet.y)
            guard let since else {   // on the way there
                let next = BuddyMath.step(from: position, to: spot, dt: dt)
                face(next.x - position.x)
                moving = next != position
                position = next
                origin = position
                gait = .walk
                if !moving { mode = .toy(id, kind, since: now); toyBeat = -1 }
                break
            }
            let t = now - since
            busy = true
            origin = position
            switch kind {
            case .trampoline:   // three bounces, the mat dipping under each
                let beat = Int(t / 0.6), u = CGFloat(t / 0.6) - CGFloat(beat)
                if beat != toyBeat, beat < 3 { toyBeat = beat; ToyBox.shared.played(id, dir: 0) }
                origin.y += 4 * u * (1 - u) * box.height * 1.4
                gait = .walk
                if t >= 1.8 { mode = .follow; parked = true; origin = position }
            case .ball:   // kicks it, then runs after it
                if toyBeat < 0 { toyBeat = 0; ToyBox.shared.played(id, dir: feet.x < f.midX ? 1 : -1) }
                let next = BuddyMath.step(from: position, to: spot, dt: dt, speed: BuddyMath.runSpeed)
                face(next.x - position.x)
                moving = next != position
                position = next
                origin = position
                gait = moving ? .run : .stand
                if t >= 3 { mode = .follow; parked = true }
            case .cushion:   // a nap until the cursor moves
                if toyBeat < 0 { toyBeat = 0; ToyBox.shared.played(id, dir: 0) }
                busy = false
                gait = .sleep
                if t >= 30 { mode = .follow; parked = true }
            case .slide:   // down the chute
                let c = ToyKind.chute(f), u = CGFloat(min(1, t / 0.8))
                position = CGPoint(x: c.top.x + (c.bottom.x - c.top.x) * u - box.width / 2, y: c.top.y + (c.bottom.y - c.top.y) * u)
                origin = position
                facingLeft = false
                moving = true
                gait = .walk
                if t >= 0.8 { position.y = f.minY; mode = .follow; parked = true }
            }

        case .react(let r, let start):
            busy = true
            gait = has(r.gait) ? r.gait : r.gait == .special && has(.eat) ? .eat : .walk
            let p = r.pose(now - start, still: still)
            origin = BuddyMath.clamp(position, size: box, in: bounds)
            rise = max(0, p.lift * box.height)
            origin.y += rise
            turn = (p.angle, p.sx, p.sy)
            if r == .spin { pivot = 0.5 }   // spins about its middle
            if now - start >= r.duration { mode = .follow; parked = true }

        case .deliver(let to, let dropped):
            busy = true
            let spot = CGPoint(x: to.x - box.width / 2, y: to.y)
            let side = max(16, min(32, box.height * 0.6))
            if let d = dropped {
                // Puts it down in front of its feet: the icon sinks, shrinks and fades.
                let u = CGFloat(min(1, (now - d) / 0.5)), s = side * (1 - 0.6 * u)
                let x = position.x + box.width / 2 + (facingLeft ? -1 : 1) * box.width * 0.6 * u
                gait = has(.special) ? .special : .stand
                showProp(carried, in: CGRect(x: x - s / 2, y: position.y + (box.height + 1) * (1 - u), width: s, height: s), alpha: Float(1 - u), smooth: true)
                if u >= 1 { mode = .follow; parked = false; carried = nil; hearts() }
            } else {
                let next = BuddyMath.step(from: position, to: spot, dt: dt, speed: BuddyMath.speed * 2)
                face(next.x - position.x)
                moving = next != position
                position = next
                gait = .run
                showProp(carried, in: CGRect(x: position.x + box.width / 2 - side / 2, y: position.y + box.height + 1, width: side, height: side), smooth: true)
                if next == spot { mode = .deliver(to: to, dropped: now) }
            }
            origin = position

        case .kick(let start, let dir, let from):
            busy = true
            let t = now - start, kicked = t >= TrashKick.windup
            origin = BuddyMath.clamp(position, size: box, in: bounds)
            gait = kicked ? (has(.special) ? .special : .run) : .stand
            if !still {   // leans back to wind up, then swings through
                let follow = CGFloat(max(0, 1 - (t - TrashKick.windup) / 0.3))
                turn = (kicked ? -dir * 0.18 * follow : dir * 0.12, 1, 1)
            }
            if !kicked || !still {
                let b = TrashKick.bundle(t, dir: dir), side = bundleSide
                showProp(Self.bundle, in: CGRect(x: from.x + b.offset.x, y: from.y + b.offset.y, width: side, height: side),
                         angle: still ? 0 : b.angle, smooth: false)
            }
            if t >= TrashKick.duration || still && kicked { cheer(until: now + 1.2) }

        case .push(let win, let checked):
            if cursorMoved || !MacReactions.shared.busy { mode = .follow; parked = false; break }
            if idleSeconds(now) >= Self.napAfter { gait = .sleep; break }   // nobody around: naps, no window checks
            if now - checked >= 5 { mode = .push(frontWindow(), checked: now) }   // moved, closed or another came in front
            let spot = win.flatMap { MacPush.spot(window: $0, size: box, in: bounds) }
            let next = BuddyMath.step(from: position, to: spot?.origin ?? position, dt: dt, speed: BuddyMath.speed * 2)
            face(next.x - position.x)
            moving = next != position
            position = next
            origin = BuddyMath.clamp(position, size: box, in: bounds)
            gait = moving ? .run : spot == nil ? .stand : .walk
            guard !moving else { break }
            if let dir = spot?.dir {   // leaning into the window with its legs going, trembling a little
                facingLeft = dir < 0
                if !still { turn = BuddyMath.lean(k: 0.6, dir: dir); origin.x += CGFloat(sin(now * 45)) }
            }
            if now >= sweatAt { sweatAt = now + 1.6; mark("💦", .systemBlue) }
        }

        // 꾸욱: held down, it squashes and trembles a little, gathering itself for the hop or the throw.
        if let p = pressAt, !still {
            switch mode {
            case .follow, .act, .react:
                let w = BuddyMath.windup(held: now - p)
                turn = (0, w.sx, w.sy)
                if w.sx > 1.01 { origin.x += CGFloat(sin(now * 70)) * (w.sx - 1) * 5 }
                parked = true
                busy = true
            default: break
            }
        }

        // Just landed: squashed flat for a moment.
        var settled = false   // following or acting: the landing squash shows
        switch mode { case .follow, .act: settled = pressAt == nil; default: break }
        if now - landed < 0.25, !still, settled {
            let u = CGFloat((now - landed) / 0.25)
            turn = (0, 1 + 0.25 * (1 - u), 1 - 0.3 * (1 - u))
            busy = true
        }

        layout(origin: origin, box: box, turn: turn, pivot: pivot, lines: moving && !hanging ? k : 0, rise: rise)
        if !propped, prop?.isVisible == true { prop?.orderOut(nil) }   // the errand ended or was cut short
        if desk.isHidden != (gait != .study) { desk.isHidden = gait != .study; book.isHidden = desk.isHidden }
        takeClicks(cursor: cursor, origin: origin, box: box, rise: rise)

        let set = frames[gait].map { facingLeft ? $0.left : $0.right } ?? frames[.walk].map { facingLeft ? $0.left : $0.right } ?? []
        if set != showing { showing = set; sprite.setFrames(set, smooth: smooth); frame = 0; frameClock = 0 }
        var per: TimeInterval = switch gait {
        case .walk: sitting ? 0.25 : 0.12
        case .run: 0.07
        case .eat: DogSpriteCache.extraFrameDuration(.eat)
        case .special: DogSpriteCache.extraFrameDuration(.special)
        case .sulk: DogSpriteCache.extraFrameDuration(.hungry)
        case .dizzy: 0.12
        case .sleep, .stand, .study: 0.5
        }
        if gait == .walk || gait == .run || gait == .special && moving { per /= Double(1 + 0.8 * k) }   // legs speed up too
        // The remainder carries over, so each motion keeps its own pace whatever the timer's jitter.
        frameClock = min(per, frameClock + min(elapsed, 1))
        if frameClock >= per { frameClock -= per; if !still { frame += 1; sprite.show(frame) } }

        // A resting cursor on it needs no fast ticks: the hit area only changes when the cursor or the frame does,
        // and a cursor moving over the window while it takes clicks wakes the fast tick from BuddyView.
        schedule(moving || busy || cursorMoved || clicks.pollAt != nil || scale != 1 ? 1.0 / 30 : per)
    }

    /// The window around the drawing (with room to lean), the lean itself and the speed lines (`lines` = their strength).
    /// `rise`: the window reaches that far further down, over the spot a reaction lifted it off.
    private func layout(origin: CGPoint, box: CGSize, turn: (angle: CGFloat, sx: CGFloat, sy: CGFloat), pivot: CGFloat, lines k: CGFloat, rise: CGFloat = 0) {
        guard let window else { return }
        let margin = ceil(max(box.width, box.height) * 0.3), low = margin + ceil(rise)   // the drawing's y in the window
        let frame = CGRect(x: origin.x - margin, y: origin.y - low, width: box.width + 2 * margin, height: box.height + margin + low)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.frame != frame { window.setFrame(frame, display: false) }
        drawn = CGRect(origin: origin, size: box)
        let deskRect = CGRect(x: margin + box.width * 0.12, y: low, width: box.width * 0.76, height: box.height * 0.24)
        desk.path = CGPath(roundedRect: deskRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        desk.lineWidth = max(1, pixelSize * 0.6)
        let bookRect = CGRect(x: deskRect.midX - box.width * 0.17, y: deskRect.maxY - 1, width: box.width * 0.34, height: box.height * 0.08)
        let open = CGMutablePath()
        open.addRect(bookRect)
        open.move(to: CGPoint(x: bookRect.midX, y: bookRect.minY))
        open.addLine(to: CGPoint(x: bookRect.midX, y: bookRect.maxY))   // the spine of an open book
        book.path = open
        book.lineWidth = desk.lineWidth
        sprite.layer?.setAffineTransform(.identity)
        sprite.frame = CGRect(x: margin, y: low, width: box.width, height: box.height)
        if let layer = sprite.layer, turn != (0, 1, 1) {
            layer.setAffineTransform(BuddyMath.transform(angle: turn.angle, sx: turn.sx, sy: turn.sy,
                                                         pivot: CGPoint(x: box.width / 2, y: box.height * pivot),
                                                         anchor: layer.anchorPoint, size: box))
        }
        lines.frame = view.bounds
        if k > 0.05 {
            // Three short lines trailing behind it.
            let dir: CGFloat = facingLeft ? -1 : 1, back = facingLeft ? margin + box.width : margin
            let path = CGMutablePath()
            for (i, f) in [0.35, 0.55, 0.75].enumerated() {
                let y = low + box.height * CGFloat(f), len = (margin - 2) * (i == 1 ? 1 : 0.65)
                path.move(to: CGPoint(x: back + dir * 2, y: y))
                path.addLine(to: CGPoint(x: back - dir * len, y: y))
            }
            lines.path = path
            lines.lineWidth = max(1, pixelSize)
            lines.opacity = Float(k)
        } else {
            lines.opacity = 0
        }
        CATransaction.commit()
    }

    /// Takes the mouse only over the drawing, so clicks on the transparent rest go to the window below. Reacting
    /// (`rise` up), also over the spot it rose off, so the next click of a combo never falls through.
    private func takeClicks(cursor: CGPoint, origin: CGPoint, box: CGSize, rise: CGFloat) {
        guard let window else { return }
        var take = false
        if case .hang(_, true, _) = mode { take = true }
        else if NSEvent.pressedMouseButtons & 1 != 0 && !window.ignoresMouseEvents { take = true }   // mid-click: keep it
        else if window.frame.contains(cursor), !showing.isEmpty {
            let image = showing[min(sprite.index, showing.count - 1)], id = ObjectIdentifier(image)
            if hits[id] == nil { hits[id] = AlphaHit(image) }
            take = hits[id]?.hits(CGPoint(x: cursor.x - origin.x, y: cursor.y - origin.y), in: box) ?? false
        }
        if !take, rise > 0, CGRect(origin: CGPoint(x: origin.x, y: origin.y - rise), size: box).contains(cursor) { take = true }
        if window.ignoresMouseEvents == take { window.ignoresMouseEvents = !take }
    }

    // MARK: Idle life

    /// Resting by a quiet cursor: now and then a butterfly, a seat on the front window, a 장난감 nearby, or a bit of play.
    private func idleLife(now: TimeInterval, box: CGSize, bounds: CGRect) {
        if now >= storyAt, now - stillSince >= 5 {
            storyAt = now + .random(in: 180...360)
            let head = CGPoint(x: position.x + box.width / 2, y: position.y + box.height + 12)
            let side: CGFloat = Bool.random() ? 1 : -1
            let from = CGPoint(x: min(max(head.x + side * 260, bounds.minX + 10), bounds.maxX - 10), y: min(head.y + 90, bounds.maxY - 10))
            mode = .story(ButterflyStory(from: from, spot: head), start: now)
            return
        }
        if now - stillSince >= 15, now >= perchAfter {
            perchAfter = now + 60
            if let win = frontWindow(), BuddyMath.perch(on: win, x: position.x, size: box, in: bounds) != nil {
                mode = .perch(win, checked: now)
                return
            }
        }
        if now - stillSince >= 8, now >= toyAt, let t = ToyBox.shared.pick(near: CGPoint(x: position.x + box.width / 2, y: position.y), reach: 360) {
            toyAt = now + .random(in: 60...150)
            mode = .toy(t.id, t.kind, since: nil)
            return
        }
        guard now >= playAt else { return }
        playAt = now + BuddyMath.playGap(working: AssistantSettings.shared.workHours.working(Date()), random: .random(in: 0...1))
        let choices = [BuddyGait.eat, .special].filter(has)
        guard !choices.isEmpty else { return }
        let g = LinePick.pick("buddy.play", choices)   // never the same one twice in a row
        mode = .act(g, until: now + min(4, max(1.5, Double(frames[g]?.right.count ?? 0) * DogSpriteCache.extraFrameDuration(g == .eat ? .eat : .special) * 2)))
    }

    /// Seconds since the last key, click or mouse move anywhere (read at most once a second).
    private func idleSeconds(_ now: TimeInterval) -> TimeInterval {
        if now - idle.read >= 1 {
            idle = (now, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved))
        }
        return idle.seconds + (now - idle.read)
    }

    /// The frame of the front app's front window in screen points (y up). Only bounds, layer and owner: no names,
    /// so no screen recording permission.
    private func frontWindow() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame.height else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier, front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let owner = { (w: [String: Any]) in (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
        let normal = list.filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 && owner($0) != me }
        guard let info = normal.first(where: { owner($0) == front }) ?? normal.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return CGRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height)   // window list: y down from the top
    }

    // MARK: Clicks

    private func mouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation, t = e.timestamp   // seconds since boot, like systemUptime
        switch e.type {
        case .rightMouseDown: showMenu(e)
        case .leftMouseDown where e.modifierFlags.contains(.control): showMenu(e)
        case .leftMouseDown where e.modifierFlags.contains(.option): quickAsk()   // no press: its release finds nothing
        case .leftMouseDown:
            pressAt = t
            clicks.mouseDown(p, at: t).forEach(handle)
        case .leftMouseDragged: clicks.mouseMoved(p, at: t).forEach(handle)
        case .leftMouseUp:
            // Held long without a drag (꾸욱): no click, it hops instead.
            if let at = pressAt, t - at >= 0.4, grounded {
                pressAt = nil
                clicks = ClickRecognizer()
                hop()
                break
            }
            pressAt = nil
            var g = clicks.mouseUp(p, at: t)
            // Answered at once, so clicks in a row make a combo, never a double click.
            if clicks.pollAt != nil { clicks = ClickRecognizer(); g = [.single(p)] }
            g.forEach(handle)
        default: break
        }
        schedule(1.0 / 30)
    }

    /// The menu swallows the button's release: a held buddy is let go first, so it never stays stuck to the cursor.
    private func showMenu(_ e: NSEvent) {
        pressAt = nil
        clicks.cancel(at: NSEvent.mouseLocation).forEach(handle)
        FriendMenu.pop([
            FriendMenu.item(L("퀵물어보기")) { [weak self] in self?.quickAsk() },
            FriendMenu.item(L("AI 비서랑 이야기하기")) { [weak self] in self?.openAssistant?() },
            FriendMenu.item(L("복제해서 바탕화면에 두기")) { [weak self] in self?.cloneOut() },
            FriendMenu.submenu(L("놀이"), StarGame.menuItems(.buddy)),
            FriendMenu.item(L("커서 친구 쉬게 하기")) { MotionStore.shared.cursorBuddy = false },
        ], with: e, for: view)
    }

    private func handle(_ g: ClickRecognizer.Gesture) {
        let now = ProcessInfo.processInfo.systemUptime
        switch g {
        case .single, .double:   // a double never comes: singles are answered at once
            react(combo.click(at: now), now: now)
        case .dragBegan:
            pressAt = nil
            endStory()
            hang(byHand: true, cursor: NSEvent.mouseLocation, now: now)
        case .dragged:
            break
        case .dragEnded(_, let v):
            guard case .hang(_, true, _) = mode else { break }
            if !still, hypot(v.dx, v.dy) >= BuddyMath.throwMin { fling(v); FriendCry.play(.hop, friend: "buddy") }
            else { mode = .drop(vy: 0, landY: position.y - size.height * scale * 0.6) }
        }
    }

    private var grounded: Bool { switch mode { case .follow, .act, .react: true; default: false } }

    /// Thrown at `v` from where it hangs: flies within the screen it is on and may land on the front window's top.
    /// A hop (`hop`) instead comes down where it stood.
    // ponytail: no flying across displays; per-screen walls if asked
    private func fling(_ v: CGVector, hop: Bool = false) {
        let box = CGSize(width: size.width * scale, height: size.height * scale)
        let mid = CGPoint(x: position.x + box.width / 2, y: position.y + box.height / 2)
        guard let b = (NSScreen.screens.first { NSMouseInRect(mid, $0.frame, false) } ?? NSScreen.main)?.visibleFrame else { return }
        let floor = hop ? min(max(position.y, b.minY), b.maxY - box.height) : b.minY
        let walls = CGRect(x: b.minX + box.width / 2, y: floor, width: max(0, b.width - box.width), height: max(0, b.maxY - box.height - floor))
        var top: (minX: CGFloat, maxX: CGFloat, y: CGFloat)?
        if !hop, let win = frontWindow(), BuddyMath.perch(on: win, x: position.x, size: box, in: b) != nil {
            top = (max(win.minX, b.minX) + box.width / 2, min(win.maxX, b.maxX) - box.width / 2, win.maxY - 2)
        }
        let start = CGPoint(x: min(max(mid.x, walls.minX), walls.maxX), y: min(max(position.y, walls.minY), walls.maxY))
        mode = .fly(Fling(at: start, velocity: v, walls: walls, ledge: top))
        schedule(1.0 / 30)
    }

    /// The payoff of a long press: a hop straight up in place (a happy face in place under 동작 줄이기).
    private func hop() {
        endStory()
        FriendCry.play(.hop, friend: "buddy")
        if still { cheer(until: ProcessInfo.processInfo.systemUptime + 1.2); return }
        fling(CGVector(dx: 0, dy: BuddyMath.hopSpeed), hop: true)
        mark("✦", .systemYellow)
    }

    /// Down from a flight: dizzy after a hard landing or a lot of bouncing, else happy. Then it walks back on its own.
    private func land(_ f: Fling, now: TimeInterval) {
        landed = now
        if f.impact > 1500 || f.bounces >= 4 {
            mode = .act(.dizzy, until: now + 2)
            if now >= dizzyAfter { dizzyAfter = now + 30; sayDizzy() }
        } else {
            cheer(until: now + 1.2)
        }
    }

    /// Its happy pose in place with a heart.
    private func cheer(until: TimeInterval) {
        mode = .act([BuddyGait.special, .eat].first(where: has) ?? .walk, until: until)
        parked = true
        hearts()
    }

    /// Hangs from the cursor, swinging from where it is now.
    private func hang(byHand: Bool, cursor: CGPoint, now: TimeInterval) {
        let box = CGSize(width: size.width * scale, height: size.height * scale)
        var d = Dangle(anchor: cursor, restLength: max(10, box.height * 0.3))
        d.grab(at: BuddyMath.grip(origin: position, size: box, cursor: cursor))
        d.release(velocity: byHand ? .zero : CGVector(dx: motion.velocity.dx * 0.3, dy: 0))
        mode = .hang(d, byHand: byHand, until: now + 4)
        if !byHand { clingAfter = now + 16 }   // 12 s after it let go
    }

    private func sayDizzy() {
        let line = LinePick.pick("buddy.dizzy", [L("어질어질…"), L("세상이 빙글빙글 돌아요"), L("눈앞이 핑핑 돌아요")])
        let own = AppSettings.shared.shownVoice.cries   // the character's own sounds first
        let text = own.isEmpty ? AssistantModel.persona().dress(line) : "\(LinePick.pick("buddy.cry", own)) \(line)"
        SpeechBubbleCenter.shared.say(text: text, source: .system)
    }

    /// Clicked: reaction `r` in place with its mark. Dizzy and pout also say so (at most every 30 s).
    private func react(_ r: Reaction, now: TimeInterval) {
        switch mode { case .hang, .drop, .fly, .deliver, .kick: return; default: break }   // a click mid-air or mid-errand changes nothing
        endStory()
        FriendCry.play(r, friend: "buddy")
        if r == .pout { facingLeft.toggle() }   // turns its back on you
        mode = .react(r, start: now)
        parked = true
        if let m = r.mark { mark(m.text, m.color) }
        guard r == .dizzy || r == .pout, now >= dizzyAfter else { return }
        dizzyAfter = now + 30
        if r == .dizzy { sayDizzy() } else { SpeechBubbleCenter.shared.say(text: AssistantModel.persona().dress(L("그만 눌러요, 흥!")), source: .system) }
    }

    /// A copy of it on the desktop (복제 친구), standing where it stands.
    private func cloneOut() {
        guard DesktopClones.shared.add(at: CGPoint(x: drawn.midX, y: drawn.minY)) else { return }
        mark("✦", .systemYellow)
        SpeechBubbleCenter.shared.say(text: AssistantModel.persona().dress(L("똑같은 친구가 바탕화면에 생겼어요")), source: .system)
    }

    /// 퀵물어보기 over its head; again while it is open closes it.
    private func quickAsk() {
        MainActor.assumeIsolated {
            let ask = FriendQuickAsk.shared
            ask.toggle(from: view.window) { [weak self] in self?.head() }
        }
    }

    /// A heart rising over its head (반가워하기).
    private func hearts() { mark("♥", .systemPink) }

    private func mark(_ text: String, _ color: NSColor) {
        guard let layer = view.layer else { return }
        FriendMark.pop(text, color: color, over: sprite.frame, in: layer, still: still, scale: window?.backingScaleFactor ?? 2)
    }

    // MARK: Butterfly

    private func endStory() {
        butterfly?.orderOut(nil)
        if case .story = mode { mode = .follow }
    }

    private func showButterfly(_ p: CGPoint?, t: TimeInterval) {
        guard let p else { butterfly?.orderOut(nil); return }
        let w = butterfly ?? makeFloat()
        butterfly = w
        let s = CGSize(width: 5 * pixelSize, height: 4 * pixelSize)
        w.setFrame(CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        w.contentView?.layer?.contents = Self.wings[still ? 0 : Int(t / 0.12) % 2]
        CATransaction.commit()
        if !w.isVisible { w.orderFrontRegardless() }
    }

    // MARK: Props

    /// What it carries or kicks: `image` in `rect` (screen points), turned by `angle` about its middle.
    private func showProp(_ image: CGImage?, in rect: CGRect, angle: CGFloat = 0, alpha: Float = 1, smooth: Bool) {
        propped = true
        let w = prop ?? makeFloat()
        if prop == nil { w.contentView?.layer?.addSublayer(propLayer); prop = w }
        let pad = ceil(rect.width * 0.25)   // room for the turn
        w.setFrame(rect.insetBy(dx: -pad, dy: -pad), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        propLayer.contents = image
        propLayer.contentsScale = w.backingScaleFactor
        propLayer.magnificationFilter = smooth ? .linear : .nearest
        propLayer.opacity = alpha
        propLayer.setAffineTransform(.identity)
        propLayer.frame = CGRect(x: pad, y: pad, width: rect.width, height: rect.height)
        propLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
        if !w.isVisible { w.orderFrontRegardless() }
    }

    /// 휴지통's bundle: a tied bag, 7 x 7 dots drawn in code.
    private static let bundle = dots(["..t.t..", "...t...", ".bbbbb.", "bbbhbbb", "bbhbbbb", "bbbbbbb", ".bbbbb."],
                                     ["b": CGColor(red: 0.4, green: 0.44, blue: 0.5, alpha: 1), "h": CGColor(red: 0.66, green: 0.7, blue: 0.76, alpha: 1),
                                      "t": CGColor(red: 0.95, green: 0.76, blue: 0.3, alpha: 1)])

    /// A borderless see-through panel that never takes the mouse, for the butterfly and the props.
    private func makeFloat() -> NSWindow {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        v.layer?.magnificationFilter = .nearest
        v.layer?.contentsGravity = .resize
        w.contentView = v
        return w
    }

    /// Our butterfly, wings open and closed: 5 x 4 dots drawn in code.
    private static let wings: [CGImage] = [["ww.ww", "wwbww", ".wbw.", ".w.w."], [".w.w.", ".wbw.", "..b..", "....."]].compactMap {
        dots($0, ["w": CGColor(red: 0.98, green: 0.62, blue: 0.25, alpha: 1), "b": CGColor(red: 0.25, green: 0.2, blue: 0.2, alpha: 1)])
    }

    /// Rows of dots, top row first, each character a colour from `colors` ("." and unknown ones see-through).
    private static func dots(_ rows: [String], _ colors: [Character: CGColor]) -> CGImage? {
        let w = rows.map(\.count).max() ?? 0, h = rows.count
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                guard let color = colors[ch] else { continue }
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: c, y: h - 1 - r, width: 1, height: 1))   // the context's y goes up
            }
        }
        return ctx.makeImage()
    }

    /// Left-facing copy; nearest-neighbour so pixels stay crisp.
    private static func mirrored(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            let t = NSAffineTransform()
            t.translateX(by: rect.width, yBy: 0)
            t.scaleX(by: -1, yBy: 1)
            t.concat()
            image.draw(in: rect)
            return true
        }
    }
}

/// The buddy window's view: takes the first click (the window never becomes key) and hands mouse events on.
/// While it takes the mouse, a move or exit wakes the fast tick, so it stops taking clicks off the drawing at once.
private final class BuddyView: NSView {
    var onMouse: ((NSEvent) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func mouseMoved(with event: NSEvent) { onMouse?(event) }
    override func mouseExited(with event: NSEvent) { onMouse?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouse?(event) }
    override func mouseDragged(with event: NSEvent) { onMouse?(event) }
    override func mouseUp(with event: NSEvent) { onMouse?(event) }
    override func rightMouseDown(with event: NSEvent) { onMouse?(event) }
}
