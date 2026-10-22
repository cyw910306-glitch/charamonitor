#if !MAS   // 후원 친구 is the direct build's only: the App Store build has none (docs/appstore/review-notes.md)
import AppKit
import Combine

// MARK: The list

/// One text in both languages; the app shows the one it runs in.
struct SponsorText: Codable, Equatable {
    var ko: String
    var en: String
    var shown: String { appIsEnglish ? en : ko }
}

/// One 후원 친구 card: one of the maker's own services.
struct SponsorCard: Codable, Equatable {
    var id: String
    var emoji: String
    var color: String
    var url: String
    var title: SponsorText
    var pitch: SponsorText
    var cta: SponsorText
    /// A paid card (a company's, not the maker's own service): the card says 광고, as Korean ad rules ask.
    var paid: Bool? = nil
}

/// web/sponsors.json, signed like update.json (sponsors.json.sig, scripts/package.sh). `serial` only goes up; `enabled`
/// false is the kill switch (a cached one holds offline too). Only `serial` and `enabled` are required, so
/// `{"serial":2,"enabled":false}` is a whole kill switch.
struct SponsorManifest: Equatable {
    var serial: Int
    var enabled: Bool
    var maxPerDay: Int
    var minHoursBetween: Double
    /// Every card's host must be one of these: a consistency check inside the signed file (the signature is the
    /// security), so a typo in a card's link drops that card instead of opening somewhere unplanned.
    var hosts: [String]
    var cards: [SponsorCard]
    /// When this Mac last fetched and verified it from the site (not part of the file); nil for the built-in list.
    /// Automatic offers come only from a list fetched in the last `SponsorRules.freshFor`.
    var fetchedAt: Date? = nil
}

enum SponsorCheck {
    static let maxBytes = 65_536, maxSignatureBytes = 256
    static let maxHosts = 20, maxCards = 20
    static let manifestURL = URL(string: "https://\(UpdateCheck.checkHost)/sponsors.json")!
    static let signatureURL = URL(string: "https://\(UpdateCheck.checkHost)/sponsors.json.sig")!

    enum Failure: Error, Equatable { case tooBig, badSignature, badManifest, rollback }

    private struct Raw: Decodable {
        var serial: Int, enabled: Bool, maxPerDay: Int, minHoursBetween: Double, hosts: [String], cards: [Lossy]

        private enum CodingKeys: String, CodingKey { case serial, enabled, maxPerDay, minHoursBetween, hosts, cards }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            serial = try c.decode(Int.self, forKey: .serial)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            maxPerDay = try c.decodeIfPresent(Int.self, forKey: .maxPerDay) ?? 2
            minHoursBetween = try c.decodeIfPresent(Double.self, forKey: .minHoursBetween) ?? 3
            hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
            cards = try c.decodeIfPresent([Lossy].self, forKey: .cards) ?? []
        }
    }

    /// One card that may not decode (a missing language, a wrong type): nil then, and only it is dropped.
    private struct Lossy: Decodable {
        let card: SponsorCard?
        init(from decoder: Decoder) throws { card = try? SponsorCard(from: decoder) }
    }

    /// The size, then the release key's signature over the exact bytes, then the parse. `minSerial`: the cached list's
    /// (an older list is a rollback). `rejected`: cards dropped as bad.
    static func verify(_ data: Data, signature: Data, publicKey: [UInt8] = UpdateCheck.publicKey,
                       minSerial: Int = 0) throws -> (manifest: SponsorManifest, rejected: Int) {
        guard data.count <= maxBytes else { throw Failure.tooBig }
        guard UpdateCheck.signed(data, signature: signature, publicKey: publicKey) else { throw Failure.badSignature }
        let parsed = try parse(data)
        guard parsed.manifest.serial >= minSerial else { throw Failure.rollback }
        return parsed
    }

    /// The JSON with each card checked on its own: a bad one is dropped, the good ones stay (at most `maxCards`).
    static func parse(_ data: Data) throws -> (manifest: SponsorManifest, rejected: Int) {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.serial >= 0, raw.hosts.count <= maxHosts,
              raw.minHoursBetween.isFinite else { throw Failure.badManifest }
        let hosts = raw.hosts.map { $0.lowercased() }
        var seen = Set<String>()
        let cards = raw.cards.compactMap(\.card).filter { valid($0, hosts: Set(hosts)) && seen.insert($0.id).inserted }.prefix(maxCards)
        let m = SponsorManifest(serial: raw.serial, enabled: raw.enabled, maxPerDay: min(2, max(0, raw.maxPerDay)),
                                minHoursBetween: min(168, max(1, raw.minHoursBetween)), hosts: hosts, cards: Array(cards))
        return (m, raw.cards.count - m.cards.count)
    }

    static func valid(_ c: SponsorCard, hosts: Set<String>) -> Bool {
        func fits(_ t: SponsorText, _ most: Int) -> Bool {
            [t.ko, t.en].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= most }
        }
        return c.id.range(of: #"\A[a-z0-9-]{1,32}\z"#, options: .regularExpression) != nil
            && c.color.range(of: #"\A#[0-9A-Fa-f]{6}\z"#, options: .regularExpression) != nil
            && (1...4).contains(c.emoji.count)
            && fits(c.title, 40) && fits(c.pitch, 120) && fits(c.cta, 16)
            && allowed(c.url, hosts: hosts) != nil
    }

    /// `text` as a URL when it is https on exactly one of `hosts`, with no port or login.
    static func allowed(_ text: String, hosts: Set<String>) -> URL? {
        guard let u = URL(string: text), u.scheme == "https", let h = u.host?.lowercased(), hosts.contains(h),
              u.port == nil, u.user == nil, u.password == nil else { return nil }
        return u
    }

    /// Both files from the site (UpdateCheck.fetch: our host only, 200, no cache on disk, size capped), or from `folder` (QA).
    static func fetch(folder: URL? = nil) async throws -> (data: Data, signature: Data) {
        if let folder {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent("sponsors.json")),
                  let s = try? Data(contentsOf: folder.appendingPathComponent("sponsors.json.sig")) else { throw Failure.badManifest }
            return (d, s)
        }
        async let d = UpdateCheck.fetch(manifestURL, maxBytes: maxBytes)
        async let s = UpdateCheck.fetch(signatureURL, maxBytes: maxSignatureBytes)
        return (try await d, try await s)
    }

    /// `--check-sponsors [폴더]`: read-only. Fetches (or reads) the list, verifies it and prints what the app would use.
    static func runCLI(folder: URL?) async -> Int32 {
        do {
            let files = try await fetch(folder: folder)
            let (m, rejected) = try verify(files.data, signature: files.signature)
            print("서명 확인됨 · serial \(m.serial) · \(m.enabled ? "켜짐" : "꺼짐(킬 스위치)") · 하루 \(m.maxPerDay)번 · \(m.minHoursBetween)시간 간격")
            print("카드 \(m.cards.count)개: \(m.cards.map(\.id).joined(separator: ", ")) · 버린 카드 \(rejected)개")
            return 0
        } catch {
            print("실패: \(error)")
            return 1
        }
    }
}

extension SponsorManifest {
    /// The list built into this version (web/sponsors.json when it shipped; a test keeps them equal), for a Mac that has
    /// never fetched one.
    static let bundled: SponsorManifest = (try? SponsorCheck.parse(Data(bundledJSON.utf8)).manifest)
        ?? SponsorManifest(serial: 0, enabled: false, maxPerDay: 0, minHoursBetween: 24, hosts: [], cards: [])

    private static let bundledJSON = #"""
    {"serial":1,"enabled":true,"maxPerDay":2,"minHoursBetween":3,
     "hosts":["wayhomeguide.co.kr","offer-platform.vercel.app","tokku-kit.vercel.app","mbtilovetest.com","benefit-radar-kappa.vercel.app","jlpt-n3-study.vercel.app"],
     "cards":[
      {"id":"wayhome","emoji":"🏠","color":"#B04238","url":"https://wayhomeguide.co.kr",
       "title":{"ko":"WAYHOME 셀프 인테리어 길잡이","en":"WAYHOME self-interior guide"},
       "pitch":{"ko":"셀프 인테리어, 순서와 견적부터 같이 잡아 줘요. 처음이어도 헤매지 않아요.","en":"Plan your own interior job step by step, from the order of work to quotes."},
       "cta":{"ko":"구경하기","en":"Take a look"}},
      {"id":"offer","emoji":"🎤","color":"#2F4BD8","url":"https://offer-platform.vercel.app",
       "title":{"ko":"OFFER¹ 면접 코칭","en":"OFFER¹ interview coaching"},
       "pitch":{"ko":"실전처럼 연습하고 답변을 다듬어요. 면접 전날의 막막함이 줄어들어요.","en":"Practice like the real thing and sharpen your answers before the big day."},
       "cta":{"ko":"둘러보기","en":"See how"}},
      {"id":"tokku","emoji":"🎨","color":"#E2557B","url":"https://tokku-kit.vercel.app",
       "title":{"ko":"톡꾸 키트: 사진으로 카톡 테마","en":"Tokku Kit: KakaoTalk themes from photos"},
       "pitch":{"ko":"좋아하는 사진으로 나만의 카톡 테마를 만들어요. 무료이고 금방 끝나요.","en":"Turn your favorite photos into your own KakaoTalk theme. Free and quick."},
       "cta":{"ko":"만들어 보기","en":"Try it"}},
      {"id":"mbti","emoji":"💘","color":"#C2366A","url":"https://mbtilovetest.com",
       "title":{"ko":"MBTI 연애 테스트","en":"MBTI love test"},
       "pitch":{"ko":"우리 둘의 연애 궁합은 어떨까요? 몇 문항만 답하면 결과가 나와요.","en":"How well do you two match? Answer a few questions and see."},
       "cta":{"ko":"해 보기","en":"Take the test"}},
      {"id":"benefit","emoji":"🎁","color":"#1F8460","url":"https://benefit-radar-kappa.vercel.app",
       "title":{"ko":"혜택레이더: 정부 혜택 매칭","en":"Benefit Radar: government benefits"},
       "pitch":{"ko":"조건만 넣으면 받을 수 있는 정부 혜택을 찾아 줘요. 놓친 지원금이 있을지 몰라요.","en":"Enter a few details and see the government benefits you may qualify for."},
       "cta":{"ko":"찾아보기","en":"Find mine"}},
      {"id":"jlpt","emoji":"🗾","color":"#3E3166","url":"https://jlpt-n3-study.vercel.app",
       "title":{"ko":"JLPT 스터디","en":"JLPT study"},
       "pitch":{"ko":"N5부터 N1까지 단어, 한자, 문법, 모의고사를 한곳에서 공부해요.","en":"Words, kanji, grammar and mock tests from N5 to N1, all in one place."},
       "cta":{"ko":"공부하기","en":"Start studying"}}
     ]}
    """#

    /// The cached list when its bytes still verify (it was checked when it came; checked again here) and its serial is
    /// not below the bundled one's, else `bundled`. So a cached `enabled: false` holds offline, and a newer app's
    /// built-in kill switch beats an older cached list.
    static func load(_ defaults: UserDefaults, publicKey: [UInt8] = UpdateCheck.publicKey, bundled: SponsorManifest = bundled) -> SponsorManifest {
        guard let d = defaults.data(forKey: SponsorCenter.manifestKey), let s = defaults.data(forKey: SponsorCenter.signatureKey),
              var m = try? SponsorCheck.verify(d, signature: s, publicKey: publicKey).manifest, m.serial >= bundled.serial else { return bundled }
        m.fetchedAt = defaults.object(forKey: SponsorCenter.fetchedKey) as? Date
        return m
    }
}

// MARK: State and rules

/// 얼마나 자주. Raw values are saved; never rename one.
enum SponsorFrequency: String, Codable, CaseIterable {
    case sometimes, normal

    var label: String { self == .sometimes ? L("가끔") : L("보통") }
}

/// What this Mac counted (shown in 설정, never sent anywhere).
struct SponsorStats: Codable, Equatable {
    var offers = 0, opens = 0, completes = 0, clicks = 0
}

/// 후원 친구's own state on this Mac (UserDefaults `sponsor.state`; not in 내 설정 파일).
struct SponsorState: Codable, Equatable {
    var on = true
    var frequency = SponsorFrequency.normal
    /// When this Mac first ran it: nothing comes in the first two days (upgraders get them too).
    var firstSeen: Date?
    /// The one-time explanation bubble really showed.
    var introduced = false
    /// "yyyy-MM-dd" in the local calendar; the counters below are for that day.
    var day = ""
    var offersToday = 0, rewardsToday = 0
    /// 오늘은 그만 was pressed on that day.
    var stoppedDay = ""
    var lastOfferAt: Date?
    /// Offers let go by in a row; three make the next ones rarer (`backoff` 0...5, the gap doubling each step).
    var ignoredStreak = 0, backoff = 0
    /// Card id to when it last came, so each comes in turn.
    var lastShown: [String: Date] = [:]
    var stats = SponsorStats()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SponsorState()
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? d.on
        frequency = (try? c.decodeIfPresent(SponsorFrequency.self, forKey: .frequency)) ?? d.frequency
        firstSeen = try? c.decodeIfPresent(Date.self, forKey: .firstSeen)
        introduced = (try? c.decodeIfPresent(Bool.self, forKey: .introduced)) ?? d.introduced
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? d.day
        offersToday = (try? c.decodeIfPresent(Int.self, forKey: .offersToday)) ?? d.offersToday
        rewardsToday = (try? c.decodeIfPresent(Int.self, forKey: .rewardsToday)) ?? d.rewardsToday
        stoppedDay = (try? c.decodeIfPresent(String.self, forKey: .stoppedDay)) ?? d.stoppedDay
        lastOfferAt = try? c.decodeIfPresent(Date.self, forKey: .lastOfferAt)
        ignoredStreak = (try? c.decodeIfPresent(Int.self, forKey: .ignoredStreak)) ?? d.ignoredStreak
        backoff = min(SponsorRules.maxBackoff, max(0, (try? c.decodeIfPresent(Int.self, forKey: .backoff)) ?? d.backoff))
        lastShown = (try? c.decodeIfPresent([String: Date].self, forKey: .lastShown)) ?? d.lastShown
        stats = (try? c.decodeIfPresent(SponsorStats.self, forKey: .stats)) ?? d.stats
    }

    /// A card came. Automatic ones count toward the day; 지금 보기 only toward the totals.
    mutating func offered(_ id: String, now: Date, automatic: Bool) {
        stats.offers += 1
        lastShown[id] = now
        guard automatic else { return }
        offersToday += 1
        lastOfferAt = now
    }

    /// The cloth came off: the slow-down is forgotten.
    mutating func opened() {
        stats.opens += 1
        ignoredStreak = 0
        backoff = 0
    }

    /// Let go by without a click.
    mutating func ignored() {
        ignoredStreak += 1
        guard ignoredStreak >= SponsorRules.ignoredForBackoff else { return }
        ignoredStreak = 0
        backoff = min(SponsorRules.maxBackoff, backoff + 1)
    }

    /// 오늘은 그만: nothing more today (no slow-down: it was asked, not ignored).
    mutating func stop(now: Date) { stoppedDay = SponsorRules.day(now) }

    /// Watched to the end: a gift from `unlock` while today's are not all given (`capped` when they are).
    mutating func completed(unlock: () -> SponsorGift?) -> (gift: SponsorGift?, capped: Bool) {
        stats.completes += 1
        guard rewardsToday < SponsorRules.rewardsPerDay else { return (nil, true) }
        guard let g = unlock() else { return (nil, false) }
        rewardsToday += 1
        return (g, false)
    }
}

/// What is going on at the Mac right now; any of it keeps 후원 친구 away.
struct SponsorEnv: Equatable {
    var fullScreen = false, focusRunning = false, playing = false, asleep = false
    /// Seconds since the last key, click or mouse move.
    var idle: TimeInterval = 0
    /// 잠시 조용히, or a call app in front.
    var muted = false, popoverOpen = false
    /// An offer or a card is already out.
    var busy = false

    var clear: Bool {
        !fullScreen && !focusRunning && !playing && !asleep && idle <= SponsorRules.awayAfter && !muted && !popoverOpen && !busy
    }
}

/// The pure rules: when an offer may come, how often, which card, the link and the card's text colour.
enum SponsorRules {
    static let grace: TimeInterval = 2 * 86_400
    static let awayAfter: TimeInterval = 120
    static let rewardsPerDay = 2
    static let ignoredForBackoff = 3, maxBackoff = 5
    static let longestGap: TimeInterval = 96 * 3600
    /// Automatic offers need a list fetched this recently, so a kill switch (or a missing list) reaches every Mac.
    static let freshFor: TimeInterval = 14 * 86_400
    /// 지금 보기 fetches first when the list is older than this.
    static let staleFor: TimeInterval = 86_400
    /// A card left open stops: paused this long in a row, or out this long in all (no gift, not counted as ignored).
    static let pausedFor: TimeInterval = 120, openFor: TimeInterval = 300

    static func fetched(_ m: SponsorManifest, within: TimeInterval, now: Date) -> Bool {
        m.fetchedAt.map { now.timeIntervalSince($0) <= within } ?? false
    }

    static func cardTimedOut(open: TimeInterval, paused: TimeInterval) -> Bool { open >= openFor || paused >= pausedFor }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A new day starts the day's counters over. Only forward ("yyyy-MM-dd" sorts as text): a clock set back is still
    /// the same day, so moving it back and forth gives no extra gifts.
    static func rolled(_ s: SponsorState, now: Date) -> SponsorState {
        let today = day(now)
        guard today > s.day else { return s }
        var s = s
        s.day = today
        s.offersToday = 0
        s.rewardsToday = 0
        return s
    }

    /// Offers a day: 보통 2, 가끔 1, slowed down 1, never more than the list allows.
    static func cap(_ s: SponsorState, _ m: SponsorManifest) -> Int {
        min(m.maxPerDay, s.frequency == .normal ? 2 : 1, s.backoff > 0 ? 1 : 2)
    }

    /// Least time between offers: 3 h (보통) or 6 h (가끔) or the list's, doubled per backoff step, at most 96 h.
    static func gap(_ s: SponsorState, _ m: SponsorManifest) -> TimeInterval {
        let base = max(m.minHoursBetween, s.frequency == .normal ? 3 : 6) * 3600
        return min(longestGap, base * pow(2, Double(s.backoff)))
    }

    static func canOffer(_ s: SponsorState, _ m: SponsorManifest, _ env: SponsorEnv, now: Date) -> Bool {
        let s = rolled(s, now: now)
        guard m.enabled, !m.cards.isEmpty, fetched(m, within: freshFor, now: now), s.on, let first = s.firstSeen, now.timeIntervalSince(first) >= grace,
              s.stoppedDay != day(now), s.offersToday < cap(s, m), env.clear else { return false }
        return s.lastOfferAt.map { now.timeIntervalSince($0) >= gap(s, m) } ?? true
    }

    /// One never shown first, else the one shown longest ago; ties go by the list's order.
    static func pick(_ cards: [SponsorCard], lastShown: [String: Date]) -> SponsorCard? {
        cards.first { lastShown[$0.id] == nil } ?? cards.min { (lastShown[$0.id] ?? .distantPast) < (lastShown[$1.id] ?? .distantPast) }
    }

    /// The card's page with where it came from (utm_source, utm_medium, utm_campaign = its id) in place of any utm_ the
    /// page had; nil when its host is not on the list.
    static func link(_ c: SponsorCard, hosts: [String]) -> URL? {
        guard let u = SponsorCheck.allowed(c.url, hosts: Set(hosts)),
              var parts = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        let kept = (parts.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") }
        parts.queryItems = kept + [URLQueryItem(name: "utm_source", value: "charamonitor"),
                                   URLQueryItem(name: "utm_medium", value: "sponsor_friend"),
                                   URLQueryItem(name: "utm_campaign", value: c.id)]
        return parts.url
    }

    /// WCAG relative luminance of "#RRGGBB".
    static func luminance(_ hex: String) -> Double {
        let c = RGBColor(hex: hex)
        func lin(_ v: UInt8) -> Double { let x = Double(v) / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Text on `hex`: white when it reads at 4.5:1, else near black.
    static func ink(on hex: String) -> String { contrast(hex, "#FFFFFF") >= 4.5 ? "#FFFFFF" : "#1E1E1E" }
}

/// Who may carry the frame. Sponsor content is never carried by a personal or a third-party character: only the
/// app's own (the dog, the cats, the built-in originals). Anyone else (a pack, a photo character) gets the built-in courier.
enum SponsorCarrier {
    static func buddyMayCarry(_ s: AppSettings) -> Bool {
        switch s.shownCharacter {
        case .dog, .cat: return true
        case .original:
            return OriginalCharacterSet2.all.contains { $0.id == s.originalID } && OriginalCatalog.character(s.originalID) is OriginalCharacterSet2
        case .custom: return false
        }
    }
}

// MARK: The center

/// "후원 친구": now and then a friend brings a picture frame under a cloth. Opened (a click), it shows one of the maker's
/// own services on a small card, and 15 seconds of it in view open the next 후원 선물. Rare (SponsorRules), never in the
/// first two days, in full screen, focus, play, a meeting or a screen share, while the popover is open, the screen is locked
/// or nobody is at the Mac. Only the signed list is fetched (90 s after launch, then daily, while it is on; 지금 보기 first
/// when it is a day old); nothing is sent, the card's button opens its page.
/// idle --check--> arriving --carrier there--> waiting (40 s) --open--> revealing (0.6 s) --> viewing (15 s seen) --> done.
final class SponsorCenter: ObservableObject {
    static let shared = SponsorCenter()
    static let stateKey = "sponsor.state", manifestKey = "sponsor.manifest", signatureKey = "sponsor.manifestSig",
               fetchedKey = "sponsor.fetchedAt"
    static let checkEvery: TimeInterval = 300, firstCheck: TimeInterval = 600, offerRoll = 0.3
    static let waitSeconds: TimeInterval = 40, viewSeconds: TimeInterval = 15, doneLinger: TimeInterval = 4
    /// While the card shows, someone counts as watching up to this long after their last input.
    static let watchingIdle: TimeInterval = 20

    enum Phase: Equatable { case idle, arriving, waiting, revealing, viewing, done }

    @Published var state: SponsorState { didSet { if state != oldValue { save() } } }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var card: SponsorCard?
    /// Seconds of the card seen so far (only while it is in view and someone is there).
    @Published private(set) var watched: TimeInterval = 0
    @Published private(set) var paused = false
    /// The card's last words: the gift that opened, or why none did.
    @Published private(set) var doneText: (title: String, detail: String)?
    private(set) var manifest: SponsorManifest

    private let defaults: UserDefaults
    private var automatic = false
    private enum Carrier { case buddy, courier }
    private var carrier: Carrier?
    private let courier = SponsorCourier()
    private let frame = SponsorFrame()
    private var cardWindow: SponsorCardWindow?
    private var phaseAt: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var envAt: TimeInterval = -10
    private var lastEnv = SponsorEnv()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var timers: [Timer] = []
    /// Why nobody can see the screen now: the display asleep, the session switched away, the screen locked.
    private var away: Set<String> = []
    private var asleep: Bool { !away.isEmpty }
    /// When the open card last stopped counting (uptime), nil while it counts.
    private var pausedAt: TimeInterval?
    private var bag: Set<AnyCancellable> = []

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(SponsorState.self, from: $0) } ?? SponsorState()
        manifest = SponsorManifest.load(defaults)
        frame.onOpen = { [weak self] in self?.open() }
        frame.onStop = { [weak self] in self?.stopToday() }
        frame.onMenu = { [weak self] e, v in self?.menu(e, v) }
        courier.onClick = { [weak self] in self?.open() }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(state) { defaults.set(d, forKey: Self.stateKey) }
    }

    /// Call once at launch.
    func start() {
        guard timers.isEmpty else { return }
        if state.firstSeen == nil { state.firstSeen = Date() }
        let ws = NSWorkspace.shared.notificationCenter, dn = DistributedNotificationCenter.default()
        let watch: [(NotificationCenter, Notification.Name, Notification.Name, String)] = [
            (ws, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "sleep"),
            (ws, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session"),
            (dn, Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"), "lock"),
        ]
        for (nc, down, up, why) in watch {
            nc.publisher(for: down).sink { [weak self] _ in self?.away.insert(why) }.store(in: &bag)
            nc.publisher(for: up).sink { [weak self] _ in self?.away.remove(why) }.store(in: &bag)
        }
        for (first, every, run) in [(90.0, 86_400.0, { [weak self] in self?.refreshManifest() }),
                                    (Self.firstCheck, Self.checkEvery, { [weak self] in self?.check() })] as [(TimeInterval, TimeInterval, () -> Void)] {
            let t = Timer(fire: Date() + first, interval: every, repeats: true) { _ in run() }
            t.tolerance = 30
            RunLoop.main.add(t, forMode: .common)
            timers.append(t)
        }
    }

    /// The daily fetch runs only while 후원 친구 is on; 지금 보기 asks for one (`always`) when the list is a day old, and
    /// goes on with `then` either way (with the last list, or the built-in one, when the site cannot be reached).
    private func refreshManifest(always: Bool = false, then: (() -> Void)? = nil) {
        guard state.on || always else { return }
        let minSerial = manifest.serial
        Task { @MainActor [weak self] in
            if let files = try? await SponsorCheck.fetch(),
               var m = try? SponsorCheck.verify(files.data, signature: files.signature, minSerial: minSerial).manifest, let self {
                let now = Date()
                defaults.set(files.data, forKey: Self.manifestKey)
                defaults.set(files.signature, forKey: Self.signatureKey)
                defaults.set(now, forKey: Self.fetchedKey)
                m.fetchedAt = now
                manifest = m
            }
            then?()
        }
    }

    // MARK: Offers

    /// The 5-minute look: now and then (a 30% roll) an offer when the rules allow it.
    private func check() {
        guard state.on, manifest.enabled else { return }   // off: no look around the Mac at all
        let now = Date()
        state = SponsorRules.rolled(state, now: now)
        guard SponsorRules.canOffer(state, manifest, env(force: true), now: now), Double.random(in: 0..<1) < Self.offerRoll else { return }
        begin(automatic: true)
    }

    /// 지금 보기 (the friends' menu, 설정): one now, its cloth coming off by itself, even with 후원 친구 off. Not counted in
    /// the day's offers; gifts stay at two a day.
    func showNow() {
        if phase == .waiting { open(); return }
        guard phase == .idle else { return }
        guard SponsorRules.fetched(manifest, within: SponsorRules.staleFor, now: Date()) else {
            refreshManifest(always: true) { [weak self] in self?.showFromList() }
            return
        }
        showFromList()
    }

    private func showFromList() {
        guard phase == .idle else { return }
        guard manifest.enabled, !manifest.cards.isEmpty else {
            SpeechBubbleCenter.shared.say(text: L("지금은 소개할 서비스가 없어요"), source: .system, aloud: false, repeats: true)
            return
        }
        begin(automatic: false)
    }

    private func begin(automatic: Bool) {
        guard let c = SponsorRules.pick(manifest.cards, lastShown: state.lastShown) else { return }
        if SponsorCarrier.buddyMayCarry(AppSettings.shared), CursorBuddy.shared.holdForSponsor() {
            carrier = .buddy
        } else {
            guard courier.enter() else { return }
            carrier = .courier
        }
        self.automatic = automatic
        card = c
        watched = 0
        paused = false
        pausedAt = nil
        doneText = nil
        enter(.arriving)
    }

    /// The frame was clicked (or 열어 보기, or the courier itself).
    func open() {
        guard phase == .waiting else { return }
        reveal()
    }

    private func reveal() {
        state.opened()
        frame.reveal()
        enter(.revealing)
    }

    /// 오늘은 그만: the offer on the way leaves, and none comes again today.
    func stopToday() {
        state.stop(now: Date())
        if phase == .arriving || phase == .waiting { leave() }
    }

    /// The card's button: its page, with where it came from.
    func visit() {
        guard let card, let url = SponsorRules.link(card, hosts: manifest.hosts) else { return }
        state.stats.clicks += 1
        External.open(url)
    }

    /// The card's X, or its time after the gift is up. Before the 15 s that is no gift, and not "ignored" either.
    func close() {
        cardWindow?.close()
        cardWindow = nil
        card = nil
        doneText = nil
        enter(.idle)
    }

    /// The offer goes away (ignored, stopped or interrupted) before any card.
    private func leave() {
        frame.hide()
        releaseCarrier(happy: false)
        close()
    }

    private func releaseCarrier(happy: Bool) {
        switch carrier {
        case .buddy: CursorBuddy.shared.releaseSponsor(cheer: happy)
        case .courier: courier.leave(happy: happy)
        case nil: break
        }
        carrier = nil
    }

    private func enter(_ p: Phase) {
        phase = p
        phaseAt = ProcessInfo.processInfo.systemUptime
        schedule()
    }

    /// 30 fps while the courier walks, 1 while the card is paused, 10 otherwise, nothing once all is back in.
    private func schedule() {
        let every: TimeInterval = phase == .idle && !courier.isOut ? 0 : courier.walking ? 1.0 / 30 : phase == .viewing && paused ? 1 : 0.1
        guard every != interval else { return }
        timer?.invalidate()
        timer = nil
        interval = every
        guard every > 0 else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = every * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.25, max(0, now - lastTick)), t = now - phaseAt
        lastTick = now
        courier.step(dt: dt)
        if [.arriving, .waiting, .revealing].contains(phase), interrupted() { leave(); return }
        if let head = carrierHead() { frame.place(over: head) }
        switch phase {
        case .idle:
            break
        case .arriving:
            guard carrier == .buddy || courier.arrived, let c = card else { break }
            frame.show()
            if let head = carrierHead() { frame.place(over: head) }
            if automatic && !state.introduced {
                let said = SpeechBubbleCenter.shared.say(
                    text: L("저는 후원 친구예요. 가끔 제작자가 만든 서비스를 천에 덮어 데려와요. 열어 보면 꾸미기 선물이 하나씩 열리고, 설정에서 언제든 끌 수 있어요."),
                    source: .system, aloud: false, hold: true, seconds: 10, closable: true, anchor: { [weak self] in self?.frame.top })
                guard said else { leave(); return }   // a held line is up: next time
                state.introduced = true
            }
            state = SponsorRules.rolled(state, now: Date())
            state.offered(c.id, now: Date(), automatic: automatic)
            if automatic { enter(.waiting) } else { reveal() }
        case .waiting:
            frame.hover(NSEvent.mouseLocation)
            if t >= Self.waitSeconds { state.ignored(); leave() }
        case .revealing:
            if t >= frame.revealTime { showCard() }
        case .viewing:
            let seen = (cardWindow?.inView ?? false) && !asleep && Self.idleSeconds() <= Self.watchingIdle
            if paused == seen { paused = !seen }
            pausedAt = seen ? nil : pausedAt ?? now
            if seen { watched = min(Self.viewSeconds, watched + dt) }
            if watched >= Self.viewSeconds { complete() }
            else if SponsorRules.cardTimedOut(open: t, paused: pausedAt.map { now - $0 } ?? 0) { close(); return }
        case .done:
            if t >= Self.doneLinger { close() }
        }
        schedule()
    }

    private func carrierHead() -> CGPoint? {
        switch carrier {
        case .buddy: return CursorBuddy.shared.head()
        case .courier: return courier.head()
        case nil: return nil
        }
    }

    /// Anything that sends an offer away before its card: full screen, focus, play, sleep, 후원 친구 switched off (for
    /// an automatic one), the carrier gone (switched off, a non-built-in character now, grabbed or thrown), the popover.
    private func interrupted() -> Bool {
        let e = env()
        if e.fullScreen || e.focusRunning || e.playing || e.asleep || automatic && (!state.on || e.muted) { return true }
        if phase == .waiting && e.popoverOpen { return true }
        switch carrier {
        case .buddy: return !CursorBuddy.shared.holdsSponsor || !SponsorCarrier.buddyMayCarry(AppSettings.shared)
        case .courier: return !courier.isOut
        case nil: return true
        }
    }

    private func showCard() {
        let from = frame.rect
        frame.hide()
        releaseCarrier(happy: true)
        cardWindow = SponsorCardWindow(center: self, from: from)
        enter(.viewing)
    }

    private func complete() {
        state = SponsorRules.rolled(state, now: Date())
        let r = state.completed { SponsorGifts.shared.unlock() }
        if let g = r.gift {
            // No DesktopKit.celebrate: the desktop friends may be packs, and sponsor content never reaches them.
            doneText = (L("선물이 열렸어요: \(g.emoji) \(g.label)"), g.howTo)
        } else if r.capped {
            doneText = (L("오늘 선물은 다 받았어요"), L("내일 또 열려요. 끝까지 봐 줘서 고마워요"))
        } else {
            doneText = (L("선물을 다 모았어요. 고마워요!"), L("새 선물은 다음 버전에서 또 와요"))
        }
        enter(.done)
    }

    private func menu(_ e: NSEvent, _ v: NSView) {
        FriendMenu.pop([
            FriendMenu.item(L("열어 보기")) { [weak self] in self?.open() },
            FriendMenu.item(L("오늘은 그만")) { [weak self] in self?.stopToday() },
            FriendMenu.item(L("후원 친구 끄기")) { [weak self] in self?.state.on = false; self?.leave() },
        ], with: e, for: v)
    }

    // MARK: Around the Mac

    /// Read at most once a second (`force`: now).
    private func env(force: Bool = false) -> SponsorEnv {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - envAt >= 1 else { return lastEnv }
        envAt = now
        lastEnv = SponsorEnv(fullScreen: Self.frontIsFullScreen(), focusRunning: FocusCenter.shared.running,
                             playing: PlayMode.shared.isPlaying || StarGame.shared.isOn || ClickGames.shared.playing != nil,
                             asleep: asleep, idle: Self.idleSeconds(),
                             muted: SpeechBubbleCenter.shared.isMuted() || MeetingMute.screenMaybeShared(),
                             popoverOpen: !MainActor.assumeIsolated { Updater.isIdle() }, busy: phase != .idle)
        return lastEnv
    }

    /// The front app's front window covers a whole screen (window bounds only: no names, no permission).
    static func frontIsFullScreen() -> Bool {
        guard let w = CursorBuddy.frontWindowFrame() else { return false }
        return NSScreen.screens.contains { covers(w, screen: $0.frame, notch: $0.safeAreaInsets.top) }
    }

    /// `w` fills `screen`: its whole width from the bottom up, to the top or (on a notched screen, where full screen
    /// stops under the camera) to the notch's line. A zoomed window with the Dock hidden matches too: one skipped offer.
    static func covers(_ w: CGRect, screen: CGRect, notch: CGFloat) -> Bool {
        let w = w.integral, s = screen.integral
        return w.minX == s.minX && w.width == s.width && w.minY == s.minY && w.maxY >= s.maxY - notch.rounded(.up)
    }

    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
    }
}
#endif
