import AppKit
import Combine
import SwiftUI

/// The 날씨 창문's shape: a crystal ball on a little stand, over its soft shadow. `orb` and `stand` are y down like
/// the drawing (WeatherSceneView); `hits` takes window points, y up.
enum WeatherFrame {
    /// The window is this much taller than wide, for the stand and its shadow.
    static let heightRatio: CGFloat = 1.16
    static let baseDiameter: CGFloat = 160
    /// 창 크기 steps. Each keeps the character at a whole number of pixels on a Retina screen (2 pt per art px at 100%).
    static let scales: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let defaultStep = 2

    /// "100% 보통" for the size menus.
    static func label(_ step: Int) -> String {
        let s = scales[min(max(step, 0), scales.count - 1)], pct = "\(Int(s * 100))%"
        switch s {
        case 0.5: return pct + " " + L("꼬마")
        case 1: return pct + " " + L("보통")
        case 2: return pct + " " + L("크게")
        default: return pct
        }
    }

    static func size(_ step: Int) -> CGSize {
        let d = baseDiameter * scales[min(max(step, 0), scales.count - 1)]
        return CGSize(width: d, height: (d * heightRatio).rounded())
    }

    /// The glass ball in a window of `size`: its centre and radius, y down. The stand and its shadow take the
    /// 0.52 r below the ball and a little more (WeatherArt.standBack).
    static func orb(_ size: CGSize) -> (center: CGPoint, r: CGFloat) {
        (CGPoint(x: size.width / 2, y: size.width * 0.48), size.width * 0.44)
    }

    /// Whether `p` (in a window of `size`, y up) is on the object: the ball or the stand's neck and foot as drawn.
    /// Elsewhere, the shadow and the corners beside the neck included, clicks pass through.
    static func hits(_ p: CGPoint, size: CGSize) -> Bool {
        let q = CGPoint(x: p.x, y: size.height - p.y), (c, r) = orb(size)
        let dx = q.x - c.x, dy = q.y - c.y, g = WeatherArt.standRings(c: c, r: r)
        return dx * dx + dy * dy <= r * r || WeatherArt.turned(g.collar, g.neck).contains(q)
            || WeatherArt.turned(g.footTop, g.footBottom).contains(q)
    }
}

/// "날씨 창문" (데스크톱 친구): a little crystal ball on a stand on the desktop, the current character living inside in
/// the city's weather. Never takes focus, passes clicks through outside the ball and stand, on every Space. Drag it to move it,
/// click for a hop and a reaction (now and then a line), right-click for city, preview, look, size and on-top. Draws only while it is on screen.
final class WeatherWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = WeatherWindow()

    @Published var on: Bool { didSet { defaults.set(on, forKey: "weatherWindow") } }
    @Published var sizeStep: Int { didSet { defaults.set(sizeStep, forKey: "weatherSize") } }
    @Published var onTop: Bool { didSet { defaults.set(onTop, forKey: "weatherOnTop") } }
    /// 꾸미기: 받침 색, the name plate's temperature, a line now and then on clicks, petals and leaves by the month.
    @Published var theme: WeatherTheme { didSet { defaults.set(theme.rawValue, forKey: "weatherTheme") } }
    @Published var showTemp: Bool { didSet { defaults.set(showTemp, forKey: "weatherShowTemp") } }
    @Published var chatter: Bool { didSet { defaults.set(chatter, forKey: "weatherChatter") } }
    @Published var seasonal: Bool { didSet { defaults.set(seasonal, forKey: "weatherSeasonal") } }

    /// For the scene: the character's frames at this size, and whether to animate.
    @Published var cache: DogSpriteCache?   // set by refresh(); QA renders set their own
    @Published private(set) var animating = false
    @Published private(set) var heartsAt: Date?

    var scale: CGFloat { WeatherFrame.scales[min(max(sizeStep, 0), WeatherFrame.scales.count - 1)] }

    private let defaults = AppDefaults.store
    private var panel: NSPanel?
    private var bag: Set<AnyCancellable> = []
    private var hitTimer: Timer?
    private var weatherTimer: Timer?
    private var look: (SpriteLook, CGFloat)?
    private var asleep = false
    private var visible = false
    private var wasEnabled = false
    private var clickCount = 0
    private var lastQuip = Date.distantPast

    private var enabled: Bool { on }

    override init() {
        on = defaults.bool(forKey: "weatherWindow")
        sizeStep = defaults.object(forKey: "weatherSize") as? Int ?? WeatherFrame.defaultStep
        onTop = defaults.object(forKey: "weatherOnTop") as? Bool ?? true
        theme = WeatherTheme(rawValue: defaults.string(forKey: "weatherTheme") ?? "") ?? .cream
        showTemp = defaults.object(forKey: "weatherShowTemp") as? Bool ?? true
        chatter = defaults.object(forKey: "weatherChatter") as? Bool ?? true
        seasonal = defaults.object(forKey: "weatherSeasonal") as? Bool ?? true
        super.init()
    }

    /// Call once at launch. Follows its switch, the character and 동작 줄이기 on its own.
    func start() {
        guard bag.isEmpty else { return }
        AppSettings.shared.objectWillChange
            .merge(with: CustomCharacterStore.shared.objectWillChange, objectWillChange)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        WeatherService.shared.$city.dropFirst().removeDuplicates()
            .sink { [weak self] _ in if self?.enabled == true { Task { await WeatherService.shared.refresh() } } }
            .store(in: &bag)
        DesktopKit.displayOptionsChanged.sink { [weak self] in self?.updateAnimating() }.store(in: &bag)
        let nc = NSWorkspace.shared.notificationCenter, dc = DistributedNotificationCenter.default()
        // A plain lock and unlock (display still on) posts only the screenIs* notices; the session ones are user switching.
        let notices: [(NotificationCenter, Notification.Name, Bool)] = [
            (nc, NSWorkspace.screensDidSleepNotification, true), (nc, NSWorkspace.screensDidWakeNotification, false),
            (nc, NSWorkspace.sessionDidResignActiveNotification, true), (nc, NSWorkspace.sessionDidBecomeActiveNotification, false),
            (dc, Notification.Name("com.apple.screenIsLocked"), true), (dc, Notification.Name("com.apple.screenIsUnlocked"), false),
        ]
        for (center, name, sleep) in notices {
            center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.asleep = sleep
                self?.updateAnimating()
                if !sleep { self?.wake() }
            }.store(in: &bag)
        }
        refresh()   // and wake() once it is enabled
    }

    /// The day's first wake or unlock (and launch): fresh weather, and the morning line once a day.
    private func wake() {
        guard enabled else { return }
        Task { @MainActor in
            if let line = await WeatherService.shared.morningLine() { SpeechBubbleCenter.shared.say(text: line, source: .system) }
        }
    }

    private func refresh() {
        let was = wasEnabled
        wasEnabled = enabled
        guard enabled else { stop(); return }
        if !was { wake() }
        let px = 2 * scale
        let now = SpriteLook(AppSettings.shared)
        if look.map({ $0.0 != now || $0.1 != px }) ?? true {
            look = (now, px)
            cache = DogSpriteCache(now, pixelSize: px)
        }
        if panel == nil { makePanel() }
        guard let panel else { return }
        let size = WeatherFrame.size(sizeStep)
        if panel.frame.size != size {
            let old = panel.frame
            // Grows and shrinks about the bottom centre, where the stand sits.
            panel.setFrame(CGRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height), display: true)
            savePosition()
        }
        panel.level = onTop ? .floating : .normal
        if !panel.isVisible { panel.orderFrontRegardless(); visible = true }   // the occlusion notice corrects it
        if weatherTimer == nil {
            let t = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in
                guard self?.asleep == false else { return }
                Task { await WeatherService.shared.refresh() }   // GETs only when due (Expires, 30 min)
            }
            t.tolerance = 60
            RunLoop.main.add(t, forMode: .common)
            weatherTimer = t
            Task { await WeatherService.shared.refresh() }
        }
        updateAnimating()
    }

    private func stop() {
        weatherTimer?.invalidate(); weatherTimer = nil
        panel?.orderOut(nil)
        visible = false
        updateAnimating()
    }

    private func makePanel() {
        let size = WeatherFrame.size(sizeStep)
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.delegate = self
        let host = WeatherHostView(frame: CGRect(origin: .zero, size: size))
        host.owner = self
        let scene = NSHostingView(rootView: WeatherSceneView(window: self, service: .shared))
        scene.frame = host.bounds
        scene.autoresizingMask = [.width, .height]
        host.addSubview(scene)
        p.contentView = host
        panel = p
        place(saved: true)
    }

    /// The saved spot if it is still on a screen, else the bottom right of the main screen.
    private func place(saved: Bool) {
        guard let panel else { return }
        let size = panel.frame.size
        if saved, defaults.object(forKey: "weatherX") != nil {
            let o = CGPoint(x: defaults.double(forKey: "weatherX"), y: defaults.double(forKey: "weatherY"))
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGPoint(x: o.x + size.width / 2, y: o.y + size.height / 2)) }) {
                panel.setFrameOrigin(o)
                return
            }
        }
        let v = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: v.maxX - size.width - 24, y: v.minY + 24))
        if !saved { savePosition() }
    }

    private func savePosition() {
        guard let o = panel?.frame.origin else { return }
        defaults.set(Double(o.x), forKey: "weatherX")
        defaults.set(Double(o.y), forKey: "weatherY")
    }

    private func trackMouse() {
        guard let panel, panel.isVisible else { return }
        let m = NSEvent.mouseLocation
        let inside = WeatherFrame.hits(CGPoint(x: m.x - panel.frame.minX, y: m.y - panel.frame.minY), size: panel.frame.size)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        visible = panel?.occlusionState.contains(.visible) ?? false
        updateAnimating()
    }

    /// Moves only while someone can see it, the screens are awake and 동작 줄이기 is off. The click-through poll runs
    /// only while it can be seen and the screens are awake, so a hidden or sleeping window costs nothing.
    private func updateAnimating() {
        let live = enabled && visible && !asleep
        let a = live && !DesktopKit.reduceMotion
        if a != animating { animating = a }
        if !live {
            hitTimer?.invalidate(); hitTimer = nil
        } else if hitTimer == nil {
            // Click-through: the window takes the mouse only while it is over the drawing.
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.trackMouse() }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            hitTimer = t
        }
    }

    // MARK: Mouse (from WeatherHostView)

    /// Every third click, at most every 20 s, a short line for the sky (asleep: a sleepy one) over the window.
    fileprivate func clicked() {
        heartsAt = Date()
        clickCount += 1
        if chatter, clickCount >= 3, Date().timeIntervalSince(lastQuip) >= 20 {
            let (kind, night) = WeatherService.shared.scene()
            let lines = WeatherSceneView.pose((kind, night)) == .lying ? WeatherKind.nightQuips : kind.quips
            if let line = lines.randomElement() {
                clickCount = 0
                lastQuip = Date()
                SpeechBubbleCenter.shared.say(text: line, source: .system, aloud: false,
                                              anchor: { [weak self] in self?.panel.flatMap { $0.isVisible ? CGPoint(x: $0.frame.midX, y: $0.frame.maxY) : nil } })
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if let at = self?.heartsAt, Date().timeIntervalSince(at) >= 1.2 { self?.heartsAt = nil }
        }
    }

    fileprivate func moved() { savePosition() }

    fileprivate func menuItems() -> [NSMenuItem] {
        let service = WeatherService.shared
        let item = FriendMenu.item, submenu = FriendMenu.submenu
        let info = NSMenuItem(title: service.summary, action: nil, keyEquivalent: "")
        info.isEnabled = false
        return [
            info,
            .separator(),
            submenu(L("도시 바꾸기 (\(service.city.name))"),
                    WeatherCity.presets.map { c in item(c.name, c == service.city) { service.city = c } }
                    + [.separator(), item(L("다른 도시 검색…"), false) { Self.askCity() }]),
            submenu(L("날씨 미리보기"),
                    [item(L("실제 날씨"), service.preview == nil) { service.preview = nil }]
                    + WeatherKind.allCases.map { k in item(k.title, service.preview == k) { service.preview = k } }),
            item(L("밤으로 보기"), service.previewNight) { service.previewNight.toggle() },
            .separator(),
            submenu(L("받침 색"), WeatherTheme.allCases.map { t in item(t.label, t == self.theme) { self.theme = t } }),
            item(L("온도 보이기"), showTemp) { self.showTemp.toggle() },
            submenu(L("창 크기"), WeatherFrame.scales.indices.map { i in item(WeatherFrame.label(i), i == self.sizeStep) { self.sizeStep = i } }),
            item(L("항상 위에 두기"), onTop) { self.onTop.toggle() },
            item(L("위치 초기화"), false) { self.place(saved: false) },
            .separator(),
            item(L("날씨 창문 닫기"), false) { self.on = false },
        ]
    }

    /// 다른 도시 검색…: a name in a small dialog, looked up with Apple's geocoder. The one place this window takes focus,
    /// since the owner asked to type.
    static func askCity() {
        let alert = NSAlert()
        alert.messageText = L("어느 도시의 날씨를 볼까요?")
        alert.informativeText = L("도시 이름을 한글이나 영어로 적어 주세요.")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L("예: 춘천, Tokyo, Paris")
        alert.accessoryView = field
        alert.addButton(withTitle: L("찾기"))
        alert.addButton(withTitle: L("취소"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let q = field.stringValue
        Task { @MainActor in
            if let city = await WeatherService.search(q) {
                WeatherService.shared.city = city
            } else {
                let miss = NSAlert()
                miss.messageText = L("'\(q)' 도시를 찾지 못했어요.")
                miss.informativeText = L("시나 군 이름, 또는 영어 이름으로 다시 찾아보세요.")
                NSApp.activate(ignoringOtherApps: true)
                miss.runModal()
            }
        }
    }
}

/// Takes the mouse for the whole drawing (the SwiftUI scene underneath only draws): a press drags the window, a press
/// that did not move it is a click, a right press opens the menu. Never becomes key, so the app in front stays in front.
private final class WeatherHostView: NSView {
    weak var owner: WeatherWindow?

    override func hitTest(_ point: NSPoint) -> NSView? {
        WeatherFrame.hits(convert(point, from: superview), size: bounds.size) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        guard let window else { return }
        let before = window.frame.origin
        window.performDrag(with: event)   // returns once the button is up
        if window.frame.origin == before { owner?.clicked() } else { owner?.moved() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let items = owner?.menuItems() else { return }
        FriendMenu.pop(items, with: event, for: self)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { L("날씨 창문: \(WeatherService.shared.summary)") }
    override func isAccessibilityElement() -> Bool { true }
}
