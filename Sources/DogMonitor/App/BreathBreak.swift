import AppKit
import AVFoundation
import Combine
import SwiftUI

/// 숨 고르기: the three places the character breathes in. Raw values are saved; never rename one.
enum BreathScene: String, CaseIterable {
    case dusk, lateOffice, rainForest

    var label: String {
        switch self {
        case .dusk: return L("퇴근길 노을")
        case .lateOffice: return L("새벽 두 시 사무실")
        case .rainForest: return L("비 오는 숲")
        }
    }
}

/// The 4-4 breath: in for 4 s, out for 4 s, four times (32 s, "30초" on the label). Pure, a function of the seconds since start.
enum BreathPlan {
    static let inhale: TimeInterval = 4, exhale: TimeInterval = 4, cycles = 4
    static var seconds: TimeInterval { Double(cycles) * (inhale + exhale) }

    enum Phase: Equatable { case inhale, exhale, done }

    /// The phase at `t` and how far into it (0..<1).
    static func phase(_ t: TimeInterval) -> (phase: Phase, progress: Double) {
        guard t < seconds else { return (.done, 1) }
        let u = max(0, t).truncatingRemainder(dividingBy: inhale + exhale)
        return u < inhale ? (.inhale, u / inhale) : (.exhale, (u - inhale) / exhale)
    }

    /// The guide circle's size, 0 (empty lungs) to 1 (full), eased so it slows at both ends.
    static func circle(_ t: TimeInterval) -> Double {
        let (p, x) = phase(t)
        let ease = (1 - cos(.pi * x)) / 2
        switch p {
        case .inhale: return ease
        case .exhale: return 1 - ease
        case .done: return 0
        }
    }

    /// The count in the circle: 4, 3, 2, 1 through each phase.
    static func count(_ t: TimeInterval) -> Int {
        let (p, x) = phase(t)
        return p == .done ? 0 : max(1, Int(((1 - x) * (p == .inhale ? inhale : exhale)).rounded(.up)))
    }
}

/// 하루 횟수: how many breaths were taken on `day` ("2026-10-24", the Mac's calendar). Another day starts at 0.
struct BreathTally: Equatable {
    var day = ""
    var count = 0

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func today(_ key: String) -> Int { day == key ? count : 0 }

    mutating func add(_ key: String) {
        if day != key { (day, count) = (key, 0) }
        count += 1
    }

    /// The short word after a breath, by how many today (`n`, this one counted).
    static func praise(_ n: Int, polite: Bool) -> String {
        switch n {
        case ...1: return polite ? L("숨 한 번 잘 골랐어요. 어깨가 조금 내려갔죠?") : L("숨 한 번 잘 골랐어. 어깨가 조금 내려갔지?")
        case 2: return polite ? L("오늘 두 번째예요. 아까보다 편해 보여요.") : L("오늘 두 번째야. 아까보다 편해 보여.")
        default: return polite ? L("오늘 \(n)번째 숨 고르기. 나를 잘 챙기고 있어요!") : L("오늘 \(n)번째 숨 고르기. 나를 잘 챙기고 있네!")
        }
    }
}

/// A singing bowl made in code (no recording): a soft mallet strike, then slowly fading partials of our own, the
/// first one beating against a twin a hair above it, so the ring wavers like a real bowl. Mono Float samples.
enum SingingBowl {
    static let sampleRate = 44_100.0
    /// (ratio to the base note, loudness, decay per second).
    static let partials: [(ratio: Double, amp: Double, decay: Double)] = [
        (1, 1, 0.55), (1.005, 0.7, 0.6), (2.71, 0.4, 0.95), (5.17, 0.16, 1.7), (8.6, 0.06, 2.6),
    ]

    static func samples(freq: Double = 196, seconds: Double = 5) -> [Float] {
        let n = max(0, Int(seconds * sampleRate)), total = partials.reduce(0) { $0 + $1.amp }
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            var v = 0.0
            for p in partials { v += p.amp * exp(-p.decay * t) * sin(2 * .pi * freq * p.ratio * t) }
            let attack = min(1, t / 0.04), tail = min(1, (seconds - t) / 0.3)   // no click at either end
            return Float(v / total * attack * max(0, tail) * 0.8)
        }
    }
}

/// 숨 고르기 (30초 명상): a small panel in the middle of the screen, the character resting with its eyes shut in one of
/// three scenes drawn in code, a circle to breathe with, a singing bowl at the start and the end, a word of praise, and
/// how many today. Opened from the friend menu, 설정 (집중 타이머) or, if switched on, offered when a focus run ends.
final class BreathCenter: ObservableObject {
    static let shared = BreathCenter()

    enum Stage: Equatable {
        case idle
        /// Waiting for 시작; `offered` after a focus run ("숨 고르기 할래?").
        case ready(offered: Bool)
        case breathing(since: Date)
        case done(String)
    }

    @Published var scene: BreathScene { didSet { defaults.set(scene.rawValue, forKey: "breath.scene") } }
    /// 싱잉볼 소리.
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "breath.sound") } }
    /// 집중이 끝나면 숨 고르기 제안. Off by default.
    @Published var offerAfterFocus: Bool { didSet { defaults.set(offerAfterFocus, forKey: "breath.offer") } }
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var tally: BreathTally

    private let defaults: UserDefaults
    private var panel: NSPanel?
    private var next: DispatchWorkItem?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        scene = defaults.string(forKey: "breath.scene").flatMap(BreathScene.init) ?? .dusk
        sound = defaults.object(forKey: "breath.sound") as? Bool ?? true
        offerAfterFocus = defaults.bool(forKey: "breath.offer")
        tally = BreathTally(day: defaults.string(forKey: "breath.day") ?? "", count: defaults.integer(forKey: "breath.count"))
    }

    var todayCount: Int { tally.today(BreathTally.key(Date())) }

    /// QA only (BreathCenter.render): a stage to draw, no panel, timer or sound.
    func seed(_ stage: Stage, count: Int = 0) {
        self.stage = stage
        tally = BreathTally(day: BreathTally.key(Date()), count: count)
    }

    /// From a menu or 설정: the panel, waiting for 시작.
    func open() {
        if case .breathing = stage { return }
        show(.ready(offered: false))
    }

    /// A focus run just ended: "숨 고르기 할래?" if that is switched on, nothing is up and no call or recording is going
    /// (FriendVisit.quiet). Goes by itself after 20 s untouched.
    func offer() {
        guard offerAfterFocus, stage == .idle, !FriendVisit.quiet() else { return }
        show(.ready(offered: true))
        after(20) { [weak self] in if self?.stage == .ready(offered: true) { self?.close() } }
    }

    func start() {
        stage = .breathing(since: Date())
        ring()
        after(BreathPlan.seconds) { [weak self] in self?.finish() }
    }

    /// The breath is done: counted for today, the bowl again, the word of praise, then the panel goes.
    private func finish() {
        let key = BreathTally.key(Date())
        tally.add(key)
        defaults.set(tally.day, forKey: "breath.day")
        defaults.set(tally.count, forKey: "breath.count")
        SeasonCenter.shared.breathed()
        stage = .done(BreathTally.praise(tally.count, polite: !AssistantModel.persona().style.banmal))
        ring()
        if !FriendVisit.quiet() { DesktopKit.celebrate.send(.proud) }
        after(6) { [weak self] in if case .done = self?.stage { self?.close() } }
    }

    func close() {
        next?.cancel(); next = nil
        stage = .idle
        panel?.orderOut(nil)
        player?.stop()
        engine?.stop()   // lets go of the audio device
    }

    private func after(_ seconds: TimeInterval, _ run: @escaping () -> Void) {
        next?.cancel()
        let w = DispatchWorkItem(block: run)
        next = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func show(_ s: Stage) {
        stage = s
        let p = panel ?? makePanel()
        panel = p
        if p.contentView == nil { p.contentView = FirstClickHost(rootView: BreathView(center: self)) }
        p.setContentSize(p.contentView?.fittingSize ?? .zero)
        let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        p.setFrameOrigin(CGPoint(x: v.midX - p.frame.width / 2, y: v.midY - p.frame.height / 2))
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = BreathPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        return p
    }

    /// The bowl through AVAudioEngine, when 싱잉볼 소리 and 친구 소리 are on and no call or recording is going.
    private func ring() {
        guard sound, AppSettings.shared.friendSounds, !FriendVisit.quiet(),
              let format = AVAudioFormat(standardFormatWithSampleRate: SingingBowl.sampleRate, channels: 1) else { return }
        let data = SingingBowl.samples()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(data.count)
        data.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: data.count) }
        if engine == nil {
            let e = AVAudioEngine(), n = AVAudioPlayerNode()
            e.attach(n)
            e.connect(n, to: e.mainMixerNode, format: format)
            (engine, player) = (e, n)
        }
        guard let engine, let player else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        player.volume = 0.6
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }
}

/// Never key: the app in front stays in front.
private final class BreathPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: Drawing

/// The panel: the scene card (sky, the resting character, the breathing circle), then the scene picker and buttons.
struct BreathView: View {
    @ObservedObject var center: BreathCenter
    /// QA renders: draw this moment, no clock.
    var at: Date?
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 300, sceneHeight: CGFloat = 230

    var body: some View {
        let breathing: Date? = { if case .breathing(let d) = center.stage { return d } else { return nil } }()
        let card = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            Group {
                if let at {
                    stage(now: at, since: breathing)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: center.stage == .idle || (DesktopKit.reduceMotion && breathing == nil))) { tl in
                        stage(now: tl.date, since: breathing)
                    }
                }
            }
            .frame(width: Self.width, height: Self.sceneHeight)
            .clipShape(UnevenRect(top: 22))
            controls.padding(12)
        }
        .frame(width: Self.width)
        .background(card.fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(card.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .padding(14)
        .fixedSize()
    }

    private func stage(now: Date, since: Date?) -> some View {
        let t = since.map { now.timeIntervalSince($0) } ?? 0
        let still = DesktopKit.reduceMotion
        let w = Self.width, h = Self.sceneHeight
        let cache = Self.sprite()
        let rest = cache.frames(for: .lying).first
        let size = CGFloat(BreathPlan.circle(t))
        let r = w * (0.11 + 0.1 * size)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in BreathArt.draw(ctx, w: w, h: h, scene: center.scene, t: still ? 0 : now.timeIntervalSinceReferenceDate) }
            if since != nil {
                ZStack {
                    Circle().fill(Color.white.opacity(0.16 + 0.1 * size))
                    Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 2)
                    VStack(spacing: 1) {
                        Text(verbatim: BreathPlan.phase(t).phase == .inhale ? L("들이쉬어요") : L("내쉬어요"))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(verbatim: "\(BreathPlan.count(t))").font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .fixedSize()
                }
                .frame(width: 2 * r, height: 2 * r)
                .position(x: w / 2, y: h * 0.38)
                .accessibilityElement(children: .combine)
            }
            if let rest {
                Image(nsImage: rest).interpolation(.none)
                    .frame(width: cache.imageSize.width, height: cache.imageSize.height)
                    .position(x: w / 2, y: h * 0.9 - cache.imageSize.height / 2)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The character's frames, made again only when the look changes (the stage redraws 30 times a second).
    private static var made: (SpriteLook, DogSpriteCache)?
    private static func sprite() -> DogSpriteCache {
        let look = SpriteLook(AppSettings.shared)
        if let m = made, m.0 == look { return m.1 }
        let c = DogSpriteCache(look, pixelSize: 3)
        made = (look, c)
        return c
    }

    @ViewBuilder private var controls: some View {
        let polite = !AssistantModel.persona().style.banmal
        let n = center.todayCount
        switch center.stage {
        case .breathing:
            HStack {
                Text(verbatim: L("눈을 감고 원을 따라 숨 쉬어요")).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Button(L("그만")) { center.close() }.controlSize(.small)
            }
        case .done(let line):
            VStack(spacing: 6) {
                Text(verbatim: line).font(.system(size: 13, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: L("오늘 숨 고르기 \(n)번")).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        default:
            let offered = center.stage == .ready(offered: true)
            VStack(alignment: .leading, spacing: 9) {
                Text(verbatim: offered ? (polite ? L("집중 끝! 30초 숨 고르기 할래요?") : L("집중 끝! 30초 숨 고르기 할래?")) : L("30초 숨 고르기"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    ForEach(BreathScene.allCases, id: \.self) { s in
                        Button { center.scene = s } label: {
                            Text(verbatim: s.label).font(.system(size: 11, weight: center.scene == s ? .bold : .regular, design: .rounded))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(center.scene == s ? 0.25 : 0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(center.scene == s ? .isSelected : [])
                    }
                }
                HStack {
                    Toggle(L("싱잉볼 소리"), isOn: $center.sound).toggleStyle(.checkbox).controlSize(.small)
                    Spacer()
                    if n > 0 { Text(verbatim: L("오늘 \(n)번")).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary) }
                }
                HStack {
                    Spacer()
                    Button(offered ? L("괜찮아요") : L("닫기")) { center.close() }.controlSize(.small)
                    Button(offered ? L("할래요") : L("시작")) { center.start() }.controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// QA_ONLY=breath: each scene mid-breath, the offer after a focus run, and the praise, in light and dark.
    @MainActor
    static func render(to dir: URL) throws {
        let c = BreathCenter(defaults: AppDefaults.store)
        let now = Date()
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (i, s) in BreathScene.allCases.enumerated() {
                c.scene = s
                c.seed(.breathing(since: now - [2, 6, 13][i]), count: 1)
                try DashboardSnapshot.snapshot(BreathView(center: c, at: now), appearance: appearance,
                                               to: dir.appendingPathComponent("breath-\(s.rawValue)-\(suffix).png"))
            }
            c.scene = .dusk
            c.seed(.ready(offered: true), count: 2)
            try DashboardSnapshot.snapshot(BreathView(center: c, at: now), appearance: appearance, to: dir.appendingPathComponent("breath-offer-\(suffix).png"))
            c.seed(.done(BreathTally.praise(3, polite: true)), count: 3)
            try DashboardSnapshot.snapshot(BreathView(center: c, at: now), appearance: appearance, to: dir.appendingPathComponent("breath-done-\(suffix).png"))
        }
    }
}

/// Rounded on top only (macOS 13 has no UnevenRoundedRectangle).
private struct UnevenRect: Shape {
    var top: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + top), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The three scenes in plain shapes, a pure function of the clock `t` (0 holds them still).
enum BreathArt {
    static func draw(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat, scene: BreathScene, t: Double) {
        let c = WeatherArt.color, all = CGRect(x: 0, y: 0, width: w, height: h)
        func fill(_ r: CGRect, _ hex: String, _ o: Double = 1) { ctx.fill(Path(r), with: .color(c(hex, o))) }
        func sky(_ top: String, _ bottom: String, to y: CGFloat) {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: y)),
                     with: .linearGradient(Gradient(colors: [c(top, 1), c(bottom, 1)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: y)))
        }
        switch scene {
        case .dusk:
            let horizon = h * 0.7
            ctx.fill(Path(all), with: .linearGradient(Gradient(colors: [c("#3B2A5C", 1), c("#C9587E", 1), c("#FFB36B", 1)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
            let sun = CGPoint(x: w * 0.8, y: horizon - 78)   // low over the towers, clear of the breathing circle
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 46, y: sun.y - 46, width: 92, height: 92)), with: .color(c("#FFD58A", 0.25)))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 22, y: sun.y - 22, width: 44, height: 44)), with: .color(c("#FFE3A3", 1)))
            for i in 0..<3 {   // long thin clouds drifting right
                let y = h * (0.14 + 0.1 * Double(i)), len = 70 + 30 * CGFloat(i)
                let x = CGFloat((t * (3 + Double(i)) + 90 * Double(i)).truncatingRemainder(dividingBy: Double(w + len))) - len
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: len, height: 6), cornerRadius: 3), with: .color(c("#FFC7B0", 0.55)))
            }
            var x: CGFloat = 0, i = 0
            while x < w {   // the city on the way home, a few windows still lit
                let bw = 18 + CGFloat(WeatherArt.rnd(i, 1.3) * 22), bh = 18 + CGFloat(WeatherArt.rnd(i, 2.7) * 46)
                fill(CGRect(x: x, y: horizon - bh, width: bw, height: bh + 1), "#2B1E3F")
                for wy in stride(from: horizon - bh + 5, to: horizon - 6, by: 8) {
                    for wx in stride(from: x + 4, to: x + bw - 4, by: 7) where WeatherArt.rnd(Int(wx * 7 + wy), 3.1) < 0.28 {
                        fill(CGRect(x: wx, y: wy, width: 3, height: 3), "#FFCF7A", 0.9)
                    }
                }
                x += bw + 2; i += 1
            }
            fill(CGRect(x: 0, y: horizon, width: w, height: h - horizon), "#33244A")
            fill(CGRect(x: 0, y: h * 0.8, width: w, height: 2), "#FFB36B", 0.35)   // the road's edge in the last light
        case .lateOffice:
            fill(all, "#18203A")
            let win = CGRect(x: w * 0.5, y: h * 0.1, width: w * 0.42, height: h * 0.42)
            fill(win.insetBy(dx: -4, dy: -4), "#2C3550")
            ctx.drawLayer { l in
                l.clip(to: Path(win))
                l.fill(Path(CGRect(x: win.minX, y: win.minY, width: win.width, height: win.height)), with: .linearGradient(
                    Gradient(colors: [c("#0B1030", 1), c("#22305E", 1)]), startPoint: CGPoint(x: 0, y: win.minY), endPoint: CGPoint(x: 0, y: win.maxY)))
                l.fill(Path(ellipseIn: CGRect(x: win.maxX - 34, y: win.minY + 10, width: 18, height: 18)), with: .color(c("#F3E9C6", 1)))
                for s in 0..<14 {
                    let a = 0.4 + 0.6 * (0.5 + 0.5 * sin(t * 1.5 + Double(s) * 1.7))
                    let p = CGPoint(x: win.minX + CGFloat(WeatherArt.rnd(s, 4.2)) * win.width, y: win.minY + CGFloat(WeatherArt.rnd(s, 5.9)) * win.height * 0.6)
                    l.fill(Path(CGRect(x: p.x, y: p.y, width: 1.5, height: 1.5)), with: .color(.white.opacity(a)))
                }
                for b in 0..<6 {   // the towers across the road, one window each still on
                    let bx = win.minX + CGFloat(b) * win.width / 6, bh = win.height * (0.25 + 0.3 * CGFloat(WeatherArt.rnd(b, 6.6)))
                    l.fill(Path(CGRect(x: bx, y: win.maxY - bh, width: win.width / 6 - 2, height: bh)), with: .color(c("#0E1328", 1)))
                    l.fill(Path(CGRect(x: bx + 5, y: win.maxY - bh + 6, width: 3, height: 3)), with: .color(c("#FFD27A", 0.8)))
                }
            }
            fill(CGRect(x: win.midX - 1, y: win.minY, width: 2, height: win.height), "#2C3550")
            // The wall clock at two.
            let clock = CGPoint(x: w * 0.24, y: h * 0.2)
            ctx.fill(Path(ellipseIn: CGRect(x: clock.x - 15, y: clock.y - 15, width: 30, height: 30)), with: .color(c("#E9E4D8", 0.9)))
            var hands = Path()
            hands.move(to: clock); hands.addLine(to: CGPoint(x: clock.x + 7, y: clock.y - 4))
            hands.move(to: clock); hands.addLine(to: CGPoint(x: clock.x, y: clock.y - 11))
            ctx.stroke(hands, with: .color(c("#2A2F45", 1)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            // The desk, the monitor's glow and a mug still steaming.
            fill(CGRect(x: 0, y: h * 0.74, width: w, height: h * 0.26), "#0F1422")
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.02, y: h * 0.3, width: w * 0.4, height: h * 0.4)), with: .radialGradient(
                Gradient(colors: [c("#6FA8FF", 0.35), c("#6FA8FF", 0)]), center: CGPoint(x: w * 0.22, y: h * 0.5), startRadius: 0, endRadius: w * 0.2))
            fill(CGRect(x: w * 0.03, y: h * 0.6, width: w * 0.4, height: 6), "#2E344C")
            fill(CGRect(x: w * 0.09, y: h * 0.4, width: w * 0.24, height: h * 0.17), "#2A2F45")
            fill(CGRect(x: w * 0.1, y: h * 0.41, width: w * 0.22, height: h * 0.15), "#7DB2FF", 0.85)
            fill(CGRect(x: w * 0.2, y: h * 0.57, width: 4, height: h * 0.03), "#2A2F45")
            fill(CGRect(x: w * 0.36, y: h * 0.54, width: 12, height: h * 0.06), "#E9E4D8")
            for s in 0..<2 {
                var steam = Path()
                let x0 = w * 0.36 + 3 + CGFloat(s) * 6
                steam.move(to: CGPoint(x: x0, y: h * 0.53))
                for k in 1...4 { steam.addLine(to: CGPoint(x: x0 + CGFloat(sin(t * 2 + Double(k + s * 2))) * 2.5, y: h * 0.53 - CGFloat(k) * 5)) }
                ctx.stroke(steam, with: .color(.white.opacity(0.4)), lineWidth: 1.2)
            }
        case .rainForest:
            let ground = h * 0.78
            sky("#9DB3AC", "#5E7B74", to: ground)
            for (row, hex) in ["#6E8C84", "#4F6E64", "#36564A"].enumerated() {   // three rows of firs, nearer is darker
                let count = 7 - row, base = ground - CGFloat(2 - row) * 12
                for i in 0..<count {
                    let x = (CGFloat(i) + CGFloat(WeatherArt.rnd(i, Double(row) + 7.1))) * w / CGFloat(count - 1) - 20
                    let th = 60 + CGFloat(row) * 22 + CGFloat(WeatherArt.rnd(i, Double(row) + 8.3)) * 30, tw = th * 0.45
                    var tree = Path()
                    tree.move(to: CGPoint(x: x, y: base - th))
                    tree.addLine(to: CGPoint(x: x + tw / 2, y: base))
                    tree.addLine(to: CGPoint(x: x - tw / 2, y: base))
                    tree.closeSubpath()
                    ctx.fill(tree, with: .color(c(hex, 1)))
                }
            }
            fill(CGRect(x: 0, y: ground, width: w, height: h - ground), "#2F473E")
            let puddle = CGRect(x: w * 0.62, y: h * 0.86, width: 70, height: 14)
            ctx.fill(Path(ellipseIn: puddle), with: .color(c("#8FA8A2", 0.5)))
            for k in 0..<2 {   // rings opening on the puddle
                let a = (t / 1.6 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let rw = puddle.width * 0.2 + puddle.width * 0.6 * CGFloat(a)
                ctx.stroke(Path(ellipseIn: CGRect(x: puddle.midX - rw / 2, y: puddle.midY - rw / 10, width: rw, height: rw / 5)),
                           with: .color(.white.opacity(0.5 * (1 - a))), lineWidth: 1)
            }
            var rain = Path()
            for i in 0..<46 {
                let x = CGFloat(WeatherArt.rnd(i, 9.4)) * (w + 20)
                let y = CGFloat((t * 240 + Double(i) * 57).truncatingRemainder(dividingBy: Double(h + 20))) - 20
                rain.move(to: CGPoint(x: x, y: y)); rain.addLine(to: CGPoint(x: x - 3, y: y + 11))
            }
            ctx.stroke(rain, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
    }
}
