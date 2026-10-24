import AppKit
import AVFoundation
import SwiftUI

/// The 시즌 뽑기판 panel: the season's make-up in full, the board of paper squares, and the 종이 뜯기: pick a square,
/// spend a 뽑기권, then peel its corner down (drag it, or press 바로 뜯기) to see what was under it. The result is
/// saved the moment the 뽑기권 is spent, so closing mid-peel loses nothing.
enum SeasonPanel {
    private static var panel: NSPanel?

    static func show() {
        SeasonCenter.shared.look()
        if panel == nil {
            let p = OfficeCenter.floatingPanel(title: L("시즌 뽑기판"), size: CGSize(width: 380, height: 640), resizable: false)
            if !p.setFrameUsingName("season.board") { p.center() }
            p.setFrameAutosaveName("season.board")
            p.sharingType = .readOnly   // only the board: fine on a shared screen
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: SeasonBoardView(center: .shared))
        panel?.orderFrontRegardless()
    }

    /// 놀이 ▸ 시즌 뽑기판, while it is on.
    static func menuItems() -> [NSMenuItem] {
        SeasonCenter.shared.isOn ? [FriendMenu.item(L("시즌 뽑기판")) { show() }] : []
    }
}

// MARK: Art

/// A season prize, or a coin, in code pixels: stamps as they are worn, a shirt and a bubble as small shapes in their colour.
struct SeasonIcon: View {
    /// An item id; nil = coins.
    let id: String?
    var dim = false

    private static let shirt = [".KK...KK.", "KSSKKKSSK", "KSSSSSSSK", ".KSSSSSK.", ".KSSSSSK.", ".KKKKKKK."]
    private static let bubble = [".KKKKK.", "KSSSSSK", "KSSSSSK", ".KKKKK.", "..KK...", "..K...."]
    private static let coin = ["..yyy..", ".yYYYy.", "yYWYYYy", "yYYYYYy", ".yYYYy.", "..yyy.."]

    var body: some View {
        Canvas { ctx, size in
            let (rows, colors) = Self.art(id)
            guard let w = rows.map(\.count).max(), w > 0 else { return }
            let px = floor(min(size.width / CGFloat(w), size.height / CGFloat(rows.count)))
            let ox = (size.width - px * CGFloat(w)) / 2, oy = (size.height - px * CGFloat(rows.count)) / 2
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() {
                    guard let col = colors[ch] else { continue }
                    ctx.fill(Path(CGRect(x: ox + CGFloat(c) * px, y: oy + CGFloat(r) * px, width: px, height: px)),
                             with: .color(Color(red: Double(col.r) / 255, green: Double(col.g) / 255, blue: Double(col.b) / 255)))
                }
            }
        }
        .saturation(dim ? 0 : 1)
        .opacity(dim ? 0.35 : 1)
        .accessibilityLabel(Text(verbatim: id.map(SeasonCatalog.name) ?? L("코인")))
    }

    static func art(_ id: String?) -> ([String], [Character: PixelColor]) {
        guard let id else { return (coin, Wardrobe.ink) }
        if let b = SeasonCatalog.bubble(id) { return (bubble, Wardrobe.ink.merging(["S": PixelColor(hex: b.hex)]) { $1 }) }
        if let t = Throwables.item(id: id) { return (t.art, Wardrobe.ink) }
        if let c = ChairCatalog.chair(id) { return (c.rows, c.colors) }
        guard let it = Wardrobe.item(id) else { return ([], [:]) }
        if let hex = it.hex { return (shirt, Wardrobe.ink.merging(["S": PixelColor(hex: hex)]) { $1 }) }
        return (it.art, Wardrobe.ink)
    }
}

/// One paper square. `peel` 0...1 folds its top right corner down toward the bottom left; the flap shows the paper's
/// back. What lies under it shows through where the paper is gone.
struct SeasonPaper: View {
    let number: Int
    var peel: Double = 0
    var selected = false

    static let face = Color(red: 0.99, green: 0.96, blue: 0.86), back = Color(red: 0.90, green: 0.84, blue: 0.68)
    static let edge = Color(red: 0.62, green: 0.50, blue: 0.30)

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height), d = s * min(1, max(0, peel))
            ZStack {
                Self.sheet(s, d).fill(Self.face)
                Self.sheet(s, d).applying(CGAffineTransform(translationX: s * 0.06, y: s * 0.06).scaledBy(x: 0.88, y: 0.88))
                    .stroke(Self.edge.opacity(0.55), style: StrokeStyle(lineWidth: max(1, s / 60), dash: [s / 22, s / 30]))
                Self.snow(s).fill(Self.edge.opacity(0.18)).mask(Self.sheet(s, d))
                Text(verbatim: "\(number)").font(.system(size: s * 0.3, weight: .heavy, design: .rounded))
                    .foregroundStyle(Self.edge.opacity(0.75)).mask(Self.sheet(s, d))
                if d > 0 {
                    Self.flap(s, d).fill(Self.back).shadow(color: .black.opacity(0.25), radius: s / 40, x: -s / 80, y: s / 80)
                    Self.flap(s, d).stroke(Self.edge.opacity(0.35), lineWidth: 1)
                }
            }
            .frame(width: s, height: s)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Color.accentColor : .clear, lineWidth: 3).padding(-3))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The square without its folded corner (top left origin).
    static func sheet(_ s: CGFloat, _ d: CGFloat) -> Path {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: s - d, y: 0))
            p.addLine(to: CGPoint(x: s, y: d))
            p.addLine(to: CGPoint(x: s, y: s))
            p.addLine(to: CGPoint(x: 0, y: s))
            p.closeSubpath()
        }
    }

    /// The corner folded over along the 45° crease: (s,0) lands on (s-d, d).
    static func flap(_ s: CGFloat, _ d: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: s - d, y: 0))
            p.addLine(to: CGPoint(x: s, y: d))
            p.addLine(to: CGPoint(x: s - d, y: d))
            p.closeSubpath()
        }
    }

    /// A faint pixel snowflake in the lower left, the season's mark on the paper.
    static func snow(_ s: CGFloat) -> Path {
        let rows = ["..X..", "X.X.X", ".XXX.", "X.X.X", "..X.."], px = s / 16
        return Path { p in
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() where ch == "X" {
                    p.addRect(CGRect(x: s * 0.1 + CGFloat(c) * px, y: s * 0.62 + CGFloat(r) * px, width: px, height: px))
                }
            }
        }
    }

    /// How far a drag from the corner has peeled: along the diagonal down and to the left, over the square's side.
    static func progress(_ t: CGSize, side: CGFloat) -> Double {
        guard side > 0 else { return 0 }
        return min(1, max(0, Double((t.height - t.width) / 2 / side)))
    }

    /// Let go past this and the paper comes off; before it, it springs back.
    static let tearAt = 0.45
}

// MARK: The board

struct SeasonBoardView: View {
    @ObservedObject var center: SeasonCenter
    @ObservedObject var pet = PetModel.shared
    @State var selected: Int?
    /// The cell being peeled and what it gave (already saved).
    @State var pending: (cell: Int, outcome: SeasonOutcome)?
    @State var peel: Double = 0
    @State var revealed = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private var m: SeasonManifest { center.manifest }
    private var s: SeasonState { center.state }
    private var today: String { center.today }
    private var accent: Color { AppSettings.shared.palette.accent ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            makeUp
            if pending != nil { tearing } else { board }
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: "🎟️ " + m.title.shown).font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text(verbatim: dayText).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(L("뽑기권 \(s.tickets)장"), systemImage: "ticket").font(.system(size: 12, weight: .semibold))
                Label(L("코인 \(pet.state.coins)"), systemImage: "circle.hexagongrid").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var dayText: String {
        if today < m.starts { return L("오픈까지 \(SeasonRules.days(from: today, to: m.starts) ?? 0)일") }
        if today > m.ends { return L("시즌이 끝났어요") }
        let left = SeasonRules.days(from: today, to: m.ends) ?? 0
        return left == 0 ? L("오늘 마지막 날") : L("\(left)일 남음")
    }

    /// The whole board in the open: so many cells, these items, the rest coins, and which items are here already.
    private var makeUp: some View {
        let b = s.board, coinCells = m.cells - m.items.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("판 구성: \(m.cells)칸 · 꾸미기 \(m.items.count)개 · 코인 \(coinCells)칸(\(m.coins)개씩)"))
                .font(.system(size: 11, weight: .semibold))
            Text(L("판을 다 열면 전부 가져요. 이미 가진 꾸미기는 코인 \(m.refund)개로 바꿔 줘요."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 4), count: 12), spacing: 4) {
                ForEach(m.items, id: \.self) { id in
                    let found = b.map { b in b.opened.contains { b.cells[$0] == id } } ?? false
                    SeasonIcon(id: id, dim: !found && !s.owned.contains(id)).padding(2).frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(SeasonPaper.face))   // the dark outlines read in dark mode too
                        .overlay(alignment: .bottomTrailing) {
                            if found { Image(systemName: "checkmark.circle.fill").font(.system(size: 8)).foregroundStyle(accent) }
                        }
                        .help(SeasonCatalog.name(id))
                }
            }
            if let b { Text(L("남은 칸 \(b.left)/\(b.cells.count)")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private var board: some View {
        if let b = s.board, SeasonRules.active(m, today: today) {
            let cols = b.cells.count <= 9 ? 3 : b.cells.count <= 16 ? 4 : 5
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                ForEach(b.cells.indices, id: \.self) { i in
                    if b.opened.contains(i) {
                        RoundedRectangle(cornerRadius: 4).fill(SeasonPaper.back.opacity(0.6)).aspectRatio(1, contentMode: .fit)
                            .overlay(SeasonIcon(id: b.cells[i]).padding(10))
                    } else {
                        SeasonPaper(number: i + 1, selected: selected == i)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = selected == i ? nil : i }
                            .accessibilityElement()
                            .accessibilityLabel(Text(L("\(i + 1)번 종이")))
                            .accessibilityAddTraits(selected == i ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            if b.isDone {
                Button(L("판을 다 열었어요! 새 판 받기")) { center.nextBoard(); selected = nil }.controlSize(.large).frame(maxWidth: .infinity)
            } else {
                Button(L("한 장 뜯기 · 뽑기권 1장")) { tear() }
                    .controlSize(.large).keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
                    .disabled(selected == nil || s.tickets == 0)
            }
        } else {
            Text(today < m.starts ? L("시즌이 열리면 판이 나와요. 뽑기권은 그대로 남아요.") : L("이번 시즌은 끝났어요. 남은 뽑기권은 다음 시즌에 써요."))
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    /// The big paper over what it hid: drag its corner down, or 바로 뜯기.
    @ViewBuilder private var tearing: some View {
        if let p = pending {
            let side: CGFloat = 200
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(SeasonPaper.back.opacity(0.6))
                    SeasonIcon(id: Self.item(p.outcome)).padding(36)
                    if !revealed {
                        SeasonPaper(number: p.cell + 1, peel: peel)
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { v in peel = SeasonPaper.progress(v.translation, side: side) }
                                .onEnded { _ in peel >= SeasonPaper.tearAt ? finish() : spring(0) })
                            .accessibilityElement()
                            .accessibilityLabel(Text(L("\(p.cell + 1)번 종이, 모서리를 아래로 끌어 뜯어요")))
                            .accessibilityAction(named: Text(L("바로 뜯기"))) { finish() }
                    }
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity)
                if revealed {
                    Text(verbatim: Self.result(p.outcome)).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Button(L("확인")) { pending = nil; peel = 0; revealed = false; selected = nil }
                        .controlSize(.large).keyboardShortcut(.defaultAction).frame(maxWidth: .infinity)
                } else {
                    Text(L("오른쪽 위 모서리를 왼쪽 아래로 끌어 뜯어요")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Button(L("바로 뜯기")) { finish() }.controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .onAppear { if peel == 0, !reduceMotion { spring(0.12) } }   // a small lift says "this corner"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Button(L("뽑기권 사기 · 코인 \(m.ticketPrice)")) { _ = center.buy() }
                    .controlSize(.small)
                    .disabled(!SeasonRules.canBuy(s, m, coins: pet.state.coins, today: today))
                Text(L("오늘 \(s.bought)/\(m.buyPerDay)")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(L("뽑기권은 무료예요. 매일 \(m.freePerDay)장이 오고, 후원 친구 카드를 끝까지 보면 1장 더 와요. 돈은 받지 않아요."))
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("코인은 미션·집중·숨 고르기·친구와 이모트로 모여요(숨 고르기·이모트는 하루 \(SeasonRules.bonusPerDay)개까지)."))
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tear() {
        guard let cell = selected, let out = center.open(cell) else { return }
        peel = 0
        revealed = false
        pending = (cell, out)
        SeasonSound.play(.lift)
    }

    private func finish() {
        guard !revealed else { return }
        SeasonSound.play(.rip)
        if reduceMotion { revealed = true } else {
            withAnimation(.easeIn(duration: 0.18)) { peel = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { revealed = true }
                if case .item = pending?.outcome { SeasonSound.play(.prize) }
            }
        }
    }

    private func spring(_ to: Double) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { peel = to }
    }

    static func item(_ o: SeasonOutcome) -> String? {
        switch o {
        case .item(let id), .duplicate(let id, _): return id
        case .coins: return nil
        }
    }

    static func result(_ o: SeasonOutcome) -> String {
        switch o {
        case .item(let id):
            let hint = ChairCatalog.chair(id) != nil ? L("데스크톱 친구 설정의 의자에서 골라요")
                : SeasonCatalog.bubble(id) != nil ? L("시즌 뽑기판 설정에서 골라요")
                : Throwables.item(id: id) != nil ? L("던지기 놀이에서 골라요") : L("옷 입히기에서 입혀요")
            return L("새 꾸미기: \(SeasonCatalog.name(id))") + "\n" + hint
        case let .duplicate(id, coins): return L("\(SeasonCatalog.name(id))은(는) 이미 있어서 코인 \(coins)개로 바꿨어요")
        case .coins(let n): return L("코인 \(n)개")
        }
    }
}

// MARK: 설정 > 플러그인 > 시즌 뽑기판

struct SeasonSettings: View {
    @ObservedObject private var center = SeasonCenter.shared
    @ObservedObject private var settings = AppSettings.shared

    private var accent: Color { settings.palette.accent ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("시즌 뽑기판 쓰기", isOn: $center.isOn).toggleStyle(.switch).controlSize(.small).tint(accent)
            Text(L("\(center.manifest.title.shown) · \(center.manifest.starts) ~ \(center.manifest.ends)"))
                .font(.system(size: 11, weight: .semibold))
            Text("무료 뽑기권으로 종이를 뜯어 이번 시즌 꾸미기를 모아요. 판 구성은 다 보여 주고, 판을 다 열면 전부 가져요. 결제는 없어요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if center.isOn {
                HStack {
                    Text(L("뽑기권 \(center.state.tickets)장 · 모은 꾸미기 \(center.state.owned.count)개")).font(.system(size: 11))
                    Spacer()
                    Button("뽑기판 열기") { SeasonPanel.show() }.controlSize(.small)
                }
                let bubbles = SeasonCatalog.bubbles.filter { center.state.owned.contains($0.id) }
                if !bubbles.isEmpty {
                    HStack(spacing: 4) {
                        Text("말풍선 색").font(.system(size: 11)).foregroundStyle(.secondary)
                        chip(L("기본"), on: center.state.bubble == nil) { center.wear(bubble: nil) }
                        ForEach(bubbles, id: \.id) { b in chip(b.name, on: center.state.bubble == b.id) { center.wear(bubble: b.id) } }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(on ? accent.opacity(0.22) : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Sound

/// The 종이 뜯기 sounds, made in memory like FriendCry: a soft lift, a dry rip (filtered noise in crackles), a two-note prize.
enum SeasonSound {
    enum Kind: CaseIterable { case lift, rip, prize }

    static let sampleRate = 22_050
    /// Rip loudness and length: the knobs to tune by ear.
    static let ripSeconds = 0.32, ripGain = 0.55

    static func make(_ kind: Kind) -> Data {
        var rng = SplitMix64(seed: 35)
        var samples: [Double]
        switch kind {
        case .lift:   // a short breath of paper
            let n = Int(0.12 * Double(sampleRate))
            var lp = 0.0
            samples = (0..<n).map { i in
                let u = Double(i) / Double(n)
                lp += 0.08 * (Double.random(in: -1...1, using: &rng) - lp)
                return lp * sin(.pi * u) * 1.6
            }
        case .rip:   // crackles that thin out as the tear runs
            let n = Int(ripSeconds * Double(sampleRate))
            var lp = 0.0
            samples = (0..<n).map { i in
                let u = Double(i) / Double(n)
                lp += 0.45 * (Double.random(in: -1...1, using: &rng) - lp)
                let crackle = 0.55 + 0.45 * sin(2 * .pi * (38 - 20 * u) * u * ripSeconds)
                return lp * crackle * pow(1 - u, 1.4) * min(1, u * 40) * ripGain * 1.8
            }
        case .prize:   // up a fifth
            let n = Int(0.36 * Double(sampleRate)), half = n / 2
            samples = (0..<n).map { i in
                let f = i < half ? 784.0 : 1175.0, t = Double(i % half) / Double(sampleRate)
                return 0.35 * sin(2 * .pi * f * t) * exp(-t * 9)
            }
        }
        var pcm = Data(capacity: samples.count * 2)
        for v in samples {
            let s = Int16(max(-1, min(1, v)) * 26_000)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return ChimeSound.wav(pcm, sampleRate: sampleRate)
    }

    private static var players: [Kind: AVAudioPlayer] = [:]

    static func play(_ kind: Kind) {
        guard AppSettings.shared.friendSounds, !SpeechBubbleCenter.shared.isMuted(),
              let p = players[kind] ?? (try? AVAudioPlayer(data: make(kind))) else { return }
        players[kind] = p
        p.volume = 0.5
        p.currentTime = 0
        p.play()
    }
}

// MARK: QA

/// `--render-season <폴더>`: the panel and the settings in each state, light and dark, from a season made to run today.
enum SeasonQA {
    static func render(to dir: URL) throws {
        let c = SeasonCenter.shared
        let today = PluginRules.day(Date())
        var m = SeasonManifest.bundled
        m.starts = today
        m.ends = PluginRules.day(Date().addingTimeInterval(20 * 86_400))
        var s = SeasonState()
        s.day = today
        s.tickets = 3
        s.board = SeasonRules.deal(m, seed: 7)
        let items = s.board!.cells.indices.filter { s.board!.cells[$0] != nil }
        let coinCell = s.board!.cells.indices.first { s.board!.cells[$0] == nil }!
        s.board!.opened = [items[0], items[1], coinCell]
        s.owned = [s.board!.cells[items[0]]!, s.board!.cells[items[1]]!, "bubble-snow"]
        s.bubble = "bubble-snow"
        c.isOn = true
        c.seed(m, s)
        PetModel.shared.receive(coins: 64)
        let next = items[2], prize = SeasonOutcome.item(s.board!.cells[next]!)
        let shots: [(String, AnyView)] = [
            ("board", AnyView(SeasonBoardView(center: c, selected: next))),
            ("peel", AnyView(SeasonBoardView(center: c, selected: next, pending: (next, prize), peel: 0.42))),
            ("prize", AnyView(SeasonBoardView(center: c, pending: (next, prize), peel: 1, revealed: true))),
            ("refund", AnyView(SeasonBoardView(center: c, pending: (items[0], .duplicate(s.board!.cells[items[0]]!, coins: m.refund)), peel: 1, revealed: true))),
            ("settings", AnyView(SeasonSettings().frame(width: 360).padding())),
            ("bubble", AnyView(SpeechBubbleView(text: L("말풍선 색도 시즌 꾸미기예요")))),
        ]
        for (name, view) in shots {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try DashboardSnapshot.snapshot(view, appearance: appearance, to: dir.appendingPathComponent("season-\(name)-\(suffix).png"))
            }
        }
        var done = s
        done.board!.opened = Array(done.board!.cells.indices)
        c.seed(m, done)
        try DashboardSnapshot.snapshot(SeasonBoardView(center: c), appearance: .aqua, to: dir.appendingPathComponent("season-done-light.png"))
        var before = s
        before.board = nil
        m.starts = PluginRules.day(Date().addingTimeInterval(5 * 86_400))
        c.seed(m, before)
        try DashboardSnapshot.snapshot(SeasonBoardView(center: c), appearance: .aqua, to: dir.appendingPathComponent("season-soon-light.png"))
    }
}
