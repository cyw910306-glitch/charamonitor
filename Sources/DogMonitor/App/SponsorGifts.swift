import Foundation

/// 후원 선물: eight decorations that open one at a time, in this order, as 후원 친구 is watched to the end (Sponsor.swift,
/// the direct build only). Each one is a choice in a menu that already exists. The App Store build has no 후원 친구, so
/// there every gift is simply open. Raw values are saved; never rename one.
enum SponsorGift: String, CaseIterable {
    case rugHearts, peach, cloud, party, ribbon, rugStars, cocoa, rugRainbow

    var emoji: String {
        switch self {
        case .rugHearts: return "💗"
        case .peach: return "🍑"
        case .cloud: return "☁️"
        case .party: return "🎉"
        case .ribbon: return "🎀"
        case .rugStars: return "🌟"
        case .cocoa: return "☕"
        case .rugRainbow: return "🌈"
        }
    }

    var label: String {
        switch self {
        case .rugHearts: return L("하트 러그")
        case .peach: return L("복숭아 색")
        case .cloud: return L("구름 쿠션")
        case .party: return L("빵빠레 반응")
        case .ribbon: return L("리본 폴더")
        case .rugStars: return L("별빛 러그")
        case .cocoa: return L("코코아 색")
        case .rugRainbow: return L("무지개 러그")
        }
    }

    /// Where it shows up, short (the 설정 tile).
    var place: String {
        switch self {
        case .rugHearts, .rugStars, .rugRainbow: return L("러그 그림")
        case .peach, .cocoa: return L("러그·위젯 색")
        case .cloud: return L("장난감 상자")
        case .party: return L("친구 누르기")
        case .ribbon: return L("폴더 모양")
        }
    }

    /// Where to find it, as a sentence (the card once it opened).
    var howTo: String {
        switch self {
        case .rugHearts, .rugStars, .rugRainbow: return L("바탕화면 러그의 그림에서 골라요")
        case .peach, .cocoa: return L("러그 색과 집중 위젯 색에서 골라요")
        case .cloud: return L("장난감 상자에서 꺼내요")
        case .party: return L("친구를 누르면 가끔 나와요")
        case .ribbon: return L("폴더 친구의 모양에서 골라요")
        }
    }
}

/// Which 후원 선물 are open, saved as a JSON list of ids under `sponsor.gifts` (it travels in 내 설정 파일 to the owner's
/// other Macs; the counters stay on this one). Unknown ids are ignored.
final class SponsorGifts: ObservableObject {
    static let shared = SponsorGifts()
    static let key = "sponsor.gifts"
    #if MAS
    static let everyOpen = true
    #else
    static let everyOpen = false
    #endif

    private let defaults: UserDefaults
    private let allOpen: Bool
    @Published private(set) var unlocked: [SponsorGift]

    /// `allOpen`: the App Store build (tests pass it to check that build's rule).
    init(defaults: UserDefaults = AppDefaults.store, allOpen: Bool = everyOpen) {
        self.defaults = defaults
        self.allOpen = allOpen
        unlocked = Self.decode(defaults.data(forKey: Self.key))
    }

    static func decode(_ data: Data?) -> [SponsorGift] {
        let ids = data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return SponsorGift.allCases.filter { ids.contains($0.rawValue) }
    }

    func isOpen(_ g: SponsorGift) -> Bool { allOpen || unlocked.contains(g) }
    var openCount: Int { SponsorGift.allCases.filter(isOpen).count }
    /// The next one to open, in order; nil once all are.
    var next: SponsorGift? { SponsorGift.allCases.first { !isOpen($0) } }

    /// Opens `next` and returns it; nil when there is nothing left.
    @discardableResult
    func unlock() -> SponsorGift? {
        guard let g = next else { return nil }
        unlocked = SponsorGift.allCases.filter { unlocked.contains($0) || $0 == g }
        defaults.set(try? JSONEncoder().encode(unlocked.map(\.rawValue)), forKey: Self.key)
        return g
    }
}

/// A menu choice that may be a 후원 선물: pickers list the open ones plus whatever is chosen now (a locked one picked on
/// another Mac still shows and renders).
protocol GiftChoice: CaseIterable, Equatable {
    var gift: SponsorGift? { get }
}

extension GiftChoice {
    var isOffered: Bool { gift.map(SponsorGifts.shared.isOpen) ?? true }
    static func offered(current: Self?) -> [Self] { allCases.filter { $0 == current || $0.isOffered } }
}

extension RugFace: GiftChoice {
    var gift: SponsorGift? {
        switch self {
        case .hearts: return .rugHearts
        case .stars: return .rugStars
        case .rainbow: return .rugRainbow
        default: return nil
        }
    }
}

extension FocusTheme: GiftChoice {
    var gift: SponsorGift? { self == .peach ? .peach : self == .cocoa ? .cocoa : nil }
}

extension ToyKind: GiftChoice {
    var gift: SponsorGift? { self == .cloud ? .cloud : nil }
}

extension FolderIconStyle: GiftChoice {
    var gift: SponsorGift? { self == .ribbon ? .ribbon : nil }
}
