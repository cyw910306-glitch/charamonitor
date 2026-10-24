#if !MAS   // browser tabs are read and closed with osascript, which the App Store build leaves out
import AppKit
import Combine

/// 딴짓 지킴이 (off by default): a look at the app in front every 10 s (and, with 브라우저 탭 보기, the front tab's address
/// and title through AppleScript), a label per 3-minute block by DriftRules, and a card when drift is confirmed. The
/// cat (off by default) plays on the desktop or waits out of sight, and joins only a confirmed nudge; with 발로 닫기
/// (off by default) its paw closes the tab or app unless it is caught first. Everything stays on this Mac: no screen
/// recording, no screenshot, no network; the on-device AI (off by default) is asked only about looks the rules do not know.
final class DriftCenter: ObservableObject {
    static let shared = DriftCenter()
    /// --drift-dry-run and QA: the paw logs what it would close instead of closing it.
    static var dryRun = false

    @Published var on: Bool { didSet { defaults.set(on, forKey: "drift.on"); refresh() } }
    /// 집중 타이머 중엔 자동으로: watches during a 집중 run even with the switch off.
    @Published var withTimer: Bool { didSet { defaults.set(withTimer, forKey: "drift.withTimer"); refresh() } }
    @Published var hoursOn: Bool { didSet { defaults.set(hoursOn, forKey: "drift.hoursOn") } }
    @Published var hours: DriftHours { didSet { Self.put(hours, "drift.hours", defaults) } }
    /// 브라우저 탭 보기 (asks macOS's 자동화 permission per browser on first use).
    @Published private(set) var tabs: Bool { didSet { defaults.set(tabs, forKey: "drift.tabs") } }
    /// A browser said no to 자동화: that browser is seen as an app only.
    @Published private(set) var deniedBrowsers: [String] { didSet { defaults.set(deniedBrowsers, forKey: "drift.denied") } }
    @Published var needed: Int { didSet { defaults.set(needed, forKey: "drift.needed"); watch.needed = needed } }
    /// 업무 프로필: one line on what the owner does (a hint for the rules and the on-device AI).
    @Published var profile: String { didSet { defaults.set(String(profile.prefix(120)), forKey: "drift.profile") } }
    @Published private(set) var lists: DriftLists { didSet { Self.put(lists, "drift.lists", defaults) } }
    @Published var useAI: Bool { didSet { defaults.set(useAI, forKey: "drift.ai") } }
    @Published var cat: Bool { didSet { defaults.set(cat, forKey: "drift.cat"); if !cat { cancelPaw() }; DriftCat.shared.update() } }
    @Published var coat: DriftCoat { didSet { defaults.set(coat.rawValue, forKey: "drift.coat"); DriftCat.shared.update() } }
    @Published var catSize: DriftCatSize { didSet { defaults.set(catSize.rawValue, forKey: "drift.catSize"); DriftCat.shared.update() } }
    /// 평소엔 놀기 (true) or 숨어 있기 (false).
    @Published var catPlays: Bool { didSet { defaults.set(catPlays, forKey: "drift.catPlays"); DriftCat.shared.update() } }
    /// 발로 닫기 (confirmed once when turned on).
    @Published private(set) var paw: Bool { didSet { defaults.set(paw, forKey: "drift.paw") } }
    /// 잡을 시간: seconds the paw stays up.
    @Published var pawSeconds: Double { didSet { defaults.set(pawSeconds, forKey: "drift.pawSeconds") } }
    /// The owner's own 보호 목록 on top of the cleaner's.
    @Published private(set) var protectedApps: [String] { didSet { defaults.set(protectedApps, forKey: "drift.protected") } }

    @Published private(set) var log = DriftLog()
    @Published private(set) var watching = false
    @Published private(set) var lastFocus: DriftTarget?
    /// The card on screen, nil when none.
    @Published private(set) var card: DriftCardKind?
    /// The cat is on its way with 발로 닫기: the nudge card says a click on the cat keeps things open.
    @Published private(set) var pawUp = false

    private let defaults: UserDefaults
    private var timer: Timer?
    private var blocker = DriftBlocker()
    private var watch = DriftWatch()
    /// A confirmed nudge held back by a call, a share or 쉿 모드; shown once it is quiet, dropped when the drift ends.
    private var pending: DriftSample?
    /// What the nudge is about (the paw's target, what 딴짓 아님 saves).
    private var about: DriftSample?
    private var lastLabel: DriftLabel?
    private var hideCard: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    /// The on-device AI's word per site or app, this run only.
    private var aiWords: [String: DriftLabel] = [:]
    private var asking = Set<String>()
    private var reading = false

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        on = defaults.bool(forKey: "drift.on")
        withTimer = defaults.bool(forKey: "drift.withTimer")
        hoursOn = defaults.object(forKey: "drift.hoursOn") as? Bool ?? true
        hours = Self.get("drift.hours", defaults) ?? DriftHours()
        tabs = defaults.bool(forKey: "drift.tabs")
        deniedBrowsers = defaults.stringArray(forKey: "drift.denied") ?? []
        needed = min(4, max(1, defaults.object(forKey: "drift.needed") as? Int ?? 2))
        profile = defaults.string(forKey: "drift.profile") ?? ""
        lists = Self.get("drift.lists", defaults) ?? DriftLists()
        useAI = defaults.bool(forKey: "drift.ai")
        cat = defaults.bool(forKey: "drift.cat")
        coat = defaults.string(forKey: "drift.coat").flatMap(DriftCoat.init) ?? .mackerel
        catSize = defaults.string(forKey: "drift.catSize").flatMap(DriftCatSize.init) ?? .normal
        catPlays = defaults.object(forKey: "drift.catPlays") as? Bool ?? true
        paw = defaults.bool(forKey: "drift.paw")
        pawSeconds = min(6, max(2, defaults.object(forKey: "drift.pawSeconds") as? Double ?? 3))
        protectedApps = defaults.stringArray(forKey: "drift.protected") ?? []
        watch.needed = needed
    }

    func start() {
        guard bag.isEmpty else { return }
        log = DriftFile.read()
        let before = log.blocks.count
        log.prune(now: Date())
        if log.blocks.count != before { DriftFile.write(log) }
        lists.prune(now: Date())
        deniedBrowsers = []   // allowed in 자동화 since: asked again once per launch (a denied one answers -1743 at once)
        FocusCenter.shared.$session.map { $0 != nil }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        refresh()
        DriftCat.shared.update()
    }

    var tabsAllowed: Bool { tabs }

    // MARK: Switches with a question first

    /// 브라우저 탭 보기: says what is read and that macOS will ask, then reads the front tab once so the question comes now.
    func setTabs(_ want: Bool) {
        guard want else { tabs = false; return }
        let a = NSAlert()
        a.messageText = L("브라우저 탭도 볼까요?")
        a.informativeText = L("Safari, Chrome, Edge, Brave, Arc, 웨일, Vivaldi의 맨 앞 탭 주소와 제목을 10초마다 읽어 딴짓인지 판단해요. 맥 밖으로 보내지 않고, 기록에는 사이트 이름만 남겨요. macOS가 브라우저 제어를 물어보면 허용을 눌러 주세요. 허용하지 않은 브라우저는 앱 이름으로만 판단해요.")
        a.addButton(withTitle: L("계속"))
        a.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        tabs = true
        deniedBrowsers = []
        if let front = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier.flatMap(DriftRules.browser) != nil && !$0.isTerminated }),
           let b = front.bundleIdentifier.flatMap(DriftRules.browser) {
            readTab(b) { _ in }
        }
    }

    /// 발로 닫기: once, what the paw does and what it never touches.
    func setPaw(_ want: Bool) {
        guard want else { paw = false; cancelPaw(); return }
        let a = NSAlert()
        a.messageText = L("고양이가 딴짓 창을 닫게 할까요?")
        a.informativeText = L("딴짓이 확정되면 고양이가 달려와 앞발을 들어요. 몇 초 안에 고양이를 누르면 그대로 두고, 못 잡으면 브라우저는 그 탭만, 앱은 정상 종료로 닫아요(저장 안 한 문서는 앱이 물어봐요). 강제 종료는 하지 않고, 보호 목록 앱, 통화·화면 공유 중, 재생·녹화 중인 앱은 건드리지 않아요.")
        a.addButton(withTitle: L("켜기"))
        a.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { paw = true }
    }

    // MARK: Lists

    func add(_ item: String, to label: DriftLabel) { lists.add(item, to: label) }
    func remove(_ item: String) { lists.remove(item) }

    func protect(_ id: String) {
        let k = id.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty, !protectedApps.contains(k) { protectedApps.append(k) }
    }

    func unprotect(_ id: String) { protectedApps.removeAll { $0 == id } }

    /// Everything the paw never closes: the cleaner's 보호 목록 (its 19 and the owner's changes) and this card's own.
    var protectedSet: Set<String> { CleanerRules.defaultProtected.union(CleanerProtection.load()).union(protectedApps) }

    func clearLog() {
        log = DriftLog()
        lists.corrections = []
        DriftFile.write(log)
    }

    // MARK: Looking

    /// Something to watch: the switch, or 타이머 중 자동 with a 집중 run on (no timer at all otherwise).
    var wanted: Bool { on || (withTimer && FocusCenter.shared.session != nil) }

    private func refresh() {
        if wanted, timer == nil {
            let t = Timer(timeInterval: DriftRules.sampleEvery, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !wanted {
            timer?.invalidate(); timer = nil
            finishBlock()
            watching = false
            cancelPaw()
        }
        DriftCat.shared.update()
    }

    private var isActive: Bool {
        DriftRules.active(on: on, withTimer: withTimer, timerRunning: FocusCenter.shared.running, hoursOn: hoursOn, hours: hours, now: Date())
    }

    private func tick() {
        let active = isActive
        if active != watching { watching = active }
        guard active else { finishBlock(); pending = nil; return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
        guard idle < DriftRules.idleSkip, !reading,
              let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier
        else { return }
        let base = DriftSample(at: Date(), app: id, appName: app.localizedName ?? id)
        if tabs, let b = DriftRules.browser(id), !deniedBrowsers.contains(id) {
            reading = true
            readTab(b) { [weak self] tab in
                self?.reading = false
                var s = base
                if let tab { s.url = tab.url; s.title = tab.title }
                self?.take(s)
            }
        } else {
            take(base)
        }
    }

    /// One look: labelled, counted into its block, and the held nudge checked.
    private func take(_ s: DriftSample) {
        let label = classify(s)
        lastLabel = label
        if label == .focus { lastFocus = DriftTarget(app: s.app, appName: s.appName, url: s.url) }
        if let p = pending {
            if label != .drift { pending = nil } else if !FriendVisit.quiet() { pending = nil; intervene(p) }
        }
        // Back after sleep or a long idle: the block left open then does not count toward a streak.
        if blocker.stale(at: s.at) { finishBlock() }
        if let closed = blocker.add(s, label) { record(closed) }
    }

    func classify(_ s: DriftSample) -> DriftLabel {
        if let r = DriftRules.rule(s, lists: lists, profile: profile) { return r }
        if let w = aiWords[s.key] { return w }
        if useAI { ask(s) }
        return .neutral
    }

    /// The on-device model, once per site or app this run, never for anything the rules know.
    private func ask(_ s: DriftSample) {
        guard OnDeviceEngine.isAvailable, !asking.contains(s.key), asking.count < 40 else { return }
        asking.insert(s.key)
        let prompt = DriftRules.aiPrompt(s, profile: profile), key = s.key
        Task { @MainActor in
            if let word = try? await OnDeviceEngine.shared.word(prompt), let label = DriftRules.parseAI(word) { self.aiWords[key] = label }
        }
    }

    private func finishBlock() {
        if let closed = blocker.close() { record(closed, active: false) }
    }

    private func record(_ b: DriftBlocker.Closed, active: Bool = true) {
        log.add(DriftLog.Block(start: b.start, label: b.label, top: b.top), now: Date())
        DriftFile.write(log)
        if watch.feed(b.label, at: Date(), active: active) { intervene(b.sample) }
    }

    // MARK: The nudge

    /// Drift is confirmed: the card (held while quiet), and the cat when it is out with 발로 닫기.
    func intervene(_ s: DriftSample) {
        guard card == nil else { return }
        guard !FriendVisit.quiet() else { pending = s; return }
        about = s
        let pounce = cat && paw && closable(s)
        pawUp = pounce
        show(.nudge(back: lastFocus?.shown))
        if pounce { DriftCat.shared.pounce(on: s, seconds: pawSeconds) }
    }

    func closable(_ s: DriftSample) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // The mic in use, a screen recorder, or a meeting app running anywhere (not only in front).
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let inCall = MeetingMute.screenMaybeShared() || !running.isDisjoint(with: DriftRules.meetingApps)
        if DriftRules.browser(s.app) != nil {
            return s.url != nil && DriftRules.tabClosable(s.app, frontmost: front, protected: protectedSet, inCall: inCall)
        }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: s.app).map(\.processIdentifier))
        return DriftRules.appClosable(s.app, frontmost: front, own: Bundle.main.bundleIdentifier, protected: protectedSet,
                                      inUse: !Cleaner.awakePids().isDisjoint(with: pids), inCall: inCall)
    }

    /// 돌아가기.
    func goBack() {
        DriftCat.shared.leave()
        watch.reset()
        closeCard()
        returnToFocus()
    }

    /// 쉬는 중.
    func snooze(_ minutes: Int) {
        DriftCat.shared.leave()
        watch.snooze(minutes, now: Date())
        closeCard()
    }

    /// 딴짓 아님: this site or app goes on the 집중 list.
    func notDrift() {
        DriftCat.shared.leave()
        if let s = about { lists.correct(s.key, to: .focus, at: Date()) }
        watch.reset()
        closeCard()
    }

    /// The cat was caught: the tab or app stays, and the next card asks.
    func caught() {
        pawUp = false
        show(.still)
    }

    /// "아직 딴짓 중이에요?" 네: watching goes on, and the next drift block nudges again.
    func stillDrifting() {
        watch.recheckSoon()
        closeCard()
    }

    /// The paw came down: the tab or app goes (re-checked first), then back to the last 집중.
    func slam() {
        guard let s = about else { return }
        let name = s.shown
        let finish = { [weak self] (closed: Bool) in
            guard let self else { return }
            if closed { self.returnToFocus() }
            self.show(closed ? .closed(what: name, back: self.lastFocus?.shown) : .still)
        }
        // Turned off while the paw was up: nothing is closed.
        guard wanted, cat, paw, closable(s) else { finish(false); return }
        if Self.dryRun {
            DriftLogLine.write("dry-run: " + (s.url.map { "탭 닫기 \(s.app) \($0)" } ?? "앱 종료 \(s.app)"))
            finish(true)
            return
        }
        if let b = DriftRules.browser(s.app), let url = s.url {
            DriftOsa.run(DriftScript.closeTab(b, url: url)) { out in finish(out.out == "closed") }
        } else {
            finish(Self.terminate(s.app))
        }
    }

    /// The app's own quit (NSRunningApplication.terminate, never forceTerminate): unsaved work is the app's to ask about.
    static func terminate(_ bundleID: String) -> Bool {
        // The instance in front (the one closable checked), never another copy of the same app.
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID, !app.isTerminated else { return false }
        return app.terminate()
    }

    private func returnToFocus() {
        guard let t = lastFocus else { return }
        if let url = t.url, let b = DriftRules.browser(t.app) {
            DriftOsa.run(DriftScript.showTab(b, url: url)) { _ in }
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: t.app).first?.activate()
        }
    }

    private func show(_ kind: DriftCardKind) {
        card = kind
        DriftCard.shared.show()
        hideCard?.cancel()
        let w = DispatchWorkItem { [weak self] in
            if case .closed = self?.card { self?.closeCard() } else { DriftCat.shared.leave(); self?.closeCard() }
        }
        hideCard = w
        DispatchQueue.main.asyncAfter(deadline: .now() + kind.seconds, execute: w)
    }

    func closeCard() {
        hideCard?.cancel(); hideCard = nil
        card = nil
        pawUp = false
        about = nil
        DriftCard.shared.hide()
    }

    /// A switch went off: a paw already up goes away with its card.
    private func cancelPaw() {
        guard pawUp else { return }
        DriftCat.shared.leave()
        closeCard()
    }

    // MARK: Tabs

    private func readTab(_ b: DriftRules.Browser, done: @escaping ((url: String, title: String)?) -> Void) {
        DriftOsa.run(DriftScript.frontTab(b)) { [weak self] r in
            if r.denied, let self, !self.deniedBrowsers.contains(b.rawValue) { self.deniedBrowsers.append(b.rawValue) }
            done(DriftScript.parseTab(r.out))
        }
    }

    /// QA renders only: a log and a card to draw, with no timer.
    func qaShow(log: DriftLog, card: DriftCardKind?, lastFocus: DriftTarget?, on: Bool = true) {
        self.log = log
        self.card = card
        self.lastFocus = lastFocus
        self.on = on
        timer?.invalidate(); timer = nil
    }

    private static func put<T: Encodable>(_ v: T, _ key: String, _ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    private static func get<T: Decodable>(_ key: String, _ d: UserDefaults) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// The card's three kinds.
enum DriftCardKind: Equatable {
    /// "아까 X 하던 중이었죠. 돌아갈까요?"
    case nudge(back: String?)
    /// After the cat was caught (or the target changed under the paw).
    case still
    /// The paw closed `what`.
    case closed(what: String, back: String?)

    var seconds: TimeInterval {
        switch self {
        case .nudge: return 45
        case .still: return 30
        case .closed: return 7
        }
    }
}

/// 털색: six of the built-in cats' coats (CatProfile.presets). Raw values are saved; never rename one.
enum DriftCoat: String, CaseIterable {
    case mackerel = "korean-shorthair", cheese = "cheese-tabby", calico, tuxedo, gray = "russian-blue", black = "black-cat"

    var label: String {
        switch self {
        case .mackerel: return L("고등어")
        case .cheese: return L("치즈")
        case .calico: return L("삼색이")
        case .tuxedo: return L("턱시도")
        case .gray: return L("회색")
        case .black: return L("까망이")
        }
    }

    var character: (any AnimatedCharacter)? { CatCatalog.character("cat-" + rawValue) }
    var profile: CatProfile? { CatProfile.presets.first { $0.id == rawValue }?.profile }
}

/// 크기: art pixels per point.
enum DriftCatSize: String, CaseIterable {
    case small, normal, large, huge

    var label: String {
        switch self {
        case .small: return L("작게")
        case .normal: return L("보통")
        case .large: return L("크게")
        case .huge: return L("아주 크게")
        }
    }

    var pixelSize: CGFloat {
        switch self {
        case .small: return 1.5
        case .normal: return 2
        case .large: return 3
        case .huge: return 4
        }
    }
}

/// Application Support/DogMonitor/Drift.json, on this Mac only (not in 내 설정 파일).
enum DriftFile {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DogMonitor/Drift.json")
    }
    /// QA and tests: no file is read or written.
    static var off = false

    static func read() -> DriftLog {
        guard !off, let data = try? Data(contentsOf: url) else { return DriftLog() }
        return DriftLog.decode(data)
    }

    static func write(_ log: DriftLog) {
        guard !off else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? log.encode().write(to: url, options: .atomic)
    }
}

/// The dry run's log: stderr, and Application Support/DogMonitor/drift-dry-run.log.
enum DriftLogLine {
    static func write(_ line: String) {
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        let url = DriftFile.url.deletingLastPathComponent().appendingPathComponent("drift-dry-run.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }
}

/// osascript off the main thread, the answer back on it. A 자동화 question waits for the owner, so 60 s before giving up.
enum DriftOsa {
    struct Result { var out: String; var denied: Bool }

    static func run(_ script: String, done: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let r = runNow(script)
            DispatchQueue.main.async { done(r) }
        }
    }

    static func runNow(_ script: String) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return Result(out: "", denied: false) }
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return Result(out: "", denied: false) }
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(out: o.trimmingCharacters(in: .whitespacesAndNewlines), denied: e.contains("-1743"))
    }
}

/// --drift-dry-run: what the rules make of the app in front now (and its tab with --tabs), and what the paw would do.
/// Never closes anything.
enum DriftCLI {
    static func dryRun(_ args: [String]) -> Never {
        let c = DriftCenter.shared
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { print("맨 앞 앱 없음"); exit(1) }
        var s = DriftSample(at: Date(), app: id, appName: app.localizedName ?? id)
        if args.contains("--tabs"), let b = DriftRules.browser(id) {
            let r = DriftOsa.runNow(DriftScript.frontTab(b))
            if r.denied { print("자동화 권한 없음: 앱 단위로만 봐요") }
            if let tab = DriftScript.parseTab(r.out) { s.url = tab.url; s.title = tab.title }
        }
        let rule = DriftRules.rule(s, lists: c.lists, profile: c.profile)
        print("앱 \(id) · 사이트 \(s.host ?? "-") · 규칙 \(rule?.rawValue ?? "모름") · 판정 \((rule ?? .neutral).rawValue)")
        print("발로 닫기: " + (c.closable(s) ? (s.url != nil ? "그 탭만 닫을 수 있음" : "앱 정상 종료 가능") : "보호됨, 닫지 않음") + " (드라이런: 닫지 않음)")
        exit(0)
    }

    /// --drift-qa-terminate <bundle id>: the paw's real close path on a test-only app (bundle id qa.charamonitor.*),
    /// which must be in front. Anything else is refused.
    static func qaTerminate(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--drift-qa-terminate"), i + 1 < args.count, args[i + 1].hasPrefix("qa.charamonitor.") else {
            fputs("사용법: DogMonitor --drift-qa-terminate qa.charamonitor.<도우미>\n", stderr); exit(2)
        }
        let id = args[i + 1]
        let s = DriftSample(at: Date(), app: id, appName: id)
        let c = DriftCenter.shared
        print("맨 앞 \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") · 닫을 수 있음 \(c.closable(s))")
        guard c.closable(s) else { exit(1) }
        let ok = DriftCenter.terminate(id)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { !$0.isTerminated }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let gone = !NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
        print("terminate \(ok) · 종료됨 \(gone)")
        exit(gone ? 0 : 1)
    }
}
#endif
