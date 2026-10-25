import AppKit
import Combine
import SceneKit
import UniformTypeIdentifiers

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
    case character, pattern, stripes, check, dots, hearts, stars, rainbow, photo

    var label: String {
        switch self {
        case .character: return L("캐릭터")
        case .photo: return L("내 이미지")
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

extension RugFace {
    /// The 그림 choices: GiftChoice's, and 내 이미지 only once a picture is saved (or while it is the 그림), so it is never
    /// a choice that silently prints the character instead.
    static func offered(current: RugFace?) -> [RugFace] { offered(current: current, hasPhoto: RugPhoto.stamp != nil) }

    static func offered(current: RugFace?, hasPhoto: Bool) -> [RugFace] {
        allCases.filter { $0 == current || ($0.isOffered && ($0 != .photo || hasPhoto)) }
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

/// 러그 모양: the plain rectangle, or cut out round the character (the one 캐릭터 그림 prints, the menu bar's) like a
/// character mat. Either way the cloth underneath is the same grid; the cut is the texture's alpha (RugMask).
enum RugShape: String, Codable, CaseIterable {
    case rect, character

    var label: String {
        switch self {
        case .rect: return L("네모")
        case .character: return L("캐릭터 모양")
        }
    }
}

/// 러그 질감: 기본 is the flat printed cloth from before; 리얼 a tufted pile rug (RugTuft) with a soft drop shadow.
/// Unset, 캐릭터 모양 is 리얼 and the rectangle 기본, so a rug from before looks as it did.
enum RugFinish: String, Codable, CaseIterable {
    case plain, real

    var label: String {
        switch self {
        case .plain: return L("기본")
        case .real: return L("리얼")
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
    var shape = RugShape.rect
    /// 러그 질감 as picked; nil follows the shape (`look`).
    var finish: RugFinish?
    /// 러그 캐릭터: an original or pack's id; nil follows the menu bar's character.
    var character: String?
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
        shape = (try? c.decodeIfPresent(RugShape.self, forKey: .shape)) ?? d.shape
        finish = try? c.decodeIfPresent(RugFinish.self, forKey: .finish)
        character = try? c.decodeIfPresent(String.self, forKey: .character)
    }

    /// The 질감 drawn: the one picked, else 리얼 for 캐릭터 모양.
    var look: RugFinish {
        get { finish ?? (shape == .character ? .real : .plain) }
        set { finish = newValue }
    }
}

/// What the rug's textures are drawn from: they are redrawn only when this changes (not for size, softness or place).
struct RugPaint: Equatable {
    var face: RugFace, color: FocusTheme, shape: RugShape, finish: RugFinish, look: SpriteLook?, photo: Date?

    init(_ p: RugPrefs, look: SpriteLook?, photo: Date?) {
        face = p.face; color = p.color; shape = p.shape; finish = p.look
        let wantsArt = p.face == .character || p.face == .photo || p.shape == .character
        self.look = wantsArt ? look : nil
        self.photo = p.face == .photo ? photo : nil
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

    /// 내 이미지로 러그: picks a picture from this Mac, saves it (RugPhoto, off the main thread: decoding and 배경 제거
    /// take a moment) and prints it. `done` gets the problem's message, or nil, on the main thread.
    static func pickPhoto(_ done: @escaping (String?) -> Void = { _ in }) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("러그에 넣을 사진이나 PNG를 골라 주세요")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return done(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = RugPhoto.save(from: url)
            DispatchQueue.main.async {
                if problem == nil {
                    shared.prefs.face = .photo
                    shared.objectWillChange.send()   // the same 그림 with a new picture still reprints
                }
                done(problem?.message)
            }
        }
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
    /// The shadows' mesh: the drawn one with a ring round it, into the shadow textures' padding.
    private var shadowMesh: (uv: SCNGeometrySource, element: SCNGeometryElement)?
    private let front = SCNMaterial(), back = SCNMaterial(), contact = SCNMaterial(), wide = SCNMaterial()
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
    private var painted: RugPaint?
    /// 리얼's shadows: the cloth again, flat on the desk under it, through prebaked blurred textures. `shadow` is the
    /// tight contact one, its child the wide soft one pushed away by how high the cloth is lifted.
    private let shadow = SCNNode()
    /// Bumped for every new picture: a texture built off the main thread for an older one is dropped.
    private var paintJob = 0
    /// The shadow textures are on (a 리얼 rug finished building).
    private var shadowsReady = false
    /// Frames drawn since the hotspot was last reshaped (it follows the cloth a few times a second, not every frame).
    private var sinceHot = 0
    /// 캐릭터 모양's cut-out, nil for the rectangle (or a character with nothing drawn).
    private var mask: RugMask?

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
        // 캐릭터 모양: only the points on the mat, so nobody sits on the see-through corners.
        let on = mask.map { m in c.points.indices.filter { m.covers(u: c.rest[$0].x / Double(c.size.width), v: c.rest[$0].y / Double(c.size.height)) }.map { c.points[$0] } }
        let pts = on?.isEmpty == false ? on! : c.points
        let xs = pts.map { CGFloat($0.x) }, ys = pts.map { CGFloat($0.y) }
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
            (texcoords, elements) = Self.mesh(c)
            shadowMesh = Self.shadowMesh(c)
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
        let (scene, camNode) = Self.scene(size: size, node: node, shadow: shadow, materials: [front, back, contact, wide])
        Self.light(scene, real: painted?.finish == .real)
        view.scene = scene
        view.pointOfView = camNode
    }

    /// The scene and its camera (static so the QA renders draw the very same rug).
    /// `materials`: the front, the back, the contact shadow's and the wide shadow's.
    static func scene(size: CGSize, node: SCNNode, shadow: SCNNode, materials: [SCNMaterial]) -> (SCNScene, SCNNode) {
        let front = materials[0], back = materials[1]
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
        sun.name = "sun"
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.eulerAngles = SCNVector3(0.45, -0.35, 0)
        scene.rootNode.addChildNode(sun)
        let fill = SCNNode()
        fill.name = "fill"
        fill.light = SCNLight()
        fill.light?.type = .ambient
        scene.rootNode.addChildNode(fill)
        light(scene, real: false)
        front.lightingModel = .lambert
        front.cullMode = .back
        back.lightingModel = .lambert
        back.cullMode = .front
        // 리얼's shadows: black through a prebaked blurred alpha (no per-frame blur pass), under the cloth.
        for (k, m) in materials[2...].enumerated() {
            m.lightingModel = .constant
            m.diffuse.contents = NSColor.black
            m.transparencyMode = .aOne
            m.transparency = k == 0 ? 0.42 : 0.22
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
        }
        shadow.renderingOrder = -1
        let far = shadow.childNodes.first ?? SCNNode()
        far.renderingOrder = -2
        if far.parent == nil { shadow.addChildNode(far) }
        for n in [shadow, node] { n.removeFromParentNode(); scene.rootNode.addChildNode(n) }
        return (scene, camNode)
    }

    /// The light for the finish: 기본 keeps its soft, even light; 리얼 less ambient and more sun, so folds show.
    static func light(_ scene: SCNScene?, real: Bool) {
        scene?.rootNode.childNode(withName: "sun", recursively: false)?.light?.intensity = real ? 900 : 800
        scene?.rootNode.childNode(withName: "fill", recursively: false)?.light?.intensity = real ? 240 : 450
    }

    /// The drawn mesh is the cloth's grid split this many times each way along smooth curves, so a fold bends round
    /// instead of in 16 by 11 flat facets (the physics stays on the coarse grid).
    static let split = 3

    /// The flat rug's texture coordinates and the triangles, one element per face (on the split grid).
    static func mesh(_ c: ClothSheet) -> (SCNGeometrySource, [SCNGeometryElement]) {
        let cols = (c.cols - 1) * split + 1, rows = (c.rows - 1) * split + 1
        var uv: [CGPoint] = []
        for y in 0..<rows { for x in 0..<cols { uv.append(CGPoint(x: Double(x) / Double(cols - 1), y: 1 - Double(y) / Double(rows - 1))) } }
        var t: [Int32] = []
        for y in 0..<(rows - 1) { for x in 0..<(cols - 1) {
            let i = Int32(y * cols + x), w = Int32(cols)
            t += [i, i + 1, i + w + 1, i, i + w + 1, i + w]
        } }
        return (SCNGeometrySource(textureCoordinates: uv), (0..<2).map { _ in SCNGeometryElement(indices: t, primitiveType: .triangles) })
    }

    /// The cloth's points on the split grid: Catmull-Rom through the points, along the rows and then the columns.
    static func dense(_ c: ClothSheet) -> (points: [ClothSheet.P], cols: Int, rows: Int) {
        func spline(_ p: [ClothSheet.P]) -> [ClothSheet.P] {
            var out: [ClothSheet.P] = []
            for i in 0..<(p.count - 1) {
                let a = p[max(0, i - 1)], b = p[i], c = p[i + 1], d = p[min(p.count - 1, i + 2)]
                for k in 0..<split {
                    let t = Double(k) / Double(split), t2 = t * t, t3 = t2 * t
                    let k1: ClothSheet.P = (c - a) * t, k2: ClothSheet.P = (2 * a - 5 * b + 4 * c - d) * t2
                    let k3: ClothSheet.P = (3 * b - a - 3 * c + d) * t3
                    out.append(0.5 * (2 * b + k1 + k2 + k3))
                }
            }
            return out + [p[p.count - 1]]
        }
        let cols = (c.cols - 1) * split + 1, rows = (c.rows - 1) * split + 1
        let across = (0..<c.rows).map { y in spline(Array(c.points[(y * c.cols)..<((y + 1) * c.cols)])) }
        var grid = [ClothSheet.P](repeating: .zero, count: cols * rows)
        for x in 0..<cols {
            for (y, p) in spline(across.map { $0[x] }).enumerated() { grid[y * cols + x] = p }
        }
        return (grid, cols, rows)
    }

    /// The shadows' texture coordinates and triangles: the split grid plus a ring one step outside it, reaching into
    /// the shadow textures' `RugTuft.pad` so the blur fades out past the rug's edge instead of being cut there.
    static func shadowMesh(_ c: ClothSheet) -> (uv: SCNGeometrySource, element: SCNGeometryElement) {
        let cols = (c.cols - 1) * split + 1, rows = (c.rows - 1) * split + 1, gc = cols + 2, gr = rows + 2
        let tw = Double(RugArt.size.width * 2), th = Double(RugArt.size.height * 2), p = Double(RugTuft.pad)
        func at(_ i: Int, _ n: Int, _ pad: Double) -> Double { i == 0 ? -pad : i == n + 1 ? 1 + pad : Double(i - 1) / Double(n - 1) }
        var uv: [CGPoint] = []
        for y in 0..<gr { for x in 0..<gc {
            let u = at(x, cols, p / tw), t = at(y, rows, p / th)
            uv.append(CGPoint(x: (u * tw + p) / (tw + 2 * p), y: ((1 - t) * th + p) / (th + 2 * p)))
        } }
        var t: [Int32] = []
        for y in 0..<(gr - 1) { for x in 0..<(gc - 1) {
            let i = Int32(y * gc + x), w = Int32(gc)
            t += [i, i + 1, i + w + 1, i, i + w + 1, i + w]
        } }
        return (SCNGeometrySource(textureCoordinates: uv), SCNGeometryElement(indices: t, primitiveType: .triangles))
    }

    /// The cloth as it lies now, from its drawn points (`dense`). With `shadow` (its mesh and the two materials), the
    /// shadows too: flat on the desk below, the contact one just off the cloth, the wide one pushed further from the light
    /// the higher each bit is lifted.
    static func geometry(_ d: (points: [ClothSheet.P], cols: Int, rows: Int), texcoords: SCNGeometrySource, elements: [SCNGeometryElement],
                         materials: [SCNMaterial], rest: CGSize,
                         shadow: (mesh: (uv: SCNGeometrySource, element: SCNGeometryElement), contact: SCNMaterial, wide: SCNMaterial)? = nil)
        -> (cloth: SCNGeometry, contact: SCNGeometry?, wide: SCNGeometry?) {
        let (pts, cols, rows) = d
        let normals = pts.indices.map { i -> ClothSheet.P in
            let x = i % cols, y = i / cols
            let tx = pts[y * cols + min(cols - 1, x + 1)] - pts[y * cols + max(0, x - 1)]
            let ty = pts[min(rows - 1, y + 1) * cols + x] - pts[max(0, y - 1) * cols + x]
            let n = simd_cross(tx, ty), l = simd_length(n)
            return l > 1e-9 ? n / l : ClothSheet.P(0, 0, 1)
        }
        // ponytail: a face-down fold sits a hair higher so it never flickers against the cloth under it (no
        // self-collision); eased in with how far it faces down, so the crease has no step where the normal flips.
        let verts = zip(pts, normals).map { p, n in SCNVector3(p.x, p.y, max(0, p.z) + 1.5 * min(1, max(0, -n.z * 3))) }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }), texcoords],
                            elements: elements)
        g.materials = materials
        guard let shadow else { return (g, nil, nil) }
        // The ring: each edge point pushed out along the cloth by the padding's width.
        let gc = cols + 2, gr = rows + 2
        let padX = Double(RugTuft.pad) / Double(RugArt.size.width * 2) * Double(rest.width)
        let padY = Double(RugTuft.pad) / Double(RugArt.size.height * 2) * Double(rest.height)
        var ring = [ClothSheet.P](repeating: .zero, count: gc * gr)
        func unit(_ v: ClothSheet.P) -> ClothSheet.P { let f = ClothSheet.P(v.x, v.y, 0), l = simd_length(f); return l > 1e-9 ? f / l : .zero }
        for y in 0..<gr { for x in 0..<gc {
            let ix = min(cols - 1, max(0, x - 1)), iy = min(rows - 1, max(0, y - 1)), p = pts[iy * cols + ix]
            var q = p
            if x == 0 { q += unit(p - pts[iy * cols + 1]) * padX }
            if x == gc - 1 { q += unit(p - pts[iy * cols + cols - 2]) * padX }
            if y == 0 { q += unit(p - pts[cols + ix]) * padY }
            if y == gr - 1 { q += unit(p - pts[(rows - 2) * cols + ix]) * padY }
            ring[y * gc + x] = q
        } }
        func flat(_ k: Double, _ dx: Double, _ dy: Double, _ z: Double, _ m: SCNMaterial) -> SCNGeometry {
            let v = ring.map { p in SCNVector3(p.x + dx + 0.3 * k * max(0, p.z), p.y + dy - 0.45 * k * max(0, p.z), z) }
            let s = SCNGeometry(sources: [SCNGeometrySource(vertices: v), shadow.mesh.uv], elements: [shadow.mesh.element])
            s.materials = [m]
            return s
        }
        return (g, flat(0.15, 0.6, -1.2, -4, shadow.contact), flat(1, 2, -4, -5, shadow.wide))
    }

    /// Draws both faces for the current 러그 그림, 색 and character, if any of them changed. True when it drew now;
    /// 리얼 is built off the main thread (a tenth of a second or so) and put on when it is done, the old faces staying
    /// till then.
    @discardableResult
    private func retexture() -> Bool {
        let p = store.prefs
        // The photo's file is looked at only while it is the 그림.
        let paint = RugPaint(p, look: RugArt.look(AppSettings.shared, pick: p.character), photo: p.face == .photo ? RugPhoto.stamp : nil)
        guard paint != painted else { return false }
        painted = paint
        paintJob += 1
        let job = paintJob, real = paint.finish == .real
        Self.light(view.scene, real: real)
        // The character's frames are read here, on the main thread, like everywhere else.
        let art = Self.art(paint)
        guard real else {
            mask = p.shape == .character ? art.flatMap { RugArt.mask($0, grow: 3) } : nil
            shadowsReady = false
            Self.dress([front, back, contact, wide], RugArt.plain(p.face, color: p.color, character: art, mask: mask), real: false, cut: mask != nil)
            return true
        }
        let face = p.face, color = p.color, shaped = p.shape == .character
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mask = shaped ? art.flatMap { RugArt.mask($0, grow: RugArt.realGrow) } : nil
            let faces = RugArt.real(face, color: color, character: art, mask: mask)
            DispatchQueue.main.async {
                guard let self, job == self.paintJob else { return }
                self.mask = mask
                self.shadowsReady = faces.contact != nil
                Self.dress([self.front, self.back, self.contact, self.wide], faces, real: true, cut: mask != nil)
                self.render()
            }
        }
        return false
    }

    /// What `paint` prints: 내 이미지's saved picture (the character when there is none yet), else the character. 리얼
    /// takes the character in 일러스트 (pixel art smoothed into a drawing) at 8x, so the pile prints curves, not blocks;
    /// an illustrated (HD) pack gives its own full-size frame, like a photo.
    static func art(_ paint: RugPaint) -> (image: NSImage, smooth: Bool)? {
        if paint.photo != nil, let photo = RugPhoto.load() { return (photo, true) }
        guard var look = paint.look else { return nil }
        // 실사 is drawn from its photo, so it is made big enough and drawn smooth; the rest at 1 so pixel art keeps whole
        // pixels (illustrations carry their full-size frame).
        if look.custom?.styled(look.style).real != nil { return RugArt.art(DogSpriteCache(look, pixelSize: 8)).map { ($0.image, true) } }
        guard paint.finish == .real else { return RugArt.art(DogSpriteCache(look, pixelSize: 1)) }
        look.style = .illustration
        // ponytail: the full-size frame skips 옷 입히기 (drawn on a 68 x 40 grid it would blur the art); dress it here if wanted.
        if let ready = look.ready, ready.smooth, let full = RugArt.full(ready) { return full }
        return RugArt.art(DogSpriteCache(look, pixelSize: 8))
    }

    /// Puts the faces on the materials (front, back, the two shadows'). `cut`: 캐릭터 모양, whose see-through part is
    /// not there at all (discarded, so it never hides cloth folded under it); the rectangle keeps early depth testing.
    static func dress(_ m: [SCNMaterial], _ faces: RugFaces, real: Bool, cut: Bool) {
        m[0].diffuse.contents = faces.front
        m[1].diffuse.contents = faces.back
        // 기본: the face-down side is lit from behind its normals, so it glows its own colour. 리얼 turns its normals
        // over instead, so the fold's back is lit like the front and darkens toward the crease.
        m[1].emission.contents = real ? NSColor.black : faces.back
        m[1].emission.intensity = 0.55
        let discard: [SCNShaderModifierEntryPoint: String] = cut ? [.fragment: "if (_output.color.a < 0.5) { discard_fragment(); }"] : [:]
        m[0].shaderModifiers = discard.isEmpty ? nil : discard
        var under = discard
        if real { under[.surface] = "_surface.normal = -_surface.normal;" }
        m[1].shaderModifiers = under.isEmpty ? nil : under
        m[2].transparent.contents = faces.contact
        m[3].transparent.contents = faces.wide
        // 리얼: a faint, wide sheen on the pile as the folds turn to the light.
        m[0].lightingModel = real ? .blinn : .lambert
        m[0].specular.contents = NSColor(white: real ? 0.1 : 0, alpha: 1)
        m[0].shininess = 0.12
    }

    private func homeOrigin(_ c: ClothSheet, in size: CGSize) -> CGPoint {
        let h = store.prefs.home
        return CGPoint(x: min(max(0, size.width * h.x - c.size.width / 2), size.width - c.size.width),
                       y: min(max(0, size.height * h.y - c.size.height / 2), size.height - c.size.height))
    }

    // MARK: Drawing and ticking

    /// Draws the cloth as it lies. `hot`: reshape the hotspot too (left out while a hand holds the cloth, since the
    /// press stays with the hotspot anyway, and on most animation frames).
    private func render(hot reshape: Bool = true) {
        guard let c = cloth, let texcoords else { return }
        let d = Self.dense(c)
        let g = Self.geometry(d, texcoords: texcoords, elements: elements, materials: [front, back], rest: c.size,
                              shadow: shadowsReady && painted?.finish == .real ? shadowMesh.map { ($0, contact, wide) } : nil)
        node.geometry = g.cloth
        shadow.geometry = g.contact
        shadow.childNodes.first?.geometry = g.wide
        sinceHot += 1
        if reshape { place(d); sinceHot = 0 }
    }

    /// The hotspot over the box round the cloth, shaped like the drawn cloth (or 캐릭터 모양's mat on it) seen from above:
    /// the same smooth mesh that is drawn, so a click near a fold lands where the rug shows.
    private func place(_ d: (points: [ClothSheet.P], cols: Int, rows: Int)) {
        guard let panel, panel.isVisible, !d.points.isEmpty else { hot.hide(); return }
        let xs = d.points.map { CGFloat($0.x) }, ys = d.points.map { CGFloat($0.y) }
        let lo = CGPoint(x: floor(xs.min() ?? 0), y: floor(ys.min() ?? 0)), hi = CGPoint(x: ceil(xs.max() ?? 0), y: ceil(ys.max() ?? 0))
        let o = panel.frame.origin
        let off = CGVector(dx: -lo.x, dy: -lo.y)
        let shape = HotspotShape(outline: RugMask.outline(mask, d, split: 2, offset: off))
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
        let done = smoothing == nil && lift == nil && (still || c.isSettled)
        render(hot: c.held == nil && (done || sinceHot >= 8))
        if done { timer?.invalidate(); timer = nil }
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
        render(hot: c.held == nil)
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
            FriendMenu.submenu(L("러그 캐릭터"), RugArt.characterChoices().map { c in
                FriendMenu.item(c.name, on: store.prefs.character == c.id) { RugStore.shared.prefs.character = c.id }
            }),
            FriendMenu.submenu(L("러그 색"), FocusTheme.offered(current: store.prefs.color).map { t in
                FriendMenu.item("\(t.emoji) \(t.label)", on: store.prefs.color == t) { RugStore.shared.prefs.color = t }
            }),
            FriendMenu.submenu(L("러그 모양"), RugShape.allCases.map { s in
                FriendMenu.item(s.label, on: store.prefs.shape == s) { RugStore.shared.prefs.shape = s }
            }),
            FriendMenu.submenu(L("러그 질감"), RugFinish.allCases.map { f in
                FriendMenu.item(f.label, on: store.prefs.look == f) { RugStore.shared.prefs.look = f }
            }),
            FriendMenu.item(L("내 이미지로 러그…")) { RugStore.pickPhoto() },
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

/// A rug's two faces and, for 리얼, its prebaked shadows (alpha, `RugTuft.pad` wider on every side).
struct RugFaces {
    var front: NSImage, back: NSImage
    var contact: CGImage? = nil, wide: CGImage? = nil
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

    static func front(_ face: RugFace, color: FocusTheme, character: (image: NSImage, smooth: Bool)?, mask: RugMask? = nil) -> NSImage {
        guard let mask else { return front(face, color: color, character: character) }
        // 캐릭터 모양: 캐릭터 is the character big on the plain mat; a pattern is woven only inside the cut.
        let picture = face == .character || face == .photo ? characterMat(color, character) : front(face, color: color, character: character)
        return cut(picture, mask, rim: colors(color).ink, lip: true)
    }

    /// 기본's faces, exactly as before 리얼 (no shadows).
    static func plain(_ face: RugFace, color: FocusTheme, character: (image: NSImage, smooth: Bool)?, mask: RugMask?) -> RugFaces {
        RugFaces(front: front(face, color: color, character: character, mask: mask), back: back(face, color: color, mask: mask))
    }

    /// 리얼's faces: the same picture tufted (RugTuft). On 캐릭터 모양 the character alone is the art (no mat behind it),
    /// so the yarn outline hugs the drawing and the fur fills the cut round it; the rectangle gets a bound fur edge.
    static func real(_ face: RugFace, color: FocusTheme, character: (image: NSImage, smooth: Bool)?, mask: RugMask?) -> RugFaces {
        let picture = mask != nil && (face == .character || face == .photo) ? characterMat(color, character, ground: false)
            : front(face, color: color, character: character)
        guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let f = RugTuft.faces(cg, mask: mask, rim: true, soft: pixel(character, onMat: mask != nil))
        else { return plain(face, color: color, character: character, mask: mask) }
        return RugFaces(front: NSImage(cgImage: f.front, size: size), back: NSImage(cgImage: f.back, size: size), contact: f.contact, wide: f.wide)
    }

    private static func front(_ face: RugFace, color: FocusTheme, character: (image: NSImage, smooth: Bool)?) -> NSImage {
        switch face {
        case .character, .photo: return characterFace(color, character)
        case .pattern: return diamonds(color)
        case .stripes: return stripes(color)
        case .check: return check(color)
        case .dots: return dots(color)
        case .hearts: return hearts(color)
        case .stars: return stars(color)
        case .rainbow: return rainbow(color)
        }
    }

    static func back(_ face: RugFace, color: FocusTheme, mask: RugMask? = nil) -> NSImage {
        let c = colors(color)
        let plain = bitmap { r in
            c.band.setFill(); r.fill()
            if mask == nil { stitch(r, NSColor(white: 1, alpha: 0.7)) }
        }
        return mask.map { cut(plain, $0, rim: c.ink, lip: false) } ?? plain
    }

    // MARK: 캐릭터 모양

    /// The mask grid: one cell per 4 points of the face.
    static let maskCell: CGFloat = 4
    /// The character sits this far inside the face, room for the mat to grow round it.
    private static let matMargin: CGFloat = 26

    /// Where the character is drawn on a 캐릭터 모양 face (the mask is cut round the very same pixels).
    private static func matBox() -> CGRect { CGRect(origin: .zero, size: size).insetBy(dx: matMargin, dy: matMargin) }

    /// How many mask cells 리얼's mat reaches past the character: room for its yarn outline and fur rim (RugTuft's
    /// line + fur, 31 texture pixels, plus what softening the mat's corners takes back: 5 cells of 8).
    static let realGrow = 5

    /// One art pixel of `art` as drawn on the face, in texture pixels; 0 for a smooth picture, 2 for the patterns.
    static func pixel(_ art: (image: NSImage, smooth: Bool)?, onMat: Bool) -> Int {
        guard let art else { return 2 }
        guard !art.smooth else { return 0 }
        let box = onMat ? matBox() : CGRect(x: size.width / 2 - 126, y: size.height / 2 - 82, width: 252, height: 164)   // characterFace's
        guard let (src, dst) = fit(art, in: box) else { return 2 }
        return Int((dst.width / src.width * scale).rounded())
    }

    /// The mat cut round `art`'s first frame as it is drawn on the face, `grow` cells past it; nil when nothing is drawn.
    static func mask(_ art: (image: NSImage, smooth: Bool), grow: Int = 3) -> RugMask? {
        guard let (src, dst) = fit(art, in: matBox()) else { return nil }
        let w = Int(size.width / maskCell), h = Int(size.height / maskCell)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: 1 / maskCell, y: 1 / maskCell)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = art.smooth ? .high : .none
        art.image.draw(in: dst, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Memory rows run top down; the mask's run bottom up.
        let on = (0..<(w * h)).map { i in data[((h - 1 - i / w) * w + i % w) * 4 + 3] > 127 }
        // One art pixel in cells: a pixel character's 1 px tail is that wide; an illustration's fine lines about two.
        let pixel = art.smooth ? 2 : Int((dst.width / src.width / maskCell).rounded())
        let m = RugMask(silhouette: on, cols: w, rows: h, grow: grow, thin: max(2, pixel))
        return m.isEmpty ? nil : m
    }

    /// 캐릭터 그림 on a 캐릭터 모양 rug: the character big on the pale mat (`ground`), or alone (리얼's art).
    private static func characterMat(_ color: FocusTheme, _ character: (image: NSImage, smooth: Bool)?, ground: Bool = true) -> NSImage {
        let c = colors(color)
        return bitmap { r in
            if ground || character == nil { c.base.setFill(); r.fill() }
            if let character { draw(character, in: matBox()) }
        }
    }

    /// `picture` cut to `mask`: see-through outside, a dark rim round the edge and, on the front, a shaded lip along
    /// the bottom inside it, so the mat reads as a thick cut-out lying on the desk.
    private static func cut(_ picture: NSImage, _ mask: RugMask, rim: NSColor, lip: Bool) -> NSImage {
        guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return picture }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return picture }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ink = rim.usingColorSpace(.deviceRGB) ?? rim
        let rc = [ink.redComponent, ink.greenComponent, ink.blueComponent].map { Float($0) * 0.8 * 255 }
        func edge(_ v: Float) -> Float { let t = min(1, max(0, (v - 0.4) / 0.2)); return t * t * (3 - 2 * t) }
        let drop = 7 / Double(size.height)   // the lip: 7 points of the face
        for row in 0..<h {
            let v = 1 - (Double(row) + 0.5) / Double(h)
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w), i = (row * w + x) * 4
                let outer = edge(mask.value(u: u, v: v))
                guard outer > 0 else { for k in 0..<4 { data[i + k] = 0 }; continue }
                let inside = min(outer, edge(mask.value(u: u, v: v, inner: true)))
                let shade = lip ? 1 - 0.22 * inside * (1 - edge(mask.value(u: u, v: v - drop, inner: true))) : 1
                for k in 0..<3 { data[i + k] = UInt8(min(255, Float(data[i + k]) * shade * inside + rc[k] * (outer - inside))) }
                data[i + 3] = UInt8(min(255, Float(data[i + 3]) * inside + 255 * (outer - inside)))
            }
        }
        return ctx.makeImage().map { NSImage(cgImage: $0, size: picture.size) } ?? picture
    }

    /// The first walking frame of `cache`'s character and whether it is an illustration (drawn smooth, not blocky).
    static func art(_ cache: DogSpriteCache) -> (image: NSImage, smooth: Bool)? {
        cache.frames(for: .walk).first.map { ($0, cache.smooth) }
    }

    /// The poses that stand best on a rug, calmest first.
    static let poses: [DogPose] = [.slowWalk, .walk]

    /// An illustrated character's representative frame at its own full size (an HD pack's 272 x 160, not the bar's 34 x
    /// 20 copy), as a smooth picture; nil when it has none drawn.
    static func full(_ character: any AnimatedCharacter) -> (image: NSImage, smooth: Bool)? {
        let frames = poses.lazy.compactMap { character.frames(for: $0).first }
        for frame in frames {
            let reps = frame.representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
            if let cg = reps.max(by: { $0.width < $1.width }), opaqueBounds(frame).width > 0 {
                return (NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)), true)
            }
        }
        return nil
    }

    /// 러그 캐릭터's menu: 지금 캐릭터 (nil), then the user's packs (an HD pair once, by its dot half's id).
    static func characterChoices() -> [(id: String?, name: String)] {
        var seen = Set<String>()
        let packs = OriginalCatalog.all.compactMap { $0 as? CharacterPack }.compactMap { p -> (id: String?, name: String)? in
            let id = RenderStyle.listed(p.id, has: RenderStyle.hasOriginal)
            guard seen.insert(id).inserted else { return nil }
            return (id, OriginalCatalog.character(id)?.displayName ?? p.displayName)
        }
        return [(nil, L("지금 캐릭터"))] + packs
    }

    /// The look the rug prints: the menu bar's, or the picked original or pack (plain, its 일러스트 half when 리얼).
    /// A pick that is gone (a pack removed) follows the menu bar again.
    static func look(_ settings: AppSettings, pick: String?) -> SpriteLook {
        var look = SpriteLook(settings)
        guard let pick, OriginalCatalog.character(pick) != nil else { return look }
        look.custom = nil; look.character = .original; look.readyID = pick
        look.colors = nil; look.cat = nil; look.outfit = nil
        return look
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
        guard let (src, dst) = fit(art, in: box) else { return }
        let interp: NSImageInterpolation = art.smooth ? .high : .none
        NSGraphicsContext.current?.imageInterpolation = interp
        art.image.draw(in: dst, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: interp.rawValue])
    }

    /// What of the frame is drawn (`src`) and where (`dst`) for `draw`.
    private static func fit(_ art: (image: NSImage, smooth: Bool), in box: CGRect) -> (src: CGRect, dst: CGRect)? {
        let src = opaqueBounds(art.image)
        guard src.width > 0, src.height > 0 else { return nil }
        var k = min(box.width / src.width, box.height / src.height)
        if !art.smooth { k = max(1, (k * scale).rounded(.down)) / scale }   // whole device pixels per art pixel
        let w = src.width * k, h = src.height * k
        return (src, CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h))
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
