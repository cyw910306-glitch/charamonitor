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

/// "커서 친구": the current character follows the mouse in a floating window that only takes clicks on its drawing.
/// macOS does not let an app replace the system cursor, so this is the oneko way.
/// Walks after the cursor, runs when the cursor got far ahead (bigger, leaning, with speed lines when the mouse is fast);
/// once there it waits until the cursor goes farther than it is big, so it can be clicked (반가워하기), double clicked
/// (AI 비서), dragged (it hangs and swings, then drops) or right clicked (the menu bar menu). At rest it eats while
/// charging, plays now and then, sits on the front window's top edge, chases a butterfly; it naps after 90 s without
/// input and gets dizzy when shaken. 30 fps only while something moves, the rest pose's own pace otherwise,
/// nothing while off or the screens sleep. 동작 줄이기: no growing, swinging or idle play, still poses.
final class CursorBuddy {
    static let shared = CursorBuddy()
    /// The menu bar's menu for a right click, and the AI 비서 for a double click. Set by StatusItemController.
    var showMenu: ((NSEvent, NSView) -> Void)?
    var openAssistant: (() -> Void)?

    private var window: NSWindow?
    private let view = BuddyView(frame: .zero)
    private let sprite = SpriteView(frame: .zero)
    private let lines = CAShapeLayer()   // speed lines
    /// 집중 중: a low pink desk with an open book in front of it (our own shapes over its standing pose).
    private let desk = CAShapeLayer(), book = CAShapeLayer()
    private var butterfly: NSWindow?
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var bag: Set<AnyCancellable> = []
    private var started = false

    private enum Gait { case walk, run, sleep, eat, stand, special, dizzy, sulk, study }
    /// What it does besides following the cursor.
    private enum Mode {
        case follow
        /// One pose in place until then (반가워하기, 혼자 놀기, 어질어질).
        case act(Gait, until: TimeInterval)
        /// Hanging from the cursor: held by the hand (a drag) or clinging on by itself until `until`.
        case hang(Dangle, byHand: Bool, until: TimeInterval)
        case drop(vy: CGFloat, landY: CGFloat)
        /// On the top edge of this window (screen points), last looked at `checked`.
        case perch(CGRect, checked: TimeInterval)
        case story(ButterflyStory, start: TimeInterval)
    }

    private var look: SpriteLook?
    private var pixelSize: CGFloat = 0
    private var frames: [Gait: (right: [NSImage], left: [NSImage])] = [:]
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
    private var lastCursor = CGPoint.zero
    private var stillSince: TimeInterval = 0   // the cursor last moved
    private var landed: TimeInterval = -1      // a drop landed: squashed for a moment
    private var dizzyAfter: TimeInterval = 0, clingAfter: TimeInterval = 0, perchAfter: TimeInterval = 0
    private var playAt: TimeInterval = 0, storyAt: TimeInterval = 0
    private var idle: (read: TimeInterval, seconds: TimeInterval) = (-10, 0)
    private var reperch = false   // dropping off a window that moved
    /// 동작 줄이기: it still follows, in one still pose per gait.
    private var still = DesktopKit.reduceMotion
    /// The drawing's rect on screen at the last layout (bubbles over its head point here).
    private var drawn = CGRect.zero

    private var enabled: Bool { MotionStore.shared.cursorBuddy && !asleep }
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

    /// 춤춰 줘·응원해 줘·a focus well done: its special moment in place, with a heart.
    private func celebrate() {
        guard timer != nil else { return }
        switch mode { case .follow, .act, .perch: break; default: return }   // not mid-swing or mid-fall
        let now = ProcessInfo.processInfo.systemUptime
        let a = [Gait.special, .eat].first(where: has) ?? .walk
        mode = .act(a, until: now + 2.5)
        parked = true
        hearts()
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
            let lying = cache.frames(for: .lying), walk = cache.frames(for: .walk)
            let sets: [Gait: [NSImage]] = [
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
            smooth = cache.smooth
            frames = sets.filter { !$0.value.isEmpty }.mapValues { ($0, $0.map(Self.mirrored)) }
            hits = [:]
            showing = []
        }
        if window == nil { makeWindow() }
        if timer == nil {
            let t = ProcessInfo.processInfo.systemUptime
            position = BuddyMath.target(cursor: NSEvent.mouseLocation, size: size)
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
        scale = 1
        window?.orderOut(nil)
        butterfly?.orderOut(nil)
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

    /// QA renders only: it running right at boost `k` (0...1 of 빠르게 움직이면) as `layout` draws it, or dizzy; no timer.
    /// Needs the QA's own MotionStore with 커서 친구 on. Returns the view whose layer holds the drawing.
    func qaPose(k: CGFloat, dizzy: Bool = false) -> NSView {
        refresh()
        timer?.invalidate(); timer = nil; interval = 0
        scale = 1 + k * (MotionStore.shared.buddyBoost.maxScale - 1)
        facingLeft = false
        let box = CGSize(width: size.width * scale, height: size.height * scale)
        let gait: Gait = dizzy ? .dizzy : k == 0 ? .walk : k > 0.7 && has(.special) ? .special : .run
        layout(origin: CGPoint(x: -4000, y: -4000), box: box, turn: k > 0 ? BuddyMath.lean(k: k, dir: 1) : (0, 1, 1), fromTop: false, lines: k)
        showing = frames[gait]?.right ?? []
        sprite.setFrames(showing, smooth: smooth)
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

    private func has(_ g: Gait) -> Bool { frames[g] != nil }
    private func face(_ dx: CGFloat) { if dx < -0.5 { facingLeft = true } else if dx > 0.5 { facingLeft = false } }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - lastTick)
        let dt = min(0.1, elapsed)
        lastTick = now
        let cursor = NSEvent.mouseLocation
        motion.feed(cursor, at: now)
        let cursorMoved = cursor != lastCursor
        if cursorMoved { lastCursor = cursor; stillSince = now }
        for g in clicks.poll(at: now) { handle(g) }
        let play = MotionStore.shared.buddyPlay

        // Grows with the cursor's speed (not while hanging), eases back when it slows.
        let top = still ? 1 : MotionStore.shared.buddyBoost.maxScale
        var hanging = false
        if case .hang = mode { hanging = true }
        scale = BuddyMath.ease(scale, to: hanging ? 1 : BuddyMath.boost(speed: motion.speed, max: top), dt: dt)
        if abs(scale - 1) < 0.005 { scale = 1 }
        let k = top > 1 ? min(1, max(0, (scale - 1) / (top - 1))) : 0
        let box = CGSize(width: size.width * scale, height: size.height * scale)

        // NSMouseInRect: edge-inclusive, so the top row of a display still counts as on it.
        let bounds = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // The cursor went to another display: start the chase from that display's edge, not across the gap.
        let slack = bounds.insetBy(dx: -(box.width + BuddyMath.gap), dy: -(box.height + BuddyMath.gap))
        if !slack.contains(position) { position = BuddyMath.clamp(position, size: box, in: bounds) }

        // Shaken hard while just following: dizzy for a moment.
        if motion.isShaking, MotionStore.shared.buddyBoost != .off, now >= dizzyAfter, case .follow = mode {
            dizzyAfter = now + 30
            motion.reset()
            mode = .act(.dizzy, until: now + 2.5)
            sayDizzy()
        }

        var gait = Gait.stand
        var moving = false, busy = false, sitting = false
        var origin = position
        var turn: (angle: CGFloat, sx: CGFloat, sy: CGFloat) = (0, 1, 1)
        var fromTop = false   // the turn's pivot: the head when hanging, else the feet

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
                if parked, play, !still, !napping, now - stillSince >= 3 { idleLife(now: now, box: box, bounds: bounds) }
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
                fromTop = true
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
        }

        // Just landed: squashed flat for a moment.
        if now - landed < 0.25, !still, case .follow = mode {
            let u = CGFloat((now - landed) / 0.25)
            turn = (0, 1 + 0.25 * (1 - u), 1 - 0.3 * (1 - u))
            busy = true
        }

        layout(origin: origin, box: box, turn: turn, fromTop: fromTop, lines: moving && !hanging ? k : 0)
        if desk.isHidden != (gait != .study) { desk.isHidden = gait != .study; book.isHidden = desk.isHidden }
        takeClicks(cursor: cursor, origin: origin, box: box)

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
    private func layout(origin: CGPoint, box: CGSize, turn: (angle: CGFloat, sx: CGFloat, sy: CGFloat), fromTop: Bool, lines k: CGFloat) {
        guard let window else { return }
        let margin = ceil(max(box.width, box.height) * 0.3)
        let frame = CGRect(x: origin.x - margin, y: origin.y - margin, width: box.width + 2 * margin, height: box.height + 2 * margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.frame != frame { window.setFrame(frame, display: false) }
        drawn = CGRect(origin: origin, size: box)
        let deskRect = CGRect(x: margin + box.width * 0.12, y: margin, width: box.width * 0.76, height: box.height * 0.24)
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
        sprite.frame = CGRect(x: margin, y: margin, width: box.width, height: box.height)
        if let layer = sprite.layer, turn != (0, 1, 1) {
            layer.setAffineTransform(BuddyMath.transform(angle: turn.angle, sx: turn.sx, sy: turn.sy,
                                                         pivot: CGPoint(x: box.width / 2, y: fromTop ? box.height : 0),
                                                         anchor: layer.anchorPoint, size: box))
        }
        lines.frame = view.bounds
        if k > 0.05 {
            // Three short lines trailing behind it.
            let dir: CGFloat = facingLeft ? -1 : 1, back = facingLeft ? margin + box.width : margin
            let path = CGMutablePath()
            for (i, f) in [0.35, 0.55, 0.75].enumerated() {
                let y = margin + box.height * CGFloat(f), len = (margin - 2) * (i == 1 ? 1 : 0.65)
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

    /// Takes the mouse only over the drawing, so clicks on the transparent rest go to the window below.
    private func takeClicks(cursor: CGPoint, origin: CGPoint, box: CGSize) {
        guard let window else { return }
        var take = false
        if case .hang(_, true, _) = mode { take = true }
        else if NSEvent.pressedMouseButtons & 1 != 0 && !window.ignoresMouseEvents { take = true }   // mid-click: keep it
        else if window.frame.contains(cursor), !showing.isEmpty {
            let image = showing[min(sprite.index, showing.count - 1)], id = ObjectIdentifier(image)
            if hits[id] == nil { hits[id] = AlphaHit(image) }
            take = hits[id]?.hits(CGPoint(x: cursor.x - origin.x, y: cursor.y - origin.y), in: box) ?? false
        }
        if window.ignoresMouseEvents == take { window.ignoresMouseEvents = !take }
    }

    // MARK: Idle life

    /// Resting by a quiet cursor: now and then a butterfly, a seat on the front window, or a bit of play.
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
        guard now >= playAt else { return }
        playAt = now + BuddyMath.playGap(working: AssistantSettings.shared.workHours.working(Date()), random: .random(in: 0...1))
        let choices = [Gait.eat, .special].filter(has)
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
        case .rightMouseDown: showMenu?(e, view)
        case .leftMouseDown where e.modifierFlags.contains(.control): showMenu?(e, view)
        case .leftMouseDown: clicks.mouseDown(p, at: t).forEach(handle)
        case .leftMouseDragged: clicks.mouseMoved(p, at: t).forEach(handle)
        case .leftMouseUp: clicks.mouseUp(p, at: t).forEach(handle)
        default: break
        }
        schedule(1.0 / 30)
    }

    private func handle(_ g: ClickRecognizer.Gesture) {
        let now = ProcessInfo.processInfo.systemUptime
        switch g {
        case .single:
            endStory()
            let a = [Gait.special, .eat].first(where: has) ?? .walk
            let per = DogSpriteCache.extraFrameDuration(a == .eat ? .eat : .special)
            mode = .act(a, until: now + min(3, max(1, Double(frames[a]?.right.count ?? 0) * per)))
            parked = true
            hearts()
            // 퀵물어보기 over its head; a second click while it is open closes it and just says hello.
            let opened = MainActor.assumeIsolated { () -> Bool in
                let ask = FriendQuickAsk.shared
                if ask.isOpen { ask.close(); return false }
                ask.show(from: view.window) { [weak self] in self?.head() }
                return true
            }
            if !opened {
                let persona = AssistantModel.persona()
                SpeechBubbleCenter.shared.say(text: LinePick.pick("buddy.click", persona.cries.isEmpty ? Persona.neutralCries : persona.cries),
                                              source: .system, aloud: false, repeats: true)
            }
        case .double:
            openAssistant?()
        case .dragBegan:
            endStory()
            hang(byHand: true, cursor: NSEvent.mouseLocation, now: now)
        case .dragged:
            break
        case .dragEnded:
            if case .hang(_, true, _) = mode { mode = .drop(vy: 0, landY: position.y - size.height * scale * 0.6) }
        }
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

    /// A heart rising over its head (반가워하기).
    private func hearts() {
        guard let layer = view.layer else { return }
        let fs = max(10, size.height * 0.35)
        let h = CATextLayer()
        h.string = "♥"
        h.fontSize = fs
        h.foregroundColor = NSColor.systemPink.cgColor
        h.alignmentMode = .center
        h.contentsScale = window?.backingScaleFactor ?? 2
        h.frame = CGRect(x: sprite.frame.midX - fs / 2, y: sprite.frame.maxY - fs, width: fs, height: fs * 1.2)
        h.opacity = 0
        layer.addSublayer(h)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        let group = CAAnimationGroup()
        group.duration = 0.9
        if still {
            group.animations = [fade]
        } else {
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.byValue = (view.bounds.height - sprite.frame.maxY) * 0.9
            group.animations = [fade, rise]
        }
        h.add(group, forKey: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { h.removeFromSuperlayer() }
    }

    // MARK: Butterfly

    private func endStory() {
        butterfly?.orderOut(nil)
        if case .story = mode { mode = .follow }
    }

    private func showButterfly(_ p: CGPoint?, t: TimeInterval) {
        guard let p else { butterfly?.orderOut(nil); return }
        let w = butterfly ?? makeButterfly()
        butterfly = w
        let s = CGSize(width: 5 * pixelSize, height: 4 * pixelSize)
        w.setFrame(CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        w.contentView?.layer?.contents = Self.wings[still ? 0 : Int(t / 0.12) % 2]
        CATransaction.commit()
        if !w.isVisible { w.orderFrontRegardless() }
    }

    private func makeButterfly() -> NSWindow {
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
    private static let wings: [CGImage] = [["ww.ww", "wwbww", ".wbw.", ".w.w."], [".w.w.", ".wbw.", "..b..", "....."]].compactMap { rows in
        guard let ctx = CGContext(data: nil, width: 5, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch != "." {
                ctx.setFillColor(ch == "w" ? CGColor(red: 0.98, green: 0.62, blue: 0.25, alpha: 1) : CGColor(red: 0.25, green: 0.2, blue: 0.2, alpha: 1))
                ctx.fill(CGRect(x: c, y: 3 - r, width: 1, height: 1))   // the context's y goes up
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
