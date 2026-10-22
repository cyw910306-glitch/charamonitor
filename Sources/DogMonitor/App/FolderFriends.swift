import AppKit
import Combine
import QuartzCore

// MARK: Settings

extension BuddySize: Codable {}

struct FolderPrefs: Codable, Equatable {
    var on = false
    var size = BuddySize.medium
    /// One friend on each open Finder window (up to `maxWindows`); off = only on the frontmost one.
    var everyWindow = false
    /// How the character is on the desktop folders' icons.
    var iconStyle = FolderIconStyle.stand

    static let maxWindows = 3
}

extension FolderPrefs {
    /// Settings saved before a field existed (or a size this build does not know) keep everything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FolderPrefs()
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? d.on
        size = (try? c.decodeIfPresent(String.self, forKey: .size)).flatMap { $0.flatMap(BuddySize.init(rawValue:)) } ?? d.size
        everyWindow = (try? c.decodeIfPresent(Bool.self, forKey: .everyWindow)) ?? d.everyWindow
        iconStyle = (try? c.decodeIfPresent(String.self, forKey: .iconStyle)).flatMap { $0.flatMap(FolderIconStyle.init(rawValue:)) } ?? d.iconStyle
    }
}

final class FolderStore: ObservableObject {
    static let shared = FolderStore()
    static let key = "folderFriends"

    private let defaults: UserDefaults
    @Published var prefs: FolderPrefs {
        didSet { if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key) } }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        prefs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(FolderPrefs.self, from: $0) } ?? FolderPrefs()
    }
}

// MARK: Finder windows (pure)

/// One entry of the window list, in screen points with y up (like NSWindow frames).
struct ListedWindow: Equatable {
    var id: Int
    var pid: pid_t
    var layer: Int
    var frame: CGRect
    var alpha: Double = 1

    /// A CGWindowListCopyWindowInfo entry. Number, owner, layer, bounds and alpha only: none of them needs Screen
    /// Recording (window names would). `primaryHeight`: the menu bar screen's height (the list's y runs down from its top).
    init?(_ info: [String: Any], primaryHeight: CGFloat) {
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        self.init(id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                  frame: CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height),
                  alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }

    init(id: Int, pid: pid_t, layer: Int = 0, frame: CGRect, alpha: Double = 1) {
        self.id = id; self.pid = pid; self.layer = layer; self.frame = frame; self.alpha = alpha
    }
}

/// Where a 폴더 친구 sits and when it hides. Pure; FolderFriends feeds it the window list.
enum FolderPerch {
    static let finder = "com.apple.finder"
    /// Smaller than this is a sheet, a progress window, a helper or a 정보 가져오기 window (265 pt wide), not a folder window.
    static let minSize = CGSize(width: 280, height: 120)

    /// Finder's own windows, front first: the normal layer, shown, big enough. The desktop is not one of them (it is
    /// below layer 0, and the list is asked without desktop elements).
    static func finderWindows(_ list: [ListedWindow], finder: Set<pid_t>) -> [ListedWindow] {
        list.filter { finder.contains($0.pid) && $0.layer == 0 && $0.alpha > 0
            && $0.frame.width >= minSize.width && $0.frame.height >= minSize.height }
    }

    /// The windows that get a friend: the frontmost, or with `every` each of the front `cap`.
    static func chosen(_ windows: [ListedWindow], every: Bool, cap: Int = FolderPrefs.maxWindows) -> [ListedWindow] {
        Array(windows.prefix(every ? max(1, cap) : 1))
    }

    /// How deep a nap drapes it over the edge, as a share of its height. Standing or walking, the feet are on the edge.
    static let nap: CGFloat = 0.08

    /// How far the panel's bottom is under the window's top edge: the deepest the feet go (a nap). Whole points, as
    /// AppKit keeps window frames: a fractional one never matches its own frame again.
    static func edge(_ height: CGFloat) -> CGFloat { (height * nap).rounded() }

    /// How deep its feet are under the edge: napping `edge`, otherwise just on it.
    static func sink(_ height: CGFloat, napping: Bool) -> CGFloat { napping ? edge(height) : min(2, edge(height)) }

    /// The friend's panel on `window`: as wide as the window, its bottom `edge` under the top edge, room above for a hop
    /// and a mark; whole points. nil when there is no room: the window is not half again as wide as the friend, or its
    /// top middle is on no screen (`screens`: visible frames) with room for the friend under the menu bar.
    static func panelFrame(on window: CGRect, size: CGSize, screens: [CGRect]) -> CGRect? {
        guard size.width > 0, size.height > 0, window.width >= size.width * 1.5 else { return nil }
        let top = CGPoint(x: window.midX, y: window.maxY - 1)
        // ponytail: a window against the menu bar (zoomed, tiled) gets no friend; sitting inside its title bar would
        // cover the toolbar's buttons.
        guard let screen = screens.first(where: { $0.contains(top) }), window.maxY + size.height <= screen.maxY + 1 else { return nil }
        let e = edge(size.height)
        return CGRect(x: window.minX, y: window.maxY - e, width: window.width, height: e + (size.height * 2.2).rounded() + 40).integral
    }

    /// Its middle kept over the edge of a window `width` wide: clear of the traffic lights on the left, in from the
    /// rounded corner on the right.
    static func clampX(_ x: CGFloat, width: CGFloat, size: CGSize) -> CGFloat {
        let lo = max(size.width / 2 + 6, 84), hi = width - size.width / 2 - 18
        return hi < lo ? width / 2 : min(max(x, lo), hi)
    }

    /// A normal window in front of `window` (another app's or Finder's own) over the friend's `rect`: it would draw
    /// over the friend, so the friend hides. `list` front first; our own windows (`me`) never count. A window that is
    /// gone from the list counts as covered.
    static func covered(_ rect: CGRect, behind window: ListedWindow, in list: [ListedWindow], me: pid_t) -> Bool {
        guard let i = list.firstIndex(where: { $0.id == window.id }) else { return true }
        // ponytail: only layer 0 counts; floating panels and other high layers are drawn over the friend instead.
        return list[..<i].contains { $0.pid != me && $0.layer == 0 && $0.alpha > 0 && $0.frame.intersects(rect) }
    }

    /// How often to read the window list: nil = not at all (no Finder window out and Finder not in front: an app
    /// switch or a Space change wakes it), every frame while the button is down (a window may be dragged) and for 0.6 s
    /// after a window moved or the button came up (zooming and tiling animate after the click), else every second.
    static func pollEvery(windows: Bool, finderFront: Bool, dragging: Bool, sinceMove: TimeInterval) -> TimeInterval? {
        // ponytail: a look a second while any Finder window is out (about a millisecond each); being told of moves
        // instead would need Accessibility (AXObserver), which this friend never asks for.
        guard windows || finderFront else { return nil }
        if windows && (dragging || sinceMove < 0.6) { return 1.0 / 60 }
        return 1
    }
}

// MARK: Friends on folder windows

/// "폴더 친구" (데스크톱 친구): the menu bar character sits on the top edge of the front Finder window (or of each, up to
/// three), like a cat on a box: it stands on the edge with a little bounce, naps, looks around, walks along the edge now and
/// then, and goes with the window when it is dragged. A closed or minimised window: it hops off. It hides while another
/// window covers it or there is no room under the menu bar. Only the window list's bounds, layer and owner are read, so
/// no permission is asked for. A click is a MeadowReaction with a line, ⌥ click 퀵물어보기, a right click its menu.
/// Nothing ticks while no Finder window is out; a second's look otherwise, every frame only while a window moves.
/// Under 동작 줄이기 it sits still and snaps along.
final class FolderFriends {
    static let shared = FolderFriends()
    /// QA renders only: panels stay see-through.
    static var qaHidden = false

    fileprivate final class Friend {
        var window: ListedWindow
        var panel: FolderPanel?
        /// The panel's content (QA: a stand-in layer): the drawing's coordinates are its own.
        let host: CALayer
        let layer = CALayer()
        /// x: the drawing's middle from the window's left edge; y: how high a hop has it.
        var walk: MeadowWalk
        var frames: [BuddyGait: [NSImage]] = [:]
        var says: [BuddyGait: [String]] = [:]
        var size = CGSize.zero
        /// How deep its feet are under the edge now (eases between standing and a nap).
        var sink: CGFloat = 0
        /// Leaning back against the way its window is dragged (-1 left, 1 right) until `until`.
        var lean: (dir: CGFloat, until: TimeInterval) = (0, 0)
        let phase = Double.random(in: 0..<(2 * .pi))
        var frame = 0, clock: TimeInterval = 0
        var think: TimeInterval = 0, sitUntil: TimeInterval = 0, lookUntil: TimeInterval = 0, turnAt: TimeInterval = 0
        var facingLeft = false
        var react: (r: MeadowReaction, start: TimeInterval)?
        var combo = ClickCombo()
        var shown: NSImage?
        var leaving: TimeInterval?
        var hidden = false

        init(window: ListedWindow, host: CALayer, x: CGFloat) { self.window = window; self.host = host; walk = MeadowWalk(x: x) }

        func has(_ g: BuddyGait) -> Bool { !(frames[g] ?? []).isEmpty }
        var gait: BuddyGait {
            if let r = react?.r { return has(r.gait) ? r.gait : .stand }
            if walk.state == .walk || walk.airborne || leaving != nil { return .walk }
            return walk.state == .sit && has(.sleep) ? .sleep : .stand
        }
        var napping: Bool { gait == .sleep && react == nil }
        var moving: Bool { walk.state == .walk || walk.airborne || leaving != nil }
        func lift(_ now: TimeInterval, still: Bool) -> CGFloat {
            react.map { $0.r.reaction.pose(now - $0.start, still: still).lift * size.height } ?? 0
        }
    }

    private var friends: [Friend] = []
    private var hits: [ObjectIdentifier: AlphaHit] = [:]
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var bag: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var started = false
    private var asleep = false
    private var still = DesktopKit.reduceMotion
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastPoll: TimeInterval = -10
    private var lastMove: TimeInterval = -10
    private var lastRelease: TimeInterval = -10
    private var windowsOut = false
    /// Kept from app activations: asking NSWorkspace every frame is a LaunchServices round trip.
    private var finderFront = false
    /// Windows that had a friend: one coming back (another Space, uncovered) is not hopped onto again.
    private var seen: Set<Int> = []
    private var clicks = ClickRecognizer()
    private var pressed: Friend?
    private var talkAfter: TimeInterval = 0

    private struct Built: Equatable {
        var look: SpriteLook
        var colors: [String: [String: RGBColor]]
        var size: BuddySize
    }
    private var built: Built?
    /// QA renders only: an original's id drawn instead of the menu bar character.
    private var qaCharacter: String?
    private var sprites: (frames: [BuddyGait: [NSImage]], says: [BuddyGait: [String]], size: CGSize, smooth: Bool)?

    private var store: FolderStore { .shared }
    private var enabled: Bool { store.prefs.on && !asleep }
    private static let me = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard !started else { return }
        started = true
        FolderStore.shared.objectWillChange
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
        // Finder windows come and go with app switches, hides and Spaces: look again then, with no timer meanwhile.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            nc.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] n in
                guard let self else { return }
                if n.name == NSWorkspace.didActivateApplicationNotification {
                    finderFront = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == FolderPerch.finder
                }
                // Another Space: the panels stay on the old one, so they go at once and come back (no hop) where the
                // windows are.
                if n.name == NSWorkspace.activeSpaceDidChangeNotification { friends.forEach(remove); friends = [] }
                poke()
            }.store(in: &bag)
        }
        DesktopKit.displayOptionsChanged
            .sink { [weak self] in self?.still = DesktopKit.reduceMotion; self?.poke() }
            .store(in: &bag)
        DesktopKit.celebrate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cheer() }
            .store(in: &bag)
        refresh()
    }

    private func head(of f: Friend) -> CGPoint? {
        guard let p = f.panel, p.isVisible, !f.hidden else { return nil }
        return CGPoint(x: p.frame.minX + f.layer.position.x, y: p.frame.minY + f.layer.position.y + f.size.height)
    }

    private func cheer() {
        for (i, f) in friends.enumerated() where f.leaving == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(i)) { [weak self] in
                guard let self else { return }
                if self.still { self.pop("♥", .systemPink, over: f) } else { f.walk.state = .idle; f.walk.hop(); self.wake() }
            }
        }
    }

    // MARK: Building

    private func refresh() {
        guard enabled else { teardown(); return }
        let now = Built(look: SpriteLook(AppSettings.shared), colors: AppSettings.shared.characterColors, size: store.prefs.size)
        if now != built { build(now) }
        finderFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FolderPerch.finder
        if monitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.global(e) }) { monitors.append(g) }
        }
        poke()
    }

    /// The menu bar character's sprites at the chosen size, for every friend.
    private func build(_ now: Built) {
        built = now
        let c = MeadowFriends.cache(character: qaCharacter, pixelSize: now.size.pixelSize)
        sprites = (BuddyGait.frames(c).filter { !$0.value.isEmpty },
                   [.special: c.lines(forExtra: .special, variant: 0), .eat: c.lines(forExtra: .eat, variant: 0)].filter { !$0.value.isEmpty },
                   c.imageSize, c.smooth)
        hits = [:]
        for f in friends { dress(f) }
    }

    private func teardown() {
        timer?.invalidate(); timer = nil; interval = 0
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        friends.forEach(remove)
        friends = []; pressed = nil; built = nil; sprites = nil; windowsOut = false
    }

    private func remove(_ f: Friend) {
        f.layer.removeFromSuperlayer()
        f.panel?.orderOut(nil)
        if pressed === f { pressed = nil }
    }

    private func makePanel() -> FolderPanel {
        let p = FolderPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        if Self.qaHidden { p.alphaValue = 0 }
        p.ignoresMouseEvents = true   // until the cursor is over the friend (hover)
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        // The normal level, ordered just above its Finder window: windows in front of that one cover it, like the window.
        p.level = .normal
        // Transient: not its own window in Mission Control (it goes and comes back on a Space change anyway).
        p.collectionBehavior = [.ignoresCycle, .fullScreenNone, .transient]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        let v = FolderView(frame: .zero)
        v.owner = self
        v.wantsLayer = true
        p.contentView = v
        return p
    }

    /// `f`'s frames, size and layer from the sprites built now.
    private func dress(_ f: Friend) {
        guard let s = sprites else { return }
        f.frames = s.frames
        f.says = s.says
        f.size = s.size
        f.shown = nil
        f.layer.contentsScale = f.panel?.backingScaleFactor ?? 2
        f.layer.magnificationFilter = s.smooth ? .linear : .nearest
        f.layer.bounds = CGRect(origin: .zero, size: s.size)
        f.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        f.layer.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull(), "bounds": NSNull(), "opacity": NSNull(),
                           "contentsScale": NSNull()]
        f.walk.x = FolderPerch.clampX(f.walk.x, width: f.window.frame.width, size: s.size)
    }

    /// A friend for `w` at `share` of its width (where the one leaving sat, or anywhere in the middle). It fades in, and
    /// hops on unless it sat there before (a window back from another Space or clicked again).
    private func arrive(_ w: ListedWindow, now: TimeInterval, share: CGFloat?) -> Friend {
        let p = makePanel()
        let host = p.contentView?.layer ?? CALayer()
        let f = Friend(window: w, host: host, x: w.frame.width * (share ?? .random(in: 0.3...0.7)))
        f.panel = p
        dress(f)
        host.addSublayer(f.layer)
        f.think = now + .random(in: 3...7)
        if !still { f.layer.opacity = 0 }
        if !seen.contains(w.id), !still { f.walk.drop(from: 60) }
        seen.insert(w.id)
        return f
    }

    /// The window closed, minimised or no longer the front one: it hops up and away (gone at once under 동작 줄이기).
    private func leave(_ f: Friend, now: TimeInterval) {
        guard f.leaving == nil else { return }
        if still || f.hidden || f.panel?.isVisible != true { remove(f); friends.removeAll { $0 === f }; return }
        f.leaving = now
        f.react = nil
        f.walk = MeadowWalk(x: f.walk.x)
        f.walk.hop()
        if pressed === f { pressed = nil }
    }

    // MARK: Watching the windows

    /// Look at the windows now and tick from here.
    private func poke() {
        guard enabled, sprites != nil else { return }
        poll(now: ProcessInfo.processInfo.systemUptime)
        schedule(1.0 / 30)
    }

    private func global(_ e: NSEvent) {
        // A press may start a window drag: look every frame until the tick sees the button up, and a little after (a
        // double-click zooms, a drop on the screen edge tiles, both animated after the button is up).
        switch e.type {
        case .leftMouseDown: if windowsOut { schedule(1.0 / 60) }
        case .leftMouseUp: lastRelease = ProcessInfo.processInfo.systemUptime; if windowsOut { schedule(1.0 / 60) }
        default: hover()
        }
    }

    private func poll(now: TimeInterval) {
        lastPoll = now
        let finder = Set(NSRunningApplication.runningApplications(withBundleIdentifier: FolderPerch.finder).map(\.processIdentifier))
        var list: [ListedWindow] = []
        if !finder.isEmpty, let primary = NSScreen.screens.first?.frame.height,
           let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            list = raw.compactMap { ListedWindow($0, primaryHeight: primary) }
        }
        let windows = FolderPerch.finderWindows(list, finder: finder)
        windowsOut = !windows.isEmpty
        let chosen = FolderPerch.chosen(windows, every: store.prefs.everyWindow)
        // One that hops off a window another comes onto (a click on another Finder window) hands over its place.
        var shares: [CGFloat] = []
        for f in friends where f.leaving == nil && !chosen.contains(where: { $0.id == f.window.id }) {
            if f.window.frame.width > 0 { shares.append(f.walk.x / f.window.frame.width) }
            leave(f, now: now)
        }
        for w in chosen {
            if let f = friends.first(where: { $0.window.id == w.id && $0.leaving == nil }) {
                if f.window.frame != w.frame {
                    lastMove = now
                    let dx = w.frame.minX - f.window.frame.minX   // moved, not resized: it holds on, leaning back
                    if dx != 0, w.frame.size == f.window.frame.size, !still { f.lean = (dx > 0 ? 1 : -1, now + 0.15) }
                }
                f.window = w
            } else {
                friends.append(arrive(w, now: now, share: shares.popLast()))
            }
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        for f in friends where f.leaving == nil {
            guard let target = FolderPerch.panelFrame(on: f.window.frame, size: f.size, screens: screens), let p = f.panel else { hide(f, true); continue }
            let feet = CGPoint(x: target.minX + f.walk.x, y: f.window.frame.maxY)
            let rect = CGRect(x: feet.x - f.size.width / 2, y: target.minY, width: f.size.width, height: f.size.height * 1.2)
            if FolderPerch.covered(rect, behind: f.window, in: list, me: Self.me) { hide(f, true); continue }
            // Goes with its window as one: polled every frame while the window moves, set straight to it.
            if p.frame != target || !p.isVisible { p.setFrame(target, display: false) }
            // Sharp on whichever screen it is on now (one at 1x, another at 2x).
            if f.layer.contentsScale != p.backingScaleFactor { f.layer.contentsScale = p.backingScaleFactor; f.shown = nil }
            hide(f, false)
            // Just above its Finder window; again whenever that window came in front of it (clicked, dragged).
            let mine = list.firstIndex { $0.id == p.windowNumber }, theirs = list.firstIndex { $0.id == f.window.id }
            if mine == nil || theirs.map({ mine! > $0 }) == true {
                p.orderFrontRegardless()
                p.order(.above, relativeTo: f.window.id)
            }
        }
    }

    /// Hides (fading out, then off the screen) or shows (fading in) `f`'s panel; at once under 동작 줄이기.
    private func hide(_ f: Friend, _ hidden: Bool) {
        guard hidden != f.hidden, let p = f.panel else { return }
        f.hidden = hidden
        if hidden, pressed === f { pressed = nil }
        let to: CGFloat = hidden || Self.qaHidden ? 0 : 1
        if still || hidden && !p.isVisible { p.alphaValue = to; if hidden { p.orderOut(nil) }; return }
        if !p.isVisible { p.alphaValue = 0 }   // shown again: poll orders it in right after, from clear
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.15; p.animator().alphaValue = to }) { [weak f, weak p] in
            if f?.hidden == true { p?.orderOut(nil) }
        }
    }

    // MARK: Ticking

    private func wake() { schedule(1.0 / 30) }

    private func schedule(_ every: TimeInterval) {
        guard enabled, every != interval else { return }
        timer?.invalidate()
        interval = every
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = every * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTick = ProcessInfo.processInfo.systemUptime
    }

    private func stopTimer() { timer?.invalidate(); timer = nil; interval = 0 }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        // ponytail: any press with a Finder window out polls every frame (a ⌘-drag moves a window behind without making
        // Finder frontmost); a press elsewhere costs a millisecond a frame while it is held.
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        let pollEvery = FolderPerch.pollEvery(windows: windowsOut, finderFront: finderFront, dragging: dragging,
                                              sinceMove: now - max(lastMove, lastRelease))
        if let every = pollEvery, now - lastPoll >= every * 0.9 { poll(now: now) }
        var busy = false, idleFrames = false
        for f in friends {
            if let r = f.react, now - r.start >= r.r.duration { f.react = nil }
            if let gone = f.leaving {
                f.walk.step(dt: dt)
                f.layer.opacity = Float(max(0, 1 - (now - gone) / 0.4))
                if now - gone >= 0.4 { remove(f); f.leaving = .infinity }
                busy = true
                layout(f, now: now)
                continue
            }
            if f.hidden { continue }
            if !still, f.react == nil { think(f, now: now) }
            f.walk.step(dt: dt)
            if f.walk.state == .sit, now >= f.sitUntil { f.walk.state = .idle }
            if f.walk.vx < -1 { f.facingLeft = true } else if f.walk.vx > 1 { f.facingLeft = false }
            if now < f.lookUntil, now >= f.turnAt { f.facingLeft.toggle(); f.turnAt = now + 0.8 }
            // A window made narrower mid-walk: the walk ends at the new corner instead of pushing at it forever.
            f.walk.x = FolderPerch.clampX(f.walk.x, width: f.window.frame.width, size: f.size)
            f.walk.target = FolderPerch.clampX(f.walk.target, width: f.window.frame.width, size: f.size)
            if f.layer.opacity < 1 { f.layer.opacity = still ? 1 : min(1, f.layer.opacity + Float(dt / 0.25)) }
            let want = FolderPerch.sink(f.size.height, napping: f.napping)
            f.sink = still || abs(want - f.sink) < 0.3 ? want : f.sink + (want - f.sink) * CGFloat(min(1, dt * 8))
            f.clock += dt
            let per: TimeInterval = switch f.gait {
            case .walk: 0.12
            case .eat: DogSpriteCache.extraFrameDuration(.eat)
            case .special: DogSpriteCache.extraFrameDuration(.special)
            case .sulk: DogSpriteCache.extraFrameDuration(.hungry)
            case .dizzy: 0.12
            default: 0.5
            }
            if !still, f.clock >= per { f.clock = 0; f.frame += 1 }
            layout(f, now: now)
            busy = busy || f.moving || f.react != nil && !still || abs(want - f.sink) > 0.3 || f.layer.opacity < 1 || now < f.lean.until
            idleFrames = idleFrames || !still && (f.frames[f.gait]?.count ?? 0) > 1 || now < f.lookUntil || f.react != nil || f.walk.state == .sit
        }
        friends.removeAll { $0.leaving == .infinity }
        hover()
        // Moving or reacting: 30 fps (60 while a window may be dragged). Idle frames or a nap: 2 a second. Else just the
        // window list's pace (nothing at all with no Finder window out).
        let fast = pollEvery.map { $0 < 0.1 } == true
        if fast { schedule(1.0 / 60) } else if busy || pressed != nil { schedule(1.0 / 30) } else if idleFrames { schedule(0.5) }
        else if let every = pollEvery { schedule(every) } else { stopTimer() }
    }

    /// Now and then a sitting friend does something: a walk along the edge, a nap, a look around, a hop, or nothing.
    private func think(_ f: Friend, now: TimeInterval) {
        guard now >= f.think, f.walk.state == .idle, !f.walk.airborne else { return }
        f.think = now + .random(in: 4...10)
        let r = Double.random(in: 0..<1)
        if r < 0.25 {
            f.walk.walk(to: FolderPerch.clampX(f.walk.x + .random(in: -160...160), width: f.window.frame.width, size: f.size))
        } else if r < 0.4, f.has(.sleep) {
            f.walk.state = .sit
            f.sitUntil = now + .random(in: 6...14)
            f.think = f.sitUntil + .random(in: 2...5)
        } else if r < 0.6 {
            f.lookUntil = now + 2.4
            f.turnAt = now
        } else if r < 0.68 {
            f.walk.hop()
        }
    }

    private func layout(_ f: Friend, now: TimeInterval) {
        guard let set = f.frames[f.gait] ?? f.frames[.walk], !set.isEmpty else { return }
        let image = set[still ? 0 : f.frame % set.count]
        var turn: (angle: CGFloat, sx: CGFloat, sy: CGFloat) = (0, 1, 1), pivot: CGFloat = 0
        if let r = f.react {
            let p = r.r.reaction.pose(now - r.start, still: still)
            turn = (p.angle, p.sx, p.sy)
            if r.r.reaction.spins { pivot = 0.5 }
            if r.r.reaction == .pout, !still { turn.sx = 1.04; turn.sy = 0.94 }
        } else if !still, now < f.lean.until {
            turn.angle = f.lean.dir * 0.07   // holding on: the window goes right, its top leans back left
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if f.shown !== image { f.layer.contents = image; f.shown = image }
        // The panel's bottom is `edge` under the window's top: the feet `sink` under it.
        let edge = FolderPerch.edge(f.size.height)
        f.layer.position = CGPoint(x: f.walk.x, y: edge - f.sink + f.walk.y + f.lift(now, still: still))
        let flip = f.facingLeft ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        f.layer.setAffineTransform(flip.concatenating(BuddyMath.transform(angle: turn.angle, sx: turn.sx, sy: turn.sy,
                                                                          pivot: CGPoint(x: f.size.width / 2, y: f.size.height * pivot),
                                                                          anchor: f.layer.anchorPoint, size: f.size)))
        // The 풀밭 친구들's small bounce where it stands (Core Animation's, so no fast timer of ours); none under 동작
        // 줄이기, napping, reacting, in the air or leaving.
        let bob = !(still || f.walk.airborne || f.walk.state == .sit || f.react != nil || f.leaving != nil)
        if bob, f.layer.animation(forKey: "bob") == nil {
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0; a.toValue = 2
            a.duration = .pi / 6
            a.autoreverses = true
            a.repeatCount = .infinity
            a.isAdditive = true
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.timeOffset = f.phase / 3
            f.layer.add(a, forKey: "bob")
        } else if !bob, f.layer.animation(forKey: "bob") != nil {
            f.layer.removeAnimation(forKey: "bob")
        }
        CATransaction.commit()
    }

    private func pop(_ text: String, _ color: NSColor, over f: Friend) {
        let up = still ? f.size.height * 0.35 : 0
        let rect = CGRect(x: f.layer.position.x - f.size.width / 2, y: f.layer.position.y + up, width: f.size.width, height: f.size.height)
        FriendMark.pop(text, color: color, over: rect, in: f.host, still: still, scale: f.panel?.backingScaleFactor ?? 2)
    }

    // MARK: Reacting

    static var lines: [String] {
        [L("폴더 위가 제일 명당이에요"), L("여기서 정리하는 거 구경할래요"), L("창 옮기면 꽉 붙잡을게요"), L("헤헤, 불렀어요?"), L("이 폴더 안엔 뭐가 있어요?")]
    }

    private func react(_ f: Friend, _ r: MeadowReaction, now: TimeInterval) {
        f.walk = MeadowWalk(x: f.walk.x)
        f.lookUntil = 0
        f.frame = 0; f.clock = 0
        if r.reaction == .pout { f.facingLeft.toggle() }
        if r.sits {
            f.react = nil
            f.walk.state = .sit
            f.sitUntil = now + .random(in: 4...6)
        } else {
            f.react = (r, now)
            if let m = r.reaction.mark { pop(m.text, m.color, over: f) }
        }
        layout(f, now: now)
        let combo = r.reaction == .dizzy || r.reaction == .pout
        guard combo || now >= talkAfter else { return }
        talkAfter = now + 4
        let own = f.says[r.gait] ?? [], persona = MeadowFriends.persona(character: qaCharacter)
        let text = combo ? persona.dress(LinePick.pick("folder.\(r.reaction.rawValue)", r.lines))
            : own.isEmpty ? persona.dress(LinePick.pick("folder.say", Self.lines)) : LinePick.pick("folder.say.\(r.gait)", own)
        SpeechBubbleCenter.shared.say(text: text, source: .system, aloud: false, repeats: true, anchor: { [weak self, weak f] in
            f.flatMap { self?.head(of: $0) }
        })
    }

    // MARK: Mouse

    private func friend(at p: CGPoint) -> Friend? {
        friends.last { f in
            guard f.leaving == nil, !f.hidden, let panel = f.panel, panel.frame.contains(p), let image = f.shown else { return false }
            let id = ObjectIdentifier(image)
            if hits[id] == nil { hits[id] = AlphaHit(image) }
            var lx = p.x - panel.frame.minX - (f.layer.position.x - f.size.width / 2)
            if f.facingLeft { lx = f.size.width - lx }
            let ly = p.y - panel.frame.minY - f.layer.position.y
            if hits[id]?.hits(CGPoint(x: lx, y: ly), in: f.size) == true { return true }
            return f.react != nil && lx >= 0 && lx <= f.size.width && ly >= -f.size.height && ly <= f.size.height
        }
    }

    /// The panels take clicks only over a friend.
    fileprivate func hover() {
        guard pressed == nil, !friends.isEmpty else { return }
        let p = NSEvent.mouseLocation
        let over = friend(at: p)
        for f in friends { if let panel = f.panel, panel.ignoresMouseEvents == (over === f) { panel.ignoresMouseEvents = over !== f } }
    }

    fileprivate func mouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        switch e.type {
        case .rightMouseDown: showMenu(e, at: p)
        case .leftMouseDown where e.modifierFlags.contains(.control): showMenu(e, at: p)
        case .leftMouseDown where e.modifierFlags.contains(.option): quickAsk(friend(at: p))
        case .leftMouseDown:
            _ = clicks.mouseDown(p, at: t)
            pressed = friend(at: p)
        case .leftMouseDragged: _ = clicks.mouseMoved(p, at: t)
        case .leftMouseUp:
            var g = clicks.mouseUp(p, at: t)
            if clicks.pollAt != nil { clicks = ClickRecognizer(); g = [.single(p)] }   // answered at once: clicks in a row make a combo
            // ponytail: no picking it up; a drag off it does nothing (the window under it is Finder's to drag).
            if let f = pressed, g.contains(where: { if case .single = $0 { true } else { false } }) {
                MainActor.assumeIsolated { if FriendQuickAsk.shared.isOpen { FriendQuickAsk.shared.close() } }
                let r = MeadowReaction.click(&f.combo, at: t, has: f.has, key: "folder.react")
                FriendCry.play(r.reaction, friend: "folder-\(ObjectIdentifier(f).hashValue)")
                react(f, r, now: t)
            }
            pressed = nil
        default: break
        }
        wake()
    }

    private func quickAsk(_ f: Friend?) {
        guard let f, let panel = f.panel else { return }
        MainActor.assumeIsolated {
            FriendQuickAsk.shared.toggle(from: panel, key: f.window.id) { [weak self, weak f] in f.flatMap { self?.head(of: $0) } }
        }
    }

    private func showMenu(_ e: NSEvent, at p: CGPoint) {
        _ = clicks.cancel(at: p)
        pressed = nil
        let f = friend(at: p)
        guard let v = f?.panel?.contentView else { return }
        let own = [
            FriendMenu.item(L("퀵물어보기")) { [weak self] in self?.quickAsk(f) },
            FriendMenu.item(L("창마다 한 명씩"), on: store.prefs.everyWindow) { FolderStore.shared.prefs.everyWindow.toggle() },
            FriendMenu.item(L("폴더 친구 치우기")) { FolderStore.shared.prefs.on = false },
        ]
        FriendMenu.pop(own, with: e, for: v)
        hover()
    }

    // MARK: QA

    /// QA renders only (FriendMark.qa on): stand-in Finder windows side by side, a friend on each: standing on the edge,
    /// walking along it, napping, clicked (hearts), and held on while its window is dragged right. As under 동작 줄이기
    /// when `still`; `dark`: dark Finder windows; `character`: an original's id (nil: the menu bar character). Returns
    /// the scene.
    func qaScene(still qaStill: Bool, dark: Bool = false, character: String? = nil) -> CALayer {
        still = qaStill
        qaCharacter = character
        defer { still = DesktopKit.reduceMotion; qaCharacter = nil; built = nil }
        build(Built(look: SpriteLook(AppSettings.shared), colors: AppSettings.shared.characterColors, size: store.prefs.size))
        let now = ProcessInfo.processInfo.systemUptime
        let win = CGSize(width: 260, height: 170), gap: CGFloat = 24, top: CGFloat = ((sprites?.size.height ?? 60) * 2.2).rounded() + 44
        let scene = CALayer()
        scene.frame = CGRect(x: 0, y: 0, width: gap + 5 * (win.width + gap), height: win.height + top + gap)
        for i in 0..<5 {
            let frame = CGRect(x: gap + CGFloat(i) * (win.width + gap), y: gap, width: win.width, height: win.height)
            scene.addSublayer(Self.fakeWindow(frame, dark: dark))
            let host = CALayer()
            let f = Friend(window: ListedWindow(id: -i - 1, pid: 0, frame: frame), host: host, x: [110, 150, 130, 190, 140][i])
            dress(f)
            host.frame = FolderPerch.panelFrame(on: frame, size: f.size, screens: [scene.frame]) ?? .zero
            host.addSublayer(f.layer)
            scene.addSublayer(host)
            switch i {
            case 1: f.walk.state = .walk; f.frame = 1
            case 2: f.walk.state = .sit
            case 3: f.react = (MeadowReaction.plays[0], now - MeadowReaction.plays[0].duration * 0.4)
            case 4: f.lean = (1, now + 1)
            default: break
            }
            f.sink = FolderPerch.sink(f.size.height, napping: f.napping)
            layout(f, now: now)
            f.layer.removeAnimation(forKey: "bob")
            if i == 3, let m = MeadowReaction.plays[0].reaction.mark { pop(m.text, m.color, over: f) }
        }
        return scene
    }

    /// A plain Finder-like window (light or dark): a body, a title bar with the three buttons and a few folder tiles.
    private static func fakeWindow(_ frame: CGRect, dark: Bool) -> CALayer {
        let w = CALayer()
        w.frame = frame
        w.backgroundColor = NSColor(white: dark ? 0.12 : 0.98, alpha: 1).cgColor
        w.cornerRadius = 10
        w.borderWidth = 0.5
        w.borderColor = NSColor(white: dark ? 0.32 : 0.7, alpha: 1).cgColor
        w.shadowOpacity = 0.25; w.shadowRadius = 8; w.shadowOffset = CGSize(width: 0, height: -3)
        let bar = CALayer()
        bar.frame = CGRect(x: 0, y: frame.height - 30, width: frame.width, height: 30)
        bar.backgroundColor = NSColor(white: dark ? 0.18 : 0.92, alpha: 1).cgColor
        bar.cornerRadius = 10
        bar.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        w.addSublayer(bar)
        for (j, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let dot = CALayer()
            dot.frame = CGRect(x: 12 + CGFloat(j) * 18, y: 9, width: 12, height: 12)
            dot.cornerRadius = 6
            dot.backgroundColor = c.cgColor
            bar.addSublayer(dot)
        }
        for j in 0..<4 {
            let tile = CALayer()
            tile.frame = CGRect(x: 20 + CGFloat(j) * 58, y: frame.height - 100, width: 40, height: 32)
            tile.cornerRadius = 4
            tile.backgroundColor = NSColor(red: 0.42, green: 0.70, blue: 0.95, alpha: 1).cgColor
            w.addSublayer(tile)
        }
        return w
    }
}

/// Never key, never main: touching the friend never takes the focus from Finder.
fileprivate final class FolderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FolderView: NSView {
    weak var owner: FolderFriends?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { owner?.hover() }
    override func mouseDown(with event: NSEvent) { owner?.mouse(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouse(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouse(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.mouse(event) }
}
