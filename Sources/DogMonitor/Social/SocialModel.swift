import AppKit
import Combine

/// 가상 오피스: what someone is doing, in menu order.
enum OfficeStatus: String, Codable, CaseIterable {
    case working, away, meal, restroom, meeting, focus, off

    var label: String {
        switch self {
        case .working: return L("근무 중")
        case .away: return L("자리 비움")
        case .meal: return L("식사")
        case .restroom: return L("화장실")
        case .meeting: return L("회의")
        case .focus: return L("집중")
        case .off: return L("퇴근")
        }
    }

    var emoji: String {
        switch self {
        case .working: return "💻"
        case .away: return "🚶"
        case .meal: return "🍚"
        case .restroom: return "🚻"
        case .meeting: return "📞"
        case .focus: return "🎧"
        case .off: return "🌙"
        }
    }
}

/// A nudge of one 옷 입히기 slot, in art pixels (-8...8).
struct OutfitNudge: Codable, Equatable {
    var dx: Int
    var dy: Int
}

/// 옷 입히기: one item id per slot (Wardrobe.items), nil = nothing there. Unknown ids are skipped when drawn.
struct Outfit: Codable, Equatable {
    var head: String?
    var eyes: String?
    var neck: String?
    /// "#RRGGBB": a shirt in that colour.
    var shirt: String?
    /// By slot name ("head", "eyes", "neck").
    var nudges: [String: OutfitNudge]?

    var isEmpty: Bool { head == nil && eyes == nil && neck == nil && shirt == nil }
}

/// How a paired friend looks on this Mac: a built-in character by id plus its 꾸미기, never pack or photo art.
struct FriendLook: Codable, Equatable {
    /// .custom never travels (it goes out as .dog).
    var character: SpriteCharacter
    /// catID or originalID; nil for the dog.
    var id: String?
    var profile: DogProfile?
    var colors: [String: RGBColor]?
    var cat: CatProfile?
    var outfit: Outfit?

    static let fallback = FriendLook(character: .dog, id: nil, profile: nil, colors: nil, cat: nil, outfit: nil)

    /// A friend's look as this Mac keeps it: .custom, or one over 4 KiB encoded (a look is a few hundred bytes), shows
    /// as the plain dog.
    static func received(_ look: FriendLook) -> FriendLook {
        guard look.character != .custom, let d = SocialWire.encode(look), d.count <= 4096 else { return .fallback }
        return look
    }
}

/// A paired friend. The key that proves it is in the Keychain, never here.
struct SocialFriend: Codable, Equatable, Identifiable {
    /// The friend's install id: a random UUID made once per install.
    var id: String
    /// What they call themselves (16 characters at most).
    var nickname: String
    var look: FriendLook
    var status: OfficeStatus
    var pairedAt: Date
}

enum NetGame: String, Codable { case play, starDuel }

/// One player for the other Mac, about 20 a second. x and y are 0...1 of the sender's visible frame; speeds are
/// visible frames per second.
struct PlayNetState: Codable, Equatable {
    var x: Double, y: Double
    var vx: Double, vy: Double
    var onGround: Bool, crouching: Bool, facingLeft: Bool
    /// 별 대결 score.
    var stars: Int
}

/// Everything paired Macs say to each other. The sender is the connection's key, never a field here.
enum SocialMessage: Codable, Equatable {
    case hello(nickname: String, look: FriendLook, status: OfficeStatus, version: Int)
    case look(FriendLook)
    case status(OfficeStatus)
    /// Plain text, 200 characters at most.
    case chat(String)
    case invite(NetGame, seed: UInt64)
    case inviteAnswer(accept: Bool)
    case play(PlayNetState)
    case starTaken(Int)
    case playEnd
    /// 20 ms of 16 kHz mono Int16 little-endian (640 bytes).
    case voice(seq: UInt32, pcm: Data)
    case voiceEnd
    case remoteAsk
    case remoteAnswer(accept: Bool, screenSharingOn: Bool)
    case bye
}

/// The one place features talk to 같은 와이파이 친구. Stream 4 fills the bodies in; until then nothing is on and
/// nothing is sent.
final class SocialBus: ObservableObject {
    static let shared = SocialBus()
    /// 설정 > 플러그인 > 근처 친구 on (and the plugin open): listener and browser up.
    @Published private(set) var isOn = false
    @Published private(set) var friends: [SocialFriend] = []
    /// Friend ids with a live connection.
    @Published private(set) var online: Set<String> = []
    /// Me in the 가상 오피스: sent to online friends when it changes and in every hello.
    @Published var myStatus: OfficeStatus = .working
    /// Every message from a paired friend, with the friend's id.
    let inbox = PassthroughSubject<(from: String, message: SocialMessage), Never>()

    // Stream 4's state (Social/Pairing.swift has the rest).
    /// Macs nearby showing their 친구 추가 code.
    @Published var nearby: [NearbyMac] = []
    /// My 6-digit code while 내 코드 보여주기 shows it.
    @Published var code: String?
    /// Friends whose chat came while a visit could not show (a call, a recording).
    @Published var unread: Set<String> = []
    var defaults: UserDefaults = AppDefaults.store
    var keys: FriendKeys = .keychain
    var node: SocialNode?
    var bag = Set<AnyCancellable>()
    var lastLook: FriendLook?
    private var gate: AnyCancellable?

    func start() {
        friends = loadFriends()
        refresh()
        // The plugin opening or closing (a signed list moved its day) turns 근처 친구 on or off too; after the change lands.
        gate = PluginCenter.shared.$open.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func send(_ message: SocialMessage, to friendID: String) { node?.send(message, to: friendID) }

    /// To every online friend.
    func broadcast(_ message: SocialMessage) { online.forEach { send(message, to: $0) } }

    /// 데스크톱 친구 ▸ 친구 ▸ ... (empty while off).
    static func menuItems() -> [NSMenuItem] { shared.isOn ? shared.friendMenu() : [] }

    /// The setters stream 4's code uses (the published values stay read-only outside).
    func setOn(_ on: Bool) { isOn = on }
    func setFriends(_ f: [SocialFriend]) { friends = f }
    func setOnline(_ o: Set<String>) { online = o }
}

extension SocialFriend {
    var isOnline: Bool { SocialBus.shared.online.contains(id) }
}
