import AppKit
import SwiftUI

// 친구 상주 자리: which screen, which edge and how much of it, and 창에 매달기 (a friend dropped on another app's window
// edge holds on by a rubber band, DesktopKit's RubberBand). The screen is kept by its signature, so a monitor plugged back in gets its
// friends back. Keys: social.room.length, social.room.screen, social.room.hang (OFF). Pure parts tested in RoomPlaceTests.

/// How much of the edge the seats use, in its middle. Raw values are saved; never rename one.
enum RoomLength: String, CaseIterable {
    case full, half, third

    var share: CGFloat {
        switch self {
        case .full: return 1
        case .half: return 0.5
        case .third: return 1.0 / 3
        }
    }

    var label: String {
        switch self {
        case .full: return L("전체")
        case .half: return L("1/2")
        case .third: return L("1/3")
        }
    }
}

extension RoomEdge {
    var label: String {
        switch self {
        case .bottom: return L("아래")
        case .top: return L("위")
        case .left: return L("왼쪽")
        case .right: return L("오른쪽")
        }
    }
}

/// A screen as saved: enough to know it again after it was unplugged (the display id alone can change).
struct ScreenSignature: Codable, Equatable {
    var id: UInt32
    var name: String
    var frame: CGRect
    var scale: CGFloat

    init(id: UInt32, name: String, frame: CGRect, scale: CGFloat) {
        self.id = id; self.name = name; self.frame = frame; self.scale = scale
    }

    init(_ s: NSScreen) {
        let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.init(id: n?.uint32Value ?? 0, name: s.localizedName, frame: s.frame, scale: s.backingScaleFactor)
    }
}

enum RoomPlace {
    /// `saved`'s screen among `screens`: the same display and name, else the same name, size and scale (it came back
    /// with a new id), else the same frame. nil (the main screen) when none fits or nothing was picked.
    static func match(_ saved: ScreenSignature?, in screens: [ScreenSignature]) -> Int? {
        guard let s = saved else { return nil }
        return screens.firstIndex { $0.id == s.id && $0.name == s.name }
            ?? screens.firstIndex { $0.name == s.name && $0.frame.size == s.frame.size && $0.scale == s.scale }
            ?? screens.firstIndex { $0.frame == s.frame }
    }

    /// The part of `vf` the seats use: `length` of `edge` in its middle, the whole depth. Whole points.
    static func band(_ vf: CGRect, edge: RoomEdge, length: RoomLength) -> CGRect {
        switch edge {
        case .bottom, .top:
            let w = (vf.width * length.share).rounded()
            return CGRect(x: (vf.midX - w / 2).rounded(), y: vf.minY, width: w, height: vf.height)
        case .left, .right:
            let h = (vf.height * length.share).rounded()
            return CGRect(x: vf.minX, y: (vf.midY - h / 2).rounded(), width: vf.width, height: h)
        }
    }

    /// Along the top their heads are against the menu bar: bubbles go under them.
    static func bubbleBelow(_ edge: RoomEdge) -> Bool { edge == .top }
}

// MARK: 창에 매달기

/// Where a dropped friend catches on and whether it still can. Pure; FriendRoom feeds it the window list (the same
/// permission-free keys as 폴더 친구: number, owner, layer, bounds, alpha).
enum HangRules {
    /// Dropped this close to an edge, it catches it.
    static let reach: CGFloat = 24
    /// Smaller windows (sheets, palettes, alerts) are not hung on.
    static let minSize = CGSize(width: 160, height: 100)
    /// How often the window list is read while someone hangs (only then). ponytail: a window dragged fast lags up to
    /// this much; per-frame reads while the button is down (as FolderFriends does) if that shows.
    static let pollEvery: TimeInterval = 0.5

    enum Side { case top, left, right }

    struct Spot: Equatable {
        var window: ListedWindow
        var side: Side
        var anchor: CGPoint
    }

    /// Windows a friend can hang on, front first: other apps' (never ours), the normal layer, shown, big enough.
    static func hangable(_ list: [ListedWindow], me: pid_t) -> [ListedWindow] {
        list.filter { $0.pid != me && $0.layer == 0 && $0.alpha > 0 && $0.frame.width >= minSize.width && $0.frame.height >= minSize.height }
    }

    /// Where a friend `width` wide dropped with its feet at `feet` catches on: the frontmost window whose top edge,
    /// or left or right side, is within `reach`. Dropped inside a window, the ones behind it do not count. nil: it falls.
    static func spot(feet: CGPoint, width: CGFloat, in list: [ListedWindow], me: pid_t) -> Spot? {
        for w in hangable(list, me: me) {
            let f = w.frame
            if feet.x >= f.minX, feet.x <= f.maxX, abs(feet.y - f.maxY) <= reach {
                return Spot(window: w, side: .top, anchor: CGPoint(x: feet.x.rounded(), y: f.maxY))
            }
            if feet.y >= f.minY, feet.y < f.maxY - reach {
                let y = min(f.maxY, (feet.y + RubberBand.length).rounded())
                if abs(feet.x - f.minX) <= reach { return Spot(window: w, side: .left, anchor: CGPoint(x: f.minX - width / 2, y: y)) }
                if abs(feet.x - f.maxX) <= reach { return Spot(window: w, side: .right, anchor: CGPoint(x: f.maxX + width / 2, y: y)) }
            }
            if f.contains(feet) { return nil }
        }
        return nil
    }

    /// The anchor from the window's corner on that side (top left; top right for .right).
    static func offset(_ side: Side, anchor: CGPoint, on f: CGRect) -> CGVector {
        CGVector(dx: anchor.x - (side == .right ? f.maxX : f.minX), dy: anchor.y - f.maxY)
    }

    /// The anchor on the window now: the same place from its corner, kept over its top edge when it got narrower.
    static func anchor(_ side: Side, offset o: CGVector, on f: CGRect) -> CGPoint {
        let x = (side == .right ? f.maxX : f.minX) + o.dx
        return CGPoint(x: side == .top ? min(max(x, f.minX), f.maxX) : x, y: f.maxY + o.dy)
    }

    /// Where the band is tied: the anchor, moved onto the window's side for a friend `width` wide hanging beside it
    /// (the anchor is over the friend's middle, so it hangs clear of the window).
    static func knot(_ side: Side, anchor: CGPoint, width: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x + (side == .left ? width / 2 : side == .right ? -width / 2 : 0), y: anchor.y)
    }

    /// The top edge it stands on (nil hanging by a side).
    static func floor(_ side: Side, on f: CGRect) -> (minX: CGFloat, maxX: CGFloat, y: CGFloat)? {
        side == .top ? (f.minX, f.maxX, f.maxY) : nil
    }

    enum Status: Equatable { case at(ListedWindow), covered, gone }

    /// Its window still out (not closed, minimized or on another Space) and nothing in front over the friend's `rect`.
    static func status(_ id: Int, rect: CGRect, in list: [ListedWindow], me: pid_t) -> Status {
        guard let w = list.first(where: { $0.id == id }) else { return .gone }
        return FolderPerch.covered(rect, behind: w, in: list, me: me) ? .covered : .at(w)
    }
}

/// A seat hanging on a window.
struct RoomHang {
    var window: Int
    var side: HangRules.Side
    var offset: CGVector
    var rope: RubberBand
    /// A window in front is over it: hidden until it is clear again.
    var hidden = false
}

/// The rubber band between the window and a hanging friend, drawn in its own click-through panel.
final class BandLineView: NSView {
    /// Both ends in this view's points.
    var ends: (CGPoint, CGPoint) = (.zero, .zero) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        p.move(to: ends.0)
        p.line(to: ends.1)
        p.lineWidth = 2
        p.lineCapStyle = .round
        NSColor(red: 0.86, green: 0.36, blue: 0.42, alpha: 0.9).setStroke()
        p.stroke()
    }
}

// MARK: Settings

/// 친구 상주 자리 in 설정 > 근처 친구: screen, edge, length, 창에 매달기.
struct RoomPlaceSettings: View {
    @AppStorage(FriendRoom.edgeKey, store: AppDefaults.store) private var edge = RoomEdge.bottom.rawValue
    @AppStorage(FriendRoom.lengthKey, store: AppDefaults.store) private var length = RoomLength.full.rawValue
    @AppStorage(FriendRoom.hangKey, store: AppDefaults.store) private var hang = false
    @State private var screen = FriendRoom.shared.screenChoice
    /// QA renders: these screens instead of the Mac's.
    var screens: [ScreenSignature] = NSScreen.screens.map(ScreenSignature.init)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("화면"))
                Picker(L("화면"), selection: $screen) {
                    Text(L("주 화면")).tag(-1)
                    ForEach(screens.indices, id: \.self) { i in Text(verbatim: screens[i].name).tag(i) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                .onChange(of: screen) { i in FriendRoom.shared.screen = screens.indices.contains(i) ? screens[i] : nil }
            }
            HStack {
                Text(L("자리"))
                Picker(L("자리"), selection: $edge) {
                    ForEach(RoomEdge.allCases, id: \.self) { Text(verbatim: $0.label).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
            }
            HStack {
                Text(L("길이"))
                Picker(L("길이"), selection: $length) {
                    ForEach(RoomLength.allCases, id: \.self) { Text(verbatim: $0.label).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
            }
            Toggle(L("다른 앱 창에 매달기"), isOn: $hang).toggleStyle(.switch).controlSize(.small)
            Text(L("친구를 잡아 다른 앱 창의 윗변이나 옆에 놓으면 고무줄로 매달려 창을 따라다녀요. 당겼다 놓으면 튕겨 돌아오고, 세게 당기면 떨어져요. 창이 닫히면 떨어지고, 다른 창에 가려지면 숨었다 나와요. 화면 기록 권한은 필요 없어요."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
