import AppKit
import Combine

/// 시즌 뽑기판: a free box draw. The board's whole make-up is shown (so many cells, these items, the rest 코인), every
/// cell opens once, a board opened to the end has given everything on it, and an item already owned pays coins back.
/// 뽑기권 are free: a few a day, a few more for 펫 코인, one for a 후원 친구 card watched to the end. No money anywhere.
/// The season itself (its days, items and numbers) comes from the signed web/season.json, so seasons change without an
/// app update. Off by default; while off nothing runs and nothing extra is paid. Pure parts tested in SeasonTests.

// MARK: Items

/// What a season can give: 옷 입히기 stamps and shirts (Wardrobe.items with `season`), 말풍선 색, 투척물 (Throwables) and 의자
/// (ChairCatalog). Drawn here in code;
/// a friend wearing one is drawn from this Mac's own copy of the art (only the id travels).
enum SeasonCatalog {
    struct Bubble: Equatable { let id: String; let name: String; let hex: String }

    static let bubbles: [Bubble] = [
        Bubble(id: "bubble-snow", name: L("눈빛 말풍선"), hex: "#CFE8FF"),
        Bubble(id: "bubble-pine", name: L("솔잎 말풍선"), hex: "#CFEBD2"),
        Bubble(id: "bubble-berry", name: L("산딸기 말풍선"), hex: "#F8CFDC"),
    ]

    static func bubble(_ id: String?) -> Bubble? { id.flatMap { id in bubbles.first { $0.id == id } } }

    /// Every id a season.json may name.
    static var known: Set<String> {
        Set(Wardrobe.items.filter(\.season).map(\.id) + bubbles.map(\.id) + Throwables.seasonIDs + ChairCatalog.all.filter(\.season).map(\.id))
    }

    static func name(_ id: String) -> String {
        Wardrobe.item(id)?.name ?? bubble(id)?.name ?? Throwables.item(id: id)?.name ?? ChairCatalog.chair(id)?.name ?? id
    }
}

// MARK: The season file

/// One text in both languages.
struct SeasonText: Equatable {
    var ko: String, en: String
    var shown: String { appIsEnglish ? en : ko }
}

/// web/season.json, signed like plugins.json (season.json.sig, scripts/package.sh). `serial` only goes up.
struct SeasonManifest: Equatable {
    var serial: Int
    /// Changing it deals a new board (owned items and 뽑기권 stay).
    var id: String
    var title: SeasonText
    /// "yyyy-MM-dd", both days included.
    var starts: String, ends: String
    /// Cells on a board; `items` fill one each, the rest pay `coins`.
    var cells: Int
    var items: [String]
    var coins: Int
    /// Paid for an item already owned.
    var refund: Int
    var freePerDay: Int
    var ticketPrice: Int, buyPerDay: Int
    /// 뽑기권 a day for 후원 친구 cards watched to the end.
    var sponsorTickets: Int
}

enum SeasonCheck {
    static let maxBytes = 16_384, maxSignatureBytes = 256
    static let cellRange = 4...24, maxItems = 16

    enum Failure: Error, Equatable { case tooBig, badSignature, badManifest, rollback }

    private struct Raw: Decodable {
        struct Text: Decodable { var ko: String; var en: String }
        struct Season: Decodable {
            var id: String, title: Text, starts: String, ends: String, cells: Int, items: [String]
            var coins: Int, refund: Int, freePerDay: Int, ticketPrice: Int, buyPerDay: Int, sponsorTickets: Int?
        }
        var serial: Int
        var season: Season
    }

    /// Unknown or repeated items are dropped (an older app skips a newer season's new art); numbers are held to sane
    /// ranges; a season with no item left, bad days or a bad id is refused whole.
    static func parse(_ data: Data) throws -> SeasonManifest {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.serial >= 0 else { throw Failure.badManifest }
        let s = raw.season, day = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#
        func fits(_ t: String) -> Bool { !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && t.count <= 24 }
        guard s.id.range(of: #"\A[a-z0-9-]{1,32}\z"#, options: .regularExpression) != nil,
              s.starts.range(of: day, options: .regularExpression) != nil, s.ends.range(of: day, options: .regularExpression) != nil,
              s.starts <= s.ends, fits(s.title.ko), fits(s.title.en), cellRange.contains(s.cells) else { throw Failure.badManifest }
        var seen = Set<String>()
        let known = SeasonCatalog.known
        let items = s.items.filter { known.contains($0) && seen.insert($0).inserted }.prefix(min(maxItems, s.cells))
        guard !items.isEmpty else { throw Failure.badManifest }
        func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }
        return SeasonManifest(serial: raw.serial, id: s.id, title: SeasonText(ko: s.title.ko, en: s.title.en), starts: s.starts,
                              ends: s.ends, cells: s.cells, items: Array(items), coins: clamp(s.coins, 0...50),
                              refund: clamp(s.refund, 0...100), freePerDay: clamp(s.freePerDay, 0...5),
                              ticketPrice: clamp(s.ticketPrice, 1...500), buyPerDay: clamp(s.buyPerDay, 0...10),
                              sponsorTickets: clamp(s.sponsorTickets ?? 1, 0...2))
    }

    #if !MAS   // the App Store build has no UpdateCheck: it keeps the built-in season
    static let manifestURL = URL(string: "https://\(UpdateCheck.checkHost)/season.json")!
    static let signatureURL = URL(string: "https://\(UpdateCheck.checkHost)/season.json.sig")!

    /// The size, then the release key's signature over the exact bytes, then the parse. `minSerial`: the stored file's.
    static func verify(_ data: Data, signature: Data, publicKey: [UInt8] = UpdateCheck.publicKey, minSerial: Int = 0) throws -> SeasonManifest {
        guard data.count <= maxBytes, signature.count <= maxSignatureBytes else { throw Failure.tooBig }
        guard UpdateCheck.signed(data, signature: signature, publicKey: publicKey) else { throw Failure.badSignature }
        let m = try parse(data)
        guard m.serial >= minSerial else { throw Failure.rollback }
        return m
    }

    /// Both files from the site, or from `folder` (QA, scripts/package.sh).
    static func fetch(folder: URL? = nil) async throws -> (data: Data, signature: Data) {
        if let folder {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent("season.json")),
                  let s = try? Data(contentsOf: folder.appendingPathComponent("season.json.sig")) else { throw Failure.badManifest }
            return (d, s)
        }
        async let d = UpdateCheck.fetch(manifestURL, maxBytes: maxBytes)
        async let s = UpdateCheck.fetch(signatureURL, maxBytes: maxSignatureBytes)
        return (try await d, try await s)
    }

    /// `--check-season [폴더]`: read-only. Fetches (or reads) the file, verifies it and prints what the app would use.
    static func runCLI(folder: URL?) async -> Int32 {
        do {
            let files = try await fetch(folder: folder)
            let m = try verify(files.data, signature: files.signature)
            print("서명 확인됨 · serial \(m.serial) · \(m.id) \(m.title.ko) · \(m.starts)~\(m.ends)")
            print("판 \(m.cells)칸 · 아이템 \(m.items.count)개(\(m.items.joined(separator: ", "))) · 코인 칸 \(m.coins) · 중복 \(m.refund)")
            print("무료 하루 \(m.freePerDay)장 · 코인 \(m.ticketPrice)에 하루 \(m.buyPerDay)장 · 후원 하루 \(m.sponsorTickets)장")
            return 0
        } catch {
            print("실패: \(error)")
            return 1
        }
    }
    #endif
}

extension SeasonManifest {
    /// The season built into this version (web/season.json when it shipped; a test keeps them equal).
    static let bundled: SeasonManifest = (try? SeasonCheck.parse(Data(bundledJSON.utf8)))
        ?? SeasonManifest(serial: 0, id: "none", title: SeasonText(ko: "시즌", en: "Season"), starts: "2000-01-01", ends: "2000-01-01",
                          cells: 4, items: ["bubble-snow"], coins: 0, refund: 0, freePerDay: 0, ticketPrice: 1, buyPerDay: 0, sponsorTickets: 0)

    private static let bundledJSON = #"""
    {"serial":1,
     "season":{"id":"first-snow-2026","title":{"ko":"첫눈 시즌","en":"First Snow"},
      "starts":"2026-11-01","ends":"2027-01-31","cells":16,
      "items":["s-earmuffs","s-snowcap","s-antlers","s-starglasses","s-checkscarf","s-bell",
               "s-shirt-snow","s-shirt-pine","s-shirt-berry","bubble-snow","bubble-pine","bubble-berry"],
      "coins":8,"refund":15,"freePerDay":2,"ticketPrice":40,"buyPerDay":3,"sponsorTickets":1}}
    """#

    /// The stored file when its bytes still verify and its serial is not below the bundled one's, else `bundled`.
    static func load(_ defaults: UserDefaults, bundled: SeasonManifest = bundled) -> SeasonManifest {
        #if MAS
        return bundled
        #else
        guard let d = defaults.data(forKey: SeasonCenter.manifestKey), let s = defaults.data(forKey: SeasonCenter.signatureKey),
              let m = try? SeasonCheck.verify(d, signature: s), m.serial >= bundled.serial else { return bundled }
        return m
        #endif
    }
}

// MARK: State and rules

/// One dealt board: what each cell holds (an item id, or nil for coins) and the cells opened so far.
struct SeasonBoard: Codable, Equatable {
    var season: String
    var cells: [String?]
    var opened: [Int] = []

    var isDone: Bool { opened.count >= cells.count }
    var left: Int { cells.count - opened.count }
}

/// What one cell gave.
enum SeasonOutcome: Equatable {
    case item(String)
    /// Already owned: `coins` back instead.
    case duplicate(String, coins: Int)
    case coins(Int)

    var coins: Int {
        switch self {
        case .item: return 0
        case .duplicate(_, let c), .coins(let c): return c
        }
    }
}

/// Saved as JSON under `season.state` (this Mac only).
struct SeasonState: Codable, Equatable {
    var tickets = 0
    /// "yyyy-MM-dd": the counters below are for that day. Forward only, so setting the clock back pays nothing twice.
    var day = ""
    var bought = 0, sponsored = 0
    /// Season items, kept across seasons.
    var owned: [String] = []
    var board: SeasonBoard?
    var boardsDone = 0
    /// The 말풍선 색 in use (an owned SeasonCatalog.bubbles id), nil = the usual.
    var bubble: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        tickets = min(max(get(.tickets) ?? 0, 0), SeasonRules.maxTickets)
        day = get(.day) ?? ""
        bought = get(.bought) ?? 0; sponsored = get(.sponsored) ?? 0
        owned = Array(Set((get(.owned) as [String]?) ?? []).intersection(SeasonCatalog.known)).sorted()
        board = get(.board).flatMap { (b: SeasonBoard) in SeasonRules.sane(b) ? b : nil }
        boardsDone = get(.boardsDone) ?? 0
        bubble = get(.bubble)
    }
}

enum SeasonRules {
    /// 뽑기권 held at most (free ones stop piling up past it).
    static let maxTickets = 20
    /// 펫 코인 for the season's own ways of earning, and their day's cap (missions and 집중 pay as before).
    static let breathCoins = 5, emoteCoins = 2, bonusPerDay = 30

    /// Whether `today` ("yyyy-MM-dd") is within the season.
    static func active(_ m: SeasonManifest, today: String) -> Bool { m.starts <= today && today <= m.ends }

    /// A new day (forward only): the counters start over and the day's free 뽑기권 come, while the season runs.
    static func rolled(_ s: SeasonState, _ m: SeasonManifest, today: String) -> SeasonState {
        guard today > s.day else { return s }
        var n = s
        n.day = today
        n.bought = 0
        n.sponsored = 0
        if active(m, today: today) { n.tickets = max(n.tickets, min(maxTickets, n.tickets + m.freePerDay)) }
        return n
    }

    /// The season's items one per cell, the rest coin cells, in an order from `seed`.
    static func deal(_ m: SeasonManifest, seed: UInt64) -> SeasonBoard {
        var cells: [String?] = m.items.map { $0 } + Array(repeating: nil, count: max(0, m.cells - m.items.count))
        var rng = SplitMix64(seed: seed)
        cells.shuffle(using: &rng)
        return SeasonBoard(season: m.id, cells: cells)
    }

    /// A saved board that is still a board: some cells holding known items, opened ones in range and once each.
    static func sane(_ b: SeasonBoard) -> Bool {
        let known = SeasonCatalog.known
        return SeasonCheck.cellRange.contains(b.cells.count) && b.cells.allSatisfy { $0.map(known.contains) ?? true }
            && Set(b.opened).count == b.opened.count && b.opened.allSatisfy(b.cells.indices.contains)
    }

    /// This season's board in `s`, dealt fresh when there is none, it is another season's, or it was opened to the end.
    static func ensureBoard(_ s: inout SeasonState, _ m: SeasonManifest, seed: UInt64) {
        if let b = s.board, b.season == m.id, !b.isDone { return }
        s.board = deal(m, seed: seed)
    }

    /// Opens `cell` for one 뽑기권. nil (nothing changes) without a 뽑기권, outside the season, or for a cell that is
    /// not there or already open. The last cell finishes the board (the next look deals a new one).
    static func open(_ s: inout SeasonState, cell: Int, _ m: SeasonManifest, today: String) -> SeasonOutcome? {
        guard s.tickets > 0, active(m, today: today), var b = s.board, b.season == m.id, b.cells.indices.contains(cell),
              !b.opened.contains(cell) else { return nil }
        s.tickets -= 1
        b.opened.append(cell)
        let out: SeasonOutcome
        if let id = b.cells[cell] {
            if s.owned.contains(id) { out = .duplicate(id, coins: m.refund) } else { s.owned.append(id); out = .item(id) }
        } else {
            out = .coins(m.coins)
        }
        if b.isDone { s.boardsDone += 1 }
        s.board = b
        return out
    }

    /// One more 뽑기권 for coins may be bought: in season, under the day's count and the holding cap, coins enough.
    static func canBuy(_ s: SeasonState, _ m: SeasonManifest, coins: Int, today: String) -> Bool {
        active(m, today: today) && s.bought < m.buyPerDay && s.tickets < maxTickets && coins >= m.ticketPrice
    }

    /// A 후원 친구 card watched to the end: one 뽑기권 while today's are not all given. False when they are.
    static func sponsorTicket(_ s: inout SeasonState, _ m: SeasonManifest, today: String) -> Bool {
        guard active(m, today: today), s.sponsored < m.sponsorTickets, s.tickets < maxTickets else { return false }
        s.sponsored += 1
        s.tickets += 1
        return true
    }

    /// Whole days from `today` to `day` (both "yyyy-MM-dd"), nil for a bad one.
    static func days(from today: String, to day: String, calendar: Calendar = .current) -> Int? {
        func date(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        guard let a = date(today), let b = date(day) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}

// MARK: The center

/// The season on this Mac. Off by default; turned on from 설정 > 플러그인 > 시즌 뽑기판. While on (direct build only) the
/// signed season.json is fetched 60 s after launch and then daily; nothing else runs on a clock: the day rolls when the
/// board is looked at or a 뽑기권 comes.
final class SeasonCenter: ObservableObject {
    static let shared = SeasonCenter()
    static let onKey = "season.on", stateKey = "season.state", manifestKey = "season.manifest", signatureKey = "season.manifestSig"

    @Published var isOn: Bool { didSet { defaults.set(isOn, forKey: Self.onKey); isOn ? start() : stop() } }
    @Published private(set) var state: SeasonState { didSet { if state != oldValue { save() } } }
    @Published private(set) var manifest: SeasonManifest

    private let defaults: UserDefaults
    private var fetchTimer: Timer?

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.onKey)
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(SeasonState.self, from: $0) } ?? SeasonState()
        manifest = SeasonManifest.load(defaults)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(state) { defaults.set(d, forKey: Self.stateKey) }
    }

    var today: String { PluginRules.day(Date()) }
    var running: Bool { isOn && SeasonRules.active(manifest, today: today) }

    /// Call once at launch: nothing while off.
    func start() {
        guard isOn, fetchTimer == nil else { return }
        #if !MAS
        scheduleFetch(after: 60)
        #endif
        look()
    }

    private func stop() {
        fetchTimer?.invalidate()
        fetchTimer = nil
    }

    /// The day rolled and this season's board dealt (the board shows it).
    func look(seed: UInt64 = UInt64.random(in: .min ... .max)) {
        var s = SeasonRules.rolled(state, manifest, today: today)
        if SeasonRules.active(manifest, today: today) { SeasonRules.ensureBoard(&s, manifest, seed: seed) }
        state = s
    }

    /// Opens a cell; its coins go to the pet's purse.
    func open(_ cell: Int) -> SeasonOutcome? {
        guard isOn else { return nil }
        var s = SeasonRules.rolled(state, manifest, today: today)
        guard let out = SeasonRules.open(&s, cell: cell, manifest, today: today) else { return nil }
        state = s
        if out.coins > 0 { PetModel.shared.receive(coins: out.coins) }
        return out
    }

    /// A new board once the last one is opened to the end (the panel asks after the last reveal).
    func nextBoard() { look() }

    @discardableResult
    func buy() -> Bool {
        var s = SeasonRules.rolled(state, manifest, today: today)
        guard isOn, SeasonRules.canBuy(s, manifest, coins: PetModel.shared.state.coins, today: today),
              PetModel.shared.spend(manifest.ticketPrice) else { return false }
        s.bought += 1
        s.tickets += 1
        state = s
        return true
    }

    func wear(bubble id: String?) {
        guard id == nil || state.owned.contains(id!) else { return }
        state.bubble = id
    }

    /// The 말풍선 색 to draw, nil for the usual (off, or none chosen).
    var bubbleHex: String? { isOn ? SeasonCatalog.bubble(state.bubble)?.hex : nil }

    // MARK: Earning

    /// A 후원 친구 card watched to the end. True when a 뽑기권 came.
    @discardableResult
    func sponsorWatched() -> Bool {
        guard isOn else { return false }
        var s = SeasonRules.rolled(state, manifest, today: today)
        let got = SeasonRules.sponsorTicket(&s, manifest, today: today)
        state = s
        return got
    }

    /// 숨 고르기 finished.
    func breathed() { if isOn { PetModel.shared.bonus(SeasonRules.breathCoins, cap: SeasonRules.bonusPerDay) } }

    /// An emote sent to or got from a friend (근처 친구 or 원격 모임).
    func emoted() { if isOn { PetModel.shared.bonus(SeasonRules.emoteCoins, cap: SeasonRules.bonusPerDay) } }

    #if !MAS
    private func scheduleFetch(after: TimeInterval) {
        fetchTimer?.invalidate()
        let t = Timer(fire: Date() + after, interval: 0, repeats: false) { [weak self] _ in self?.fetch() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        fetchTimer = t
    }

    private func fetch() {
        let minSerial = manifest.serial
        Task { @MainActor [weak self] in
            if let files = try? await SeasonCheck.fetch(),
               (try? SeasonCheck.verify(files.data, signature: files.signature, minSerial: minSerial)) != nil, let self {
                defaults.set(files.data, forKey: Self.manifestKey)
                defaults.set(files.signature, forKey: Self.signatureKey)
                manifest = SeasonManifest.load(defaults)
            }
            guard let self, self.isOn else { return }
            self.look()
            self.scheduleFetch(after: 86_400)
        }
    }
    #endif

    /// QA renders only (--render-season, its own preferences suite): a given season and state.
    func seed(_ m: SeasonManifest, _ s: SeasonState) {
        manifest = m
        state = s
    }
}
