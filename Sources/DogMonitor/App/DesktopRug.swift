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

/// 러그 그림: the chosen character printed big on a pastel rug, or the old woven pattern. Raw values are saved.
enum RugFace: String, Codable, CaseIterable {
    case character, pattern

    var label: String { self == .character ? L("캐릭터") : L("무늬") }
}

/// 러그 색 reuses the 위젯 색 pastels (the 꾸미기 colours).
extension FocusTheme: Codable {}

struct RugPrefs: Codable, Equatable {
    var on = false
    var softness = RugSoftness.normal
    var face = RugFace.character
    var color = FocusTheme.strawberry
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
        face = (try? c.decodeIfPresent(RugFace.self, forKey: .face)) ?? d.face
        color = (try? c.decodeIfPresent(FocusTheme.self, forKey: .color)) ?? d.color
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
    /// What the faces were last drawn for, so a texture is redrawn only when the picture would change.
    private var painted: Paint?
    private struct Paint: Equatable { var face: RugFace, color: FocusTheme, look: SpriteLook? }

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
        // A new character (or its colours, or a custom one redrawn) reprints the rug, once things settle.
        AppSettings.shared.objectWillChange
            .merge(with: CustomCharacterStore.shared.objectWillChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.enabled, self.cloth != nil, self.retexture() else { return }
                self.render()
            }
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

    /// Where the cloth lies on screen (the box round it), for friends to sit on; nil while it is off.
    func footprint() -> CGRect? {
        guard enabled, let c = cloth, let o = panel?.frame.origin, !c.points.isEmpty else { return nil }
        let xs = c.points.map { CGFloat($0.x) }, ys = c.points.map { CGFloat($0.y) }
        let lo = CGPoint(x: xs.min() ?? 0, y: ys.min() ?? 0)
        return CGRect(x: o.x + lo.x, y: o.y + lo.y, width: (xs.max() ?? 0) - lo.x, height: (ys.max() ?? 0) - lo.y)
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
        retexture()
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
        front.lightingModel = .lambert
        front.cullMode = .back
        back.emission.intensity = 0.55   // the face-down side is lit from behind its normals: it glows its own colour (retexture)
        back.lightingModel = .lambert
        back.cullMode = .front
        node.removeFromParentNode()
        scene.rootNode.addChildNode(node)
        view.scene = scene
        view.pointOfView = camNode
    }

    /// Draws both faces for the current 러그 그림, 색 and character, if any of them changed. True when it drew.
    @discardableResult
    private func retexture() -> Bool {
        let p = store.prefs
        let paint = Paint(face: p.face, color: p.color, look: p.face == .character ? SpriteLook(AppSettings.shared) : nil)
        guard paint != painted else { return false }
        painted = paint
        let art = paint.look.flatMap { look -> (image: NSImage, smooth: Bool)? in
            // 실사 is drawn from its photo, so it is made big enough for the sticker and drawn smooth; the rest at 1 so
            // pixel art keeps whole pixels (illustrations carry their full-size frame).
            guard look.custom?.styled(look.style).real != nil else { return RugArt.art(DogSpriteCache(look, pixelSize: 1)) }
            return RugArt.art(DogSpriteCache(look, pixelSize: 8)).map { ($0.image, true) }
        }
        front.diffuse.contents = RugArt.front(p.face, color: p.color, character: art)
        let underside = RugArt.back(p.face, color: p.color)
        back.diffuse.contents = underside
        back.emission.contents = underside
        return true
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

    /// The menu swallows the button's release: a cloth in the hand is let go first, so it never stays grabbed.
    private func showMenu(_ e: NSEvent) {
        clicks.cancel(at: NSEvent.mouseLocation).forEach(handle)
        FriendMenu.pop([
            FriendMenu.item(L("빳빳하게 펼치기")) { [weak self] in self?.smooth() },
            FriendMenu.item(L("러그를 화면 가운데로")) { [weak self] in self?.center() },
            FriendMenu.submenu(L("러그 그림"), RugFace.allCases.map { f in
                FriendMenu.item(f.label, on: store.prefs.face == f) { RugStore.shared.prefs.face = f }
            }),
            FriendMenu.submenu(L("러그 색"), FocusTheme.allCases.map { t in
                FriendMenu.item("\(t.emoji) \(t.label)", on: store.prefs.color == t) { RugStore.shared.prefs.color = t }
            }),
            FriendMenu.submenu(L("부드러움"), RugSoftness.allCases.map { s in
                FriendMenu.item(s.label, on: store.prefs.softness == s) { RugStore.shared.prefs.softness = s }
            }),
            .separator(),
            FriendMenu.item(L("러그 치우기")) { RugStore.shared.prefs.on = false },
        ], with: e, for: view)
        hover()   // the cursor may have left the cloth while the menu was up
    }
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

/// The rug's two faces, drawn in code (our own art; the character is the user's own pick, never bundled here).
/// 캐릭터: a pastel rug in 러그 색 with a rounded, stitched sticker border, small paws and hearts scattered about and
/// the chosen character big on a white sticker in the middle; its back the same colour, stitched. 무늬: a cream weave
/// with a terracotta border and a navy diamond; the back plain light grey with the border's stitching showing through.
enum RugArt {
    static let size = CGSize(width: 512, height: 352)

    static func front(_ face: RugFace, color: FocusTheme, character: (image: NSImage, smooth: Bool)?) -> NSImage {
        face == .pattern ? pattern : characterFace(color, character)
    }

    static func back(_ face: RugFace, color: FocusTheme) -> NSImage {
        guard face == .character else { return plainBack }
        let c = colors(color)
        return bitmap { r in
            c.band.setFill(); r.fill()
            stitch(r, NSColor(white: 1, alpha: 0.7))
        }
    }

    /// The first walking frame of `cache`'s character and whether it is an illustration (drawn smooth, not blocky).
    static func art(_ cache: DogSpriteCache) -> (image: NSImage, smooth: Bool)? {
        cache.frames(for: .walk).first.map { ($0, cache.smooth) }
    }

    private static func colors(_ t: FocusTheme) -> (base: NSColor, band: NSColor, accent: NSColor) {
        let h = t.hexes(dark: false), accent = RGBColor(hex: h.accent).nsColor
        return (RGBColor(hex: h.fill).nsColor, accent.blended(withFraction: 0.55, of: .white) ?? accent, accent)
    }

    private static func stitch(_ r: CGRect, _ color: NSColor) {
        color.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 14, dy: 14), xRadius: 50, yRadius: 50)
        p.lineWidth = 3
        p.setLineDash([10, 7], count: 2, phase: 0)
        p.stroke()
    }

    private static func characterFace(_ color: FocusTheme, _ character: (image: NSImage, smooth: Bool)?) -> NSImage {
        let c = colors(color)
        return bitmap { r in
            c.band.setFill(); r.fill()
            c.base.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 28, dy: 28), xRadius: 40, yRadius: 40).fill()
            stitch(r, NSColor(white: 1, alpha: 0.9))
            let sticker = CGRect(x: r.midX - 150, y: r.midY - 100, width: 300, height: 200)
            c.accent.withAlphaComponent(0.3).setFill()   // little paws and hearts around the sticker, on a centred grid
            let step: CGFloat = 28, field = r.insetBy(dx: 46, dy: 46)
            let cols = Int(field.width / step), rows = Int(field.height / step)
            for j in 0...rows { for i in 0...cols {
                let p = CGPoint(x: r.midX + (CGFloat(i) - CGFloat(cols) / 2) * step, y: r.midY + (CGFloat(j) - CGFloat(rows) / 2) * step)
                guard !sticker.insetBy(dx: -12, dy: -12).contains(p) else { continue }
                (i + j) % 2 == 0 ? heart(p, 7).fill() : paw(p, 7)
            } }
            let blob = NSBezierPath(roundedRect: sticker, xRadius: 70, yRadius: 70)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = c.accent.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -5)
            shadow.shadowBlurRadius = 6
            shadow.set()
            NSColor.white.setFill(); blob.fill()
            NSGraphicsContext.restoreGraphicsState()
            c.band.setStroke(); blob.lineWidth = 6; blob.stroke()
            if let character { draw(character, in: sticker.insetBy(dx: 24, dy: 18)) } else { c.accent.setFill(); heart(CGPoint(x: r.midX, y: r.midY), 60).fill() }
        }
    }

    /// The character as big as fits `box`, cropped to what is drawn. Pixel art keeps whole, square pixels.
    private static func draw(_ art: (image: NSImage, smooth: Bool), in box: CGRect) {
        let img = art.image, src = opaqueBounds(img)
        guard src.width > 0, src.height > 0 else { return }
        var k = min(box.width / src.width, box.height / src.height)
        if !art.smooth { k = max(1, (k * scale).rounded(.down)) / scale }   // whole device pixels per art pixel
        let w = src.width * k, h = src.height * k
        let dst = CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h)
        let interp: NSImageInterpolation = art.smooth ? .high : .none
        NSGraphicsContext.current?.imageInterpolation = interp
        img.draw(in: dst, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: interp.rawValue])
    }

    /// The part of `image` (in its points) that is not see-through. Pixel frames are measured at their own pixels.
    static func opaqueBounds(_ image: NSImage) -> CGRect {
        let k: CGFloat = 4, w = Int(image.size.width * k), h = Int(image.size.height * k)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .zero }
        var lo = (x: w, y: h), hi = (x: -1, y: -1)
        for row in 0..<h { for x in 0..<w where data[(row * w + x) * 4 + 3] > 8 {
            lo = (min(lo.x, x), min(lo.y, row)); hi = (max(hi.x, x), max(hi.y, row))
        } }
        guard hi.x >= 0 else { return .zero }
        // Memory rows run top down; points run bottom up.
        return CGRect(x: CGFloat(lo.x) / k, y: CGFloat(h - 1 - hi.y) / k, width: CGFloat(hi.x - lo.x + 1) / k, height: CGFloat(hi.y - lo.y + 1) / k)
    }

    private static func heart(_ c: CGPoint, _ s: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x, y: c.y - s))
        p.curve(to: CGPoint(x: c.x - s, y: c.y + s * 0.35), controlPoint1: CGPoint(x: c.x - s * 0.5, y: c.y - s * 0.5), controlPoint2: CGPoint(x: c.x - s, y: c.y - s * 0.1))
        p.curve(to: CGPoint(x: c.x, y: c.y + s * 0.45), controlPoint1: CGPoint(x: c.x - s, y: c.y + s * 1.1), controlPoint2: CGPoint(x: c.x - s * 0.15, y: c.y + s * 1.0))
        p.curve(to: CGPoint(x: c.x + s, y: c.y + s * 0.35), controlPoint1: CGPoint(x: c.x + s * 0.15, y: c.y + s * 1.0), controlPoint2: CGPoint(x: c.x + s, y: c.y + s * 1.1))
        p.curve(to: CGPoint(x: c.x, y: c.y - s), controlPoint1: CGPoint(x: c.x + s, y: c.y - s * 0.1), controlPoint2: CGPoint(x: c.x + s * 0.5, y: c.y - s * 0.5))
        p.close()
        return p
    }

    private static func paw(_ c: CGPoint, _ s: CGFloat) {
        NSBezierPath(ovalIn: CGRect(x: c.x - s * 0.6, y: c.y - s * 0.75, width: s * 1.2, height: s * 0.95)).fill()
        for (dx, dy) in [(-0.85, 0.15), (-0.32, 0.62), (0.32, 0.62), (0.85, 0.15)] {
            NSBezierPath(ovalIn: CGRect(x: c.x + s * dx - s * 0.24, y: c.y + s * dy - s * 0.2, width: s * 0.48, height: s * 0.56)).fill()
        }
    }

    /// Faces are drawn once into a bitmap at twice the size: the 3D cloth samples it, and pixel art stays crisp.
    /// Always in light: a character's frames carry a dark menu bar variant (lifted outline) that must not be printed.
    private static let scale: CGFloat = 2
    private static func bitmap(_ draw: (CGRect) -> Void) -> NSImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { draw(CGRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { NSImage(cgImage: $0, size: size) } ?? NSImage(size: size)
    }

    static let pattern: NSImage = NSImage(size: size, flipped: false) { r in
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

    static let plainBack: NSImage = NSImage(size: size, flipped: false) { r in
        NSColor(white: 0.86, alpha: 1).setFill(); r.fill()
        NSColor(white: 0.66, alpha: 1).setStroke()
        let stitch = NSBezierPath(rect: r.insetBy(dx: 22, dy: 22))
        stitch.lineWidth = 2.5
        stitch.setLineDash([9, 6], count: 2, phase: 0)
        stitch.stroke()
        return true
    }
}
