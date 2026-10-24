import AppKit
import Combine
import SwiftUI

// 친구 상주: each online friend's character (FriendLook, built-in only) stays on my screen over the Dock, holding a
// 퇴근 sign when they are off. 다같이 뽀뽀·똥 go to every friend and play on everyone's screen at once; a friend picked up
// and thrown (Fling) lands on their screen too. 원격 모임 members stand in the same row (seat id "m:" + member id) by the
// look their hello carried, with their 한마디 or 입력 중 in a bubble over the head (SeatTalk, RoomBubbles).
// Key: social.room (on unless switched off), only while 근처 친구 or the 원격 모임 is on.
// Where they stand (screen, edge, length) and 창에 매달기 are in RoomPlace.swift; a friend sitting on a 의자 sits here too.

/// 다같이 이모트, as it travels. Raw values go on the wire; never rename one.
enum EmoteKind: String, Codable, CaseIterable {
    case kiss, poop, toss

    /// The menu's 다같이 item (던지기 has its own per friend).
    var label: String {
        switch self {
        case .kiss: return L("다같이 뽀뽀")
        case .poop: return L("다같이 똥")
        case .toss: return L("던지기")
        }
    }

    /// What a friend's emote says over their character.
    var line: String {
        switch self {
        case .kiss: return L("다같이 뽀뽀!")
        case .poop: return L("다같이 똥!")
        case .toss: return L("날아왔어!")
        }
    }

    var effect: RoomEffect? {
        switch self {
        case .kiss: return .hearts
        case .poop: return .poop
        case .toss: return nil
        }
    }
}

/// What plays over each friend in the room for a few seconds (party: the 모임 filled up).
enum RoomEffect: Equatable { case hearts, poop, party }

/// Who stays and who hears an emote. Pure, tested (FriendRoomTests).
enum RoomRules {
    /// A full 모임 of 8 is me and 7 friends.
    static let most = 7
    /// The whole row with 원격 모임 members (a full room of 12 is me and 11): about 1,100 pt of a screen's width.
    static let mostSeats = 12

    /// 근처 친구 first, then the 원격 모임, `mostSeats` at most.
    static func row(nearby: [SocialFriend], remote: [SocialFriend]) -> [SocialFriend] { Array((nearby + remote).prefix(mostSeats)) }
    /// The protocol version that knows `.emote`; an older friend closes the link on a case it cannot read.
    static let emoteVersion = 2

    /// Online friends in friend-list order, `most` at most.
    static func members(_ friends: [SocialFriend], online: Set<String>, most: Int = most) -> [SocialFriend] {
        Array(friends.filter { online.contains($0.id) }.prefix(most))
    }

    static func canEmote(version: Int?) -> Bool { (version ?? 0) >= emoteVersion }

    /// Online friends whose hello said they read emotes, sorted.
    static func emoteTargets(online: Set<String>, versions: [String: Int]) -> [String] {
        online.filter { canEmote(version: versions[$0]) }.sorted()
    }

    /// Seat `i`'s middle, from the left edge of the visible frame, `width` apart with a small gap.
    static func slotX(_ i: Int, minX: CGFloat, width: CGFloat) -> CGFloat { minX + 40 + width / 2 + CGFloat(i) * (width + 8) }

    /// Seat `i`'s panel origin on `edge` of `vf`: a row along the bottom (at `x` once put there) or the top, a column
    /// down the left or right side from near the top, kept on screen.
    static func origin(_ i: Int, edge: RoomEdge, size: CGSize, in vf: CGRect, x: CGFloat? = nil) -> CGPoint {
        switch edge {
        case .bottom, .top:
            let mid = min(max(x ?? slotX(i, minX: vf.minX, width: size.width), vf.minX + size.width / 2), vf.maxX - size.width / 2)
            return CGPoint(x: mid - size.width / 2, y: edge == .bottom ? vf.minY : vf.maxY - size.height)
        case .left, .right:
            let y = max(vf.minY, vf.maxY - 40 - size.height - CGFloat(i) * (size.height + 8))
            return CGPoint(x: edge == .left ? vf.minX : vf.maxX - size.width, y: y)
        }
    }
}

/// Where seats' bubbles go. Pure, tested (RemoteMeetTests).
enum RoomBubbles {
    /// The transparent margin SpeechBubbleView keeps round itself for its shadow.
    static let pad: CGFloat = 8

    /// A bubble of `size` for the seat panel `seat`, whose sprite (`sprite`) stands at its bottom left: its tail on the
    /// head, or under the seat on the top edge; kept in `vf`.
    static func frame(seat: CGRect, sprite: CGSize, size: CGSize, edge: RoomEdge, in vf: CGRect) -> CGRect {
        let x = seat.minX + sprite.width / 2 - size.width / 2
        let y = edge == .top ? seat.minY - size.height + pad / 2 : seat.minY + sprite.height - pad / 2
        return CGRect(x: min(max(x, vf.minX), vf.maxX - size.width), y: min(max(y, vf.minY), vf.maxY - size.height),
                      width: size.width, height: size.height)
    }

    /// Bubbles that would cover one another move apart: each, in order, goes up (down on the top edge) past every
    /// earlier one it overlaps, a small gap between the cards.
    static func stacked(_ frames: [CGRect], down: Bool = false) -> [CGRect] {
        var out: [CGRect] = []
        for f in frames {
            var r = f
            var moved = true
            while moved {
                moved = false
                for o in out where r.insetBy(dx: pad, dy: pad).intersects(o.insetBy(dx: pad, dy: pad)) {
                    r.origin.y = down ? o.minY - r.height + 2 * pad - 3 : o.maxY - 2 * pad + 3
                    moved = true
                }
            }
            out.append(r)
        }
        return out
    }
}

/// Where 친구 상주 stands (단축키 상/하/좌/우). Raw values are saved; never rename one.
enum RoomEdge: String, CaseIterable {
    case bottom, top, left, right
}

/// One friend in the room.
final class RoomSeat: ObservableObject {
    let id: String
    @Published var nickname: String
    @Published var cache: DogSpriteCache
    @Published var off: Bool
    @Published var effect: RoomEffect?
    @Published var effectStart = Date()
    @Published var flying = false
    /// 던지기 놀이: 기절 until then (their Mac said so), and the last 퍽 on them.
    @Published var koUntil: Date?
    @Published var bonkAt: Date?
    var look: FriendLook
    /// The middle of its feet once dragged or thrown; nil keeps its slot.
    var x: CGFloat?
    var fling: Fling?
    var held = false
    /// Seats this one already hit in its current flight.
    var hitThisFlight = Set<String>()
    var panel: NSPanel?
    /// A 원격 모임 member's 한마디 and 입력 중, and the bubble showing it.
    var talk = SeatTalk()
    var shown: SeatTalk.Show?
    var bubble: NSPanel?
    var remote: Bool { id.hasPrefix("m:") }
    /// Hanging on another app's window (창에 매달기), and its rubber band's panel.
    var hang: RoomHang?
    var band: NSPanel?

    init(_ f: SocialFriend) {
        id = f.id
        nickname = f.nickname
        look = f.look
        cache = DogSpriteCache(SpriteLook(friend: f.look), pixelSize: 2)
        off = f.status == .off
    }

    /// The 의자 they sit on, drawn from this Mac's own art.
    var chair: ChairArt? { ChairCatalog.chair(look.seat) }
    /// The character, on its chair when it sits.
    var body: CGSize { chair.map { $0.layout(sprite: cache.imageSize, px: 2).size } ?? cache.imageSize }
    /// The panel: the character plus room on its right (똥) and above (hearts).
    var size: CGSize { CGSize(width: body.width + 30, height: body.height + FriendRoom.headroom) }
}

final class FriendRoom {
    static let shared = FriendRoom()
    static let key = "social.room"
    static let headroom: CGFloat = 44
    static let effectSeconds: TimeInterval = 3
    /// Between two of my 다같이 sends (the friend's Mac takes 3 in 10 s).
    static let cooldown: TimeInterval = 2

    private(set) var seats: [RoomSeat] = []
    var seatIDs: [String] { seats.map(\.id) }
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var lastSend: TimeInterval = -.infinity
    private var clear: DispatchWorkItem?
    private var talkTurn: DispatchWorkItem?
    private var clicks = ClickRecognizer()
    private var pressed: RoomSeat?
    private var grab = CGVector.zero
    /// My own character flying in after a friend threw me.
    private var flown: (panel: NSPanel, fling: Fling, size: CGSize)?
    /// 던지기 놀이: items in flight, and my character walking over (고유행동).
    private struct Shot { let panel: NSPanel; let wire: Int; let from: CGPoint; let seat: String; let start: TimeInterval; let seconds: TimeInterval }
    private var shots: [Shot] = []
    private var walker: (panel: NSPanel, size: CGSize, from: CGFloat, to: CGFloat, y: CGFloat, start: TimeInterval, seconds: TimeInterval, seat: String, move: ThrowMove)?

    private var bus: SocialBus { .shared }
    var on: Bool { bus.defaults.object(forKey: Self.key) as? Bool ?? true }
    static let edgeKey = "social.room.edge"
    var edge: RoomEdge {
        get { bus.defaults.string(forKey: Self.edgeKey).flatMap(RoomEdge.init) ?? .bottom }
        set { bus.defaults.set(newValue.rawValue, forKey: Self.edgeKey); seats.forEach { $0.x = nil }; layout() }
    }
    static let lengthKey = "social.room.length", screenKey = "social.room.screen", hangKey = "social.room.hang"
    var length: RoomLength { bus.defaults.string(forKey: Self.lengthKey).flatMap(RoomLength.init) ?? .full }
    /// The screen picked in 설정 (nil: the main one), found again by its signature after it was unplugged.
    var screen: ScreenSignature? {
        get { bus.defaults.data(forKey: Self.screenKey).flatMap { try? JSONDecoder().decode(ScreenSignature.self, from: $0) } }
        set { bus.defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.screenKey) }
    }
    /// The picked screen's place in NSScreen.screens, -1 for the main one (설정's picker).
    var screenChoice: Int { RoomPlace.match(screen, in: NSScreen.screens.map(ScreenSignature.init)) ?? -1 }
    var hangOn: Bool { bus.defaults.bool(forKey: Self.hangKey) }
    private var laid: String?
    private var place: String { "\(edge.rawValue) \(length.rawValue) \(screenChoice)" }
    private var hangTimer: Timer?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard bag.isEmpty else { return }
        bus.$friends.combineLatest(bus.$online, bus.$isOn).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        RemoteMeet.shared.$members.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.seats.forEach { $0.x = nil }; self?.layout() }.store(in: &bag)
    }

    /// The seats follow the online friends and the 원격 모임's members, their looks and statuses.
    func refresh() {
        let meet = RemoteMeet.shared
        let nearby = bus.isOn && on ? RoomRules.members(bus.friends, online: bus.online) : []
        let remote = meet.isOn && meet.code != nil && on
            ? MeetSeats.row(meet.members, now: now).map { SocialFriend(id: "m:" + $0.id, nickname: $0.name, look: $0.look, status: $0.status, pairedAt: .distantPast) }
            : []
        let want = RoomRules.row(nearby: nearby, remote: remote)
        let ids = Set(want.map(\.id))
        for s in seats where !ids.contains(s.id) {
            s.panel?.orderOut(nil); s.panel = nil
            s.bubble?.orderOut(nil); s.bubble = nil
            s.band?.orderOut(nil); s.band = nil
        }
        let before = seatIDs
        var resized = false
        seats = want.map { f in
            let s = seats.first { $0.id == f.id } ?? RoomSeat(f)
            if s.look != f.look {
                let was = s.size
                s.look = f.look
                s.cache = DogSpriteCache(SpriteLook(friend: f.look), pixelSize: 2)
                s.panel?.setContentSize(s.size)
                resized = resized || s.size != was   // sat down or got up: a bigger or smaller panel
            }
            if s.nickname != f.nickname { s.nickname = f.nickname }
            if s.off != (f.status == .off) { s.off = f.status == .off }
            if s.panel == nil { s.panel = makePanel(s) }
            return s
        }
        if !hangOn { seats.filter { $0.hang != nil }.forEach { drop($0) } }
        if laid != place { seats.forEach { $0.x = nil } }
        if seatIDs != before || laid != place || resized { layout() }
        if showsRemote { meet.hurry() }   // a member just came on screen: the next poll is a fast one
    }

    /// A 원격 모임 member's character is on screen (the room polls fast while it is).
    var showsRemote: Bool { seats.contains { $0.remote && $0.panel?.isVisible == true } }

    private func makePanel(_ s: RoomSeat) -> NSPanel {
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: s.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.sharingType = .none   // friends stay out of screen shares, like their visits
        let v = RoomClickView(frame: CGRect(origin: .zero, size: s.size))
        v.onMouse = { [weak self, weak s] e in if let self, let s { self.mouse(e, s) } }
        v.toolTip = s.remote ? "🌏 " + s.nickname : s.nickname
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel(s.nickname)
        let host = NSHostingView(rootView: RoomFriendView(seat: s))
        host.frame = v.bounds
        host.autoresizingMask = [.width, .height]
        v.addSubview(host)
        p.contentView = v
        p.orderFrontRegardless()
        return p
    }

    /// The picked screen's visible frame, else the main one's.
    private var visible: CGRect {
        let all = NSScreen.screens
        let i = RoomPlace.match(screen, in: all.map(ScreenSignature.init))
        return (i.map { all[$0] } ?? NSScreen.main ?? all.first)?.visibleFrame ?? .zero
    }

    /// Seats not held, flying or hanging stand at their slot on the chosen part of the edge (on the floor: where they
    /// were put).
    private func layout() {
        let band = RoomPlace.band(visible, edge: edge, length: length), edge = self.edge
        laid = place
        for (i, s) in seats.enumerated() where s.fling == nil && !s.held && s.hang == nil {
            s.panel?.setFrameOrigin(RoomRules.origin(i, edge: edge, size: s.size, in: band, x: edge == .bottom ? s.x : nil))
        }
        placeBubbles()
    }

    private func walls(_ size: CGSize) -> CGRect {
        let vf = visible
        return CGRect(x: vf.minX + size.width / 2, y: vf.minY, width: max(0, vf.width - size.width), height: max(0, vf.height - size.height))
    }

    // MARK: Mouse

    private func mouse(_ e: NSEvent, _ s: RoomSeat) {
        let p = NSEvent.mouseLocation, t = now
        switch e.type {
        case .leftMouseDown:
            pressed = s
            if let o = s.panel?.frame.origin { grab = CGVector(dx: o.x - p.x, dy: o.y - p.y) }
            handle(clicks.mouseDown(p, at: t))
        case .leftMouseDragged:
            handle(clicks.mouseMoved(p, at: t))
        case .leftMouseUp:
            handle(clicks.mouseUp(p, at: t))
            DispatchQueue.main.asyncAfter(deadline: .now() + ClickRecognizer.doubleWindow + 0.02) { [weak self] in
                guard let self else { return }
                self.handle(self.clicks.poll(at: self.now))
            }
        case .rightMouseDown:
            handle(clicks.cancel(at: p))
            guard let v = s.panel?.contentView else { return }
            FriendMenu.pop(seatItems(s), with: e, for: v)
        default:
            break
        }
    }

    private func handle(_ gestures: [ClickRecognizer.Gesture]) {
        guard let s = pressed else { return }
        for g in gestures {
            switch g {
            case .dragBegan:
                s.held = true
                s.fling = nil
            case .dragged(let p):
                s.panel?.setFrameOrigin(CGPoint(x: p.x + grab.dx, y: p.y + grab.dy))
                if var h = s.hang, let f = s.panel?.frame {
                    h.rope.position = CGPoint(x: f.midX, y: f.minY)
                    if h.rope.snapped { drop(s, falling: false) } else { s.hang = h; drawBand(s) }   // pulled too far: it lets go
                }
                placeBubbles()
            case .dragEnded(_, let v):
                s.held = false
                if var h = s.hang {   // still tied: springs back
                    h.rope.release(v)
                    s.hang = h
                    tickOn()
                    break
                }
                let thrown = hypot(v.dx, v.dy) >= BuddyMath.throwMin
                if !thrown, hangOn, let f = s.panel?.frame,
                   let spot = HangRules.spot(feet: CGPoint(x: f.midX, y: f.minY), width: f.width, in: windows(), me: getpid()) {
                    attach(s, spot)
                    break
                }
                fly(s, thrown ? v : .zero)   // a drop falls back to the floor
                if thrown { sendToss(s.id) }
            case .single where ThrowCenter.shared.clickThrows:
                throwAt(s)
            case .single, .double:
                if s.remote { RecentLog.open() } else { FriendWindow.open(s.id) }
            }
        }
    }

    /// The seat's own right-click items.
    private func seatItems(_ s: RoomSeat) -> [NSMenuItem] {
        let away = FriendMenu.item(L("친구 캐릭터 화면에서 치우기")) { SocialBus.shared.defaults.set(false, forKey: Self.key) }
        if s.remote {
            let member = String(s.id.dropFirst(2))
            return [FriendMenu.item(L("원격 모임에 한마디…")) { RemoteMeet.shared.askLine() },
                    FriendMenu.item(L("대화 모아보기…")) { RecentLog.open() }]
                + (RemoteMeet.shared.notes[member].map { card in [FriendMenu.item(L("프로필 카드")) { FriendCardPanel.show(card) }] } ?? [])
                + throwItems(s)
                + (s.hang == nil ? [] : [FriendMenu.item(L("창에서 내려오기")) { [weak self] in self?.drop(s) }])
                + [away]
        }
        return [FriendMenu.item(L("대화하기")) { FriendWindow.open(s.id) },
         FriendMenu.item(L("프로필 카드")) { SocialBus.shared.card(s.id).map(FriendCardPanel.show) },
         FriendMenu.item(L("낙서 쪽지 보내기…")) { DoodleCenter.open(.friend(s.id), name: s.nickname) },
         FriendMenu.item(L("던지기")) { [weak self] in self?.toss(s.id) }]
            + throwItems(s)
            + (s.hang == nil ? [] : [FriendMenu.item(L("창에서 내려오기")) { [weak self] in self?.drop(s) }])
            + groupItems()
            + [away]
    }

    /// 다같이 ▸ 뽀뽀·똥, for the menus (empty while no online friend reads emotes).
    func groupItems() -> [NSMenuItem] {
        guard !RoomRules.emoteTargets(online: bus.online, versions: bus.versions).isEmpty else { return [] }
        return [FriendMenu.submenu(L("다같이"), [EmoteKind.kiss, .poop].map { k in FriendMenu.item(k.label) { [weak self] in self?.sendAll(k) } })]
    }

    /// 던지기 놀이's items, while it is on.
    private func throwItems(_ s: RoomSeat) -> [NSMenuItem] {
        let c = ThrowCenter.shared
        guard c.isOn else { return [] }
        let what = c.move?.label ?? L("\(c.item.name) 던지기")
        return [FriendMenu.item(what) { [weak self] in self?.throwAt(s) }, c.itemMenu()]
            + (c.guarded ? [FriendMenu.item(L("던질 준비 (10초)")) { c.arm() }] : [])
    }

    // MARK: Throwing

    /// 던지기 from a menu: up and away from the middle of the screen.
    func toss(_ id: String) {
        guard let s = seats.first(where: { $0.id == id }), let f = s.panel?.frame else { return }
        let left = f.midX > visible.midX
        fly(s, CGVector(dx: (left ? -1 : 1) * CGFloat.random(in: 900...1400), dy: 1200))
        sendToss(id)
    }

    private func sendToss(_ id: String) {
        guard bus.online.contains(id), RoomRules.canEmote(version: bus.versions[id]) else { return }
        bus.send(.emote(.toss), to: id)
    }

    private func fly(_ s: RoomSeat, _ v: CGVector) {
        guard let f = s.panel?.frame else { return }
        if s.hang != nil { s.hang = nil; s.band?.orderOut(nil) }
        s.fling = Fling(at: CGPoint(x: f.midX, y: f.minY), velocity: v, walls: walls(f.size))
        s.flying = true
        s.hitThisFlight = []
        tickOn()
    }

    private func tickOn() {
        guard timer == nil else { return }
        lastTick = now
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let t = now, dt = t - lastTick
        lastTick = t
        for s in seats {
            guard var f = s.fling else { continue }
            f.step(dt: dt)
            let size = s.size
            s.panel?.setFrameOrigin(CGPoint(x: f.position.x - size.width / 2, y: f.position.y))
            s.x = f.position.x
            if ThrowCenter.shared.isOn, let mine = s.panel?.frame { collide(s, mine) }
            s.fling = f.isSettled ? nil : f
            if s.bubble != nil { placeBubbles() }
            if s.fling == nil {
                s.flying = false
                if edge != .bottom { s.x = nil; layout() }   // landed on the floor: back to its seat on the edge
            }
        }
        for s in seats where !s.held {
            guard var h = s.hang, !h.rope.isSettled, let size = s.panel?.frame.size else { continue }
            h.rope.step(dt: dt)
            s.hang = h
            s.panel?.setFrameOrigin(CGPoint(x: (h.rope.position.x - size.width / 2).rounded(), y: h.rope.position.y.rounded()))
            drawBand(s)
        }
        if var m = flown, !m.fling.isSettled {
            m.fling.step(dt: dt)
            m.panel.setFrameOrigin(CGPoint(x: m.fling.position.x - m.size.width / 2, y: m.fling.position.y))
            flown = m
        }
        stepShots(t)
        let roping = seats.contains { s in !s.held && s.hang.map { !$0.rope.isSettled } == true }
        if !seats.contains(where: { $0.fling != nil }), !roping, flown.map({ $0.fling.isSettled }) ?? true, shots.isEmpty, walker == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: 던지기 놀이

    /// Where an item aims on a seat: the middle of its character, a little above.
    private static func aim(_ s: RoomSeat) -> CGPoint? {
        s.panel.map { CGPoint(x: $0.frame.minX + s.cache.imageSize.width / 2, y: $0.frame.minY + s.cache.imageSize.height * 0.6) }
    }

    /// A click (or the menu) on a seat: walk over (고유행동) or throw the chosen item at it.
    func throwAt(_ s: RoomSeat) {
        guard ThrowCenter.shared.isOn, !FriendVisit.quiet(), let to = Self.aim(s) else { return }
        if let m = ThrowCenter.shared.move { walk(to: s, m); return }
        guard shots.count < 6 else { return }   // a fast clicker: a few in the air at once
        let vf = visible
        let from = CursorBuddy.shared.head() ?? CGPoint(x: to.x < vf.midX ? to.x + 320 : to.x - 320, y: vf.minY + 24)
        let item = ThrowCenter.shared.item
        let start = Date()
        let p = Self.floater(CGSize(width: 24, height: 24), TimelineView(.animation) { ctx in
            ThrowItemView(item: item, turn: ctx.date.timeIntervalSince(start) * 9).frame(width: 24, height: 24)
        })
        p.setFrameOrigin(CGPoint(x: from.x - 12, y: from.y - 12))
        p.orderFrontRegardless()
        shots.append(Shot(panel: p, wire: item.wire, from: from, seat: s.id, start: now, seconds: ThrowRules.seconds(hypot(to.x - from.x, to.y - from.y))))
        tickOn()
    }

    /// Items fly along their arc to wherever their seat is now, and land.
    private func stepShots(_ t: TimeInterval) {
        shots.removeAll { shot in
            guard let s = seats.first(where: { $0.id == shot.seat }), let to = Self.aim(s) else { shot.panel.orderOut(nil); return true }
            let u = (t - shot.start) / shot.seconds
            let p = ThrowRules.point(from: shot.from, to: to, u: u)
            shot.panel.setFrameOrigin(CGPoint(x: p.x - 12, y: p.y - 12))
            guard u >= 1 else { return false }
            shot.panel.orderOut(nil)
            landed(on: s, shot.wire)
            return true
        }
        guard let w = walker else { return }
        let u = min(1, (t - w.start) / w.seconds)
        w.panel.setFrameOrigin(CGPoint(x: w.from + (w.to - w.from) * CGFloat(u) - w.size.width / 2, y: w.y))
        guard u >= 1 else { return }
        walker = nil
        if let s = seats.first(where: { $0.id == w.seat }) {
            if w.move == .kiss {
                s.effect = .hearts
                s.effectStart = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.effectSeconds) { [weak s] in if s?.effect == .hearts { s?.effect = nil } }
            } else {
                SpeechBubbleCenter.shared.say(text: L("왁!"), source: .system, aloud: false, repeats: true, seconds: 1.5,
                                              anchor: { [weak p = w.panel] in p.flatMap { $0.isVisible ? CGPoint(x: $0.frame.midX, y: $0.frame.maxY) : nil } })
            }
            landed(on: s, w.move.wire)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [p = w.panel] in p.orderOut(nil) }
    }

    /// 고유행동: my character pops up beside the seat, on the screen's middle side, and walks over to it.
    private func walk(to s: RoomSeat, _ m: ThrowMove) {
        guard walker == nil, let f = s.panel?.frame else { return }
        let (p, size) = myPanel()
        let vf = visible, side: CGFloat = f.midX < vf.midX ? 1 : -1
        let to = f.minX + s.cache.imageSize.width / 2 + side * (s.cache.imageSize.width / 2 + size.width / 2)
        let from = min(max(to + side * 300, vf.minX + size.width / 2), vf.maxX - size.width / 2)
        p.setFrameOrigin(CGPoint(x: from - size.width / 2, y: f.minY))
        p.orderFrontRegardless()
        walker = (p, size, from, to, f.minY, now, min(ThrowRules.walkMost, max(0.3, Double(abs(to - from) / ThrowRules.walkSpeed))), s.id, m)
        tickOn()
    }

    /// Something of mine reached a seat: the 퍽 and its sound here, the hit to the friend (whose Mac counts it).
    private func landed(on s: RoomSeat, _ wire: Int) {
        if wire != ThrowRules.kiss {
            let at = Date()
            s.bonkAt = at
            DispatchQueue.main.asyncAfter(deadline: .now() + StunView.bonkSeconds) { [weak s] in if s?.bonkAt == at { s?.bonkAt = nil } }
        }
        ThrowSound.play(wire)
        if s.remote { RemoteMeet.shared.sendHit(wire, to: String(s.id.dropFirst(2))) }
        else if bus.online.contains(s.id), RoomRules.canEmote(version: bus.versions[s.id]) { bus.send(.hit(item: wire), to: s.id) }
    }

    /// A thrown seat touching others on its way hits each once.
    private func collide(_ s: RoomSeat, _ frame: CGRect) {
        var others: [String: CGRect] = [:]
        for o in seats where o !== s && o.fling == nil && !o.held { if let f = o.panel?.frame { others[o.id] = f } }
        for id in ThrowRules.hits(frame, others: others, already: s.hitThisFlight) {
            s.hitThisFlight.insert(id)
            if let o = seats.first(where: { $0.id == id }) { landed(on: o, ThrowRules.friend) }
        }
    }

    /// A friend's Mac says they are out for `seconds` (held to 1...10): the stars over their seat.
    func knockedOut(_ id: String, seconds: Int) {
        guard ThrowCenter.shared.isOn, let s = seats.first(where: { $0.id == id }) else { return }
        let until = Date() + TimeInterval(min(max(seconds, 1), 10))
        s.koUntil = until
        DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow) { [weak s] in if s?.koUntil == until { s?.koUntil = nil } }
    }

    // MARK: 창에 매달기

    /// The window list, front first, with the same keys 폴더 친구 reads (no Screen Recording).
    private func windows() -> [ListedWindow] {
        guard let primary = NSScreen.screens.first?.frame.height,
              let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { ListedWindow($0, primaryHeight: primary) }
    }

    private func attach(_ s: RoomSeat, _ spot: HangRules.Spot) {
        guard let f = s.panel?.frame else { return }
        let w = spot.window.frame
        // Caught just under a top edge, it is put on it (the band would hold it over the window's title bar).
        let feet = CGPoint(x: f.midX, y: spot.side == .top ? max(f.minY, w.maxY) : f.minY)
        let rope = RubberBand(anchor: spot.anchor, floor: HangRules.floor(spot.side, on: w), position: feet)
        s.hang = RoomHang(window: spot.window.id, side: spot.side, offset: HangRules.offset(spot.side, anchor: spot.anchor, on: w), rope: rope)
        s.fling = nil
        tickOn()
        guard hangTimer == nil else { return }
        let t = Timer(timeInterval: HangRules.pollEvery, repeats: true) { [weak self] _ in self?.pollHangs() }
        RunLoop.main.add(t, forMode: .common)
        hangTimer = t
    }

    /// Lets go of the window: falls to the floor (or, already flying off a snapped band, keeps its seat's way).
    private func drop(_ s: RoomSeat, falling: Bool = true) {
        s.hang = nil
        s.band?.orderOut(nil)
        if s.panel?.isVisible == false { s.panel?.orderFrontRegardless() }
        if falling, !s.held { fly(s, .zero) }
    }

    /// Every half second while someone hangs: follow its window, hide while another is over it, fall once it is gone.
    private func pollHangs() {
        let hung = seats.filter { $0.hang != nil }
        guard !hung.isEmpty else { hangTimer?.invalidate(); hangTimer = nil; return }
        let list = windows(), me = getpid()
        for s in hung {
            guard var h = s.hang, let p = s.panel else { continue }
            switch HangRules.status(h.window, rect: CGRect(origin: p.frame.origin, size: s.body), in: list, me: me) {
            case .gone:
                drop(s)
            case .covered:
                if !h.hidden { h.hidden = true; p.orderOut(nil); s.band?.orderOut(nil); s.hang = h }
            case .at(let w):
                if h.hidden { h.hidden = false; p.orderFrontRegardless() }
                let a = HangRules.anchor(h.side, offset: h.offset, on: w.frame)
                if a != h.rope.anchor {
                    h.rope.follow(a, floor: HangRules.floor(h.side, on: w.frame))
                    if !s.held { p.setFrameOrigin(CGPoint(x: (h.rope.position.x - p.frame.width / 2).rounded(), y: h.rope.position.y.rounded())) }
                }
                s.hang = h
                drawBand(s)
            }
        }
    }

    /// The band from its knot on the window to the friend's middle, while it is stretched out at all.
    private func drawBand(_ s: RoomSeat) {
        guard let h = s.hang, !h.hidden, let f = s.panel?.frame else { s.band?.orderOut(nil); return }
        let a = HangRules.knot(h.side, anchor: h.rope.anchor, width: f.width), b = CGPoint(x: f.midX, y: f.minY + s.body.height / 2)
        guard hypot(b.x - a.x, b.y - a.y) > s.body.height / 2 + 6 else { s.band?.orderOut(nil); return }
        let box = CGRect(x: min(a.x, b.x) - 3, y: min(a.y, b.y) - 3, width: abs(a.x - b.x) + 6, height: abs(a.y - b.y) + 6).integral
        let p: NSPanel = s.band ?? {
            let p = NSPanel(contentRect: box, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.sharingType = .none
            p.contentView = BandLineView()
            return p
        }()
        s.band = p
        p.setFrame(box, display: false)
        (p.contentView as? BandLineView)?.ends = (CGPoint(x: a.x - box.minX, y: a.y - box.minY), CGPoint(x: b.x - box.minX, y: b.y - box.minY))
        if !p.isVisible { p.order(.below, relativeTo: s.panel?.windowNumber ?? 0) }
    }

    // MARK: Emotes

    /// 다같이: to every online friend that reads emotes, and here at once. False while waiting out the cooldown or
    /// with nobody to send to.
    @discardableResult
    func sendAll(_ kind: EmoteKind) -> Bool {
        let to = RoomRules.emoteTargets(online: bus.online, versions: bus.versions)
        guard kind != .toss, !to.isEmpty, now - lastSend >= Self.cooldown else { return false }
        lastSend = now
        to.forEach { bus.send(.emote(kind), to: $0) }
        SeasonCenter.shared.emoted()
        if let e = kind.effect { play(e) }
        return true
    }

    /// A friend's emote (after the link's 3 in 10 s). Nothing shows in a call or a recording.
    func received(_ kind: EmoteKind, from id: String) {
        guard !FriendVisit.quiet() else { return }
        let name = bus.friend(id)?.nickname ?? L("친구")
        guard let e = kind.effect else { flyIn(from: name); return }
        guard let s = seats.first(where: { $0.id == id }), let p = s.panel else {
            FriendVisit.shared.show(id, line: kind.line)
            return
        }
        play(e)
        let under = RoomPlace.bubbleBelow(edge) && s.hang == nil
        SpeechBubbleCenter.shared.say(text: "\(name): \(kind.line)", source: .system, aloud: false, repeats: true, seconds: Self.effectSeconds,
                                      anchor: { [weak p] in p.flatMap { $0.isVisible ? CGPoint(x: $0.frame.midX, y: under ? $0.frame.minY : $0.frame.maxY) : nil } },
                                      under: under)
    }

    /// Every seat plays `effect` together for a few seconds (not in a call or a recording).
    func play(_ effect: RoomEffect) {
        guard !FriendVisit.quiet() else { return }
        let start = Date()
        for s in seats { s.effect = effect; s.effectStart = start }
        clear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.seats.forEach { $0.effect = nil } }
        clear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.effectSeconds, execute: w)
    }

    // MARK: 한마디 and 입력 중 over 원격 모임 members

    /// A member's 한마디 over their head. False when they have no seat on screen (or in a call or a recording), so the
    /// caller shows it another way.
    func said(_ id: String, _ text: String) -> Bool {
        guard !FriendVisit.quiet(), let s = seats.first(where: { $0.id == id }), s.panel?.isVisible == true else { return false }
        s.talk.said(text, at: now)
        updateTalk()
        return true
    }

    /// A member is typing (`age` s ago at the relay).
    func typing(_ id: String, age: TimeInterval) {
        guard !FriendVisit.quiet(), let s = seats.first(where: { $0.id == id }) else { return }
        s.talk.typing(at: now, age: age)
        updateTalk()
    }

    /// Each seat's bubble for what its talk shows now, then one timer to the next change (none while nothing shows).
    private func updateTalk() {
        let t = now
        for s in seats {
            let show = s.talk.show(at: t)
            guard show != s.shown else { continue }
            s.shown = show
            guard let show else { s.bubble?.orderOut(nil); s.bubble = nil; continue }
            let p = s.bubble ?? Self.makeBubble()
            let host = NSHostingView(rootView: SeatBubbleView(show: show, tailUp: edge == .top))
            p.contentView = host
            p.setContentSize(host.fittingSize)
            p.orderFrontRegardless()
            s.bubble = p
        }
        placeBubbles()
        talkTurn?.cancel()
        guard let next = seats.compactMap({ $0.talk.next(after: t) }).min() else { return }
        let w = DispatchWorkItem { [weak self] in self?.updateTalk() }
        talkTurn = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next - t + 0.02), execute: w)
    }

    private func placeBubbles() {
        let vf = visible, edge = self.edge
        let shown = seats.filter { $0.bubble != nil && $0.panel != nil }
        let frames = shown.map { RoomBubbles.frame(seat: $0.panel!.frame, sprite: $0.cache.imageSize, size: $0.bubble!.frame.size, edge: edge, in: vf) }
        for (s, f) in zip(shown, RoomBubbles.stacked(frames, down: edge == .top)) where s.bubble?.frame.origin != f.origin {
            s.bubble?.setFrameOrigin(f.origin)
        }
    }

    private static func makeBubble() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true   // only a drawing: clicks go to what is under it
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.sharingType = .none   // a friend's words never go out in a screen share
        return p
    }

    /// A friend threw me: my own character flies in from the left edge and lands.
    private func flyIn(from name: String) {
        flown?.panel.orderOut(nil)
        let (p, size) = myPanel()
        let w = walls(size)
        let fling = Fling(at: CGPoint(x: w.minX, y: w.minY + w.height * 0.6), velocity: CGVector(dx: 1300, dy: 400), walls: w)
        p.setFrameOrigin(CGPoint(x: fling.position.x - size.width / 2, y: fling.position.y))
        p.orderFrontRegardless()
        flown = (p, fling, size)
        tickOn()
        SpeechBubbleCenter.shared.say(text: L("\(name)\(Banmal.particle(name, "이", "가")) 던져서 날아왔어!"), source: .system, aloud: false, repeats: true, seconds: 4,
                                      anchor: { [weak p] in p.flatMap { $0.isVisible ? CGPoint(x: $0.frame.midX, y: $0.frame.maxY) : nil } })
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak p] in
            p?.orderOut(nil)
            if let self, self.flown?.panel === p { self.flown = nil }
        }
    }
}

extension FriendRoom {
    /// A click-through panel the size of `size`, showing `view` over everything (out of screen shares).
    static func floater<V: View>(_ size: CGSize, _ view: V) -> NSPanel {
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.sharingType = .none
        p.contentView = NSHostingView(rootView: view)
        return p
    }

    /// My own character running, in a panel of its size.
    fileprivate func myPanel() -> (NSPanel, CGSize) {
        let cache = DogSpriteCache(SpriteLook(AppSettings.shared), pixelSize: 2)
        return (Self.floater(cache.imageSize, AnimatedDog(cache: cache, pose: .run, cpu: 0.6)), cache.imageSize)
    }
}

/// Takes every click on the seat (also the first while another app is active).
private final class RoomClickView: NSView {
    var onMouse: (NSEvent) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouse(event) }
    override func mouseDragged(with event: NSEvent) { onMouse(event) }
    override func mouseUp(with event: NSEvent) { onMouse(event) }
    override func rightMouseDown(with event: NSEvent) { onMouse(event) }
}

/// A seat: the effect over it, the character, and the 퇴근 sign in front when they are off. `t` pins the effect's
/// moment (QA renders); nil runs it live.
struct RoomFriendView: View {
    @ObservedObject var seat: RoomSeat
    var t: Double?

    var body: some View {
        let sprite = seat.body
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if seat.koUntil != nil || seat.bonkAt != nil { stun }
                if let e = seat.effect, e != .poop {
                    if let t {
                        RoomEffectView(effect: e, t: t)
                    } else {
                        TimelineView(.animation) { ctx in
                            RoomEffectView(effect: e, t: min(1, ctx.date.timeIntervalSince(seat.effectStart) / FriendRoom.effectSeconds))
                        }
                    }
                }
            }
            .frame(width: sprite.width, height: FriendRoom.headroom)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .bottom, spacing: 0) {
                Group {
                    if let c = seat.chair, !seat.flying {
                        ChairSeatView(chair: c, cache: seat.cache)
                    } else {
                        AnimatedDog(cache: seat.cache, pose: (seat.off || seat.koUntil != nil) && !seat.flying ? .lying : (seat.flying ? .run : .walk), cpu: 0.2)
                            .frame(width: seat.cache.imageSize.width, height: seat.cache.imageSize.height)
                    }
                }
                .frame(width: sprite.width, height: sprite.height, alignment: .bottom)
                    .overlay(alignment: .topTrailing) { if seat.off { OffSign().offset(x: 10) } }   // above the lying sprite: "Off work" is wider than 퇴근
                ZStack(alignment: .bottom) {
                    if seat.effect == .poop { PoopView(pop: t ?? 1).padding(.bottom, 1) }
                }
                .frame(width: 30, height: sprite.height, alignment: .bottom)
            }
        }
        .frame(width: sprite.width + 30, height: sprite.height + FriendRoom.headroom)
    }

    /// 기절 stars, or a 퍽 just after a hit, over the head.
    private var stun: some View {
        let kind: StunView.Kind = seat.koUntil != nil ? .out(StunRule.seconds) : .bonk
        let since = seat.koUntil.map { $0.addingTimeInterval(-StunRule.seconds) } ?? seat.bonkAt ?? Date()
        return Group {
            if let t {
                StunView(kind: kind, t: t)
            } else {
                TimelineView(.animation) { ctx in StunView(kind: kind, t: ctx.date.timeIntervalSince(since)) }
            }
        }
        .offset(y: 16)
    }
}

/// A seat's bubble: the 한마디, or three dots while they type. `t` pins the dots (QA renders); nil runs them live.
struct SeatBubbleView: View {
    let show: SeatTalk.Show
    var tailUp = false
    var t: Double?

    var body: some View {
        switch show {
        case .line(let text):
            SpeechBubbleView(text: text, tailUp: tailUp, tailDown: !tailUp, still: DesktopKit.reduceMotion)
        case .typing:
            TypingBubble(tailUp: tailUp, t: t)
        }
    }
}

/// 입력 중: three dots in a small card, rising one after another (still under 동작 줄이기).
struct TypingBubble: View {
    var tailUp = false
    var t: Double?
    private let paper = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        VStack(spacing: 0) {
            if tailUp { SpeechBubbleView.Tail().fill(paper).frame(width: 12, height: 6) }
            Group {
                if let t { dots(t) } else if DesktopKit.reduceMotion { dots(0) } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { dots($0.date.timeIntervalSinceReferenceDate) }
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Capsule().fill(paper))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            if !tailUp { SpeechBubbleView.Tail().fill(paper).frame(width: 12, height: 6).rotationEffect(.degrees(180)) }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .padding(RoomBubbles.pad)
        .fixedSize()
        .accessibilityLabel(L("입력 중"))
    }

    private func dots(_ t: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                let k = max(0, sin(t * 2 * .pi * 1.1 - Double(i) * 0.9))
                Circle().fill(Color.secondary.opacity(0.55 + 0.45 * k)).frame(width: 6, height: 6).offset(y: -3 * k)
            }
        }
        .frame(height: 9, alignment: .bottom)
    }
}

/// Hearts floating up, or confetti falling, `t` 0...1 through it.
struct RoomEffectView: View {
    let effect: RoomEffect
    let t: Double

    var body: some View {
        ZStack {
            switch effect {
            case .hearts:
                ForEach(0..<3, id: \.self, content: heart)
            case .party:
                ForEach(0..<9, id: \.self, content: confetti)
            case .poop:
                EmptyView()
            }
        }
    }

    private func heart(_ i: Int) -> some View {
        let k = max(0, min(1, t * 1.3 - Double(i) * 0.15))
        let x = CGFloat(i - 1) * 13 + CGFloat(sin((k + Double(i)) * 6)) * 3
        let y = 14 - CGFloat(k) * 30
        return Image(systemName: "heart.fill")
            .font(.system(size: 13 - CGFloat(i) * 2))
            .foregroundStyle(Color(red: 1, green: 0.42 + Double(i) * 0.08, blue: 0.58))
            .offset(x: x, y: y)
            .opacity(1 - k * k)
    }

    private func confetti(_ i: Int) -> some View {
        let colors: [Color] = [.pink, .yellow, .mint, .orange, .purple, .cyan]
        let x = CGFloat(i - 4) * 7
        let y = -16 + CGFloat(t) * 30 + CGFloat(i % 3) * 5
        return RoundedRectangle(cornerRadius: 1)
            .fill(colors[i % colors.count])
            .frame(width: 4, height: 7)
            .rotationEffect(.degrees(Double(i) * 47 + t * 360))
            .offset(x: x, y: y)
            .opacity(1 - t * 0.6)
    }
}

/// Our own 똥: three soft tiers with a curl on top, a face and pink cheeks. `pop` 0...1 is it popping in.
struct PoopView: View {
    var pop: Double = 1

    var body: some View {
        let brown = Color(red: 0.62, green: 0.41, blue: 0.26)
        let edge = Color(red: 0.38, green: 0.24, blue: 0.14)
        ZStack {
            Circle().fill(brown).overlay(Circle().stroke(edge, lineWidth: 1)).frame(width: 7, height: 7).offset(x: 3, y: -13)
            Capsule().fill(brown).overlay(Capsule().stroke(edge, lineWidth: 1)).frame(width: 13, height: 8).offset(y: -7)
            Capsule().fill(brown).overlay(Capsule().stroke(edge, lineWidth: 1)).frame(width: 20, height: 9).offset(y: -1)
            Capsule().fill(brown).overlay(Capsule().stroke(edge, lineWidth: 1)).frame(width: 27, height: 10).offset(y: 6)
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 6, height: 2).offset(x: -4, y: -3)
            HStack(spacing: 6) {
                Circle().fill(Color.black).frame(width: 3, height: 3)
                Circle().fill(Color.black).frame(width: 3, height: 3)
            }
            .offset(y: 4)
            HStack(spacing: 12) {
                Ellipse().fill(Color(red: 1, green: 0.55, blue: 0.62).opacity(0.85)).frame(width: 4, height: 2.5)
                Ellipse().fill(Color(red: 1, green: 0.55, blue: 0.62).opacity(0.85)).frame(width: 4, height: 2.5)
            }
            .offset(y: 7)
        }
        .frame(width: 28, height: 28)
        .scaleEffect(0.3 + 0.7 * min(1, pop * 4), anchor: .bottom)
        .accessibilityHidden(true)
    }
}

/// A little wooden 퇴근 sign on a stick.
struct OffSign: View {
    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "🌙 " + L("퇴근"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.25, green: 0.16, blue: 0.08))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.95, green: 0.83, blue: 0.62)))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(red: 0.55, green: 0.37, blue: 0.20), lineWidth: 1))
            Rectangle().fill(Color(red: 0.55, green: 0.37, blue: 0.20)).frame(width: 2, height: 7)
        }
        .fixedSize()
    }
}
