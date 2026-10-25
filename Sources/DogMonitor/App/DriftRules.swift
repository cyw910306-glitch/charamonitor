import Foundation

// 딴짓 지킴이, the pure part: what one 10-second look at the front app (and a browser's front tab) counts as, how
// 3-minute blocks get their label, when drift is confirmed, what may be closed, the browser scripts as text, and the
// cat's catch window. No AppKit and no clock of its own, so the tests drive every rule. DriftGuard runs it.

/// One block's or one look's label.
enum DriftLabel: String, Codable, CaseIterable {
    case focus, neutral, drift

    var label: String {
        switch self {
        case .focus: return L("집중")
        case .neutral: return L("중립")
        case .drift: return L("딴짓")
        }
    }
}

/// What was in front at one look: the app, and for a supported browser with tab reading on, its front tab.
struct DriftSample: Equatable {
    var at: Date
    var app: String
    var appName: String
    var url: String?
    var title: String?

    /// "youtube.com" for "https://www.youtube.com/watch?v=1": lowercased, without "www." and "m.".
    var host: String? { url.flatMap(DriftRules.host) }

    /// What the lists match and a correction saves: the site for a tab, else the app's bundle id.
    var key: String { host ?? app }

    /// What the owner reads: the site, else the app's name.
    var shown: String { host ?? appName }
}

/// Where to go back to: the last thing counted as 집중.
struct DriftTarget: Codable, Equatable {
    var app: String
    var appName: String
    var url: String?

    var shown: String { url.flatMap(DriftRules.host) ?? appName }
}

/// The owner's own lists and corrections, saved in preferences. Each item is a site ("youtube.com", its subdomains
/// too) or an app's bundle id. A correction moves an item to the other list and is logged (the last 50).
struct DriftLists: Codable, Equatable {
    struct Correction: Codable, Equatable {
        var key: String
        var to: DriftLabel
        var at: Date
    }

    var focus: [String] = []
    var drift: [String] = []
    var corrections: [Correction] = []

    static let keepCorrections = 50

    /// "딴짓 아님" or "이건 딴짓": the item goes on one list and off the other.
    mutating func correct(_ key: String, to label: DriftLabel, at: Date) {
        let k = DriftRules.normalized(key)
        guard !k.isEmpty else { return }
        focus.removeAll { $0 == k }
        drift.removeAll { $0 == k }
        switch label {
        case .focus: focus.append(k)
        case .drift: drift.append(k)
        case .neutral: break
        }
        corrections.append(Correction(key: k, to: label, at: at))
        if corrections.count > Self.keepCorrections { corrections.removeFirst(corrections.count - Self.keepCorrections) }
    }

    /// Corrections older than the log's 7 days go (the lists themselves stay).
    mutating func prune(now: Date) {
        corrections.removeAll { now.timeIntervalSince($0.at) > TimeInterval(DriftLog.keepDays) * 86_400 }
    }

    mutating func add(_ item: String, to label: DriftLabel) {
        let k = DriftRules.normalized(item)
        guard !k.isEmpty else { return }
        focus.removeAll { $0 == k }
        drift.removeAll { $0 == k }
        if label == .focus { focus.append(k) } else if label == .drift { drift.append(k) }
    }

    mutating func remove(_ item: String) {
        focus.removeAll { $0 == item }
        drift.removeAll { $0 == item }
    }
}

/// 근무 시간: minutes after midnight, `start` to `end`. An `end` at or before `start` runs past midnight (22:00 to 02:00),
/// and the hours after midnight belong to the evening's day for 평일만.
struct DriftHours: Codable, Equatable {
    var start = 9 * 60
    var end = 18 * 60
    var weekdaysOnly = true

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let wraps = end <= start
        let inside = wraps ? (m >= start || m < end) : (m >= start && m < end)
        guard inside else { return false }
        guard weekdaysOnly else { return true }
        // After midnight on a wrapping range: the day it started on (the evening before) decides.
        var weekday = c.weekday ?? 2
        if wraps && m < end { weekday = weekday == 1 ? 7 : weekday - 1 }
        return (2...6).contains(weekday)   // 1 = Sunday, 7 = Saturday
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60) }
}

enum DriftRules {
    /// One look every 10 s, one label every 3 minutes (vars only for the real-screen QA, `--qa-drift-block`).
    static var sampleEvery: TimeInterval = 10
    static var blockSeconds: TimeInterval = 180
    /// Away from the keyboard and mouse this long: the look is skipped (nobody is drifting).
    static let idleSkip: TimeInterval = 120
    /// The same nudge no sooner than this after the last one.
    static let cooldown: TimeInterval = 15 * 60

    /// Default 딴짓 sites by kind. A kind named in 업무 프로필 (영상 편집자: video) is not drift for that owner.
    enum Kind: String, CaseIterable { case video, social, shopping, community, game, webtoon }

    static let driftSites: [Kind: [String]] = [
        .video: ["youtube.com", "youtu.be", "netflix.com", "tving.com", "wavve.com", "coupangplay.com", "disneyplus.com",
                 "twitch.tv", "chzzk.naver.com", "sooplive.co.kr", "afreecatv.com", "laftel.net", "watcha.com"],
        .social: ["instagram.com", "facebook.com", "x.com", "twitter.com", "threads.net", "tiktok.com", "pinterest.com"],
        .shopping: ["coupang.com", "11st.co.kr", "gmarket.co.kr", "auction.co.kr", "musinsa.com", "aliexpress.com",
                    "temu.com", "amazon.com", "ebay.com", "29cm.co.kr", "ohou.se", "kream.co.kr", "shopping.naver.com"],
        .community: ["reddit.com", "dcinside.com", "fmkorea.com", "theqoo.net", "ruliweb.com", "clien.net", "instiz.net",
                     "ppomppu.co.kr", "pann.nate.com", "9gag.com", "inven.co.kr"],
        .game: ["store.steampowered.com", "steamcommunity.com", "op.gg", "poki.com", "chess.com"],
        .webtoon: ["comic.naver.com", "webtoon.kakao.com", "page.kakao.com", "webtoons.com"],
    ]

    static let driftApps: [Kind: [String]] = [
        .video: ["com.apple.TV", "com.netflix.Netflix", "com.google.ios.youtube"],
        .game: ["com.valvesoftware.steam", "net.battle.app", "com.epicgames.EpicGamesLauncher",
                "com.riotgames.LeagueofLegends.LeagueClientUx", "com.riotgames.RiotGames.RiotClient", "com.apple.Chess"],
        .social: ["com.tiktok.TikTok"],
    ]

    /// Words in 업무 프로필 that make a kind work, not drift.
    static let kindWords: [Kind: [String]] = [
        .video: ["영상", "유튜브", "youtube", "편집", "크리에이터", "pd", "video", "creator", "editor"],
        .social: ["마케팅", "마케터", "sns", "소셜", "인스타", "marketing", "marketer", "social"],
        .shopping: ["md", "쇼핑", "커머스", "구매", "바이어", "셀러", "commerce", "buyer", "seller"],
        .community: ["커뮤니티", "모더레이터", "community", "moderator"],
        .game: ["게임", "game", "qa"],
        .webtoon: ["웹툰", "만화", "작가", "webtoon", "comic"],
    ]

    /// Work by default: editors, terminals, office and design apps, and the sites people work in.
    static let focusApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.cmuxterm.app", "com.microsoft.Word",
        "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.apple.iWork.Pages", "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote", "com.figma.Desktop", "notion.id", "md.obsidian", "com.jetbrains.intellij",
        "com.sublimetext.4", "com.apple.TextEdit", "com.adobe.Photoshop", "com.adobe.illustrator", "com.anthropic.claudefordesktop",
    ]
    static let focusSites: [String] = [
        "github.com", "gitlab.com", "docs.google.com", "sheets.google.com", "slides.google.com", "notion.so", "figma.com",
        "stackoverflow.com", "developer.apple.com", "claude.ai", "chatgpt.com", "linear.app", "atlassian.net", "jira.com",
        "localhost", "vercel.com", "overleaf.com", "miro.com",
    ]

    /// Browsers whose front tab can be read (AppleScript), and in which dialect.
    enum Browser: String, CaseIterable {
        case safari = "com.apple.Safari"
        case chrome = "com.google.Chrome"
        case edge = "com.microsoft.edgemac"
        case brave = "com.brave.Browser"
        case arc = "company.thebrowser.Browser"
        case whale = "com.naver.Whale"
        case vivaldi = "com.vivaldi.Vivaldi"

        /// Safari says "current tab" and "name"; the Chromium ones say "active tab" and "title".
        var safariStyle: Bool { self == .safari }
    }

    static func browser(_ bundleID: String) -> Browser? { Browser(rawValue: bundleID) }

    static func host(_ url: String) -> String? {
        guard let h = URLComponents(string: url)?.host?.lowercased(), !h.isEmpty else { return nil }
        for prefix in ["www.", "m."] where h.hasPrefix(prefix) { return String(h.dropFirst(prefix.count)) }
        return h
    }

    /// A list item as typed: "https://www.YouTube.com/x" becomes "youtube.com"; a bundle id stays as it is.
    static func normalized(_ item: String) -> String {
        let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://"), let h = host(t) { return h }
        if t.contains("/") { return normalized("https://" + t) }
        // A bundle id is reverse DNS ("com.google.Chrome") and keeps its case; a site is lowercased, without "www.".
        let bundle = ["com.", "net.", "org.", "io.", "dev.", "app.", "us.", "tv.", "company.", "md.", "notion.", "Cisco-"]
            .contains { t.hasPrefix($0) }
        guard !bundle, t.contains(".") else { return t }
        let h = t.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The site or one of its subdomains ("chzzk.naver.com" is not "naver.com" unless the list says naver.com).
    static func matches(_ host: String, _ item: String) -> Bool { host == item || host.hasSuffix("." + item) }

    /// The kinds 업무 프로필 names.
    static func workKinds(_ profile: String) -> Set<Kind> {
        let p = profile.lowercased()
        let words = Set(p.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return Set(Kind.allCases.filter { k in
            kindWords[k, default: []].contains { w in w.count <= 3 && w.allSatisfy(\.isASCII) ? words.contains(w) : p.contains(w) }
        })
    }

    /// The default kind of `sample`, nil when it is not on a default 딴짓 list.
    static func defaultKind(_ s: DriftSample) -> Kind? {
        if let h = s.host, let k = Kind.allCases.first(where: { driftSites[$0, default: []].contains { matches(h, $0) } }) { return k }
        guard s.host == nil else { return nil }   // a browser shows a site: the site decides, not the browser
        return Kind.allCases.first { driftApps[$0, default: []].contains(s.app) }
    }

    /// One look's label by the rules: the owner's 내 기준 lines, then their lists, then what the page's path and title
    /// say (a lecture or a short on the same site), then the defaults (less the kinds 업무 프로필 names).
    /// nil: the rules do not know it (neutral, unless an AI says otherwise).
    static func rule(_ s: DriftSample, lists: DriftLists, profile: String, memo: [DayMemo.Rule] = [], videoDrift: Bool = true) -> DriftLabel? {
        func listed(_ items: [String]) -> Bool {
            items.contains { item in s.host.map { matches($0, item) } == true || item == s.app && s.host == nil }
        }
        if let m = DayMemo.match(s, memo) { return m }
        if listed(lists.focus) { return .focus }
        if listed(lists.drift) { return .drift }
        if let h = s.host, let c = DayContent.rule(host: h, path: s.url.flatMap { URLComponents(string: $0)?.path } ?? "",
                                                   title: s.title, profile: profile, videoDrift: videoDrift) { return c }
        if let k = defaultKind(s) { return workKinds(profile).contains(k) ? .neutral : .drift }
        if let h = s.host { return focusSites.contains { matches(h, $0) } ? .focus : nil }
        if focusApps.contains(s.app) { return .focus }
        return browser(s.app) != nil ? .neutral : nil   // a browser with no tab read
    }

    /// The on-device model's one word, read loosely ("딴짓이에요." counts). nil: not one of the three.
    static func parseAI(_ answer: String) -> DriftLabel? {
        let a = answer.lowercased()
        let hits: [(DriftLabel, [String])] = [(.drift, ["딴짓", "drift"]), (.focus, ["집중", "focus"]), (.neutral, ["중립", "neutral"])]
        let found = hits.filter { $0.1.contains(where: a.contains) }.map(\.0)
        return found.count == 1 ? found[0] : nil
    }

    /// What the on-device model is asked: the profile and the look, nothing else (never sent off this Mac).
    static func aiPrompt(_ s: DriftSample, profile: String) -> String {
        var lines = ["업무: " + (profile.isEmpty ? "알 수 없음" : String(profile.prefix(80))), "앱: " + s.appName]
        if let h = s.host { lines.append("사이트: " + h) }
        if let t = s.title, !t.isEmpty { lines.append("제목: " + String(t.prefix(80))) }
        lines.append("이 화면이 업무에 집중, 중립, 딴짓 중 무엇인지 한 단어로만 답해.")
        return lines.joined(separator: "\n")
    }

    /// The label of a block from its looks: 딴짓 when half or more were drift, else 집중 when half or more were focus,
    /// else 중립. nil for a block with no looks (asleep, away).
    static func label(_ looks: [DriftLabel]) -> DriftLabel? {
        guard !looks.isEmpty else { return nil }
        let n = looks.count
        if looks.filter({ $0 == .drift }).count * 2 >= n { return .drift }
        if looks.filter({ $0 == .focus }).count * 2 >= n { return .focus }
        return .neutral
    }

    /// The 3-minute block `date` falls in, counted from the day's start (so blocks line up with the clock).
    static func blockStart(_ date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let n = floor(date.timeIntervalSince(day) / blockSeconds)
        return day.addingTimeInterval(n * blockSeconds)
    }

    /// Whether to watch now: switched on and in 근무 시간 (when that is set) or a 집중 타이머 running; or only the timer
    /// with 타이머 중 자동 켜기.
    static func active(on: Bool, withTimer: Bool, timerRunning: Bool, hoursOn: Bool, hours: DriftHours, now: Date,
                       calendar: Calendar = .current) -> Bool {
        if timerRunning && (on || withTimer) { return true }
        return on && hoursOn && hours.contains(now, calendar: calendar)
    }

    /// Never closed by the paw: ourselves, Finder, an app not in front, a protected one (the cleaner's 보호 목록 and the
    /// owner's), a call or screen-sharing app, an app keeping the Mac awake (playing, recording), and anything while a
    /// call is on.
    static func appClosable(_ app: String, frontmost: String?, own: String?, protected: Set<String>, inUse: Bool, inCall: Bool) -> Bool {
        guard app != own, app != "com.apple.finder", app == frontmost, !protected.contains(app), !neverClose.contains(app) else { return false }
        guard !callApps.contains(app), !inUse, !inCall else { return false }
        return browser(app) == nil   // a browser loses one tab, never the whole browser
    }

    /// A tab may be closed when its browser is in front and no call is on. Playing video in it is the point.
    static func tabClosable(_ browserID: String, frontmost: String?, protected: Set<String>, inCall: Bool) -> Bool {
        browser(browserID) != nil && browserID == frontmost && !inCall && !protected.contains(browserID)
    }

    /// System and utility apps mid-job (an install, a disk repair, a password): never quit, whatever the on-device AI said.
    static let neverClose: Set<String> = [
        "com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.installer", "com.apple.DiskUtility",
        "com.apple.keychainaccess", "com.apple.SoftwareUpdate", "com.apple.archiveutility", "com.apple.loginwindow",
        "com.apple.SecurityAgent", "com.apple.MigrateAssistant", "com.apple.BootCampAssistant", "com.apple.Passwords",
        "com.apple.backup.launcher", "com.apple.AppStore", "com.apple.Console", "com.apple.ScriptEditor2",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.dt.Instruments",
    ]

    /// Meeting apps that are open only around a meeting: running anywhere counts as a call. Chat apps with calls
    /// (Discord, Teams) stay open all day, so for them the mic in use decides.
    static let meetingApps: Set<String> = ["us.zoom.xos", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.apple.ScreenSharing"]

    /// Call and screen-sharing apps (MeetingMute.apps, copied so this file stays free of AppKit).
    static let callApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp",
                                        "Cisco-Systems.Spark", "com.apple.FaceTime", "com.hnc.Discord", "com.apple.ScreenSharing"]
}

/// The 3-minute blocks of the day as looks come in. Pure: `add` returns the block that just ended, with its label and
/// what was in front most of it.
struct DriftBlocker {
    private(set) var start: Date?
    private(set) var looks: [(DriftLabel, DriftSample)] = []

    struct Closed: Equatable {
        var start: Date
        var label: DriftLabel
        var top: String
        /// The most seen look of the winning label (where the cat goes, what a correction saves).
        var sample: DriftSample
    }

    mutating func add(_ sample: DriftSample, _ label: DriftLabel, calendar: Calendar = .current) -> Closed? {
        let b = DriftRules.blockStart(sample.at, calendar: calendar)
        var closed: Closed?
        if let s = start, s != b { closed = close() }
        start = b
        looks.append((label, sample))
        return closed
    }

    /// A look at `at` is not in this block or the next: the time between was asleep or away.
    func stale(at: Date, calendar: Calendar = .current) -> Bool {
        guard let s = start else { return false }
        return DriftRules.blockStart(at, calendar: calendar).timeIntervalSince(s) > DriftRules.blockSeconds
    }

    /// The block so far, ended now (a look after a long pause starts a fresh one).
    mutating func close() -> Closed? {
        defer { start = nil; looks = [] }
        guard let s = start, let label = DriftRules.label(looks.map(\.0)) else { return nil }
        let pool = looks.filter { $0.0 == label }.map(\.1)
        let counts = Dictionary(grouping: pool, by: \.key)
        let top = counts.max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key }?.value.last ?? pool[0]
        return Closed(start: s, label: label, top: top.shown, sample: top)
    }
}

/// When drift is confirmed: `needed` drift blocks in a row while watching, not while snoozed (쉬는 중), and not
/// within the cooldown of the last nudge. Anything but a drift block starts the count again.
struct DriftWatch: Equatable {
    var needed = 2
    var cooldown = DriftRules.cooldown
    private(set) var streak = 0
    private(set) var lastNudge: Date?
    private(set) var snoozedUntil: Date?

    /// One finished block. True: drift is confirmed now (the count starts again).
    mutating func feed(_ label: DriftLabel, at now: Date, active: Bool) -> Bool {
        guard active else { streak = 0; return false }
        guard label == .drift else { streak = 0; return false }
        streak += 1
        guard streak >= max(1, needed) else { return false }
        if let s = snoozedUntil, now < s { return false }
        if let l = lastNudge, now.timeIntervalSince(l) < cooldown { return false }
        streak = 0
        lastNudge = now
        return true
    }

    /// 쉬는 중: no nudge for `minutes`.
    mutating func snooze(_ minutes: Int, now: Date) {
        snoozedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
        streak = 0
    }

    /// "아직 딴짓 중이에요?" 네: the next drift block nudges again, without the cooldown.
    mutating func recheckSoon() {
        lastNudge = nil
        streak = max(0, needed - 1)
    }

    /// "딴짓 아님" or 돌아가기: the count starts again.
    mutating func reset() { streak = 0 }
}

/// The cat's catch window: it runs in, lifts its paw, and `window` seconds later the paw comes down unless the cat was
/// caught first (a click on it while running or with the paw up).
struct PawPlay: Equatable {
    enum Phase: Equatable { case away, running, raised, caught, slammed }

    var window: TimeInterval = 3
    private(set) var phase: Phase = .away
    private(set) var raisedAt: Date?

    mutating func run() { phase = .running; raisedAt = nil }

    mutating func arrive(at now: Date) {
        guard phase == .running else { return }
        phase = .raised
        raisedAt = now
    }

    /// True when this click caught it in time.
    mutating func grab(at now: Date) -> Bool {
        switch phase {
        case .running:
            phase = .caught
            return true
        case .raised:
            guard let r = raisedAt, now.timeIntervalSince(r) < window else { return false }
            phase = .caught
            return true
        default:
            return false
        }
    }

    /// True once, when the paw comes down.
    mutating func tick(at now: Date) -> Bool {
        guard phase == .raised, let r = raisedAt, now.timeIntervalSince(r) >= window else { return false }
        phase = .slammed
        return true
    }

    /// 0...1 of the window gone (the paw's wind-up).
    func progress(at now: Date) -> Double {
        guard phase == .raised, let r = raisedAt, window > 0 else { return phase == .slammed ? 1 : 0 }
        return min(1, max(0, now.timeIntervalSince(r) / window))
    }

    mutating func leave() { phase = .away; raisedAt = nil }
}

/// The browser scripts, as text (DriftGuard runs them with osascript). Each one names the browser by bundle id.
enum DriftScript {
    /// The front window's front tab: URL, a record separator, the title. Never opens a browser that is closed.
    static func frontTab(_ b: DriftRules.Browser) -> String {
        let (tab, title) = b.safariStyle ? ("current tab", "name") : ("active tab", "title")
        return """
        tell application id "\(b.rawValue)"
            if (count of windows) is 0 then return ""
            set t to \(tab) of front window
            return (URL of t) & (character id 30) & (\(title) of t)
        end tell
        """
    }

    /// Closes the front tab only while it still shows `url` ("closed"), else leaves it ("changed").
    static func closeTab(_ b: DriftRules.Browser, url: String) -> String {
        let tab = b.safariStyle ? "current tab" : "active tab"
        return """
        tell application id "\(b.rawValue)"
            if (count of windows) is 0 then return "changed"
            set t to \(tab) of front window
            considering case
                if (URL of t) is not \(quote(url)) then return "changed"
            end considering
            close t
            return "closed"
        end tell
        """
    }

    /// Brings the tab showing `url` to the front of its window ("shown"), or says it is gone ("gone").
    static func showTab(_ b: DriftRules.Browser, url: String) -> String {
        let pick = b.safariStyle ? "set current tab of w to t" : "set active tab index of w to i"
        return """
        tell application id "\(b.rawValue)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (URL of t) is \(quote(url)) then
                        \(pick)
                        set index of w to 1
                        activate
                        return "shown"
                    end if
                end repeat
            end repeat
            return "gone"
        end tell
        """
    }

    /// An AppleScript string literal (the same escaping as AppleScriptText.quote).
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": continue
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    /// frontTab's answer: (url, title), nil for an empty or odd one.
    static func parseTab(_ out: String) -> (url: String, title: String)? {
        let parts = out.trimmingCharacters(in: .newlines).split(separator: "\u{1E}", maxSplits: 1, omittingEmptySubsequences: false)
        guard let u = parts.first.map(String.init), u.contains("://") else { return nil }
        return (u, parts.count > 1 ? String(parts[1]) : "")
    }
}

/// The log of finished blocks, on this Mac only (Application Support/DogMonitor/Drift.json), the last 7 days.
/// What was in front is kept as a site or an app name: never a page title or anything from the screen.
struct DriftLog: Codable, Equatable {
    struct Block: Codable, Equatable {
        var start: Date
        var label: DriftLabel
        var top: String
    }

    static let keepDays = 7
    var blocks: [Block] = []

    mutating func add(_ b: Block, now: Date, calendar: Calendar = .current) {
        if let i = blocks.lastIndex(where: { $0.start == b.start }) { blocks[i] = b } else { blocks.append(b) }
        prune(now: now, calendar: calendar)
    }

    mutating func prune(now: Date, calendar: Calendar = .current) {
        let from = calendar.date(byAdding: .day, value: -(Self.keepDays - 1), to: calendar.startOfDay(for: now)) ?? now
        blocks.removeAll { $0.start < from }
    }

    func today(_ now: Date, calendar: Calendar = .current) -> [Block] {
        blocks.filter { calendar.isDate($0.start, inSameDayAs: now) }
    }

    /// Minutes of each label today.
    func minutes(_ now: Date, calendar: Calendar = .current) -> [DriftLabel: Int] {
        var out: [DriftLabel: Int] = [:]
        for b in today(now, calendar: calendar) { out[b.label, default: 0] += Int(DriftRules.blockSeconds / 60) }
        return out
    }

    static func decode(_ data: Data) -> DriftLog {
        guard data.count <= 2 * 1024 * 1024 else { return DriftLog() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(DriftLog.self, from: data)) ?? DriftLog()
    }

    func encode() -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(self)) ?? Data()
    }
}
