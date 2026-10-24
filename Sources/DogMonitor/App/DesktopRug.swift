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

/// 러그 그림: the chosen character printed big on a pastel rug, or one of the woven patterns, all in 러그 색.
/// Raw values are saved (`pattern` is the diamond weave, from before there were others). 하트, 별빛 and 무지개 are 후원 선물
/// (SponsorGifts).
enum RugFace: String, Codable, CaseIterable {
    case character, pattern, stripes, check, dots, hearts, stars, rainbow

    var label: String {
        switch self {
        case .character: return L("캐릭터")
        case .pattern: return L("마름모")
        case .stripes: return L("줄무늬")
        case .check: return L("체크")
        case .dots: return L("물방울")
        case .hearts: return L("하트")
        case .stars: return L("별빛")
        case .rainbow: return L("무지개")
        }
    }
}

/// 러그 크기: how far apart the cloth's points lie (the grid stays 16 by 11, so the physics feels the same).
enum RugSize: String, Codable, CaseIterable {
    case small, normal, large, huge

    var label: String {
        switch self {
        case .small: return L("작게")
        case .normal: return L("보통")
        case .large: return L("크게")
        case .huge: return L("아주 크게")
        }
    }

    /// ClothSheet's spacing: 보통 is the original 255 by 170 pt rug.
    var spacing: Double {
        switch self {
        case .small: return 12
        case .normal: return 17
        case .large: return 25
        case .huge: return 34
        }
    }
}

/// 러그 색 reuses the 위젯 색 pastels (the 꾸미기 colours).
extension FocusTheme: Codable {}

struct RugPrefs: Codable, Equatable {
    var on = false
    var softness = RugSoftness.normal
    var face = RugFace.character
    var color = FocusTheme.strawberry
    var size = RugSize.normal
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
        size = (try? c.decodeIfPresent(RugSize.self, forKey: .size)) ?? d.size
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
    private let view = SCNView(frame: .zero)
    /// Takes the clicks on the cloth.
    private let hot = HotspotPanel()
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
    private var started = false
    private var asleep = false
    private var still = DesktopKit.reduceMotion
    private var builtFor: (frame: CGRect, size: RugSize)?
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
        if builtFor?.frame != frame || builtFor?.size != store.prefs.size {
            if builtFor?.frame != frame {
                p.setFrame(frame, display: false)
                view.frame = CGRect(origin: .zero, size: frame.size)
                setUpScene(size: frame.size)
            }
            builtFor = (frame, store.prefs.size)
            smoothing = nil; lift = nil
            var c = ClothSheet(spacing: store.prefs.size.spacing, bend: store.prefs.softness.bend, walls: CGRect(origin: .zero, size: frame.size))
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
        render()
        wake()
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        smoothing = nil; lift = nil
        panel?.orderOut(nil)
        hot.hide()
    }

    private func makePanel() -> NSPanel {
        let p = RugPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        if Self.qaHidden { p.alphaValue = 0 }
        p.ignoresMouseEvents = true   // for good: the HotspotPanel over the cloth takes its clicks
        p.hidesOnDeactivate = false
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        hot.collectionBehavior = p.collectionBehavior
        hot.onMouse = { [weak self] in self?.mouse($0) }
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
        place(c)
    }

    /// The hotspot over the box round the cloth, shaped like the cloth seen from above.
    private func place(_ c: ClothSheet) {
        guard let panel, panel.isVisible, !c.points.isEmpty else { hot.hide(); return }
        let xs = c.points.map { CGFloat($0.x) }, ys = c.points.map { CGFloat($0.y) }
        let lo = CGPoint(x: floor(xs.min() ?? 0), y: floor(ys.min() ?? 0)), hi = CGPoint(x: ceil(xs.max() ?? 0), y: ceil(ys.max() ?? 0))
        let o = panel.frame.origin
        let shape = HotspotShape(outline: c.outline(offset: CGVector(dx: -lo.x, dy: -lo.y)))
        hot.place(CGRect(x: o.x + lo.x, y: o.y + lo.y, width: max(1, hi.x - lo.x), height: max(1, hi.y - lo.y)), shape, level: panel.level)
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
        if smoothing == nil, lift == nil, still || c.isSettled { timer?.invalidate(); timer = nil }
    }

    /// 빳빳하게 펼치기: eases every point back to the flat rug at its place in about a second, with a word from the character.
    func smooth() {
        guard let c = cloth, let size = builtFor?.frame.size else { return }
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
        guard var c = cloth, let size = builtFor?.frame.size else { return }
        c.place(ClothSheet.flatten(from: c.points, rest: c.rest, to: homeOrigin(c, in: size), progress: 1))
        cloth = c
        render()
    }

    // MARK: Mouse

    private func local(_ p: CGPoint) -> CGPoint {
        guard let o = panel?.frame.origin else { return p }
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    /// Every mouse event on the cloth's hotspot.
    private func mouse(_ e: NSEvent) {
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
        guard var c = cloth, let size = builtFor?.frame.size else { return }
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
            FriendMenu.submenu(L("러그 그림"), RugFace.offered(current: store.prefs.face).map { f in
                FriendMenu.item(f.label, on: store.prefs.face == f) { RugStore.shared.prefs.face = f }
            }),
            FriendMenu.submenu(L("러그 색"), FocusTheme.offered(current: store.prefs.color).map { t in
                FriendMenu.item("\(t.emoji) \(t.label)", on: store.prefs.color == t) { RugStore.shared.prefs.color = t }
            }),
            FriendMenu.submenu(L("러그 크기"), RugSize.allCases.map { s in
                FriendMenu.item(s.label, on: store.prefs.size == s) { RugStore.shared.prefs.size = s }
            }),
            FriendMenu.submenu(L("부드러움"), RugSoftness.allCases.map { s in
                FriendMenu.item(s.label, on: store.prefs.softness == s) { RugStore.shared.prefs.softness = s }
            }),
            .separator(),
            FriendMenu.item(L("러그 치우기")) { RugStore.shared.prefs.on = false },
        ], with: e, for: hot.contentView ?? view)
    }
}

/// Never key, never main: touching the rug never takes the focus from the app in front.
private final class RugPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The rug's two faces, drawn in code (our own art; the character is the user's own pick, never bundled here).
/// 캐릭터: a pastel rug in 러그 색 with a rounded, stitched sticker border, small paws and hearts scattered about and
/// the chosen character big on a white sticker in the middle. The woven ones (마름모, 줄무늬, 체크, 물방울) use the
/// same colours. Every back is the band colour, stitched.
enum RugArt {
    static let size = CGSize(width: 512, height: 352)

    static func front(_ face: RugFace, color: FocusTheme, character: (image: NSImage, smooth: Bool)?) -> NSImage {
        switch face {
        case .character: return characterFace(color, character)
        case .pattern: return diamonds(color)
        case .stripes: return stripes(color)
        case .check: return check(color)
        case .dots: return dots(color)
        case .hearts: return hearts(color)
        case .stars: return stars(color)
        case .rainbow: return rainbow(color)
        }
    }

    static func back(_ face: RugFace, color: FocusTheme) -> NSImage {
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

    private static func colors(_ t: FocusTheme) -> (base: NSColor, band: NSColor, accent: NSColor, ink: NSColor) {
        let h = t.hexes(dark: false), accent = RGBColor(hex: h.accent).nsColor
        return (RGBColor(hex: h.fill).nsColor, accent.blended(withFraction: 0.55, of: .white) ?? accent, accent, RGBColor(hex: h.ink).nsColor)
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

    /// 마름모: a pale weave with a wide accent border, a thin ink line inside it, a big diamond and rows of small ones.
    private static func diamonds(_ color: FocusTheme) -> NSImage {
        let c = colors(color)
        return bitmap { r in
            c.base.setFill(); r.fill()
            c.accent.setStroke()
            let border = NSBezierPath(rect: r.insetBy(dx: 22, dy: 22)); border.lineWidth = 18; border.stroke()
            c.ink.setStroke()
            let line = NSBezierPath(rect: r.insetBy(dx: 40, dy: 40)); line.lineWidth = 3; line.stroke()
            func diamond(_ m: CGPoint, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: m.x, y: m.y + h)); p.line(to: CGPoint(x: m.x + w, y: m.y))
                p.line(to: CGPoint(x: m.x, y: m.y - h)); p.line(to: CGPoint(x: m.x - w, y: m.y)); p.close()
                return p
            }
            let mid = CGPoint(x: r.midX, y: r.midY)
            c.ink.setFill(); diamond(mid, 110, 80).fill()
            c.accent.setFill(); diamond(mid, 70, 50).fill()
            c.base.setFill(); diamond(mid, 26, 18).fill()
            c.ink.setFill()
            for i in 0..<9 {   // a row of small diamonds inside the border, top and bottom
                let x = r.minX + 70 + CGFloat(i) * (r.width - 140) / 8
                diamond(CGPoint(x: x, y: r.minY + 62), 9, 9).fill()
                diamond(CGPoint(x: x, y: r.maxY - 62), 9, 9).fill()
            }
        }
    }

    /// A woven face: `weave` fills the field inside a solid accent border (clipped to it), then the stitching goes on top.
    private static func woven(_ color: FocusTheme, stitches: NSColor = NSColor(white: 1, alpha: 0.9),
                              _ weave: (CGRect, (base: NSColor, band: NSColor, accent: NSColor, ink: NSColor)) -> Void) -> NSImage {
        let c = colors(color)
        return bitmap { r in
            c.accent.setFill(); r.fill()
            let field = r.insetBy(dx: 12, dy: 12)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: field).addClip()
            weave(field, c)
            NSGraphicsContext.restoreGraphicsState()
            stitch(r, stitches)
        }
    }

    /// Evenly spaced positions across `span`, centred, `step` apart.
    private static func centred(_ lo: CGFloat, _ hi: CGFloat, step: CGFloat) -> [CGFloat] {
        let n = Int(((hi - lo) / step).rounded(.down)), start = (lo + hi) / 2 - CGFloat(n) * step / 2
        return (0...n).map { start + CGFloat($0) * step }
    }

    /// 줄무늬: wide band stripes across a pale ground, a thin accent line in each gap.
    private static func stripes(_ color: FocusTheme) -> NSImage {
        woven(color) { f, c in
            c.base.setFill(); f.fill()
            let step: CGFloat = 64
            for x in centred(f.minX, f.maxX, step: step) {
                c.band.setFill(); NSRect(x: x - 16, y: f.minY, width: 32, height: f.height).fill()
                c.accent.setFill(); NSRect(x: x + step / 2 - 2.5, y: f.minY, width: 5, height: f.height).fill()
            }
        }
    }

    /// 체크: gingham, see-through accent bands both ways so they deepen where they cross.
    private static func check(_ color: FocusTheme) -> NSImage {
        woven(color, stitches: NSColor(white: 1, alpha: 0.95)) { f, c in
            NSColor.white.setFill(); f.fill()
            c.accent.withAlphaComponent(0.32).setFill()
            let step: CGFloat = 44, band: CGFloat = 22
            for x in centred(f.minX, f.maxX, step: step) { NSRect(x: x - band / 2, y: f.minY, width: band, height: f.height).fill(using: .sourceOver) }
            for y in centred(f.minY, f.maxY, step: step) { NSRect(x: f.minX, y: y - band / 2, width: f.width, height: band).fill(using: .sourceOver) }
        }
    }

    /// 하트 (a 후원 선물): rows of accent hearts on the pale ground, every other row shifted and in the band colour.
    private static func hearts(_ color: FocusTheme) -> NSImage {
        woven(color) { f, c in
            c.base.setFill(); f.fill()
            let step: CGFloat = 46, inner = f.insetBy(dx: 30, dy: 30)
            for (j, y) in centred(inner.minY, inner.maxY, step: step).enumerated() {
                (j % 2 == 0 ? c.accent : c.band).setFill()
                for x in centred(inner.minX, inner.maxX, step: step) where j % 2 == 0 || x + step / 2 <= inner.maxX {
                    heart(CGPoint(x: j % 2 == 0 ? x : x + step / 2, y: y), 11).fill()
                }
            }
        }
    }

    /// 별빛 (a 후원 선물): a night field in the ink colour, five-point stars in accent and white, tiny dots between.
    private static func stars(_ color: FocusTheme) -> NSImage {
        woven(color) { f, c in
            c.ink.setFill(); f.fill()
            let step: CGFloat = 58, inner = f.insetBy(dx: 32, dy: 32)
            for (j, y) in centred(inner.minY, inner.maxY, step: step).enumerated() {
                for (i, x) in centred(inner.minX, inner.maxX, step: step).enumerated() {
                    let cx = x + (j % 2 == 0 ? 0 : step / 2)
                    guard cx <= inner.maxX else { continue }
                    ((i + j) % 2 == 0 ? NSColor.white : c.band).setFill()
                    star(CGPoint(x: cx, y: y), (i + j) % 3 == 0 ? 13 : 9).fill()
                    NSColor(white: 1, alpha: 0.55).setFill()
                    NSBezierPath(ovalIn: CGRect(x: cx + step / 2 - 2, y: y + step / 2 - 2, width: 4, height: 4)).fill()
                }
            }
        }
    }

    /// 무지개 (a 후원 선물): pastel arcs in every 위젯 색's accent over the pale ground, rising from the bottom middle.
    private static func rainbow(_ color: FocusTheme) -> NSImage {
        woven(color, stitches: RGBColor(hex: color.hexes(dark: false).accent).nsColor.withAlphaComponent(0.55)) { f, c in
            NSColor.white.setFill(); f.fill()
            let hub = CGPoint(x: f.midX, y: f.minY + 30), band: CGFloat = 22
            let accents = FocusTheme.allCases.map { RGBColor(hex: $0.hexes(dark: false).accent).nsColor }
            for (k, a) in accents.enumerated() {
                let r = min(f.width / 2 - 16, f.height - 46) - CGFloat(k) * band
                guard r > band else { break }
                let arc = NSBezierPath()
                arc.appendArc(withCenter: hub, radius: r - band / 2, startAngle: 0, endAngle: 180)
                arc.lineWidth = band
                (a.blended(withFraction: 0.35, of: .white) ?? a).setStroke()
                arc.stroke()
            }
            c.base.setFill()
            for dx in [-150, 150] as [CGFloat] {   // two little clouds at its feet
                for (ox, s) in [(-18, 20), (0, 26), (18, 20)] as [(CGFloat, CGFloat)] {
                    NSBezierPath(ovalIn: CGRect(x: hub.x + dx + ox - s, y: hub.y - 14, width: s * 2, height: s * 1.4)).fill()
                }
            }
        }
    }

    private static func star(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        for k in 0..<10 {
            let a = CGFloat.pi / 2 + CGFloat(k) * .pi / 5, len = k % 2 == 0 ? r : r * 0.45
            let q = CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len)
            if k == 0 { p.move(to: q) } else { p.line(to: q) }
        }
        p.close()
        return p
    }

    /// 물방울: white polka dots on the band colour, every other row shifted half a step, clear of the stitching.
    private static func dots(_ color: FocusTheme) -> NSImage {
        woven(color) { f, c in
            c.band.setFill(); f.fill()
            NSColor.white.setFill()
            let step: CGFloat = 40, d: CGFloat = 15, inner = f.insetBy(dx: 26, dy: 26)
            for (j, y) in centred(inner.minY, inner.maxY, step: step).enumerated() {
                for x in centred(inner.minX, inner.maxX, step: step) where j % 2 == 0 || x + step / 2 <= inner.maxX {
                    let cx = j % 2 == 0 ? x : x + step / 2
                    NSBezierPath(ovalIn: CGRect(x: cx - d / 2, y: y - d / 2, width: d, height: d)).fill()
                }
            }
        }
    }
}
