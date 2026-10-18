import AppKit
import Combine
import Foundation

/// The live 펫 키우기: PetState fed by PetSignals, saved as JSON in AppDefaults, talking through SpeechBubbleCenter.
/// Created on first use (the menu bar asks it every tick), so it is listening from launch. Main thread only.
final class PetModel: ObservableObject {
    static let shared = PetModel()
    static let key = "petState"
    /// A save that would not load, kept once so it can be looked at (never read back by the app).
    static let corruptKey = "petState.corrupt"
    /// Gauge drift alone (the 10 s samples) is written at most this often; everything else at once.
    static let saveEvery: TimeInterval = 60

    @Published var state: PetState { didSet { stateChanged(from: oldValue) } }
    /// Short reaction the room plays after a button (eat, heart, bubbles).
    @Published private(set) var reaction: Reaction?

    enum Reaction: Equatable { case eat, love, wash }

    private let defaults: UserDefaults
    private var bag = Set<AnyCancellable>()
    private var focusTimer: Timer?
    private var pendingSave: DispatchWorkItem?

    init(defaults: UserDefaults = AppDefaults.store, signals: PetSignals = .shared) {
        self.defaults = defaults
        state = Self.load(defaults) ?? PetState(now: Date())
        signals.events
            .sink { [weak self] signal in self?.receive(signal) }
            .store(in: &bag)
        // The last minute of gauge drift is written before quitting or sleeping.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification))
            .sink { [weak self] _ in self?.flush() }
            .store(in: &bag)
        scheduleFocus()
    }

    /// The saved pet, or nil for none. A save that does not decode is set aside under `corruptKey` first, so the
    /// fresh pet that replaces it never overwrites the only copy.
    static func load(_ defaults: UserDefaults) -> PetState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let state = try? JSONDecoder().decode(PetState.self, from: data) { return state }
        if defaults.data(forKey: corruptKey) == nil { defaults.set(data, forKey: corruptKey) }
        return nil
    }

    /// Writes now when anything but the gauges' drift changed (coins, room, missions, focus, 가출, a new day...),
    /// otherwise within `saveEvery`. The gauges are recomputed from `updated` at the next launch anyway.
    private func stateChanged(from old: PetState) {
        if Self.durable(old) != Self.durable(state) { flush(); return }
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveEvery, execute: work)
    }

    /// The state without what every sample changes.
    static func durable(_ s: PetState) -> PetState {
        var d = s
        d.food = 0; d.mood = 0; d.energy = 0; d.clean = 0
        d.updated = .distantPast; d.activeSince = nil; d.resting = false
        return d
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: Changes

    private func receive(_ signal: PetSignal) {
        var s = state
        let events = s.apply(signal, now: Date())
        state = s
        speak(events)
    }

    /// The page opened: from now on the pet may talk and show in the menu bar.
    func adopt(now: Date = Date()) {
        var s = state
        var events: [PetEvent] = []
        s.advance(to: now, events: &events)
        if !s.adopted { s.adopted = true; s.lastCare = now }
        s.attend(now, events: &events)
        state = s
        speak(events)
    }

    func care(_ c: PetState.Care) {
        var s = state
        let events = s.care(c, now: Date())
        state = s
        speak(events)
        react(c == .feed ? .eat : c == .pet ? .love : .wash)
    }

    func startFocus() {
        state.startFocus(now: Date())
        scheduleFocus()
    }

    func stopFocus() {
        state.stopFocus()
        scheduleFocus()
    }

    func setEyeRest(_ on: Bool) {
        state.eyeRest = on
        if on { state.activeSince = Date() }
    }

    @discardableResult func buy(_ id: String) -> Bool { state.buy(id) }
    @discardableResult func place(_ id: String?, slot: Int) -> Bool { state.place(id, slot: slot) }
    @discardableResult func cover(_ id: String) -> Bool { state.cover(id) }

    private func react(_ r: Reaction) {
        reaction = r
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.reaction == r { self?.reaction = nil }
        }
    }

    /// Fires when the focus timer runs out, so the end is on time even with the 10 s samples.
    private func scheduleFocus() {
        focusTimer?.invalidate()
        guard let end = state.focus?.endsAt else { return }
        let t = Timer(fire: end.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            var s = self.state
            var events: [PetEvent] = []
            s.advance(to: Date(), events: &events)
            self.state = s
            self.speak(events)
            self.scheduleFocus()   // the rest that follows work
        }
        RunLoop.main.add(t, forMode: .common)
        focusTimer = t
    }

    // MARK: Speech

    /// What the pet says about an event, nil when it stays quiet: one of `lines`, never the same twice in a row, or
    /// the user's own line (대사 고치기).
    static func line(_ e: PetEvent) -> String? {
        let all = lines(e)
        guard !all.isEmpty else { return nil }
        var values: [String: String] = [:]
        if case .focusDone(let coins) = e { values["코인"] = "\(coins)" }
        return LineOverrides.line(lineKey(e), values) ?? LinePick.pick(lineKey(e), all)
    }

    /// "pet.<case>": the LinePick and 대사 고치기 key.
    static func lineKey(_ e: PetEvent) -> String { "pet." + String("\(e)".prefix { $0 != "(" }) }

    /// Every line for an event, empty when it stays quiet.
    static func lines(_ e: PetEvent) -> [String] {
        switch e {
        case .hungry: return [L("배고파요. 밥 주세요!"), L("배에서 꼬르륵 소리가 나요."), L("밥 먹을 시간 지난 것 같아요. 밥 주세요!")]
        case .wentAway: return [L("배가 너무 고파서 산책 나갔어요. 편지를 남겼어요.")]
        case .cameHome: return [L("다녀왔어요! 밥 고마워요."), L("역시 집이 최고예요. 밥 고마워요!"), L("돌아왔어요! 배부르니까 기분 좋아요.")]
        case .attended(let coins, let streak): return [L("출석 \(streak)일째! 코인 \(coins)개 받았어요.")]
        case .levelUp(let n): return [L("레벨 \(n)까지 컸어요!")]
        case .evolved(let stage): return [L("\(stage.title)을 얻었어요!")]
        case let .missionDone(kind, coins): return [L("미션 완료: \(kind.title). 코인 \(coins)개 받았어요.")]
        case .focusDone(let coins):
            return [L("25분 집중 끝! 코인 \(coins)개 받았어요. 5분 쉬어요."), L("집중 한 번 해냈어요! 코인 \(coins)개 받았어요. 5분만 쉬어요."),
                    L("25분 잘 버텼어요. 코인 \(coins)개! 이제 5분 쉬어요.")]
        case .restDone: return [L("쉬는 시간 끝. 다시 집중해 볼까요?"), L("5분 다 쉬었어요. 다시 해 볼까요?"), L("충전 완료! 다음 25분 시작해 볼까요?")]
        case .eyeRest:
            return [L("20분 지났어요. 20초 동안 6미터 먼 곳을 바라봐요."), L("눈 쉴 시간이에요. 20초만 창밖을 봐요."),
                    L("화면에서 잠깐 눈을 떼요. 6미터 먼 곳을 20초 동안 봐요."), L("20분 동안 화면만 봤어요. 먼 곳을 20초 바라봐요.")]
        }
    }

    /// The day's last mission just done: every one of them is (the done set makes this once a day).
    static func allDone(_ events: [PetEvent], today: PetDay) -> Bool {
        events.contains { if case .missionDone = $0 { return true } else { return false } } && today.done.count == today.missions.count
    }

    static let allDoneLines = [L("오늘 미션 전부 끝! 축하 춤 출게요."), L("미션을 다 해냈어요! 오늘 정말 최고예요."), L("오늘 미션 완주! 내일도 같이 해요.")]

    private func speak(_ events: [PetEvent]) {
        guard state.adopted else { return }
        // One bubble at a time: the most important line wins (evolution over level up over the rest).
        let lines = events.compactMap { e in Self.line(e).map { (e, $0) } }
        let evolved = events.contains { if case .evolved = $0 { return true } else { return false } }
        // Every mission of the day done: a line of its own and the special moment (evolution still comes first).
        if !evolved, Self.allDone(events, today: state.today) {
            SituationEngine.play([.special])
            SpeechBubbleCenter.shared.say(text: AssistantModel.persona().dress(LinePick.pick("pet.allDone", Self.allDoneLines)), source: .pet)
            return
        }
        let pick = evolved ? lines.last : lines.first
        if let (e, text) = pick {   // the user's own line is said as written
            SpeechBubbleCenter.shared.say(text: LineOverrides.edited(Self.lineKey(e)) ? text : AssistantModel.persona().dress(text), source: .pet)
        }
    }

    // MARK: Menu bar

    /// The menu bar plays the hungry moment for 8 s of every 45 while the pet is hungry (or out), if the character has it.
    func menuBarMotion(now: Date = Date(), available: Set<ExtraMotion>) -> ExtraMotion? {
        guard state.adopted, available.contains(.hungry), state.food < 25 || state.isAway else { return nil }
        return Int(now.timeIntervalSince1970) % 45 < 8 ? .hungry : nil
    }

    /// A few words for the menu bar tooltip when the pet needs something.
    var menuBarNote: String? {
        let s = state
        guard s.adopted else { return nil }
        if let f = s.focus, let note = Self.focusNote(f, now: Date()) { return note }
        if s.isAway { return L("펫이 산책 나갔어요") }
        if s.food < 25 { return L("펫이 배고파요") }
        if s.energy < 15 { return L("펫이 졸려요") }
        if s.clean < 15 { return L("펫을 씻겨 주세요") }
        return nil
    }

    /// "집중 중 · 12분 남음" while a round runs (minutes rounded up), nil once it is over.
    static func focusNote(_ f: PetFocus, now: Date) -> String? {
        let left = f.endsAt.timeIntervalSince(now)
        guard left > 0 else { return nil }
        let min = Int((left / 60).rounded(.up))
        return f.mode == .work ? L("집중 중 · \(min)분 남음") : L("쉬는 중 · \(min)분")
    }
}
