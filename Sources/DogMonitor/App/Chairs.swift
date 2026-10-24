import AppKit
import SwiftUI

// 의자: a chair on the desktop for my character, in code pixels. Right-click it (or the 커서 친구) to sit or get up;
// sitting, my character leaves the cursor for the chair and friends see me on the same chair in their 친구 상주 (only
// the chair's id travels, in FriendLook.seat; their Mac draws its own copy). The 나무 의자 is everyone's, the others come
// from a 시즌 뽑기판. Keys: chair.id (none = nothing out, nothing runs), chair.sitting, chair.x. Pure parts in ChairTests.

/// One chair: rows of pixels (top first, '.' empty), where the sitter goes and which rows are drawn in front of it.
struct ChairArt: Equatable {
    let id: String
    let name: String
    let rows: [String]
    let colors: [Character: PixelColor]
    /// The row the sitter's lowest pixels go on.
    let seatRow: Int
    /// This row and the ones under it are drawn over the sitter (the seat's front, arms, a bean bag's bulge).
    let frontFrom: Int
    /// From a 시즌 뽑기판 (SeasonCatalog); the others are everyone's.
    let season: Bool

    var width: Int { rows.first?.count ?? 0 }
    var height: Int { rows.count }

    /// The view's size and the top-left corners (y down) of the chair and of a `sprite`-sized sitter in it, at `px`
    /// points a pixel. A sitter taller than the chair above its seat makes the view taller.
    func layout(sprite: CGSize, px: CGFloat) -> (size: CGSize, chair: CGPoint, sitter: CGPoint) {
        let cw = CGFloat(width) * px, ch = CGFloat(height) * px
        let top = CGFloat(seatRow + 1) * px - sprite.height
        let lift = max(0, -top), w = max(cw, sprite.width)
        return (CGSize(width: w, height: ch + lift), CGPoint(x: ((w - cw) / 2).rounded(), y: lift),
                CGPoint(x: ((w - sprite.width) / 2).rounded(), y: top + lift))
    }
}

enum ChairCatalog {
    private static let ink = PixelColor(hex: "#3B2A20")

    static let all: [ChairArt] = [
        ChairArt(id: "chair-wood", name: L("나무 의자"), rows: [
            "....KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK....",
            "...KWWLLLLLLLLLLLLLLLLLLLLLLLLLLLLWWK...",
            "...KWWLLLLLLLLLLLLLLLLLLLLLLLLLLLLWWK...",
            "...KWWDDDDDDDDDDDDDDDDDDDDDDDDDDDDWWK...",
            "...KWWWWKKKKWWKKKKWWKKKKWWKKKKWWKKWWK...",
            "...KWWWWK..KWWK..KWWK..KWWK..KWWKKWWK...",
            "...KWWWWK..KWWK..KWWK..KWWK..KWWKKWWK...",
            "...KWWWWK..KWWK..KWWK..KWWK..KWWKKWWK...",
            "...KWWWWK..KWWK..KWWK..KWWK..KWWKKWWK...",
            "...KWWWWK..KWWK..KWWK..KWWK..KWWKKWWK...",
            "...KWWWWK..KWWK..KWWK..KWWK..KWWKKWWK...",
            "...KWWWWKKKKWWKKKKWWKKKKWWKKKKWWKKWWK...",
            "...KWWDDDDDDDDDDDDDDDDDDDDDDDDDDDDWWK...",
            "...KWWKKKKKKKKKKKKKKKKKKKKKKKKKKKKWWK...",
            "..KKWWKKKKKKKKKKKKKKKKKKKKKKKKKKKKWWKK..",
            ".KLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLK.",
            ".KLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLK.",
            ".KWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWK.",
            ".KWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWK.",
            ".KDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDK.",
            "..KKWWWKKKKKKKKKKKKKKKKKKKKKKKKKKWWWKK..",
            "...KWWWKKKKKKKKKKKKKKKKKKKKKKKKKKWWWK...",
            "...KWWWDDDDDDDDDDDDDDDDDDDDDDDDDDWWWK...",
            "...KWWWKKKKKKKKKKKKKKKKKKKKKKKKKKWWWK...",
            "....KKK..........................KKK....",
        ], colors: ["K": ink, "W": PixelColor(hex: "#B07A4A"), "L": PixelColor(hex: "#D9A774"), "D": PixelColor(hex: "#7A4E2A")],
        seatRow: 16, frontFrom: 17, season: false),
        ChairArt(id: "chair-sofa", name: L("쿠션 소파"), rows: [
            "......KKKKKKKKKKKKKKKKKKKKKKKKKKKK......",
            ".....KLLLLLLLLLLLLLLLLLLLLLLLLLLLLK.....",
            "....KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK....",
            "....KSSLLLLLLLLLLLLLLLLLLLLLLLLLLSSK....",
            "....KSSSSSSSSDSSSSSSDSSSSSSDSSSSSSSK....",
            "....KSSSSSSSSDSSSSSSDSSSSSSDSSSSSSSK....",
            "....KSSSSSSSSDSSSSSSDSSSSSSDSSSSSSSK....",
            ".KKKKSSSSSSSSDSSSSSSDSSSSSSDSSSSSSSKKKK.",
            "KSLLLLSSSSSSSDSSSSSSDSSSSSSDSSSSSSLLLLSK",
            "KSSSSSSSSSSSSDSSSSSSDSSSSSSDSSSSSSSSSSSK",
            "KSSSSSSSSSSSSDSSSSSSDSSSSSSDSSSSSSSSSSSK",
            "KSSSSSSSSSSSSDSSSSSSDSSSSSSDSSSSSSSSSSSK",
            "KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK",
            "KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK",
            "KSSSSSSLLLLLLLLLLLLLLLLLLLLLLLLLLSSSSSSK",
            "KSSSSSSLLLLLLLLLLLLLLLLLLLLLLLLLLSSSSSSK",
            "KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK",
            "KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK",
            "KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK",
            "KSSSSSSDDDDDDDDDDDDDDDDDDDDDDDDDDSSSSSSK",
            "KDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDK",
            "KDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDK",
            ".KKKWWKKKKKKKKKKKKKKKKKKKKKKKKKKKKWWKKK.",
            "...KWWK..........................KWWK...",
            "....KK............................KK....",
        ], colors: ["K": ink, "S": PixelColor(hex: "#7FB8C9"), "L": PixelColor(hex: "#B6DCE6"), "D": PixelColor(hex: "#4E8799"),
                    "W": PixelColor(hex: "#B07A4A")],
        seatRow: 16, frontFrom: 16, season: true),
        ChairArt(id: "chair-bean", name: L("말랑 빈백"), rows: [
            "..............KKKKKKKKKKKK..............",
            "..........KKKKSSSSSSSSSSSSKKKK..........",
            ".......KKKSSSSSSSSSSSSSSSSSSSSKKK.......",
            "......KSSSSSSSSSSSSSSSSSSSSSSSSSSK......",
            "....KKSSSSLLLSSSSSSSSSSSSSSSSSSSSSKK....",
            "...KSSSSSLLSSSSSSSSSSSSSSSSSSSSSSSSSK...",
            "..KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK..",
            ".KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK.",
            ".KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK.",
            ".KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK.",
            "KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK",
            ".KSSSSSLLLLLLLLLLLLLLLLLLLLLLLLLLSSSSSK.",
            ".KSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSK.",
            ".KDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDK.",
            "..KDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDK..",
            "...KDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDK...",
            "....KKDDDDDDDDDDDDDDDDDDDDDDDDDDDDKK....",
            "......KDDDDDDDDDDDDDDDDDDDDDDDDDDK......",
            ".......KKKDDDDDDDDDDDDDDDDDDDDKKK.......",
            "..........KKKKDDDDDDDDDDDDKKKK..........",
            "..............KKKKKKKKKKKK..............",
        ], colors: ["K": ink, "S": PixelColor(hex: "#F2A65A"), "L": PixelColor(hex: "#F9CF9A"), "D": PixelColor(hex: "#C57B33")],
        seatRow: 12, frontFrom: 13, season: true),
    ]

    static func chair(_ id: String?) -> ChairArt? { id.flatMap { id in all.first { $0.id == id } } }

    /// Everyone's, and the season ones in `owned`.
    static func available(owned: [String]) -> [ChairArt] { all.filter { !$0.season || owned.contains($0.id) } }
}

// MARK: Drawing

/// Rows `rows` of a chair, at `px` points a pixel, in a view the whole chair's size.
struct ChairLayer: View {
    let chair: ChairArt
    let rows: Range<Int>
    let px: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for r in rows where chair.rows.indices.contains(r) {
                for (c, ch) in chair.rows[r].enumerated() {
                    guard let col = chair.colors[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(c) * px, y: CGFloat(r) * px, width: px, height: px)),
                             with: .color(Color(red: Double(col.r) / 255, green: Double(col.g) / 255, blue: Double(col.b) / 255)))
                }
            }
        }
        .frame(width: CGFloat(chair.width) * px, height: CGFloat(chair.height) * px)
        .accessibilityHidden(true)
    }
}

/// A character on a chair: the chair's back, the character resting, the chair's front over its lowest rows.
struct ChairSeatView: View {
    let chair: ChairArt
    let cache: DogSpriteCache

    var body: some View {
        let px = cache.imageSize.width / CGFloat(DogSpriteCache.canvasWidth)
        let l = chair.layout(sprite: cache.imageSize, px: px)
        ZStack(alignment: .topLeading) {
            ChairLayer(chair: chair, rows: 0..<chair.frontFrom, px: px).offset(x: l.chair.x, y: l.chair.y)
            AnimatedDog(cache: cache, pose: .lying, cpu: 0.02)
                .frame(width: cache.imageSize.width, height: cache.imageSize.height)
                .offset(x: l.sitter.x, y: l.sitter.y)
            ChairLayer(chair: chair, rows: chair.frontFrom..<chair.height, px: px).offset(x: l.chair.x, y: l.chair.y)
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
    }
}

// MARK: My chair

final class ChairCenter {
    static let shared = ChairCenter()
    static let idKey = "chair.id", sittingKey = "chair.sitting", xKey = "chair.x", buddyKey = "chair.buddyWasOut"
    static let px: CGFloat = 2

    private var defaults: UserDefaults { AppDefaults.store }
    private var panel: NSPanel?
    private var grab: CGFloat = 0

    /// The chair out (one I have), nil = none.
    var chair: ChairArt? {
        ChairCatalog.chair(defaults.string(forKey: Self.idKey)).flatMap { c in
            ChairCatalog.available(owned: SeasonCenter.shared.state.owned).contains(c) ? c : nil
        }
    }

    var sitting: Bool { chair != nil && defaults.bool(forKey: Self.sittingKey) }
    /// What friends see me sitting on (FriendLook.seat).
    var seat: String? { sitting ? chair?.id : nil }

    func start() { apply() }

    /// Puts out `id` (nil takes the chair away, and gets up).
    func choose(_ id: String?) {
        if id == nil, sitting { sit(false) }
        defaults.set(id, forKey: Self.idKey)
        apply()
        SocialBus.shared.sendLookIfChanged()
    }

    /// Sitting, my character leaves the cursor for the chair; getting up brings it back if it was out.
    func sit(_ on: Bool) {
        guard chair != nil, on != sitting else { return }
        if on {
            defaults.set(MotionStore.shared.cursorBuddy, forKey: Self.buddyKey)
            MotionStore.shared.cursorBuddy = false
        } else if defaults.bool(forKey: Self.buddyKey) {
            MotionStore.shared.cursorBuddy = true
        }
        defaults.set(on, forKey: Self.sittingKey)
        apply()
        SocialBus.shared.sendLookIfChanged()
    }

    /// Items for the 커서 친구's menu.
    func menuItems() -> [NSMenuItem] {
        chair == nil ? [] : [FriendMenu.item(L("의자에 앉기")) { [weak self] in self?.sit(true) }]
    }

    private func apply() {
        guard let c = chair else { panel?.orderOut(nil); panel = nil; return }
        let cache = DogSpriteCache(SpriteLook(AppSettings.shared), pixelSize: Self.px)
        let size = c.layout(sprite: cache.imageSize, px: Self.px).size
        let p = panel ?? makePanel()
        panel = p
        let host = NSHostingView(rootView: Group {
            if sitting { ChairSeatView(chair: c, cache: cache) } else { ChairLayer(chair: c, rows: 0..<c.height, px: Self.px) }
        }.frame(width: size.width, height: size.height, alignment: .bottom))
        let v = ChairClickView(frame: CGRect(origin: .zero, size: size))
        v.onMouse = { [weak self] e in self?.mouse(e) }
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel(c.name)
        host.frame = v.bounds
        host.autoresizingMask = [.width, .height]
        v.addSubview(host)
        p.contentView = v
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let x = defaults.object(forKey: Self.xKey) as? Double ?? Double(vf.maxX - 220)
        p.setFrame(CGRect(x: min(max(CGFloat(x), vf.minX), vf.maxX - size.width), y: vf.minY, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)   // on the desktop, under windows, like the rug
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return p
    }

    /// Dragged sideways along the floor; right-click for sitting, another chair, or none.
    private func mouse(_ e: NSEvent) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        switch e.type {
        case .leftMouseDown: grab = p.frame.minX - m.x
        case .leftMouseDragged: p.setFrameOrigin(CGPoint(x: (m.x + grab).rounded(), y: p.frame.minY))
        case .leftMouseUp: defaults.set(Double(p.frame.minX), forKey: Self.xKey)
        case .rightMouseDown:
            guard let v = p.contentView else { return }
            let mine = ChairCatalog.available(owned: SeasonCenter.shared.state.owned)
            FriendMenu.pop([
                sitting ? FriendMenu.item(L("일어나기")) { [weak self] in self?.sit(false) } : FriendMenu.item(L("앉기")) { [weak self] in self?.sit(true) },
                FriendMenu.submenu(L("의자 바꾸기"), mine.map { c in FriendMenu.item(c.name, on: c.id == chair?.id) { [weak self] in self?.choose(c.id) } }),
                FriendMenu.item(L("의자 치우기")) { [weak self] in self?.choose(nil) },
            ], with: e, for: v)
        default: break
        }
    }
}

/// Takes every click on the chair (also the first while another app is active).
private final class ChairClickView: NSView {
    var onMouse: (NSEvent) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouse(event) }
    override func mouseDragged(with event: NSEvent) { onMouse(event) }
    override func mouseUp(with event: NSEvent) { onMouse(event) }
    override func rightMouseDown(with event: NSEvent) { onMouse(event) }
}

/// 의자 in 설정 > 데스크톱 친구: none or one of mine.
struct ChairSettings: View {
    @State private var picked = ChairCenter.shared.chair?.id ?? ""
    /// QA renders: these instead of what the season gave.
    var owned: [String] = SeasonCenter.shared.state.owned

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "🪑 " + L("의자")).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                chip(nil)
                ForEach(ChairCatalog.all, id: \.id) { chip($0) }
            }
            Text(L("바탕화면 아래에 의자를 두고 오른쪽 클릭으로 앉아요. 앉아 있으면 친구 화면의 내 캐릭터도 같은 의자에 앉아요. 나무 의자 말고는 시즌 뽑기판에서 모아요."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ c: ChairArt?) -> some View {
        let id = c?.id ?? "", have = c.map { !$0.season || owned.contains($0.id) } ?? true, on = picked == id
        return Button {
            picked = id
            ChairCenter.shared.choose(c?.id)
        } label: {
            VStack(spacing: 3) {
                if let c { ChairLayer(chair: c, rows: 0..<c.height, px: 1).frame(height: 26) } else { Text(verbatim: "✕").frame(height: 26) }
                Text(verbatim: c?.name ?? L("없음")).font(.system(size: 10, weight: on ? .semibold : .regular))
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
            .saturation(have ? 1 : 0).opacity(have ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!have)
        .help(have ? "" : L("시즌 뽑기판에서 모아요"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
