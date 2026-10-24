import AppKit
import Combine
import QuartzCore

// MARK: Rules (pure)

extension PlayNetState {
    /// P1 as the other Mac gets it: 0...1 of `f` (the visible frame), speeds in frames per second.
    init(_ b: PlayBody, in f: CGRect, stars: Int) {
        self.init(x: Double((b.x - f.minX) / f.width), y: Double((b.y - f.minY) / f.height),
                  vx: Double(b.vx / f.width), vy: Double(b.vy / f.height),
                  onGround: b.onGround, crouching: b.crouching, facingLeft: b.facingLeft, stars: stars)
    }

    /// The feet on this Mac's visible frame, kept on it whatever the friend's Mac sent.
    func feet(in f: CGRect) -> CGPoint {
        CGPoint(x: f.minX + min(max(x, 0), 1) * f.width, y: f.minY + min(max(y, 0), 1) * f.height)
    }
}

/// One invite out (30 s), one session at a time, and who may talk in it. Pure and tested (NetPlayTests).
struct NetPlayLink {
    static let inviteLife: TimeInterval = 30
    /// No state from the friend for this long: their Mac is gone, the session ends.
    static let silence: TimeInterval = 5

    struct Game: Equatable {
        var friend: String
        var game: NetGame
        var seed: UInt64
    }

    private(set) var sent: (game: Game, at: TimeInterval)?
    private(set) var session: Game?
    var heard: TimeInterval = 0

    /// false while an invite is out or a session is on.
    mutating func invite(_ g: Game, now: TimeInterval) -> Bool {
        guard session == nil, sent.map({ now - $0.at >= Self.inviteLife }) ?? true else { return false }
        sent = (g, now)
        return true
    }

    /// The invite `id` answered, when it is the one we sent and still live (used up either way); nil for any other.
    mutating func answered(by id: String, now: TimeInterval) -> Game? {
        guard let s = sent, s.game.friend == id else { return nil }
        sent = nil
        return now - s.at < Self.inviteLife ? s.game : nil
    }

    mutating func begin(_ g: Game, now: TimeInterval) {
        session = g
        sent = nil
        heard = now
    }

    mutating func end() { session = nil }

    /// Play, stars and the end count only from the session's friend.
    func admits(_ m: SocialMessage, from id: String) -> Bool {
        switch m {
        case .play, .starTaken, .playEnd: return session?.friend == id
        default: return true
        }
    }

    func silent(now: TimeInterval) -> Bool { session != nil && now - heard >= Self.silence }
}

// MARK: The session

/// 같이 놀기 over the network: 같이 뛰기 (놀이 모드 side by side) or 별 대결 (StarGame with a shared seed). One Mac
/// invites, the other accepts, then both run their own 놀이 모드 and send P1 about 20 times a second; the friend shows
/// as a see-through ghost with a name tag, display only. Either end, the friend going offline or 5 s of silence ends
/// both. Key: netplay.on = 친구의 같이 놀기 초대 받기 (unset = on).
final class NetPlay {
    static let shared = NetPlay()
    static let ready = true
    private var link = NetPlayLink()
    /// The game on now, if any.
    var session: NetPlayLink.Game? { link.session }
    private var bag = Set<AnyCancellable>()
    private var asking = false
    private var ghost: NetGhost?
    private var sendClock: TimeInterval = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func name(_ id: String) -> String { SocialBus.shared.friend(id)?.nickname ?? L("친구") }
    private func say(_ text: String) { SpeechBubbleCenter.shared.say(text: text, source: .system, aloud: false, repeats: true) }

    func start() {
        guard bag.isEmpty else { return }
        SocialBus.shared.inbox.sink { [weak self] in self?.receive($0.message, from: $0.from) }.store(in: &bag)
        SocialBus.shared.$online.sink { [weak self] on in
            if let f = self?.link.session?.friend, !on.contains(f) { PlayMode.shared.end() }
        }.store(in: &bag)
    }

    func invite(_ friendID: String, _ game: NetGame) {
        let seed = UInt64.random(in: 0 ... .max)
        guard PluginGate.isOpen(.netPlay), SocialBus.shared.online.contains(friendID), !PlayMode.shared.isPlaying,
              link.invite(.init(friend: friendID, game: game, seed: seed), now: now) else { return }
        SocialBus.shared.send(.invite(game, seed: seed), to: friendID)
        say(L("초대를 보냈어요"))
    }

    /// 별 대결: I picked up that star.
    func took(_ star: Int) {
        if let f = link.session?.friend { SocialBus.shared.send(.starTaken(star), to: f) }
    }

    private func receive(_ m: SocialMessage, from id: String) {
        guard link.admits(m, from: id) else { return }
        switch m {
        case let .invite(game, seed):
            invited(by: id, game, seed)
        case .inviteAnswer(let yes):
            guard let g = link.answered(by: id, now: now) else { return }
            if yes { begin(g) } else { say(L("\(name(id))가 지금은 같이 못 놀아요")) }
        case .play(let s):
            link.heard = now
            ghost?.target = s
            StarGame.shared.remote(score: s.stars)
        case .starTaken(let i):
            StarGame.shared.remote(took: i)
        case .playEnd:
            let duel = link.session?.game == .starDuel
            link.end()   // so ended() sends nothing back
            PlayMode.shared.end()
            if !duel { say(L("\(name(id))가 놀이를 끝냈어요")) }   // 별 대결 says the result instead
        default:
            break
        }
    }

    private func invited(by id: String, _ game: NetGame, _ seed: UInt64) {
        let on = AppDefaults.store.object(forKey: "netplay.on") as? Bool ?? true
        guard PluginGate.isOpen(.netPlay), on, !PlayMode.shared.isPlaying, link.session == nil, !asking else {
            SocialBus.shared.send(.inviteAnswer(accept: false), to: id)
            return
        }
        asking = true
        DispatchQueue.main.async { [self] in
            let n = name(id)
            let title = game == .play ? L("\(n)이(가) 같이 뛰자고 해요") : L("\(n)이(가) 별 대결 하자고 해요")
            #if MAS
            let yes = SocialAlerts.ask(title, "", [L("수락"), L("거절")], timeout: NetPlayLink.inviteLife, safe: 1) == .alertFirstButtonReturn
            #else
            let yes = SocialQA.active ? SocialQA.decide("invite")
                : SocialAlerts.ask(title, "", [L("수락"), L("거절")], timeout: NetPlayLink.inviteLife, safe: 1) == .alertFirstButtonReturn
            #endif
            asking = false
            let ok = yes && SocialBus.shared.online.contains(id) && !PlayMode.shared.isPlaying && link.session == nil
            SocialBus.shared.send(.inviteAnswer(accept: ok), to: id)
            if ok { begin(.init(friend: id, game: game, seed: seed)) }
        }
    }

    private func begin(_ g: NetPlayLink.Game) {
        guard let f = SocialBus.shared.friend(g.friend) else { return }
        let play = PlayMode.shared
        if g.game == .starDuel {
            StarGame.shared.start(duel: true, seed: g.seed, rival: f.nickname)
        } else {
            play.start(.buddy)
            play.twoPlayer = false   // P2 is the friend
        }
        guard play.isPlaying, let world = play.overlay() else { SocialBus.shared.send(.playEnd, to: g.friend); return }
        link.begin(g, now: now)
        ghost = NetGhost(look: f.look, name: f.nickname, in: world, visible: play.visible)
        sendClock = 0
        play.onTick.append { [weak self] dt in self?.tick(dt) }
        play.onEnd.append { [weak self] in self?.ended() }
    }

    private func tick(_ dt: TimeInterval) {
        let play = PlayMode.shared
        guard let g = link.session else { return }
        if link.silent(now: now) { play.end(); return }
        sendClock += dt
        if sendClock >= 0.05, let b = play.body() {   // about 20 a second (the link allows 30)
            sendClock = 0
            SocialBus.shared.send(.play(PlayNetState(b, in: play.visible, stars: StarGame.shared.score)), to: g.friend)
        }
        ghost?.step(dt, in: play.visible)
    }

    private func ended() {
        ghost = nil
        guard let g = link.session else { return }
        link.end()
        SocialBus.shared.send(.playEnd, to: g.friend)
    }
}

/// The friend on this screen: their character, see-through, with their name over it, eased to where their last state
/// says. Touches nothing.
private final class NetGhost {
    private let layer = CALayer(), tag = CATextLayer()
    private let frames: [BuddyGait: [NSImage]]
    private let size: CGSize
    var target: PlayNetState?
    private var at: CGPoint?
    private var clock: TimeInterval = 0

    init(look: FriendLook, name: String, in world: CALayer, visible: CGRect) {
        let cache = DogSpriteCache(SpriteLook(friend: look), pixelSize: MotionStore.shared.buddySize.pixelSize)
        frames = BuddyGait.frames(cache)
        size = cache.imageSize
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: visible.midX, y: visible.midY)) }?.backingScaleFactor ?? 2
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer.magnificationFilter = cache.smooth ? .linear : .nearest
        layer.opacity = 0.8
        let s = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        tag.string = s
        tag.alignmentMode = .center
        tag.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        tag.cornerRadius = 4
        tag.bounds = CGRect(x: 0, y: 0, width: s.size().width + 10, height: s.size().height + 2)
        tag.anchorPoint = CGPoint(x: 0.5, y: 0)
        for l in [layer, tag] {
            l.contentsScale = scale
            l.isHidden = true   // until the first state
            l.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull(), "hidden": NSNull()]
            world.addSublayer(l)
        }
    }

    deinit { layer.removeFromSuperlayer(); tag.removeFromSuperlayer() }

    func step(_ dt: TimeInterval, in visible: CGRect) {
        guard let s = target else { return }
        let goal = s.feet(in: visible), k = CGFloat(min(1, dt * 15))
        let p = at.map { CGPoint(x: $0.x + (goal.x - $0.x) * k, y: $0.y + (goal.y - $0.y) * k) } ?? goal
        at = p
        clock += dt
        let walk = frames[.walk] ?? []
        let image: NSImage? = !s.onGround ? (walk.count > 1 ? walk[1] : walk.first)   // legs apart in the air
            : abs(s.vx) > 0.001 && !walk.isEmpty ? walk[DesktopKit.reduceMotion ? 0 : Int(clock / 0.12) % walk.count]
            : frames[.stand]?.first
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.position = p
        layer.setAffineTransform(s.facingLeft ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        tag.position = CGPoint(x: p.x, y: p.y + size.height * (s.crouching ? 0.75 : 1) + 2)
        layer.isHidden = false
        tag.isHidden = false
        CATransaction.commit()
    }
}
