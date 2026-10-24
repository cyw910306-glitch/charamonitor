import AppKit
import SwiftUI

// 그룹 뽑기: 룰렛, 사다리 and 제비뽑기 over 2 to 12 items. The maker sends the items and a seed; every Mac turns the seed
// into the same result (DrawRules.plan, SplitMix64 and plain modulo, never the stdlib's random(in:), which may change
// between Swift versions) and plays the same show. 근처 친구 get SocialMessage .draw (version 2 and up), the 원격 모임 a
// MeetEvent .draw. Draws live in memory only, 24 h; the winner's 👑 shows for `DrawBook.crownHours`.
// Keys: draw.items, draw.game (the last list, for using it alone).
//
// ponytail: the maker picks the seed, so a maker could try seeds until the result suits them before sending. Fine
// among friends; the upgrade is commit-reveal (Pairing's commit/reveal): everyone sends SHA-256 of a nonce, then the
// nonces, and the seed is the hash of all of them.

enum DrawGame: String, Codable, CaseIterable {
    case roulette, ladder, lots

    var label: String {
        switch self {
        case .roulette: return L("룰렛")
        case .ladder: return L("사다리")
        case .lots: return L("제비뽑기")
        }
    }

    var emoji: String {
        switch self {
        case .roulette: return "🎡"
        case .ladder: return "🪜"
        case .lots: return "📜"
        }
    }
}

/// A draw as it travels: everything a Mac needs to replay it. The maker is the link's friend or the relay's member.
struct DrawShare: Codable, Equatable {
    static let minItems = 2, maxItems = 12, maxText = 15, maxBytes = 1100

    var id: String
    var game: DrawGame
    var title: String?
    var items: [String]
    var seed: UInt64

    /// A new draw from what was typed: items tidied (blank ones dropped), 2 to 12 of them. nil when that fails.
    static func make(_ game: DrawGame, title: String, items typed: [String], seed: UInt64 = .random(in: .min ... .max)) -> DrawShare? {
        let items = typed.map(tidy).filter { !$0.isEmpty }
        let t = tidy(title)
        return received(DrawShare(id: UUID().uuidString, game: game, title: t.isEmpty ? nil : t, items: items, seed: seed))
    }

    /// One line, 15 characters, no space left at either end (cutting can leave one at the end).
    static func tidy(_ s: String) -> String { SocialText.clean(SocialText.clean(s, max: maxText), max: maxText) }
    static func isTidy(_ s: String) -> Bool { !s.isEmpty && tidy(s) == s }

    /// A draw from the network: an id of letters, digits and dashes, 2 to 12 items and a title already tidied (a
    /// tidied copy would replay a different draw), 1100 bytes encoded at most. nil otherwise.
    static func received(_ s: DrawShare) -> DrawShare? {
        guard (8...40).contains(s.id.count), s.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              (minItems...maxItems).contains(s.items.count), s.items.allSatisfy(isTidy), s.title.map(isTidy) ?? true,
              let d = SocialWire.encode(s), d.count <= maxBytes else { return nil }
        return s
    }
}

/// What the seed decides. Only the current game's parts are filled.
struct DrawPlan: Equatable {
    var winner: Int
    /// 룰렛: the wheel's last angle, radians clockwise, a few whole turns plus the winner's slice under the pointer.
    var spin: Double = 0
    /// 사다리: rungs[row][gap], gap i joining columns i and i + 1; `star` is the bottom column that wins.
    var rungs: [[Bool]] = []
    var star = 0
    /// 제비뽑기: the papers the hand hovers over, the winner last.
    var hops: [Int] = []
}

/// The draw itself and its show, from the seed alone. Pure, tested (GroupDrawTests).
enum DrawRules {
    // Tuning knobs.
    static let ladderRows = 9, lotsHops = 14
    static let rouletteSeconds: TimeInterval = 4.2, ladderSeconds: TimeInterval = 3.4, unfoldSeconds: TimeInterval = 0.7

    /// 0..<n from the generator: plain modulo (the bias is far below 1 in 10^17 for n ≤ 12), the same on every build.
    static func pick(_ n: Int, _ rng: inout SplitMix64) -> Int { Int(rng.next() % UInt64(n)) }

    /// 룰렛 slice labels: cut to `most` characters, and numbered where cut ones would read the same ("항목 1…" for 1,
    /// 10, 11 and 12), so every slice can be told apart.
    static func wheelLabels(_ items: [String], most: Int) -> [String] {
        let cut = items.map { $0.count > most ? $0.prefix(most - 1) + "…" : $0 }
        return cut.enumerated().map { i, l in cut.filter { $0 == l }.count > 1 ? "\(i + 1)·" + l : l }
    }

    static func plan(_ s: DrawShare) -> DrawPlan {
        var rng = SplitMix64(seed: s.seed)
        let n = s.items.count
        switch s.game {
        case .roulette:
            let w = 2 * Double.pi / Double(n)
            let winner = pick(n, &rng)
            let turns = 4 + pick(3, &rng)
            let jitter = Double(pick(1000, &rng)) / 1000 * 0.7 - 0.35   // inside the slice, off its middle
            return DrawPlan(winner: winner, spin: Double(turns) * 2 * .pi - (Double(winner) + 0.5 + jitter) * w)
        case .ladder:
            var rungs: [[Bool]] = []
            for _ in 0..<ladderRows {
                var row: [Bool] = []
                for g in 0..<(n - 1) { row.append(!(g > 0 && row[g - 1]) && pick(2, &rng) == 1) }   // never two rungs side by side
                rungs.append(row)
            }
            let star = pick(n, &rng)
            let winner = (0..<n).first { end(from: $0, rungs) == star } ?? 0
            return DrawPlan(winner: winner, rungs: rungs, star: star)
        case .lots:
            let winner = pick(n, &rng)
            var hops: [Int] = []
            for _ in 0..<(lotsHops - 1) {
                var h = pick(n, &rng)
                if h == hops.last { h = (h + 1) % n }
                hops.append(h)
            }
            if hops.last == winner { hops[hops.count - 1] = (winner + 1) % n }
            return DrawPlan(winner: winner, hops: hops + [winner])
        }
    }

    /// The slice under the top pointer with the wheel turned `angle` clockwise.
    static func slice(at angle: Double, count n: Int) -> Int {
        let w = 2 * Double.pi / Double(n)
        var a = (-angle).truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return min(Int(a / w), n - 1)
    }

    /// Where a ladder walk from top column `c` comes out.
    static func end(from c: Int, _ rungs: [[Bool]]) -> Int { ladderPath(from: c, rungs, count: (rungs.first?.count ?? 0) + 1).last.map { Int($0.x) } ?? c }

    /// The walk from top column `c` as (column, row) points: row 0 the top, rungs on rows 1...rows, rows + 1 the bottom.
    static func ladderPath(from c: Int, _ rungs: [[Bool]], count n: Int) -> [CGPoint] {
        var c = c, out = [CGPoint(x: CGFloat(c), y: 0)]
        for (r, row) in rungs.enumerated() {
            let y = CGFloat(r + 1)
            out.append(CGPoint(x: CGFloat(c), y: y))
            if c < n - 1, row[c] { c += 1 } else if c > 0, row[c - 1] { c -= 1 } else { continue }
            out.append(CGPoint(x: CGFloat(c), y: y))
        }
        out.append(CGPoint(x: CGFloat(c), y: CGFloat(rungs.count + 1)))
        return out
    }

    static func duration(_ s: DrawShare, _ p: DrawPlan) -> TimeInterval {
        switch s.game {
        case .roulette: return rouletteSeconds
        case .ladder: return ladderSeconds
        case .lots: return LunchRules.delays(p.hops.count).reduce(0, +) + unfoldSeconds
        }
    }

    /// 제비뽑기 at `t` seconds: the paper the hand is over, and 0...1 of the winner's unfolding (0 while hopping).
    static func lots(_ p: DrawPlan, at t: TimeInterval) -> (hop: Int, unfold: Double) {
        var clock: TimeInterval = 0
        for (i, d) in LunchRules.delays(p.hops.count).enumerated() {
            clock += d
            if t < clock { return (p.hops[max(i - 1, 0)], 0) }
        }
        return (p.winner, min(max((t - clock) / unfoldSeconds, 0), 1))
    }

    /// Ease out: quick, then slowing into the stop.
    static func ease(_ t: Double) -> Double { let u = 1 - min(max(t, 0), 1); return 1 - u * u * u }
}

/// One draw on this Mac. `sender`: "me", "f:<friend id>" or "m:<relay member id>".
struct DrawRecord: Identifiable, Equatable {
    var share: DrawShare
    var from: String
    var sender: String
    var at: Date
    var ended = false

    var id: String { share.id }
    var mine: Bool { sender == "me" }
    var plan: DrawPlan { DrawRules.plan(share) }
    var winner: String { share.items[plan.winner] }
    var name: String { share.title ?? share.game.label }
}

/// The last day's draws, mine and friends', with the limits: per maker 3 on show at once (until ended or its 👑 is
/// over) and 20 an hour. Pure, tested (GroupDrawTests).
struct DrawBook: Equatable {
    // Tuning knobs.
    static let maxLive = 3, perHour = 20, maxKept = 60
    static let crownHours: Double = 3, keepHours: Double = 24

    private(set) var records: [DrawRecord] = []
    /// When each maker's draws came, the last hour's, so a removed record still counts.
    private var made: [String: [Date]] = [:]

    enum Refusal: Equatable { case seen, tooMany, hourly }

    func crowned(_ r: DrawRecord, now: Date) -> Bool { !r.ended && now.timeIntervalSince(r.at) < Self.crownHours * 3600 }

    func live(_ sender: String, now: Date) -> Int { records.filter { $0.sender == sender && crowned($0, now: now) }.count }

    /// Why `sender` cannot make another draw now, nil when they can.
    func refusal(_ sender: String, now: Date) -> Refusal? {
        if live(sender, now: now) >= Self.maxLive { return .tooMany }
        if (made[sender] ?? []).filter({ now.timeIntervalSince($0) < 3600 }).count >= Self.perHour { return .hourly }
        return nil
    }

    /// Newest last; the oldest go past `maxKept`.
    mutating func add(_ r: DrawRecord, now: Date) -> Refusal? {
        prune(now)
        if records.contains(where: { $0.id == r.id }) { return .seen }
        if let no = refusal(r.sender, now: now) { return no }
        made[r.sender, default: []].append(now)
        records.append(r)
        if records.count > Self.maxKept { records.removeFirst(records.count - Self.maxKept) }
        return nil
    }

    mutating func end(_ id: String) { if let i = records.firstIndex(where: { $0.id == id }) { records[i].ended = true } }
    mutating func remove(_ id: String) { records.removeAll { $0.id == id } }

    mutating func prune(_ now: Date) {
        records.removeAll { now.timeIntervalSince($0.at) >= Self.keepHours * 3600 }
        made = made.compactMapValues { d in let k = d.filter { now.timeIntervalSince($0) < 3600 }; return k.isEmpty ? nil : k }
    }

    /// The winners wearing 👑 now (item text, a name when the items were 참가자).
    func crowns(now: Date) -> Set<String> { Set(records.filter { crowned($0, now: now) }.map(\.winner)) }
}

// MARK: The center

final class GroupDraw: ObservableObject {
    static let shared = GroupDraw()

    @Published var game: DrawGame { didSet { defaults.set(game.rawValue, forKey: "draw.game") } }
    @Published var title = ""
    @Published var items: [String] { didSet { defaults.set(items, forKey: "draw.items") } }
    /// Send it to online 근처 친구 and the 원격 모임 room too (this run only).
    @Published var share = true
    @Published private(set) var book = DrawBook()
    /// The draw on the stage and when its show started (distantPast: shown finished).
    @Published private(set) var stage: DrawRecord?
    @Published private(set) var started = Date.distantPast
    @Published private(set) var landed = true
    @Published var notice: String?

    private let defaults = AppDefaults.store
    private var panel: NSPanel?
    private var land: DispatchWorkItem?

    init() {
        game = DrawGame(rawValue: AppDefaults.store.string(forKey: "draw.game") ?? "") ?? .roulette
        items = Array((AppDefaults.store.stringArray(forKey: "draw.items") ?? [])
            .map(DrawShare.tidy).filter { !$0.isEmpty }.prefix(DrawShare.maxItems))
    }

    /// Who would see it besides me: nearby friends that read draws, and the 원격 모임 while in a room.
    var audience: (nearby: [String], meet: Bool) {
        let bus = SocialBus.shared
        return (RoomRules.emoteTargets(online: bus.online, versions: bus.versions), RemoteMeet.shared.isOn && RemoteMeet.shared.code != nil)
    }

    @discardableResult
    func add(_ typed: String) -> Bool {
        let t = DrawShare.tidy(typed)
        guard !t.isEmpty, items.count < DrawShare.maxItems else { return false }
        items.append(t)
        return true
    }

    /// 참가자 넣기: me, online 근처 친구 and 원격 모임 members, each once, up to 12.
    func addPeople() {
        let names = [SocialBus.shared.nickname]
            + SocialBus.shared.friends.filter(\.isOnline).map(\.nickname)
            + RemoteMeet.shared.notes.values.map(\.name).sorted()
        for n in names where !items.contains(n) { add(n) }
    }

    /// 뽑기: a new draw of mine, on the stage and sent. False (with `notice`) when refused.
    @discardableResult
    func start(now: Date = Date()) -> Bool {
        guard let s = DrawShare.make(game, title: title, items: items) else {
            notice = L("항목을 2개 이상 넣어 주세요"); return false
        }
        let r = DrawRecord(share: s, from: L("나"), sender: "me", at: now)
        if let no = book.add(r, now: now) {
            notice = no == .tooMany ? L("동시에 \(DrawBook.maxLive)개까지예요. 기록에서 하나를 끝내 주세요") : L("한 시간에 \(DrawBook.perHour)개까지 뽑을 수 있어요")
            return false
        }
        notice = nil
        if share {
            let a = audience
            a.nearby.forEach { SocialBus.shared.send(.draw(s), to: $0) }
            if a.meet { RemoteMeet.shared.sendDraw(s) }
        }
        play(r)
        return true
    }

    /// A friend's draw (already checked by the caller's wire). `bubble`: say the result when the panel is closed
    /// (the 원격 모임 says its own line).
    func received(_ raw: DrawShare, from name: String, sender: String, bubble: Bool, now: Date = Date()) {
        guard let s = DrawShare.received(raw) else { return }
        let r = DrawRecord(share: s, from: SocialText.nickname(name), sender: sender, at: now)
        guard book.add(r, now: now) == nil, !FriendVisit.quiet() else { return }
        if panel?.isVisible == true { play(r); return }
        guard bubble else { return }
        SpeechBubbleCenter.shared.say(text: L("\(s.game.emoji) \(r.from)의 \(r.name): 👑 \(r.winner)"), source: .system, aloud: false, repeats: true)
    }

    /// 다시 보기 too.
    func play(_ r: DrawRecord) {
        land?.cancel()
        stage = r
        let still = DesktopKit.reduceMotion
        started = still ? .distantPast : Date()
        landed = still
        guard !still else { return }
        let w = DispatchWorkItem { [weak self] in self?.landed = true }
        land = w
        DispatchQueue.main.asyncAfter(deadline: .now() + DrawRules.duration(r.share, r.plan), execute: w)
    }

    func end(_ id: String) { book.end(id) }

    func remove(_ id: String) {
        book.remove(id)
        if stage?.id == id { stage = nil }
    }

    func crowns(now: Date = Date()) -> Set<String> { book.crowns(now: now) }

    func show() {
        book.prune(Date())
        if panel == nil {
            let p = OfficeCenter.floatingPanel(title: L("그룹 뽑기"), size: CGSize(width: 380, height: 640), resizable: false)
            if !p.setFrameUsingName("draw.panel") { p.center() }
            p.setFrameAutosaveName("draw.panel")
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: GroupDrawView(draw: self))
        panel?.orderFrontRegardless()
    }

    static func menuItem() -> NSMenuItem { FriendMenu.item(L("그룹 뽑기…")) { GroupDraw.shared.show() } }

    #if !MAS
    /// QA renders only.
    func qaSet(_ r: DrawRecord?, book: DrawBook) {
        self.book = book
        stage = r
        started = .distantPast
        landed = true
    }
    #endif
}

// MARK: The panel

struct GroupDrawView: View {
    @ObservedObject var draw: GroupDraw
    @ObservedObject private var settings = AppSettings.shared
    /// QA renders: the show frozen at this many seconds.
    var at: TimeInterval?
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 10) {
            stage
            Picker(L("게임"), selection: $draw.game) {
                ForEach(DrawGame.allCases, id: \.self) { Text(verbatim: "\($0.emoji) \($0.label)").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField(L("제목 (선택, 15자)"), text: $draw.title).textFieldStyle(.roundedBorder).font(.system(size: 12))
            itemsList
            footer
            history
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        if let r = draw.stage {
            let p = r.plan
            let total = DrawRules.duration(r.share, p)
            TimelineView(.animation(paused: draw.landed || at != nil)) { ctx in
                let t = at ?? (draw.landed ? total : ctx.date.timeIntervalSince(draw.started))
                VStack(spacing: 6) {
                    Group {
                        switch r.share.game {
                        case .roulette: WheelView(items: r.share.items, angle: p.spin * DrawRules.ease(t / total))
                        case .ladder: LadderView(items: r.share.items, plan: p, progress: t / total)
                        case .lots: LotsView(items: r.share.items, plan: p, at: t)
                        }
                    }
                    .frame(height: 200)
                    result(r, done: t >= total)
                }
            }
        } else {
            VStack(spacing: 6) {
                friend(hop: false)
                Text(L("항목을 넣고 뽑기를 누르면 모두에게 같은 결과가 나와요")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(height: 230)
        }
    }

    private func result(_ r: DrawRecord, done: Bool) -> some View {
        HStack(spacing: 8) {
            friend(hop: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(r.share.game.emoji) \(r.name) · \(r.from)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: done ? "👑 \(r.winner)" : "…").font(.system(size: 16, weight: .heavy, design: .rounded)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func friend(hop: Bool) -> some View {
        let cache = DogSpriteCache(SpriteLook(settings), pixelSize: 2)
        return Image(nsImage: cache.frames(for: .walk).first ?? NSImage())
            .interpolation(.none)
            .frame(width: min(cache.imageSize.width, 56), height: min(cache.imageSize.height, 40))
            .scaleEffect(0.55)
            .offset(y: hop && !DesktopKit.reduceMotion ? -4 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.45), value: hop)
            .accessibilityHidden(true)
    }

    // MARK: Editing

    private var itemsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(L("항목 (15자)"), text: $typed).textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit(add)
                Button(L("추가"), action: add).controlSize(.small).disabled(draw.items.count >= DrawShare.maxItems)
                Button(L("참가자 넣기")) { draw.addPeople() }.controlSize(.small).help(L("나와 지금 접속한 친구 이름을 넣어요"))
            }
            FlowItems(items: draw.items) { i in draw.items.remove(at: i) }
            Text(verbatim: "\(draw.items.count)/\(DrawShare.maxItems)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        let a = draw.audience
        let who = a.nearby.isEmpty && !a.meet ? L("혼자 뽑아요") : [a.nearby.isEmpty ? nil : L("근처 친구 \(a.nearby.count)명"), a.meet ? L("원격 모임") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(spacing: 4) {
            HStack {
                Toggle(L("친구에게도 보여주기"), isOn: $draw.share).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                Text(verbatim: draw.share ? who : L("혼자 뽑아요")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: { draw.start() }) {
                    Text(L("뽑기")).font(.system(size: 13, weight: .bold, design: .rounded)).padding(.horizontal, 16).padding(.vertical, 4)
                        .background(Capsule().fill(Color.yellow)).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(draw.items.count < DrawShare.minItems || !draw.landed)
            }
            if let n = draw.notice { Text(n).font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    @ViewBuilder private var history: some View {
        let now = Date()
        if !draw.book.records.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("오늘 기록 (24시간)")).font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(draw.book.records.reversed()) { r in
                            HStack(spacing: 6) {
                                Text(verbatim: "\(r.share.game.emoji) \(r.name)").font(.system(size: 11)).lineLimit(1)
                                Text(verbatim: r.from).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(verbatim: (draw.book.crowned(r, now: now) ? "👑 " : "") + r.winner).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Button { draw.play(r) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).help(L("다시 보기"))
                                if r.mine, draw.book.crowned(r, now: now) {
                                    Button { draw.end(r.id) } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain).help(L("끝내기"))
                                }
                                Button { draw.remove(r.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help(L("기록 지우기"))
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private func add() {
        if draw.add(typed) { typed = "" }
    }
}

/// The items as removable chips, three to a row.
private struct FlowItems: View {
    let items: [String]
    let remove: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 2) {
                    Text(s).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button { remove(i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("\(s) 지우기"))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(DrawPalette.color(i).opacity(0.22)))
            }
        }
    }
}

enum DrawPalette {
    static let colors: [Color] = [Color(red: 0.96, green: 0.55, blue: 0.45), Color(red: 0.98, green: 0.78, blue: 0.35), Color(red: 0.55, green: 0.80, blue: 0.48),
                                  Color(red: 0.42, green: 0.72, blue: 0.90), Color(red: 0.70, green: 0.58, blue: 0.92), Color(red: 0.95, green: 0.60, blue: 0.80)]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }
}

/// 룰렛: slices clockwise from the top, the pointer fixed at the top.
private struct WheelView: View {
    let items: [String]
    let angle: Double

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 8, c = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
            let n = items.count, w = 2 * Double.pi / Double(n), labels = DrawRules.wheelLabels(items, most: n > 6 ? 5 : 8)
            for i in 0..<n {
                let a0 = -Double.pi / 2 + angle + Double(i) * w
                var p = Path()
                p.move(to: c)
                p.addArc(center: c, radius: r, startAngle: .radians(a0), endAngle: .radians(a0 + w), clockwise: false)
                p.closeSubpath()
                // Odd counts would put two same colours side by side at the seam.
                ctx.fill(p, with: .color(DrawPalette.color(n % DrawPalette.colors.count == 1 && i == n - 1 ? 2 : i)))
                ctx.stroke(p, with: .color(.white), lineWidth: 2)
                // Along the radius, never upside down; long names cut so they stay inside the slice.
                let mid = a0 + w / 2, flip = cos(mid) < 0, label = labels[i]
                var t = ctx
                t.translateBy(x: c.x, y: c.y)
                t.rotate(by: .radians(flip ? mid + .pi : mid))
                t.draw(Text(label).font(.system(size: n > 8 ? 10 : 12, weight: .bold, design: .rounded)).foregroundColor(.black),
                       at: CGPoint(x: (flip ? -1 : 1) * r * 0.6, y: 0))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.brown.opacity(0.7)), lineWidth: 3)
            var pin = Path()
            pin.move(to: CGPoint(x: c.x - 9, y: c.y - r - 8))
            pin.addLine(to: CGPoint(x: c.x + 9, y: c.y - r - 8))
            pin.addLine(to: CGPoint(x: c.x, y: c.y - r + 10))
            pin.closeSubpath()
            ctx.fill(pin, with: .color(.red))
        }
        .accessibilityLabel(L("룰렛"))
    }
}

/// 사다리: items on top, 👑 under the star column, the winner's walk traced as it plays.
private struct LadderView: View {
    let items: [String]
    let plan: DrawPlan
    let progress: Double

    var body: some View {
        let n = items.count
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { i in
                    Text(items[i]).font(.system(size: n > 8 ? 8 : 10, weight: i == plan.winner && progress >= 1 ? .heavy : .medium))
                        .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 26)
            Canvas { ctx, size in
                let rows = CGFloat(plan.rungs.count + 1)
                func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x + 0.5) / CGFloat(n) * size.width, y: p.y / rows * size.height) }
                for i in 0..<n {
                    var v = Path()
                    v.move(to: pt(CGPoint(x: CGFloat(i), y: 0)))
                    v.addLine(to: pt(CGPoint(x: CGFloat(i), y: rows)))
                    ctx.stroke(v, with: .color(.secondary.opacity(0.6)), lineWidth: 2)
                }
                for (r, row) in plan.rungs.enumerated() {
                    for (g, on) in row.enumerated() where on {
                        var h = Path()
                        h.move(to: pt(CGPoint(x: CGFloat(g), y: CGFloat(r + 1))))
                        h.addLine(to: pt(CGPoint(x: CGFloat(g + 1), y: CGFloat(r + 1))))
                        ctx.stroke(h, with: .color(.secondary.opacity(0.6)), lineWidth: 2)
                    }
                }
                let walk = DrawRules.ladderPath(from: plan.winner, plan.rungs, count: n).map(pt)
                ctx.stroke(Self.partial(walk, min(max(progress, 0), 1)), with: .color(.red), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { i in
                    Text(verbatim: i == plan.star ? "👑" : "·").font(.system(size: 12)).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 16)
        }
        .accessibilityElement()
        .accessibilityLabel(L("사다리"))
    }

    /// The first `f` of the polyline's length.
    static func partial(_ pts: [CGPoint], _ f: Double) -> Path {
        let segs = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var left = segs.reduce(0, +) * f, p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for (i, len) in segs.enumerated() where left > 0 {
            let a = pts[i], b = pts[i + 1], k = min(left / max(len, 0.001), 1)
            p.addLine(to: CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k))
            left -= len
        }
        return p
    }
}

/// 제비뽑기: folded papers; the hand hops over them, then the winner slides out to the right and opens.
private struct LotsView: View {
    let items: [String]
    let plan: DrawPlan
    let at: TimeInterval

    var body: some View {
        let state = DrawRules.lots(plan, at: at)
        let cols = 4
        HStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: cols), spacing: 6) {
                ForEach(0..<items.count, id: \.self) { i in
                    let over = i == state.hop
                    let gone = i == plan.winner && state.unfold > 0
                    paper(folded: true, tint: DrawPalette.color(i))
                        .frame(width: 40, height: 30)
                        .offset(y: over && !gone ? -4 : 0)
                        .opacity(gone ? 0.25 : 1)
                        .overlay(alignment: .top) { if over && !gone { Text(verbatim: "👇").font(.system(size: 12)).offset(y: -16) } }
                }
            }
            .frame(width: 190)
            // The opened paper.
            paper(folded: false, tint: DrawPalette.color(plan.winner))
                .overlay(Text(items[plan.winner]).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6).padding(6)
                    .opacity(state.unfold > 0.5 ? 1 : 0))
                .frame(width: 100, height: 70)
                .scaleEffect(x: max(state.unfold, 0.05), y: 1, anchor: .leading)
                .offset(x: CGFloat(1 - state.unfold) * -40)
                .opacity(state.unfold > 0 ? 1 : 0)
        }
        .accessibilityElement()
        .accessibilityLabel(L("제비뽑기"))
    }

    private func paper(folded: Bool, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.99, green: 0.97, blue: 0.9))
            RoundedRectangle(cornerRadius: 3).strokeBorder(tint, lineWidth: 2)
            if folded {
                Path { p in p.move(to: CGPoint(x: 6, y: 15)); p.addLine(to: CGPoint(x: 34, y: 15)) }.stroke(tint.opacity(0.7), lineWidth: 1)
                Text(verbatim: "?").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(tint).offset(y: -6)
            }
        }
    }
}

#if !MAS
/// --render-draw <폴더>: each game mid-show and landed, the empty panel, light and dark.
enum GroupDrawQA {
    static func render(to dir: URL) throws {
        let d = GroupDraw.shared
        d.items = ["보리", "콩이", "나", "두부", "감자", "치즈"]
        d.share = false
        let now = Date()
        var book = DrawBook()
        var records: [DrawRecord] = []
        for (i, g) in DrawGame.allCases.enumerated() {
            let s = DrawShare.make(g, title: i == 0 ? "커피 쏘기" : "", items: d.items, seed: UInt64(41 + i))!
            let r = DrawRecord(share: s, from: i == 1 ? "보리" : L("나"), sender: i == 1 ? "f:x" : "me", at: now)
            _ = book.add(r, now: now)
            records.append(r)
        }
        d.qaSet(nil, book: DrawBook())
        try DashboardSnapshot.snapshot(GroupDrawView(draw: d), appearance: .aqua, to: dir.appendingPathComponent("draw-empty.png"))
        for r in records {
            d.game = r.share.game
            d.qaSet(r, book: book)
            let total = DrawRules.duration(r.share, r.plan)
            try DashboardSnapshot.snapshot(GroupDrawView(draw: d, at: total * 0.55), appearance: .aqua,
                                           to: dir.appendingPathComponent("draw-\(r.share.game.rawValue)-mid.png"))
            for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try DashboardSnapshot.snapshot(GroupDrawView(draw: d, at: total), appearance: look,
                                               to: dir.appendingPathComponent("draw-\(r.share.game.rawValue)-\(name).png"))
            }
        }
        // Twelve long items: the densest wheel and ladder.
        let long = (1...12).map { "항목 \($0) 이름이 조금 긴 편" }
        for g in [DrawGame.roulette, .ladder] {
            let s = DrawShare.make(g, title: "", items: long, seed: 9)!
            let r = DrawRecord(share: s, from: L("나"), sender: "me", at: now)
            d.qaSet(r, book: book)
            try DashboardSnapshot.snapshot(GroupDrawView(draw: d, at: DrawRules.duration(s, r.plan)), appearance: .aqua,
                                           to: dir.appendingPathComponent("draw-\(g.rawValue)-12.png"))
        }
    }
}
#endif
