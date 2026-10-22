import AppKit
import Combine
import QuartzCore

// MARK: Physics (pure)

/// Something to stand on: a top edge from `minX` to `maxX` at height `y` (screen points, y up). One-way unless
/// `solid`: jumped up through from below, landed on from above, dropped through with ↓ + ↑.
struct PlayPlatform: Equatable {
    var minX: CGFloat, maxX: CGFloat, y: CGFloat
    var solid = false

    func spans(_ x: CGFloat) -> Bool { x >= minX && x <= maxX }
}

/// What one player holds this frame. `jump` is the press itself (not the key held), set once per press.
struct PlayInput: Equatable {
    var left = false, right = false, run = false, down = false, jump = false
}

enum PlayEvent: Equatable { case jumped, landed }

/// A player's feet (bottom middle) and speed, in screen points with y up.
struct PlayBody: Equatable {
    var x: CGFloat, y: CGFloat
    var vx: CGFloat = 0, vy: CGFloat = 0
    var onGround = false
    /// Jumps since it last stood: 2 = the double jump is used up.
    var jumps = 0
    var crouching = false
    var facingLeft = false
}

/// The platformer under 놀이 모드: gravity, walking, a double jump, one-way platforms. Pure and tested (PlayModeTests).
enum PlayPhysics {
    static let walk: CGFloat = 220, run: CGFloat = 480
    static let gravity: CGFloat = 2600, maxFall: CGFloat = 1800
    /// About 155 pt up, then about 120 more for the second one.
    static let jump: CGFloat = 900, doubleJump: CGFloat = 800
    /// Standing on a platform that moved this little (a window nudged) it rides along instead of falling.
    static let stick: CGFloat = 6
    /// Windows smaller than this are sheets, popovers and helpers: nothing to stand on.
    static let minWindow = CGSize(width: 80, height: 40)

    /// One frame of `dt` seconds for a body `width` wide; its feet stay within `walls` (screen x).
    @discardableResult
    static func step(_ b: inout PlayBody, input: PlayInput, platforms: [PlayPlatform], walls: ClosedRange<CGFloat>,
                     width: CGFloat, dt: TimeInterval) -> [PlayEvent] {
        var events: [PlayEvent] = []
        let t = CGFloat(max(0, dt))
        let dir: CGFloat = (input.right ? 1 : 0) - (input.left ? 1 : 0)
        b.crouching = b.onGround && input.down
        b.vx = b.crouching ? 0 : dir * (input.run ? run : walk)
        if dir != 0 { b.facingLeft = dir < 0 }

        if input.jump {
            let under = b.onGround ? support(b, platforms) : nil
            if let p = under, input.down, !p.solid {
                b.y = p.y - 1   // under its edge: the landing check no longer sees it
                b.onGround = false; b.crouching = false; b.jumps = 1
            } else if b.onGround || b.jumps < 2 {
                b.vy = b.onGround ? jump : doubleJump
                b.jumps = b.onGround ? 1 : 2
                b.onGround = false; b.crouching = false
                events.append(.jumped)
            }
        }

        if b.onGround {
            if let p = support(b, platforms) { b.y = p.y; b.vy = 0 } else { b.onGround = false; b.jumps = max(b.jumps, 1) }   // walked off
        }
        let lo = walls.lowerBound + width / 2, hi = max(lo, walls.upperBound - width / 2)
        b.x = min(max(b.x + b.vx * t, lo), hi)
        guard !b.onGround else { return events }

        b.vy = max(-maxFall, b.vy - gravity * t)
        let from = b.y, to = b.y + b.vy * t
        b.y = to
        // Falling: the highest edge it passed through from above. Rising, it goes up through them.
        if b.vy <= 0, let p = platforms.filter({ $0.spans(b.x) && from >= $0.y && to <= $0.y }).max(by: { $0.y < $1.y }) {
            b.y = p.y; b.vy = 0; b.onGround = true; b.jumps = 0
            events.append(.landed)
        }
        // Never under the ground, whatever the frame skipped.
        if let floor = platforms.filter({ $0.solid && $0.spans(b.x) }).map(\.y).max(), b.y < floor {
            if !b.onGround { events.append(.landed) }
            b.y = floor; b.vy = 0; b.onGround = true; b.jumps = 0
        }
        return events
    }

    /// The edge under its feet (within `stick`), the highest if two meet.
    static func support(_ b: PlayBody, _ platforms: [PlayPlatform]) -> PlayPlatform? {
        platforms.filter { $0.spans(b.x) && abs($0.y - b.y) <= stick }.max { $0.y < $1.y }
    }

    /// What there is to stand on, on the screen with visible frame `screen`: its bottom (above the Dock) as solid
    /// ground, then the visible parts of normal windows' top edges (`list` front first, our own `me` left out) and
    /// the 러그's top, which lies under every window; `props` (장난감) lie under every window too, over the 러그.
    /// An edge against the menu bar is a ceiling, not a platform.
    static func platforms(_ list: [ListedWindow], me: pid_t, screen: CGRect, rug: CGRect?, props: [CGRect] = []) -> [PlayPlatform] {
        var out = [PlayPlatform(minX: screen.minX, maxX: screen.maxX, y: screen.minY, solid: true)]
        let windows = list.filter { $0.pid != me && $0.layer == 0 && $0.alpha > 0
            && $0.frame.width >= minWindow.width && $0.frame.height >= minWindow.height }.map(\.frame)
        var front: [CGRect] = []
        for f in windows + props + (rug.map { [$0] } ?? []) {
            defer { front.append(f) }
            let y = f.maxY
            guard y > screen.minY + 1, y < screen.maxY - 8 else { continue }
            var spans = [(max(f.minX, screen.minX), min(f.maxX, screen.maxX))]
            for c in front where c.minY < y && y <= c.maxY {   // a window in front hides that part of the edge
                spans = spans.flatMap { s in [(s.0, min(s.1, c.minX)), (max(s.0, c.maxX), s.1)].filter { $0.1 > $0.0 } }
            }
            out += spans.filter { $0.1 - $0.0 >= 24 }.map { PlayPlatform(minX: $0.0, maxX: $0.1, y: y) }
        }
        return out
    }
}

// MARK: The session

/// "놀이 모드": the 커서 친구 or a 복제 친구 becomes a little platformer hero for a while, run with the keyboard over
/// the screen's bottom, the top edges of real windows and the 러그. Keys come only from our own key panel during a
/// session (no global key monitor, no permission); Esc, a click elsewhere, an app or Space switch, sleep or a display
/// change, or 2 minutes with no key, ends it, and the friend goes back to what it was doing from where the player stopped.
/// P1: ← → 걷기, Shift 달리기, ↑ 점프 (공중에서 한 번 더: 2단 점프), ↓ 웅크리기, ↓ + ↑ 내려가기.
/// P2 (`twoPlayer`, for games): A D 걷기, W 점프, S 웅크리기, the same character tinted.
/// For games built on it: `onTick`, `onEvent`, `onEnd`, `onStep`, `under`, `player(_:)`, `body(_:)`, `update(_:_:)`,
/// `platforms()`, `overlay(on:)`, and `didStart` to add hooks from outside; every hook is cleared when the session ends. Nothing exists or ticks outside a session; in one, 60 fps while anything moves or a
/// game ticks, 4 a second otherwise (the window list is read at most 4 times a second either way).
final class PlayMode {
    static let shared = PlayMode()
    /// 설정 > 놀이 > 둘이 놀기: P2 comes out when a session starts.
    static let twoPlayerKey = "play.twoPlayer"
    /// No key for this long and no game on: the player walked away (or the keys never reached us), the session ends.
    static let idleLimit: TimeInterval = 120

    static func idleOver(now: TimeInterval, lastKey: TimeInterval, game: Bool) -> Bool { !game && now - lastKey >= idleLimit }

    enum Source: Equatable {
        case buddy
        case clone(UUID)
    }

    private(set) var isPlaying = false
    /// Per frame while playing, with that frame's seconds.
    var onTick: [(TimeInterval) -> Void] = []
    /// A player (0 = P1, 1 = P2) jumped or landed.
    var onEvent: [(PlayEvent, Int) -> Void] = []
    /// The session is over (the overlays are about to go).
    var onEnd: [() -> Void] = []
    /// Per frame like `onTick`, but never keeping the frames fast by itself (4 a second at rest): for things that
    /// only answer the players, such as the 장난감.
    var onStep: [(TimeInterval) -> Void] = []
    /// Boxes lying under every window, as the 러그, whose tops are edges too (screen points); read with the window list.
    var under: [() -> [CGRect]] = []
    /// A session is starting, its players out: the place to add hooks from outside (the 장난감 상자).
    let didStart = PassthroughSubject<Void, Never>()

    /// P2 on WASD; on or off at any time during a session.
    var twoPlayer = false {
        didSet {
            guard isPlaying, twoPlayer != oldValue else { return }
            if twoPlayer { addP2() } else if players.count > 1 { players.removeLast().remove() }
        }
    }

    fileprivate final class Player {
        var body: PlayBody
        var input = PlayInput()
        var frames: [BuddyGait: [NSImage]] = [:]
        var size = CGSize.zero
        let layer = CALayer(), mark = CATextLayer()
        var frame = 0, clock: TimeInterval = 0
        var shown: NSImage?

        init(body: PlayBody) { self.body = body }
        var rect: CGRect { CGRect(x: body.x - size.width / 2, y: body.y, width: size.width, height: size.height) }
        func remove() { layer.removeFromSuperlayer(); mark.removeFromSuperlayer() }
    }

    private var source = Source.buddy
    private var players: [Player] = []
    private var screen = CGRect.zero
    /// The session screen's visible frame (under the menu bar, above the Dock), for a game's HUD.
    private(set) var visible = CGRect.zero
    private var keyPanel: PlayKeyPanel?
    /// One see-through panel per screen (by its frame), each with a layer in screen coordinates.
    private var overlays: [(frame: CGRect, panel: NSPanel, world: CALayer)] = []
    private var edges: [PlayPlatform] = []
    private var lastRead: TimeInterval = -1
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var bag: Set<AnyCancellable> = []
    private var previous: NSRunningApplication?
    private var lastKey: TimeInterval = 0
    private var still = DesktopKit.reduceMotion

    // MARK: API

    /// Starts a session with that friend (`.buddy` with the 커서 친구 off: the character chosen now, at the cursor).
    /// Does nothing while one is on.
    func start(_ from: Source = .buddy) {
        guard !isPlaying else { return }
        ClickGames.shared.stop()   // one game at a time
        let px = MotionStore.shared.buddySize.pixelSize
        var rect: CGRect?, character: String?
        switch from {
        case .buddy:
            rect = CursorBuddy.shared.lendForPlay()
        case .clone(let id):
            guard let lent = DesktopClones.shared.lendForPlay(id) else { return }
            (rect, character) = (lent.rect, lent.character)
        }
        let cache = MeadowFriends.cache(character: character, pixelSize: px)
        let size = cache.imageSize
        let feet = rect.map { CGPoint(x: $0.midX, y: $0.minY) } ?? CGPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - size.height)
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(CGPoint(x: feet.x, y: feet.y + 1), $0.frame, false) }) ?? NSScreen.main else {
            giveBack(from, feet: feet)
            return
        }
        source = from
        screen = s.frame
        visible = s.visibleFrame
        still = DesktopKit.reduceMotion
        isPlaying = true
        previous = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        let p1 = Player(body: PlayBody(x: min(max(feet.x, visible.minX), visible.maxX), y: min(max(feet.y, visible.minY), visible.maxY - size.height)))
        dress(p1, cache: cache, tint: nil)
        players = [p1]
        didStart.send()
        readPlatforms(now: ProcessInfo.processInfo.systemUptime)
        twoPlayer = AppDefaults.store.bool(forKey: Self.twoPlayerKey)   // P2 joins here when on
        lastTick = ProcessInfo.processInfo.systemUptime
        lastKey = lastTick
        listen()
        let k = keyPanel ?? makeKeyPanel()
        keyPanel = k
        k.setFrameOrigin(CGPoint(x: screen.minX, y: screen.minY))
        NSApp.activate(ignoringOtherApps: true)   // the keys are ours only until the session ends
        k.makeKeyAndOrderFront(nil)
        players.forEach(layout)
        wake()
    }

    /// Ends the session; with `restoreFocus` the app that was in front gets the focus back.
    func end(restoreFocus: Bool = true) {
        guard isPlaying else { return }
        isPlaying = false
        twoPlayer = false   // the next session reads 둘이 놀기 afresh
        let hooks = onEnd
        onTick = []; onEvent = []; onEnd = []; onStep = []; under = []
        hooks.forEach { $0() }
        timer?.invalidate(); timer = nil; interval = 0
        bag = []
        let feet = players.first.map { CGPoint(x: $0.body.x, y: $0.body.y) }
        players.forEach { $0.remove() }
        players = []
        edges = []
        for o in overlays { o.panel.orderOut(nil) }
        overlays = []
        keyPanel?.orderOut(nil)
        if let feet { giveBack(source, feet: feet) }
        if restoreFocus { previous?.activate(options: []) }
        previous = nil
    }

    /// Where that player's drawing is on screen (0 = P1, 1 = P2); nil when it is not out.
    func player(_ i: Int = 0) -> CGRect? { players.indices.contains(i) ? players[i].rect : nil }

    /// That player's feet and speed (0 = P1, 1 = P2); nil when it is not out.
    func body(_ i: Int = 0) -> PlayBody? { players.indices.contains(i) ? players[i].body : nil }

    /// Changes that player's body (a 트램펄린's launch, a 미끄럼틀 carrying it), then runs the frames fast.
    func update(_ i: Int, _ change: (inout PlayBody) -> Void) {
        guard players.indices.contains(i) else { return }
        change(&players[i].body)
        wake()
    }

    /// What the players stand on now, screen points (y up).
    func platforms() -> [PlayPlatform] { edges }

    /// A see-through layer over all of `screen` (the session's screen by default) for a game's sprites, above the
    /// windows and never taking the mouse; sublayers use screen points (y up). nil outside a session. It goes, with
    /// everything on it, when the session ends.
    func overlay(on screen: NSScreen? = nil) -> CALayer? {
        guard isPlaying else { return nil }
        let frame = screen?.frame ?? self.screen
        if let o = overlays.first(where: { $0.frame == frame }) { return o.world }
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        let v = NSView(frame: CGRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        p.contentView = v
        let world = CALayer()
        world.frame = v.bounds
        world.bounds.origin = frame.origin   // sublayers in screen points
        world.actions = ["sublayers": NSNull()]
        v.layer?.addSublayer(world)
        p.setFrame(frame, display: false)
        p.orderFrontRegardless()
        overlays.append((frame, p, world))
        return world
    }

    // MARK: Players

    private func dress(_ p: Player, cache: DogSpriteCache, tint: NSColor?) {
        p.frames = BuddyGait.frames(cache).filter { !$0.value.isEmpty }.mapValues { set in tint.map { t in set.map { Self.tinted($0, t) } } ?? set }
        p.size = cache.imageSize
        let scale = NSScreen.screens.first { $0.frame == screen }?.backingScaleFactor ?? 2
        p.layer.contentsScale = scale
        p.layer.magnificationFilter = cache.smooth ? .linear : .nearest
        p.layer.bounds = CGRect(origin: .zero, size: p.size)
        p.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        p.layer.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull(), "bounds": NSNull()]
        p.mark.string = "🎮"
        p.mark.fontSize = max(10, p.size.height * 0.3)
        p.mark.alignmentMode = .center
        p.mark.contentsScale = scale
        p.mark.bounds = CGRect(x: 0, y: 0, width: p.mark.fontSize * 1.6, height: p.mark.fontSize * 1.3)
        p.mark.anchorPoint = CGPoint(x: 0.5, y: 0)
        p.mark.actions = ["position": NSNull()]
        overlay()?.addSublayer(p.layer)
        overlay()?.addSublayer(p.mark)
    }

    private func addP2() {
        guard players.count == 1, let p1 = players.first else { return }
        let cache = MeadowFriends.cache(character: source.cloneCharacter, pixelSize: MotionStore.shared.buddySize.pixelSize)
        var b = p1.body
        b.x = min(b.x + p1.size.width * 1.2, visible.maxX - p1.size.width / 2)
        b.vx = 0; b.jumps = 0; b.facingLeft = true
        let p2 = Player(body: b)
        dress(p2, cache: cache, tint: .systemTeal)
        players.append(p2)
        layout(p2)
        wake()
    }

    /// The same frame washed with `color`, so P2 tells apart at a glance.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: rect)
            color.withAlphaComponent(0.4).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func giveBack(_ s: Source, feet: CGPoint) {
        switch s {
        case .buddy: CursorBuddy.shared.giveBackFromPlay(feet: feet)
        case .clone(let id): DesktopClones.shared.giveBackFromPlay(id, feet: feet)
        }
    }

    // MARK: Session

    private func listen() {
        let ws = NSWorkspace.shared.notificationCenter
        // A click elsewhere or another app in front: that app keeps the focus.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification).filter { [weak self] in $0.object as? NSWindow === self?.keyPanel },
                   NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification),
                   ws.publisher(for: NSWorkspace.screensDidSleepNotification),
                   ws.publisher(for: NSWorkspace.sessionDidResignActiveNotification),
                   ws.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
            .sink { [weak self] _ in self?.end(restoreFocus: false) }
            .store(in: &bag)
    }

    private func makeKeyPanel() -> PlayKeyPanel {
        let k = PlayKeyPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: true)
        k.isOpaque = false
        k.backgroundColor = .clear
        k.hasShadow = false
        k.ignoresMouseEvents = true
        k.hidesOnDeactivate = false
        k.level = .floating
        k.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        k.isExcludedFromWindowsMenu = true
        k.isReleasedWhenClosed = false
        k.onKey = { [weak self] e in self?.key(e) }
        return k
    }

    fileprivate func key(_ e: NSEvent) {
        guard isPlaying else { return }
        lastKey = ProcessInfo.processInfo.systemUptime
        let down = e.type == .keyDown
        if e.type == .flagsChanged {
            players.first?.input.run = e.modifierFlags.contains(.shift)
            return
        }
        if down, e.keyCode == 53 { end(); return }   // Esc
        let fresh = down && !e.isARepeat
        // ponytail: physical keys (kVK codes), so WASD works on any keyboard layout and input source
        switch e.keyCode {
        case 123: players.first?.input.left = down
        case 124: players.first?.input.right = down
        case 125: players.first?.input.down = down
        case 126: if fresh { players.first?.input.jump = true }   // ↑
        case 0: players.dropFirst().first?.input.left = down
        case 2: players.dropFirst().first?.input.right = down
        case 1: players.dropFirst().first?.input.down = down
        case 13: if fresh { players.dropFirst().first?.input.jump = true }
        default: return
        }
        wake()
    }

    private func readPlatforms(now: TimeInterval) {
        lastRead = now
        guard let primary = NSScreen.screens.first?.frame.height,
              let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let list = raw.compactMap { ListedWindow($0, primaryHeight: primary) }
        edges = PlayPhysics.platforms(list, me: ProcessInfo.processInfo.processIdentifier, screen: visible, rug: DesktopRug.shared.footprint(),
                                      props: under.flatMap { $0() })
    }

    private func wake() {
        guard isPlaying else { return }
        schedule(1.0 / 60)
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

    private func tick() {
        guard isPlaying else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, now - lastTick))
        lastTick = now
        if Self.idleOver(now: now, lastKey: lastKey, game: !onTick.isEmpty) { end(); return }
        if now - lastRead >= 0.25 { readPlatforms(now: now) }
        let walls = screen.minX...screen.maxX
        for (i, p) in players.enumerated() {
            let events = PlayPhysics.step(&p.body, input: p.input, platforms: edges, walls: walls, width: p.size.width, dt: dt)
            p.input.jump = false
            for e in events { onEvent.forEach { $0(e, i) } }
        }
        onTick.forEach { $0(dt) }
        onStep.forEach { $0(dt) }
        guard isPlaying else { return }   // a game may end it from a hook
        players.forEach { advance($0, dt: dt); layout($0) }
        let resting = onTick.isEmpty && players.allSatisfy {
            $0.body.onGround && $0.body.vx == 0 && !$0.input.left && !$0.input.right && !$0.input.down
        }
        schedule(resting ? 0.25 : 1.0 / 60)
    }

    private func gait(_ p: Player) -> BuddyGait {
        if !p.body.onGround || p.body.crouching { return .stand }
        if p.body.vx == 0 { return .stand }
        return abs(p.body.vx) > PlayPhysics.walk && p.frames[.run] != nil ? .run : .walk
    }

    private func advance(_ p: Player, dt: TimeInterval) {
        let per = gait(p) == .run ? 0.07 : 0.12
        p.clock += dt
        if p.clock >= per { p.clock -= per; p.frame += 1 }
    }

    private func layout(_ p: Player) {
        guard let set = p.frames[gait(p)] ?? p.frames[.walk], !set.isEmpty else { return }
        // In the air: a walking frame with the legs apart.
        let air = p.body.onGround ? nil : p.frames[.walk].flatMap { $0.count > 1 ? $0[1] : $0.first }
        let image = air ?? set[still ? 0 : p.frame % set.count]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if p.shown !== image { p.layer.contents = image; p.shown = image }
        p.layer.position = CGPoint(x: p.body.x, y: p.body.y)
        var t = p.body.facingLeft ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        if p.body.crouching, !still { t = t.concatenating(BuddyMath.transform(angle: 0, sx: 1.12, sy: 0.7, pivot: CGPoint(x: p.size.width / 2, y: 0),
                                                                                anchor: p.layer.anchorPoint, size: p.size)) }
        p.layer.setAffineTransform(t)
        p.mark.position = CGPoint(x: p.body.x, y: p.body.y + p.size.height * (p.body.crouching ? 0.75 : 1) + 2)
        CATransaction.commit()
    }
}

private extension PlayMode.Source {
    /// P2 wears the same character as P1.
    var cloneCharacter: String? {
        guard case .clone(let id) = self else { return nil }
        return CloneStore.shared.prefs.clones.first { $0.id == id }?.character
    }
}

/// The session's own key window: 1 point, see-through, never taking the mouse. Every key goes to PlayMode, so
/// nothing beeps.
private final class PlayKeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func keyUp(with event: NSEvent) { onKey?(event) }
    override func flagsChanged(with event: NSEvent) { onKey?(event) }
}
