import AppKit
import Combine
import SceneKit

// MARK: Settings

/// How stiff the rug's cloth is (its bending strength).
enum RugSoftness: String, Codable, CaseIterable {
    case stiff, normal, floppy

    var label: String {
        switch self {
        case .stiff: return L("빳빳")
        case .normal: return L("보통")
        case .floppy: return L("흐물")
        }
    }

    var bend: Double {
        switch self {
        case .stiff: return 0.9
        case .normal: return 0.4
        case .floppy: return 0.08
        }
    }
}

struct RugPrefs: Codable, Equatable {
    var on = false
    var softness = RugSoftness.normal
    /// Where its middle rests across the main screen's visible frame, 0...1 each way.
    var home = CGPoint(x: 0.24, y: 0.3)
}

extension RugPrefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RugPrefs()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        softness = (try? c.decodeIfPresent(RugSoftness.self, forKey: .softness)) ?? d.softness
        home = (try? c.decodeIfPresent(CGPoint.self, forKey: .home)) ?? d.home
    }
}

final class RugStore: ObservableObject {
    static let shared = RugStore()
    static let key = "desktopRug"

    private let defaults: UserDefaults
    @Published var prefs: RugPrefs {
        didSet { if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key) } }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        prefs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(RugPrefs.self, from: $0) } ?? RugPrefs()
    }
}

// MARK: The rug

/// "바탕화면 러그" (데스크톱 친구): a small cloth rug on the desktop (behind windows, over the icons' layer). Grab an
/// edge and it folds over, showing its plain stitched back; rub the middle about and it bunches into wrinkles that stay.
/// A double click, or 빳빳하게 펼치기 in its right-click menu, smooths it back to its place; 러그를 화면 가운데로 moves that
/// place. 부드러움 picks how stiff the cloth is. Drawn with SceneKit (system, no dependency), physics in ClothSheet;
/// nothing ticks once it lies still. 동작 줄이기: no physics, it lies flat and a drag moves it whole.
final class DesktopRug {
    static let shared = DesktopRug()
    static var qaHidden = false
    static let smoothTime: TimeInterval = 0.9

    private var panel: NSPanel?
    private let view = RugView(frame: .zero)
    private let node = SCNNode()
    private var cloth: ClothSheet?
    private var texcoords: SCNGeometrySource?
    private var elements: [SCNGeometryElement] = []
    private let front = SCNMaterial(), back = SCNMaterial()
    private var timer: Timer?
    private var smoothing: (from: [ClothSheet.P], to: CGPoint, start: TimeInterval)?
    private var clicks = ClickRecognizer()
    /// 동작 줄이기's drag: the whole rug moves, from where it was grabbed.
    private var lift: (origin: CGPoint, at: CGPoint)?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var bag: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var started = false
    private var asleep = false
    private var still = DesktopKit.reduceMotion
    private var builtFor: CGRect?

    private var store: RugStore { .shared }
    private var enabled: Bool { store.prefs.on && !asleep }

    func start() {
        guard !started else { return }
        started = true
        RugStore.shared.objectWillChange
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
            .sink { [weak self] in
                guard let self else { return }
                self.still = DesktopKit.reduceMotion
                if self.still { self.lieFlat() }
            }
            .store(in: &bag)
        refresh()
    }

    // MARK: Building

    private func refresh() {
        // The menu bar's screen, not NSScreen.main (whichever has the key window): a settings change must not move it.
        guard enabled, let screen = NSScreen.screens.first else { teardown(); return }
        let frame = screen.visibleFrame
        let p = panel ?? makePanel()
        panel = p
        if builtFor != frame {
            builtFor = frame
            p.setFrame(frame, display: false)
            view.frame = CGRect(origin: .zero, size: frame.size)
            setUpScene(size: frame.size)
            var c = ClothSheet(bend: store.prefs.softness.bend, walls: CGRect(origin: .zero, size: frame.size))
            c.place(ClothSheet.flatten(from: c.rest, rest: c.rest, to: homeOrigin(c, in: frame.size), progress: 1))
            cloth = c
            texcoords = SCNGeometrySource(textureCoordinates: c.rest.map {
                CGPoint(x: $0.x / Double(c.size.width), y: 1 - $0.y / Double(c.size.height))
            })
            let t = c.triangles
            elements = [front, back].map { _ in SCNGeometryElement(indices: t, primitiveType: .triangles) }
        }
        cloth?.bend = store.prefs.softness.bend
        p.orderFrontRegardless()
        if monitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.mouseMoved]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.hover() }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.hover(); return e }) { monitors.append(l) }
        }
        render()
        wake()
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        smoothing = nil; lift = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = RugPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        if Self.qaHidden { p.alphaValue = 0 }
        p.ignoresMouseEvents = true   // until the cursor is over the cloth
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        view.owner = self
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.rendersContinuously = false
        view.antialiasingMode = .multisampling4X
        p.contentView = view
        return p
    }

    /// Looking straight down at the desktop: an orthographic camera, a light from the upper left for the folds' shading.
    private func setUpScene(size: CGSize) {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = Double(size.height / 2)
        cam.zNear = 1
        cam.zFar = 4000
        let camNode = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(size.width / 2, size.height / 2, 2000)
        scene.rootNode.addChildNode(camNode)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 800
        sun.eulerAngles = SCNVector3(0.45, -0.35, 0)
        scene.rootNode.addChildNode(sun)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 450
        scene.rootNode.addChildNode(fill)
        front.diffuse.contents = RugArt.front
        front.lightingModel = .lambert
        front.cullMode = .back
        back.diffuse.contents = RugArt.back
        back.emission.contents = NSColor(white: 0.45, alpha: 1)   // the face-down side is lit from behind its normals
        back.lightingModel = .lambert
        back.cullMode = .front
        node.removeFromParentNode()
        scene.rootNode.addChildNode(node)
        view.scene = scene
        view.pointOfView = camNode
    }

    private func homeOrigin(_ c: ClothSheet, in size: CGSize) -> CGPoint {
        let h = store.prefs.home
        return CGPoint(x: min(max(0, size.width * h.x - c.size.width / 2), size.width - c.size.width),
                       y: min(max(0, size.height * h.y - c.size.height / 2), size.height - c.size.height))
    }

    // MARK: Drawing and ticking

    private func render() {
        guard let c = cloth, let texcoords else { return }
        let normals = c.normals()
        // ponytail: a face-down fold sits a hair higher so it never flickers against the cloth under it (no self-collision).
        let verts = zip(c.points, normals).map { p, n in SCNVector3(p.x, p.y, p.z + (n.z < 0 ? 1.5 : 0)) }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }), texcoords],
                            elements: elements)
        g.materials = [front, back]
        node.geometry = g
    }

    private func wake() {
        guard timer == nil, cloth != nil, enabled else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.004
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard var c = cloth else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        if let s = smoothing {
            let u = (now - s.start) / Self.smoothTime
            c.place(ClothSheet.flatten(from: s.from, rest: c.rest, to: s.to, progress: u))
            if u >= 1 { smoothing = nil }
        } else if !still {
            c.step(dt: dt)
        }
        cloth = c
        render()
        hover()
        if smoothing == nil, lift == nil, still || c.isSettled { timer?.invalidate(); timer = nil }
    }

    /// 빳빳하게 펼치기: eases every point back to the flat rug at its place in about a second, with a word from the character.
    func smooth() {
        guard let c = cloth, let size = builtFor?.size else { return }
        smoothing = (c.points, homeOrigin(c, in: size), ProcessInfo.processInfo.systemUptime)
        let polite = !AssistantModel.persona().style.banmal
        SpeechBubbleCenter.shared.say(text: polite ? L("주름을 쫙 펴고 있어요") : L("주름 쫙 펴는 중이야"), source: .system, aloud: false, repeats: true)
        wake()
    }

    /// 러그를 화면 가운데로: its place moves to the middle and it smooths out there.
    func center() {
        store.prefs.home = CGPoint(x: 0.5, y: 0.5)
        smooth()
    }

    /// 동작 줄이기: flat at its place at once.
    private func lieFlat() {
        guard var c = cloth, let size = builtFor?.size else { return }
        c.place(ClothSheet.flatten(from: c.points, rest: c.rest, to: homeOrigin(c, in: size), progress: 1))
        cloth = c
        render()
    }

    // MARK: Mouse

    private func local(_ p: CGPoint) -> CGPoint {
        guard let o = panel?.frame.origin else { return p }
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    private func hover() {
        guard let panel, let c = cloth, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let p = NSEvent.mouseLocation
        let over = panel.frame.contains(p) && c.covers(local(p))
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    fileprivate func mouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation, t = e.timestamp
        switch e.type {
        case .rightMouseDown: showMenu(e)
        case .leftMouseDown where e.modifierFlags.contains(.control): showMenu(e)
        case .leftMouseDown: clicks.mouseDown(p, at: t).forEach(handle)
        case .leftMouseDragged: clicks.mouseMoved(p, at: t).forEach(handle)
        case .leftMouseUp: clicks.mouseUp(p, at: t).forEach(handle)   // a lone click does nothing, so nobody polls for it
        default: break
        }
    }

    private func handle(_ g: ClickRecognizer.Gesture) {
        guard var c = cloth, let size = builtFor?.size else { return }
        switch g {
        case .dragBegan(let p):
            smoothing = nil
            if still { lift = (homeOrigin(c, in: size), local(p)) } else { _ = c.grab(at: local(p)) }
        case .dragged(let p):
            if let l = lift {
                let q = local(p)
                let o = CGPoint(x: l.origin.x + q.x - l.at.x, y: l.origin.y + q.y - l.at.y)
                c.place(ClothSheet.flatten(from: c.points, rest: c.rest, to: o, progress: 1))
            } else {
                c.drag(to: local(p))
            }
        case .dragEnded(let p, let v):
            if let l = lift {   // 동작 줄이기: where it was put down becomes its place
                let q = local(p)
                store.prefs.home = CGPoint(x: (l.origin.x + q.x - l.at.x + c.size.width / 2) / size.width,
                                           y: (l.origin.y + q.y - l.at.y + c.size.height / 2) / size.height)
                lift = nil
            } else {
                c.release(velocity: v)
            }
        case .double:
            cloth = c
            smooth()
            return
        case .single:
            break
        }
        cloth = c
        render()
        wake()
    }

    private func showMenu(_ e: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(RugAction.fire), keyEquivalent: "")
            let a = RugAction(run)
            item.target = a
            item.representedObject = a   // the item keeps its action alive
            item.state = checked ? .on : .off
            return item
        }
        menu.addItem(add(L("빳빳하게 펼치기")) { [weak self] in self?.smooth() })
        menu.addItem(add(L("러그를 화면 가운데로")) { [weak self] in self?.center() })
        let soft = NSMenuItem(title: L("부드러움"), action: nil, keyEquivalent: "")
        soft.submenu = NSMenu()
        for s in RugSoftness.allCases {
            soft.submenu?.addItem(add(s.label, checked: store.prefs.softness == s) { RugStore.shared.prefs.softness = s })
        }
        menu.addItem(soft)
        menu.addItem(.separator())
        menu.addItem(add(L("러그 치우기")) { RugStore.shared.prefs.on = false })
        NSMenu.popUpContextMenu(menu, with: e, for: view)
    }
}

private final class RugAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// Never key, never main: touching the rug never takes the focus from the app in front.
private final class RugPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RugView: SCNView {
    weak var owner: DesktopRug?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.mouse(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouse(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouse(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.mouse(event) }
}

/// The rug's two faces, drawn in code (our own pattern): a cream weave with a terracotta border and a navy diamond in
/// the middle; the back plain light grey with the border's stitching showing through.
enum RugArt {
    static let size = CGSize(width: 512, height: 352)

    static let front: NSImage = NSImage(size: size, flipped: false) { r in
        NSColor(red: 0.96, green: 0.9, blue: 0.78, alpha: 1).setFill(); r.fill()
        let terracotta = NSColor(red: 0.78, green: 0.4, blue: 0.3, alpha: 1), navy = NSColor(red: 0.2, green: 0.27, blue: 0.45, alpha: 1)
        terracotta.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: 22, dy: 22)); border.lineWidth = 18; border.stroke()
        navy.setStroke()
        let line = NSBezierPath(rect: r.insetBy(dx: 40, dy: 40)); line.lineWidth = 3; line.stroke()
        func diamond(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: CGPoint(x: c.x, y: c.y + h)); p.line(to: CGPoint(x: c.x + w, y: c.y))
            p.line(to: CGPoint(x: c.x, y: c.y - h)); p.line(to: CGPoint(x: c.x - w, y: c.y)); p.close()
            return p
        }
        navy.setFill(); diamond(CGPoint(x: r.midX, y: r.midY), 110, 80).fill()
        terracotta.setFill(); diamond(CGPoint(x: r.midX, y: r.midY), 70, 50).fill()
        NSColor(red: 0.96, green: 0.9, blue: 0.78, alpha: 1).setFill(); diamond(CGPoint(x: r.midX, y: r.midY), 26, 18).fill()
        navy.setFill()
        for i in 0..<9 {   // a row of small diamonds inside the border, top and bottom
            let x = r.minX + 70 + CGFloat(i) * (r.width - 140) / 8
            diamond(CGPoint(x: x, y: r.minY + 62), 9, 9).fill()
            diamond(CGPoint(x: x, y: r.maxY - 62), 9, 9).fill()
        }
        return true
    }

    static let back: NSImage = NSImage(size: size, flipped: false) { r in
        NSColor(white: 0.86, alpha: 1).setFill(); r.fill()
        NSColor(white: 0.66, alpha: 1).setStroke()
        let stitch = NSBezierPath(rect: r.insetBy(dx: 22, dy: 22))
        stitch.lineWidth = 2.5
        stitch.setLineDash([9, 6], count: 2, phase: 0)
        stitch.stroke()
        return true
    }
}
