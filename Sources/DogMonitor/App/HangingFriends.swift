import AppKit
import Combine
import QuartzCore

// MARK: Settings

/// How hard the wind blows on the 대롱대롱 친구.
enum WindLevel: String, Codable, CaseIterable {
    case calm, light, fresh, strong, local

    var label: String {
        switch self {
        case .calm: return L("고요")
        case .light: return L("산들")
        case .fresh: return L("선선")
        case .strong: return L("쌩쌩")
        case .local: return L("우리 동네 바람")
        }
    }

    /// Steady sideways push in points per second squared (Dangle.step wind). `.local` falls back to `.light` without weather.
    var push: CGFloat {
        switch self {
        case .calm: return 0
        case .light, .local: return 45
        case .fresh: return 120
        case .strong: return 260
        }
    }

    /// Real wind (m/s) to push: 3 m/s is about 산들, 9 m/s 쌩쌩, capped.
    static func push(metersPerSecond ms: Double) -> CGFloat { CGFloat(min(320, max(0, ms) * 30)) }

    /// What blows now: nothing under 동작 줄이기; `.local` follows `local` (m/s) and is 산들 while there is none.
    func push(still: Bool, local: Double?) -> CGFloat {
        still ? 0 : self == .local ? local.map(Self.push(metersPerSecond:)) ?? push : push
    }
}

/// The small ornament between the string and the friend. Our own weather set.
enum Charm: String, Codable, CaseIterable {
    case none, cloud, star, moon, heart, drop, clover

    var label: String {
        switch self {
        case .none: return L("없음")
        case .cloud: return L("구름")
        case .star: return L("별")
        case .moon: return L("달")
        case .heart: return L("하트")
        case .drop: return L("물방울")
        case .clover: return L("네잎클로버")
        }
    }

    /// 'o' outline, 'w' fill, 'l' shine; '.' clear.
    var rows: [String] {
        switch self {
        case .none: return []
        case .cloud: return ["....ooo....",
                             "..oowwwo...",
                             ".owwlwwwoo.",
                             "owwwwwwwwwo",
                             "owwwwwwwwwo",
                             ".ooooooooo."]
        case .star: return ["....o....",
                            "...owo...",
                            "ooowlwooo",
                            ".owwwwwo.",
                            "..owwwo..",
                            ".owwowwo.",
                            ".oo...oo."]
        case .moon: return ["..ooo..",
                            ".owwo..",
                            "owlo...",
                            "owwo...",
                            "owwo...",
                            "owwwo..",
                            ".owwwoo",
                            "..ooo.."]
        case .heart: return [".oo...oo.",
                             "owwo.owwo",
                             "owlwowwwo",
                             "owwwwwwwo",
                             ".owwwwwo.",
                             "..owwwo..",
                             "...owo...",
                             "....o...."]
        case .drop: return ["...o...",
                            "..owo..",
                            "..owo..",
                            ".owwwo.",
                            "owlwwwo",
                            "owlwwwo",
                            "owwwwwo",
                            ".owwwo.",
                            "..ooo.."]
        case .clover: return [".oo...oo.",
                              "owwo.owwo",
                              "owwwowwwo",
                              ".oowwwoo.",
                              ".oowwwoo.",
                              "owwwowwwo",
                              "owwo.owwo",
                              ".oo.o.oo.",
                              "....o...."]
        }
    }

    /// Fill and outline colours.
    private var colors: (fill: NSColor, line: NSColor) {
        switch self {
        case .none, .cloud: return (NSColor(white: 0.97, alpha: 1), NSColor(red: 0.45, green: 0.52, blue: 0.62, alpha: 1))
        case .star: return (NSColor(red: 1, green: 0.84, blue: 0.3, alpha: 1), NSColor(red: 0.7, green: 0.5, blue: 0.1, alpha: 1))
        case .moon: return (NSColor(red: 1, green: 0.93, blue: 0.62, alpha: 1), NSColor(red: 0.62, green: 0.55, blue: 0.3, alpha: 1))
        case .heart: return (NSColor(red: 1, green: 0.55, blue: 0.66, alpha: 1), NSColor(red: 0.7, green: 0.25, blue: 0.36, alpha: 1))
        case .drop: return (NSColor(red: 0.55, green: 0.8, blue: 1, alpha: 1), NSColor(red: 0.2, green: 0.45, blue: 0.7, alpha: 1))
        case .clover: return (NSColor(red: 0.5, green: 0.82, blue: 0.45, alpha: 1), NSColor(red: 0.22, green: 0.5, blue: 0.25, alpha: 1))
        }
    }

    /// The stamp drawn at `pixel` points per stamp pixel, nil for `.none`.
    func image(pixel: CGFloat) -> NSImage? {
        let r = rows
        guard let w = r.first?.count, w > 0 else { return nil }
        let c = colors
        return NSImage(size: CGSize(width: CGFloat(w) * pixel, height: CGFloat(r.count) * pixel), flipped: true) { _ in
            for (y, row) in r.enumerated() {
                for (x, ch) in row.enumerated() {
                    switch ch {
                    case "o": c.line.setFill()
                    case "w": c.fill.setFill()
                    case "l": NSColor.white.setFill()
                    default: continue
                    }
                    CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel).fill()
                }
            }
            return true
        }
    }
}

/// The string's look.
enum Rope: String, Codable, CaseIterable {
    case thread, ribbon, beads, vine, scarf

    var label: String {
        switch self {
        case .thread: return L("실")
        case .ribbon: return L("리본")
        case .beads: return L("구슬줄")
        case .vine: return L("덩굴줄기")
        case .scarf: return L("뜨개 목도리")
        }
    }

    /// How far a wide band ripples sideways (points); 0 = a plain curve.
    var wave: CGFloat {
        switch self {
        case .thread, .ribbon, .beads: return 0
        case .vine: return 2.5
        case .scarf: return 1.8
        }
    }

    /// The darker edge drawn behind the band (덩굴줄기 only); nothing for the others.
    func styleEdge(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.lineWidth = self == .vine ? 7.5 : 0
        layer.strokeColor = self == .vine ? NSColor(red: 0.2, green: 0.36, blue: 0.16, alpha: 0.95).cgColor : nil
    }

    func style(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineCap = .round
        switch self {
        case .thread:
            layer.lineWidth = 1; layer.lineDashPattern = nil
            layer.strokeColor = NSColor(white: 0.25, alpha: 0.8).cgColor
        case .ribbon:
            layer.lineWidth = 3; layer.lineDashPattern = nil
            layer.strokeColor = NSColor(red: 0.95, green: 0.55, blue: 0.62, alpha: 0.95).cgColor
        case .beads:
            layer.lineWidth = 4; layer.lineDashPattern = [0.01, 7]   // round caps on near-empty dashes: beads
            layer.strokeColor = NSColor(red: 0.62, green: 0.5, blue: 0.85, alpha: 0.95).cgColor
        case .vine:
            layer.lineWidth = 5; layer.lineDashPattern = nil; layer.lineJoin = .round
            layer.strokeColor = NSColor(red: 0.45, green: 0.7, blue: 0.32, alpha: 1).cgColor
        case .scarf:
            layer.lineWidth = 7; layer.lineDashPattern = [3, 1.5]; layer.lineCap = .butt; layer.lineJoin = .round   // knit stitches
            layer.strokeColor = NSColor(red: 0.95, green: 0.6, blue: 0.36, alpha: 1).cgColor
        }
    }
}

/// One hanging place. Positions are kept per screen, so a friend stays where it was put.
struct HangSlot: Codable, Equatable {
    /// OriginalCatalog id; nil = the menu bar character (a photo character too).
    var character: String?
    /// A picture in a white frame instead of a character (local file).
    var imagePath: String?
    var charm: Charm
    var rope: Rope
    /// Anchor across its screen, 0...1.
    var x: Double
    /// String rest length in points.
    var length: Double
    /// NSScreenNumber of its screen; nil or a missing screen = the main screen.
    var display: UInt32?
    /// Holds its two strands in both hands (parallel strands, no charm); nil = so when it has no charm.
    var grip: Bool?

    var grips: Bool { grip ?? (charm == .none) }

    static let lengths: ClosedRange<Double> = 30...170

    /// Across its screen and within `lengths`: whatever was saved (or imported), the layers never get inf or NaN.
    var clamped: HangSlot {
        var s = self
        s.x = x.isFinite ? min(1, max(0, x)) : 0.5
        s.length = length.isFinite ? min(Self.lengths.upperBound, max(Self.lengths.lowerBound, length)) : 90
        return s
    }

    static let defaults: [HangSlot] = zip([0.2, 0.36, 0.52, 0.68, 0.84], [90.0, 120, 70, 110, 80]).enumerated().map { i, v in
        HangSlot(character: nil, imagePath: nil, charm: [.star, .cloud, .heart, .moon, .clover][i], rope: .thread, x: v.0, length: v.1, display: nil)
    }

    /// Re-hangs it where it was put down at `p`: across `screen` (its frame), the string from `top` down to `p`.
    mutating func move(to p: CGPoint, top: CGFloat, screen: CGRect, display: UInt32?, sag: CGFloat) {
        guard screen.width > 0 else { return }
        x = min(0.98, max(0.02, Double((p.x - screen.minX) / screen.width)))
        length = min(Self.lengths.upperBound, max(Self.lengths.lowerBound, Double(top - p.y - sag)))
        self.display = display
    }
}

struct HangPrefs: Codable, Equatable {
    var on = false
    var count = 3
    var slots = HangSlot.defaults
    var wind = WindLevel.light
    var sound = true
    var volume = 0.5
    /// Above other windows; off = on the desktop, behind windows.
    var onTop = false
    /// Strings start at the very top edge of the screen and run through the (see-through) menu bar.
    var fromTop = true
    /// A cursor brushing past sets it swinging.
    var pokeOnHover = true
    var feel = StringFeel.taut

    static let maxCount = 5
}

extension HangPrefs {
    /// Settings saved before a field existed keep everything else (a missing key takes its default).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HangPrefs()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? d.count
        slots = (try c.decodeIfPresent([HangSlot].self, forKey: .slots) ?? d.slots).map(\.clamped)
        wind = (try? c.decodeIfPresent(WindLevel.self, forKey: .wind)) ?? d.wind
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound
        volume = try min(1, max(0, c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume))
        onTop = try c.decodeIfPresent(Bool.self, forKey: .onTop) ?? d.onTop
        fromTop = try c.decodeIfPresent(Bool.self, forKey: .fromTop) ?? d.fromTop
        pokeOnHover = try c.decodeIfPresent(Bool.self, forKey: .pokeOnHover) ?? d.pokeOnHover
        feel = (try? c.decodeIfPresent(StringFeel.self, forKey: .feel)) ?? d.feel
    }
}

/// How the strings behave: springy (stretch and bounce) or taut (a fixed radius, a long even swing).
enum StringFeel: String, Codable, CaseIterable {
    case springy, taut

    var label: String {
        switch self {
        case .springy: return L("통통 튀는 줄")
        case .taut: return L("팽팽한 줄")
        }
    }
}

final class HangingStore: ObservableObject {
    static let shared = HangingStore()
    static let key = "hangingFriends"

    private let defaults: UserDefaults
    @Published var prefs: HangPrefs {
        didSet { if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key) } }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        prefs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HangPrefs.self, from: $0) } ?? HangPrefs()
        if prefs.slots.count < HangPrefs.maxCount { prefs.slots += HangSlot.defaults.dropFirst(prefs.slots.count) }
    }
}

// MARK: Wind

/// The wind on all friends: a steady push with random gusts, eased so it never jerks. Pure; feed it the time.
struct Breeze {
    /// Steady push for the level (0 = no wind, nothing moves).
    var push: CGFloat
    private(set) var now: CGFloat = 0
    private var target: CGFloat = 0
    private var gustEnd: TimeInterval = 0
    private var nextGust: TimeInterval?

    init(push: CGFloat) { self.push = push }

    /// Advances to `t` (monotonic seconds); `random` gives 0..<1. Returns what blows now.
    mutating func step(to t: TimeInterval, dt: TimeInterval, random: () -> Double) -> CGFloat {
        guard push > 0 else { now = 0; target = 0; return 0 }
        let next = nextGust ?? t + 1 + random() * 3
        if t >= next {
            target = push * CGFloat(1.6 + random())
            gustEnd = t + 0.8 + random() * 1.4
            nextGust = gustEnd + 3 + random() * 6
        } else {
            nextGust = next
            if t >= gustEnd { target = push }
        }
        now += (target - now) * CGFloat(min(1, dt * 1.5))
        return now
    }

    /// The push on one friend: each has its own `phase`, so they swing out of step.
    func push(at t: TimeInterval, phase: Double) -> CGFloat { now * CGFloat(1 + 0.3 * sin(t * 1.4 + phase)) }
}

// MARK: Friends on strings

/// "대롱대롱 친구" (데스크톱 친구): 1~5 friends hang below the menu bar on springy strings, one see-through panel
/// per screen. Grab and throw them; put one down and hold still to hang it there (across, and how long the string is).
/// A click rings its chime. On the desktop by default (behind windows), or on top. Nothing ticks once they hang still.
final class HangingFriends {
    static let shared = HangingFriends()
    static let pixelSize: CGFloat = 2
    /// Wind speed in m/s where the user is, or nil. Set by a weather source; while nil, 우리 동네 바람 is not offered.
    static var localWind: (() -> Double?)? { didSet { shared.updateWind() } }
    /// Held still this long before letting go: hang it there instead of throwing.
    static let dropHold: TimeInterval = 0.5
    /// QA renders only (DesktopQA): the panels stay see-through (alpha 0), so nothing shows on the developer's screens.
    static var qaHidden = false
    /// QA renders only: the main screen's panel layer with its friends.
    var qaLayer: CALayer? { panels[NSScreen.main.map(Self.displayID) ?? 0]?.contentView?.layer }

    fileprivate final class Friend {
        let slot: Int
        var dangle: Dangle
        var display: UInt32
        var frames: [NSImage] = []
        var hits: [AlphaHit?] = []
        var size = CGSize.zero
        var charmSize = CGSize.zero
        let body = CALayer(), sprite = CALayer(), charm = CALayer(), rope = CAShapeLayer(), edge = CAShapeLayer()
        let phase = Double.random(in: 0..<(2 * .pi))
        var frame = 0, frameClock: TimeInterval = 0
        /// The frame the sprite layer shows now (set its contents only on a change).
        var shown = 0
        /// Carried onto another screen during this drag.
        var carried = false
        /// Holds both strands in its hands (HangSlot.grips).
        var grip = false
        /// The rope's sideways ripple (Rope.wave).
        var wave: CGFloat = 0
        /// The cursor was on it at the last look: a brush past pokes it once per entry.
        var inside = false

        init(slot: Int, dangle: Dangle, display: UInt32) { self.slot = slot; self.dangle = dangle; self.display = display }

        var bodySize: CGSize { CGSize(width: max(size.width, charmSize.width), height: size.height + charmSize.height) }

        /// Whether global point `p` is on the drawing (sprite alpha or the charm).
        func hits(_ p: CGPoint, tilt: Bool) -> Bool {
            let a = tilt ? -dangle.angle : 0
            let dx = p.x - dangle.position.x, dy = p.y - dangle.position.y
            let lx = dx * cos(a) - dy * sin(a), ly = dx * sin(a) + dy * cos(a)   // body space, origin at the attach point
            if abs(lx) <= charmSize.width / 2, ly <= 0, ly >= -charmSize.height { return true }
            let sx = lx + size.width / 2, sy = ly + charmSize.height + size.height
            guard hits.indices.contains(frame), let hit = hits[frame] else { return false }
            return hit.hits(CGPoint(x: sx, y: sy), in: size)
        }
    }

    private var panels: [UInt32: NSPanel] = [:]
    private var friends: [Friend] = []
    private var timer: Timer?
    /// 우리 동네 바람 only: re-reads `localWind` now and then.
    private var windTimer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var started = false
    private var asleep = false
    private var still = DesktopKit.reduceMotion
    private var breeze = Breeze(push: 0)
    private var lastTick = ProcessInfo.processInfo.systemUptime

    private var clicks = ClickRecognizer()
    /// The friend under the last press: the drag and the click go to it.
    private var pressed: Friend?
    /// What the friends were built from: a change elsewhere (sound, wind, 항상 위), or a save of only what is already live,
    /// skips the rebuild.
    private struct Built: Equatable {
        var slots: [HangSlot]
        var look: SpriteLook
        var colors: [String: [String: RGBColor]]
        var outfits: [String: Outfit]   // 옷 입히기 of the friends' own characters
        var screens: [CGRect]
        var fromTop: Bool
        var feel: StringFeel
    }
    private var built: Built?
    private var grabOffset = CGVector.zero
    private var lastMove: TimeInterval = 0
    /// The cursor's speed, for a poke when it brushes past (HangPrefs.pokeOnHover).
    private var motion = CursorMotion()

    private var store: HangingStore { .shared }
    private var enabled: Bool { store.prefs.on && !asleep }

    /// Call once at launch. Follows its switch, the character and the screens on its own.
    func start() {
        guard !started else { return }
        started = true
        HangingStore.shared.objectWillChange
            .merge(with: AppSettings.shared.objectWillChange, CustomCharacterStore.shared.objectWillChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        let nc = NSWorkspace.shared.notificationCenter
        for (name, sleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                              (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            nc.publisher(for: name).sink { [weak self] _ in self?.asleep = sleep; self?.refresh() }.store(in: &bag)
        }
        DesktopKit.displayOptionsChanged
            .sink { [weak self] in self?.motionChanged() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .filter { $0.object is HangPanel }
            .sink { [weak self] _ in self?.wake() }   // uncovered again: swing on
            .store(in: &bag)
        DesktopKit.celebrate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cheer() }
            .store(in: &bag)
        refresh()
    }

    /// 춤춰 줘·응원해 줘: a wave of hops along the row, one friend every 0.12 s.
    private func cheer() {
        guard !still else { return }
        for (i, f) in friends.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(i)) { [weak self] in
                f.dangle.nudge(CGVector(dx: i % 2 == 0 ? 380 : -380, dy: 500))   // taut: only the sideways part swings it
                self?.wake()
            }
        }
    }

    /// Rings slot `i`'s note once (설정's 들어보기).
    static func preview(_ i: Int) { ChimeSound.play(i, volume: HangingStore.shared.prefs.volume) }

    // MARK: Building

    private func refresh() {
        guard enabled else { teardown(); return }
        let prefs = store.prefs
        let level = prefs.onTop ? .floating : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        let now = Built(slots: Array(prefs.slots.prefix(max(1, min(HangPrefs.maxCount, prefs.count)))), look: SpriteLook(AppSettings.shared),
                        colors: AppSettings.shared.characterColors, outfits: AppSettings.shared.outfits,
                        screens: NSScreen.screens.flatMap { [$0.frame, $0.visibleFrame] }, fromTop: prefs.fromTop, feel: prefs.feel)
        if now != built { build(now, level: level) }
        for p in panels.values where p.level != level { p.level = level }
        if prefs.wind != .local { windTimer?.invalidate(); windTimer = nil } else if windTimer == nil {
            windTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.updateWind() }
        }
        updateWind()
        wake()
    }

    private func build(_ now: Built, level: NSWindow.Level) {
        built = now
        pressed = nil
        var keep: [UInt32: NSPanel] = [:]
        for screen in NSScreen.screens {
            let id = Self.displayID(screen)
            let p = panels.removeValue(forKey: id) ?? makePanel()
            p.setFrame(Self.panelFrame(screen), display: false)
            p.level = level
            p.orderFrontRegardless()
            keep[id] = p
        }
        panels.values.forEach { $0.orderOut(nil) }
        panels = keep

        friends.forEach { [$0.body, $0.rope, $0.edge].forEach { $0.removeFromSuperlayer() } }
        friends = now.slots.enumerated().map { makeFriend($0, $1) }
        if monitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.mouseMoved]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.hover() }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.hover(); return e }) { monitors.append(l) }
        }
        friends.forEach(layout)
    }

    /// Re-reads the wind (the level, 동작 줄이기, 우리 동네 바람) without rebuilding anyone.
    private func updateWind() {
        breeze.push = store.prefs.wind.push(still: still, local: Self.localWind?())
        if breeze.push > 0 { wake() }
    }

    /// 동작 줄이기 changed: turned on, everyone hangs at rest at once; turned off, the wind comes back.
    private func motionChanged() {
        still = DesktopKit.reduceMotion
        if still { for f in friends where !f.dangle.held { rest(f); layout(f) } }
        updateWind()
        wake()
    }

    /// Hangs `f` still at its rest point, its longest string kept in its panel.
    private func rest(_ f: Friend) {
        f.dangle = makeDangle(anchor: f.dangle.anchor, rest: f.dangle.restLength)
        fit(f)
    }

    /// A string as 줄 느낌 has it: taut swings longer on a fixed radius.
    private func makeDangle(anchor: CGPoint, rest: CGFloat) -> Dangle {
        var d = Dangle(anchor: anchor, restLength: rest)
        if store.prefs.feel == .taut { d.taut = true; d.damping = 0.6 }
        return d
    }

    /// How many rest lengths the string may stretch so a friend `body` tall stays inside a panel `panel` tall.
    static func maxStretch(panel: CGFloat, body: CGFloat, rest: CGFloat) -> CGFloat {
        max(1.1, min(2.5, (panel - body) / max(1, rest)))
    }

    /// Keeps the longest string inside its panel: after a build, a re-hang (new length) or a move to another screen.
    private func fit(_ f: Friend) {
        guard let h = panels[f.display]?.frame.height else { return }
        f.dangle.maxStretch = Self.maxStretch(panel: h, body: f.bodySize.height, rest: f.dangle.restLength)
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        windTimer?.invalidate(); windTimer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        friends.forEach { [$0.body, $0.rope, $0.edge].forEach { $0.removeFromSuperlayer() } }
        friends = []; pressed = nil; built = nil
        panels.values.forEach { $0.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let p = HangPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        if Self.qaHidden { p.alphaValue = 0 }
        p.ignoresMouseEvents = true   // until the cursor is over a friend (hover)
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        let v = HangView()
        v.owner = self
        v.wantsLayer = true
        p.contentView = v
        // Every strand under every friend: where strings cross in a big swing, none is drawn over a face.
        for name in [Self.ropes, Self.bodies] {
            let c = CALayer()
            c.name = name
            v.layer?.addSublayer(c)
        }
        return p
    }

    private static let ropes = "ropes", bodies = "bodies"

    private func container(_ display: UInt32, _ name: String) -> CALayer? {
        panels[display]?.contentView?.layer?.sublayers?.first { $0.name == name }
    }

    private func makeFriend(_ i: Int, _ slot: HangSlot) -> Friend {
        let main = NSScreen.main ?? NSScreen.screens.first
        let screen = NSScreen.screens.first { Self.displayID($0) == slot.display } ?? main
        let frame = screen?.frame ?? .zero
        let anchor = screen.map { anchorPoint($0, x: frame.minX + frame.width * slot.x) } ?? CGPoint(x: frame.midX, y: frame.maxY)
        let f = Friend(slot: i, dangle: makeDangle(anchor: anchor, rest: slot.length), display: screen.map(Self.displayID) ?? 0)
        f.grip = slot.grips
        f.wave = slot.rope.wave

        var smooth = false
        if let path = slot.imagePath, let picture = NSImage(contentsOfFile: path) {
            f.frames = [Self.framed(picture)]
            smooth = true
        } else {
            let id = slot.character.map { RenderStyle.paired($0, RenderStyle.current, has: RenderStyle.hasOriginal) }   // 그림 스타일's -hd pair
            let pick = id.flatMap(OriginalCatalog.character)
            let cache = pick.map { DogSpriteCache(CharacterColors.apply(slot.character.flatMap { AppSettings.shared.characterColors[$0] }, to: $0), pixelSize: Self.pixelSize) }
                ?? DogSpriteCache(SpriteLook(AppSettings.shared), pixelSize: Self.pixelSize)
            f.frames = cache.frames(for: .walk)
            smooth = cache.smooth
        }
        f.hits = f.frames.map(AlphaHit.init)
        f.size = f.frames.first?.size ?? .zero
        let charm = f.grip ? nil : slot.charm.image(pixel: Self.pixelSize)   // in both hands: nothing between string and friend
        f.charmSize = charm?.size ?? .zero

        let scale = screen?.backingScaleFactor ?? 2
        for l in [f.body, f.sprite, f.charm] { l.contentsScale = scale; l.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull()] }
        f.sprite.magnificationFilter = smooth ? .linear : .nearest
        f.charm.magnificationFilter = .nearest
        f.charm.contents = charm
        f.sprite.contents = f.frames.first
        let b = f.bodySize
        f.body.bounds = CGRect(origin: .zero, size: b)
        f.body.anchorPoint = CGPoint(x: 0.5, y: 1)
        f.charm.frame = CGRect(x: (b.width - f.charmSize.width) / 2, y: f.size.height, width: f.charmSize.width, height: f.charmSize.height)
        f.sprite.frame = CGRect(x: (b.width - f.size.width) / 2, y: 0, width: f.size.width, height: f.size.height)
        f.body.addSublayer(f.sprite)
        f.body.addSublayer(f.charm)
        slot.rope.style(f.rope)
        slot.rope.styleEdge(f.edge)
        for r in [f.rope, f.edge] { r.contentsScale = scale; r.actions = ["path": NSNull()] }
        attach(f)
        fit(f)
        return f
    }

    /// Puts the friend's layers into its screen's panel.
    private func attach(_ f: Friend) {
        guard let ropes = container(f.display, Self.ropes), let bodies = container(f.display, Self.bodies) else { return }
        ropes.addSublayer(f.edge)
        ropes.addSublayer(f.rope)
        bodies.addSublayer(f.body)
    }

    /// A picture in a white instant-photo frame, at most 80 pt across.
    static func framed(_ picture: NSImage) -> NSImage {
        let k = min(1, 80 / max(1, max(picture.size.width, picture.size.height)))
        let inner = CGSize(width: max(8, picture.size.width * k), height: max(8, picture.size.height * k))
        let side: CGFloat = 5, bottom: CGFloat = 15
        let size = CGSize(width: inner.width + side * 2, height: inner.height + side + bottom)
        return NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0, alpha: 0.18).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            NSGraphicsContext.current?.imageInterpolation = .high
            picture.draw(in: CGRect(origin: CGPoint(x: side, y: bottom), size: inner))
            return true
        }
    }

    static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The top half of the screen: from its very top edge (화면 맨 위에서, through the menu bar), or from under the menu bar.
    static func panelFrame(_ screen: NSScreen, fromTop: Bool = HangingStore.shared.prefs.fromTop) -> CGRect {
        let top = fromTop ? screen.frame.maxY : screen.visibleFrame.maxY, h = screen.frame.height * 0.5
        return CGRect(x: screen.frame.minX, y: top - h, width: screen.frame.width, height: h)
    }

    /// Half the gap between a friend's two strands.
    static let strandHalf: CGFloat = 8

    /// Where a string at `x` is tied: the panel's top, kept out of the camera housing when it starts at the screen's edge.
    private func anchorPoint(_ screen: NSScreen, x: CGFloat) -> CGPoint {
        var x = x
        if store.prefs.fromTop, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let gap = (screen.frame.minX + l.width)...(screen.frame.maxX - r.width)
            x = Self.outOfNotch(x: x, half: 40, gap: gap)   // room for a gripping friend's strands
        }
        return CGPoint(x: x, y: Self.panelFrame(screen).maxY)
    }

    /// `x` moved to the nearer side of `gap` (the notch, screen points) when strands `half` either side of it would start
    /// inside it. Pure.
    static func outOfNotch(x: CGFloat, half: CGFloat, gap: ClosedRange<CGFloat>) -> CGFloat {
        let lo = gap.lowerBound - half - 4, hi = gap.upperBound + half + 4
        guard x > lo, x < hi else { return x }
        return x - lo <= hi - x ? lo : hi
    }

    // MARK: Ticking

    private func wake() {
        guard timer == nil, !friends.isEmpty else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        let wind = still ? 0 : breeze.step(to: now, dt: dt) { Double.random(in: 0..<1) }
        var busy = wind != 0
        for f in friends {
            f.dangle.step(dt: dt, wind: breeze.push(at: now, phase: f.phase) * (still ? 0 : 1))
            let moving = f.dangle.held || !f.dangle.isSettled
            busy = busy || moving
            // Legs kick while it swings; it holds its first pose when it hangs still (and under 동작 줄이기).
            let fast = hypot(f.dangle.velocity.dx, f.dangle.velocity.dy) > 40 || f.dangle.held
            f.frameClock += dt
            if !still, fast, f.frames.count > 1, f.frameClock >= 0.12 {
                f.frameClock = 0; f.frame = (f.frame + 1) % f.frames.count
            } else if !fast, f.frame != 0 { f.frame = 0 }
        }
        if !still, bumpNeighbours() { busy = true }
        friends.forEach(layout)
        hover()   // they moved under a still cursor: let the click through where one swung away
        // Hanging still, or every panel covered by windows: 0 fps until a touch, the wind, uncovering or a change.
        if !busy || !panels.values.contains(where: { $0.occlusionState.contains(.visible) }) { timer?.invalidate(); timer = nil }
    }

    /// Friends on one screen knock into each other: two bodies (circles) that overlap are pushed apart by half the
    /// overlap each, and trade their speed along the line between them at half strength. Strings pass through freely.
    /// Returns whether any touched. ponytail: O(n^2) over at most 5 friends; a grid if there are ever many more.
    private func bumpNeighbours() -> Bool {
        var touched = false
        for i in friends.indices {
            for j in friends.indices where j > i {
                let a = friends[i], b = friends[j]
                guard a.display == b.display, !a.dangle.held, !b.dangle.held else { continue }
                let ra = min(a.size.width, a.size.height) / 2, rb = min(b.size.width, b.size.height) / 2
                let ca = CGPoint(x: a.dangle.position.x, y: a.dangle.position.y - a.bodySize.height / 2)
                let cb = CGPoint(x: b.dangle.position.x, y: b.dangle.position.y - b.bodySize.height / 2)
                let dx = cb.x - ca.x, dy = cb.y - ca.y, d = hypot(dx, dy)
                let va = a.dangle.velocity, vb = b.dangle.velocity
                // Two hung close together and still stay as they are: no endless nudging, the timer can stop.
                guard d < ra + rb, d > 0.001, hypot(va.dx, va.dy) + hypot(vb.dx, vb.dy) > 30 else { continue }
                let nx = dx / d, ny = dy / d, push = (ra + rb - d) / 2
                let an = va.dx * nx + va.dy * ny, bn = vb.dx * nx + vb.dy * ny
                guard an - bn > 0 else {   // already parting: only untangle
                    a.dangle.bump(by: CGVector(dx: -nx * push, dy: -ny * push), velocity: va)
                    b.dangle.bump(by: CGVector(dx: nx * push, dy: ny * push), velocity: vb)
                    continue
                }
                touched = true
                a.dangle.bump(by: CGVector(dx: -nx * push, dy: -ny * push),
                              velocity: CGVector(dx: va.dx + (bn * 0.5 - an) * nx, dy: va.dy + (bn * 0.5 - an) * ny))
                b.dangle.bump(by: CGVector(dx: nx * push, dy: ny * push),
                              velocity: CGVector(dx: vb.dx + (an * 0.5 - bn) * nx, dy: vb.dy + (an * 0.5 - bn) * ny))
                if an - bn > 600, store.prefs.sound { ChimeSound.play(a.slot + b.slot, volume: store.prefs.volume * 0.4) }   // a soft clink
            }
        }
        return touched
    }

    private func layout(_ f: Friend) {
        guard let origin = panels[f.display]?.frame.origin else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let d = f.dangle
        let bob = CGPoint(x: d.position.x - origin.x, y: d.position.y - origin.y)
        let top = CGPoint(x: d.anchor.x - origin.x, y: d.anchor.y - origin.y)
        let a = still ? 0 : d.angle
        f.body.position = bob
        f.body.setAffineTransform(CGAffineTransform(rotationAngle: a))
        if f.shown != f.frame, f.frames.indices.contains(f.frame) { f.sprite.contents = f.frames[f.frame]; f.shown = f.frame }
        // Two strands: in both hands (parallel, a body width apart, to the hand points), or from either side of the
        // anchor to the top corners of the charm (or the friend).
        let path = CGMutablePath()
        let slack = d.taut ? 0 : max(0, 1 - d.stretch) * d.restLength * 0.6   // a short springy string sags
        let grip = f.size.width * 0.42, hand = -f.size.height * 0.35
        let half = max(4, (f.charmSize.width > 0 ? f.charmSize.width : f.size.width * 0.5) / 2 - 2)
        let t = ProcessInfo.processInfo.systemUptime, speed = hypot(d.velocity.dx, d.velocity.dy)
        for s: CGFloat in [-1, 1] {
            let from = CGPoint(x: top.x + s * (f.grip ? grip : Self.strandHalf), y: top.y)
            let (hx, hy) = f.grip ? (s * grip, hand) : (s * half, 0)
            let to = CGPoint(x: bob.x + hx * cos(a) - hy * sin(a), y: bob.y + hx * sin(a) + hy * cos(a))
            let control = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - slack)
            path.move(to: from)
            guard f.wave > 0 else { path.addQuadCurve(to: to, control: control); continue }
            // A wide band: ten segments that ripple sideways, still at both ends, more while it swings fast.
            let amp = f.wave * (1 + min(2, speed / 400)), len = max(1, hypot(to.x - from.x, to.y - from.y))
            let nx = -(to.y - from.y) / len, ny = (to.x - from.x) / len
            for k in 1...10 {
                let u = CGFloat(k) / 10, v = 1 - u
                let px = v * v * from.x + 2 * v * u * control.x + u * u * to.x
                let py = v * v * from.y + 2 * v * u * control.y + u * u * to.y
                let off = CGFloat(sin(Double(u) * 9 + f.phase * s + t * 3)) * amp * sin(.pi * u)
                path.addLine(to: CGPoint(x: px + nx * off, y: py + ny * off))
            }
        }
        f.rope.path = path
        f.edge.path = path
        CATransaction.commit()
    }

    // MARK: Mouse

    /// Lets the mouse through everywhere but over a friend.
    private func hover() {
        guard !friends.contains(where: { $0.dangle.held }) else { return }
        let p = NSEvent.mouseLocation
        motion.feed(p, at: ProcessInfo.processInfo.systemUptime)
        // Brushed past: a push the way the cursor went, once each time it comes onto a friend. A slow pass barely moves it.
        let poke = store.prefs.pokeOnHover && !still
        for f in friends {
            let inside = f.hits(p, tilt: !still)
            if inside, !f.inside, poke, motion.speed > 150 {
                f.dangle.nudge(CGVector(dx: motion.velocity.dx * 0.6, dy: motion.velocity.dy * 0.6))
                if motion.speed > 1200, store.prefs.sound { ChimeSound.play(f.slot, volume: store.prefs.volume * 0.6) }
                wake()
            }
            f.inside = inside
        }
        for (id, panel) in panels {
            let over = panel.frame.contains(p) && friends.contains { $0.display == id && $0.hits(p, tilt: !still) }
            if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        }
    }

    fileprivate func mouseDown() {
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        handle(clicks.mouseDown(p, at: t))
        pressed = friends.last { $0.hits(p, tilt: !still) }
        if let f = pressed { grabOffset = CGVector(dx: f.dangle.position.x - p.x, dy: f.dangle.position.y - p.y) }
    }

    fileprivate func mouseDragged() {
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        lastMove = t
        handle(clicks.mouseMoved(p, at: t))
    }

    fileprivate func mouseUp() {
        let p = NSEvent.mouseLocation
        var g = clicks.mouseUp(p, at: ProcessInfo.processInfo.systemUptime)
        // A click rings at once: there is no double-click action to wait for.
        if clicks.pollAt != nil { clicks = ClickRecognizer(); g = [.single(p)] }
        handle(g)
    }

    /// Right click or control click on a friend. The menu swallows the button's release: a friend in the hand is let
    /// go first and the press ends, so it never stays held (held, the panel would keep eating clicks).
    fileprivate func showMenu(_ e: NSEvent, in view: NSView) {
        handle(clicks.cancel(at: NSEvent.mouseLocation))
        pressed = nil
        let prefs = store.prefs
        FriendMenu.pop([
            FriendMenu.submenu(L("바람"), WindLevel.allCases.map { w in
                FriendMenu.item(w.label, on: prefs.wind == w) { HangingStore.shared.prefs.wind = w }
            }),
            FriendMenu.item(L("풍경 소리"), on: prefs.sound) { HangingStore.shared.prefs.sound.toggle() },
            FriendMenu.item(L("다른 창보다 위에 두기"), on: prefs.onTop) { HangingStore.shared.prefs.onTop.toggle() },
            FriendMenu.item(L("대롱대롱 친구 치우기")) { HangingStore.shared.prefs.on = false },
        ], with: e, for: view)
        hover()
    }

    private func handle(_ gestures: [ClickRecognizer.Gesture]) {
        guard let f = pressed else { return }
        for g in gestures {
            switch g {
            case .dragBegan:
                f.carried = false
                f.dangle.grab(at: f.dangle.position)
            case .dragged(let p):
                carry(f, to: p)
                f.dangle.drag(to: CGPoint(x: p.x + grabOffset.dx, y: p.y + grabOffset.dy))
                layout(f)
            case .dragEnded(let p, let v):
                let dropped = ProcessInfo.processInfo.systemUptime - lastMove >= Self.dropHold
                f.dangle.release(velocity: still || dropped ? .zero : v)
                // Only a put-down or a carry to another screen saves a place: a saved screen that is unplugged stays saved.
                if dropped || f.carried { rehang(f, dropAt: dropped ? CGPoint(x: p.x + grabOffset.dx, y: p.y + grabOffset.dy) : nil) }
                if !dropped, hypot(v.dx, v.dy) > 1800 { ring(f) }
                if still { rest(f) }   // no swing: hang at once
                wake()
            case .single, .double:
                ring(f)
                if !still { f.dangle.release(velocity: CGVector(dx: f.phase > .pi ? 260 : -260, dy: 120)) }
                wake()
            }
        }
    }

    /// Dragged onto another screen: the friend moves to that screen's panel, its anchor to that screen's top.
    private func carry(_ f: Friend, to p: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        let id = Self.displayID(screen)
        guard id != f.display, panels[id] != nil else { return }
        f.display = id
        f.carried = true
        f.dangle.anchor = anchorPoint(screen, x: p.x)
        fit(f)
        [f.body, f.rope, f.edge].forEach { $0.removeFromSuperlayer() }
        attach(f)
    }

    /// Remembers where it hangs now: put down at `dropAt` (across, and the string down to there), or its anchor after a
    /// throw onto another screen.
    private func rehang(_ f: Friend, dropAt: CGPoint?) {
        guard let screen = NSScreen.screens.first(where: { Self.displayID($0) == f.display }) else { return }
        var slot = store.prefs.slots[f.slot]
        let top = Self.panelFrame(screen).maxY
        let at = dropAt ?? CGPoint(x: f.dangle.anchor.x, y: top - CGFloat(slot.length) - f.dangle.gravity / f.dangle.stiffness)
        slot.move(to: at, top: top, screen: screen.frame, display: f.display, sag: f.dangle.gravity / f.dangle.stiffness)
        f.dangle.anchor = anchorPoint(screen, x: screen.frame.minX + screen.frame.width * CGFloat(slot.x))
        f.dangle.restLength = CGFloat(slot.length)
        fit(f)
        built?.slots[f.slot] = slot   // the live friend already hangs there: no rebuild for this save
        store.prefs.slots[f.slot] = slot
    }

    private func ring(_ f: Friend) {
        let prefs = store.prefs
        if prefs.sound { ChimeSound.play(f.slot, volume: prefs.volume) }
        guard !still, let root = panels[f.display]?.contentView?.layer else { return }
        let p = f.body.position
        sparkle(at: CGPoint(x: p.x, y: p.y - f.charmSize.height / 2), in: root)
    }

    /// A short puff of tiny stars around the charm.
    private func sparkle(at p: CGPoint, in root: CALayer) {
        let e = CAEmitterLayer()
        e.emitterPosition = p
        e.emitterShape = .point
        let c = CAEmitterCell()
        c.contents = Self.sparkImage
        c.birthRate = 60
        c.lifetime = 0.7
        c.velocity = 70
        c.velocityRange = 30
        c.emissionRange = 2 * .pi
        c.scaleSpeed = -1.2
        c.alphaSpeed = -1.3
        c.color = NSColor(red: 1, green: 0.95, blue: 0.6, alpha: 1).cgColor
        e.emitterCells = [c]
        root.addSublayer(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { e.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { e.removeFromSuperlayer() }
    }

    private static let sparkImage: CGImage? = {
        let img = NSImage(size: CGSize(width: 6, height: 6), flipped: false) { r in
            NSColor.white.setFill()
            CGRect(x: 2, y: 0, width: 2, height: 6).fill()
            CGRect(x: 0, y: 2, width: 6, height: 2).fill()
            return true
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
}

/// Never key, never main: touching a friend never takes the focus from the app in front.
private final class HangPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HangView: NSView {
    weak var owner: HangingFriends?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { owner?.showMenu(event, in: self) } else { owner?.mouseDown() }
    }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp() }
    override func rightMouseDown(with event: NSEvent) { owner?.showMenu(event, in: self) }
}
