import Combine
import CryptoKit
import SwiftUI

/// Every content feature as a 플러그인. The first group is installed (always open); the rest drip out weekly.
enum PluginID: String, CaseIterable, Codable {
    case cursor, clones, hanging, meadow, folder, play, toys, mac, rug, weather, focus, quickAsk, sponsor
    case playMoves, wardrobe, nearby, netPlay, walkieTalkie, office, remoteHelp

    /// The new ones, in the order they open (one a week; 근처 친구 before the four that need a paired friend).
    static let drip: [PluginID] = [.playMoves, .wardrobe, .nearby, .netPlay, .walkieTalkie, .office, .remoteHelp]

    var isInstalled: Bool { !Self.drip.contains(self) }

    /// 설정 > 플러그인, new ones first. 후원 친구 is the direct build's only; 같이 놀기 shows once NetPlay.ready.
    static var shown: [PluginID] {
        let drip = drip.filter { $0 != .netPlay || NetPlay.ready }
        #if MAS
        return drip + allCases.filter { $0.isInstalled && $0 != .sponsor }
        #else
        return drip + allCases.filter(\.isInstalled)
        #endif
    }

    var emoji: String {
        switch self {
        case .cursor: return "🐾"
        case .clones: return "👯"
        case .hanging: return "🎐"
        case .meadow: return "🌱"
        case .folder: return "📁"
        case .play: return "🎮"
        case .toys: return "🧸"
        case .mac: return "💻"
        case .rug: return "🧶"
        case .weather: return "⛅"
        case .focus: return "⏰"
        case .quickAsk: return "💬"
        case .sponsor: return "🎀"
        case .playMoves: return "🦘"
        case .wardrobe: return "👒"
        case .nearby: return "📡"
        case .netPlay: return "🤝"
        case .walkieTalkie: return "📻"
        case .office: return "🏢"
        case .remoteHelp: return "🛟"
        }
    }

    /// The installed ones' names are the 데스크톱 친구 titles (DesktopFriends.toggles finds its switch by it).
    var name: String {
        switch self {
        case .cursor: return L("커서 친구")
        case .clones: return L("복제 친구")
        case .hanging: return L("대롱대롱 친구")
        case .meadow: return L("풀밭 친구들")
        case .folder: return L("폴더 친구")
        case .play: return L("놀이")
        case .toys: return L("장난감 상자")
        case .mac: return L("맥과 같이 놀기")
        case .rug: return L("바탕화면 러그")
        case .weather: return L("날씨 창문")
        case .focus: return L("집중 타이머")
        case .quickAsk: return L("퀵물어보기")
        case .sponsor: return L("후원 친구")
        case .playMoves: return L("놀이 기술")
        case .wardrobe: return L("옷 입히기")
        case .nearby: return L("근처 친구")
        case .netPlay: return L("같이 놀기")
        case .walkieTalkie: return L("무전기")
        case .office: return L("가상 오피스")
        case .remoteHelp: return L("원격 지원")
        }
    }

    var line: String {
        switch self {
        case .cursor: return L("커서를 졸졸 따라다녀요")
        case .clones: return L("커서 친구를 복사해 바탕화면을 꾸며요")
        case .hanging: return L("메뉴바에 매달려 살랑살랑")
        case .meadow: return L("독 위에서 통통 뛰놀아요")
        case .folder: return L("바탕화면 폴더와 Finder 창 위에 올라앉아요")
        case .play: return L("친구를 키보드로 움직여 창 위를 폴짝폴짝 뛰어다녀요")
        case .toys: return L("바탕화면에 장난감을 꺼내 두면 친구들이 놀러 와요")
        case .mac: return L("맥에서 생긴 일에 친구가 같이 반응해요")
        case .rug: return L("접고 구기는 작은 천 러그")
        case .weather: return L("그 도시 날씨를 담은 작은 수정구슬")
        case .focus: return L("친구랑 같이 집중해요")
        case .quickAsk: return L("머리 위 말풍선이 바로 답해 줘요")
        case .sponsor: return L("가끔 제작자 서비스를 소개하고 꾸미기 선물을 줘요")
        case .playMoves: return L("하늘날기·높이 점프·빠른 대시")
        case .wardrobe: return L("모자·리본·안경·목도리·셔츠")
        case .nearby: return L("같은 와이파이 맥끼리 친구 맺고 대화")
        case .netPlay: return L("친구 맥과 같이 뛰기·별 대결")
        case .walkieTalkie: return L("버튼 누르는 동안만 내 목소리 전달")
        case .office: return L("나·친구·AI 팀원 자리와 상태판")
        case .remoteHelp: return L("수락하면 화면 공유로 도와주기 (맥끼리)")
        }
    }

    /// The 데스크톱 친구 switch this installed one shares, if it has one.
    var desktopToggle: DesktopToggle? {
        isInstalled ? DesktopFriends.toggles.first { $0.title == name } : nil
    }
}

enum PluginGate {
    /// Whether `id` may be used (installed, its day came, or its Instagram code was typed).
    static func isOpen(_ id: PluginID) -> Bool { id.isInstalled || PluginCenter.shared.open.contains(id) }
}

// MARK: The list

/// One new plugin's day and Instagram code, from web/plugins.json.
struct PluginRelease: Equatable {
    /// "yyyy-MM-dd" in the user's calendar: open for everyone from that day.
    var day: String
    /// PluginRules.hash of its code; nil = no code opens it early.
    var codeHash: String?
    /// The Instagram post that shares it.
    var post: URL?
}

/// web/plugins.json, signed like sponsors.json (plugins.json.sig, scripts/package.sh). `serial` only goes up. The
/// Instagram handle lives only here, so it can change without an app update.
struct PluginManifest: Equatable {
    var serial: Int
    var handle: String
    var profile: URL
    var releases: [PluginID: PluginRelease]
}

enum PluginCheck {
    static let maxBytes = 32_768, maxSignatureBytes = 256

    enum Failure: Error, Equatable { case tooBig, badSignature, badManifest, rollback }

    private struct Raw: Decodable {
        struct Instagram: Decodable { var handle: String; var url: String? }
        var serial: Int
        var instagram: Instagram
        var plugins: [Lossy]?
    }

    private struct Entry: Decodable { var id: String; var release: String; var code: String?; var post: String? }

    /// One entry that may not decode: nil then, and only it is dropped.
    private struct Lossy: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    /// Unknown or installed ids and bad days are dropped; a bad code or post link drops only that field.
    static func parse(_ data: Data) throws -> PluginManifest {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.serial >= 0,
              raw.instagram.handle.range(of: #"\A[A-Za-z0-9._]{1,30}\z"#, options: .regularExpression) != nil,
              let derived = URL(string: "https://www.instagram.com/\(raw.instagram.handle)/") else { throw Failure.badManifest }
        var releases: [PluginID: PluginRelease] = [:]
        for e in (raw.plugins ?? []).compactMap(\.entry) {
            guard let id = PluginID(rawValue: e.id), !id.isInstalled, releases[id] == nil,
                  e.release.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil else { continue }
            let code = e.code.flatMap { $0.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil ? $0 : nil }
            releases[id] = PluginRelease(day: e.release, codeHash: code, post: instagram(e.post))
        }
        return PluginManifest(serial: raw.serial, handle: raw.instagram.handle, profile: instagram(raw.instagram.url) ?? derived,
                              releases: releases)
    }

    /// `text` as a URL when it is https on instagram.com, with no port or login.
    static func instagram(_ text: String?) -> URL? {
        guard let text, let u = URL(string: text), u.scheme == "https", let h = u.host?.lowercased(),
              h == "instagram.com" || h == "www.instagram.com", u.port == nil, u.user == nil, u.password == nil else { return nil }
        return u
    }

    #if !MAS   // the App Store build has no UpdateCheck: it keeps the built-in list
    static let manifestURL = URL(string: "https://\(UpdateCheck.checkHost)/plugins.json")!
    static let signatureURL = URL(string: "https://\(UpdateCheck.checkHost)/plugins.json.sig")!

    /// The size, then the release key's signature over the exact bytes, then the parse. `minSerial`: the stored list's.
    static func verify(_ data: Data, signature: Data, publicKey: [UInt8] = UpdateCheck.publicKey, minSerial: Int = 0) throws -> PluginManifest {
        guard data.count <= maxBytes, signature.count <= maxSignatureBytes else { throw Failure.tooBig }
        guard UpdateCheck.signed(data, signature: signature, publicKey: publicKey) else { throw Failure.badSignature }
        let m = try parse(data)
        guard m.serial >= minSerial else { throw Failure.rollback }
        return m
    }

    /// Both files from the site, or from `folder` (QA, scripts/package.sh).
    static func fetch(folder: URL? = nil) async throws -> (data: Data, signature: Data) {
        if let folder {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent("plugins.json")),
                  let s = try? Data(contentsOf: folder.appendingPathComponent("plugins.json.sig")) else { throw Failure.badManifest }
            return (d, s)
        }
        async let d = UpdateCheck.fetch(manifestURL, maxBytes: maxBytes)
        async let s = UpdateCheck.fetch(signatureURL, maxBytes: maxSignatureBytes)
        return (try await d, try await s)
    }

    /// `--check-plugins [폴더]`: read-only. Fetches (or reads) the list, verifies it and prints what the app would use.
    static func runCLI(folder: URL?) async -> Int32 {
        do {
            let files = try await fetch(folder: folder)
            let m = try verify(files.data, signature: files.signature)
            print("서명 확인됨 · serial \(m.serial) · 인스타 @\(m.handle)")
            for id in PluginID.drip {
                guard let r = m.releases[id] else { print("  \(id.rawValue): 목록에 없음"); continue }
                print("  \(id.rawValue): \(r.day) · 코드 \(r.codeHash == nil ? "없음" : "있음") · 게시물 \(r.post?.absoluteString ?? "없음")")
            }
            return 0
        } catch {
            print("실패: \(error)")
            return 1
        }
    }
    #endif
}

extension PluginManifest {
    /// The list built into this version (web/plugins.json when it shipped; a test keeps them equal), so plugins open
    /// on their day offline.
    static let bundled: PluginManifest = (try? PluginCheck.parse(Data(bundledJSON.utf8)))
        ?? PluginManifest(serial: 0, handle: "0won.made", profile: URL(string: "https://www.instagram.com/0won.made/")!, releases: [:])

    private static let bundledJSON = #"""
    {"serial":1,
     "instagram":{"handle":"0won.made","url":"https://www.instagram.com/0won.made/"},
     "plugins":[
      {"id":"playMoves","release":"2026-10-30","code":"f64aa172695c693c11d680a7d8331ac6468ceaa04824eac5da88bfb72bed7839","post":null},
      {"id":"wardrobe","release":"2026-11-06","code":"03daef84467fbc7e4eb5150db95e8a52f7341ffcb56eb332f4e690ecb98b6fe0","post":null},
      {"id":"nearby","release":"2026-11-13","code":"e29c64d5a2a2b47e6de3bac85e9f59f0bb1fd49427bec2824c550a75b3a1560e","post":null},
      {"id":"netPlay","release":"2026-11-20","code":"8f51ab676f70d8ae510880d27df6cf03b6bbc55239f128156b9f85b814c0d27a","post":null},
      {"id":"walkieTalkie","release":"2026-11-27","code":"97533cb5e1c0e99cc46eeda1017b7f6cf950c2a6dc23066a514f03d53a84e6a6","post":null},
      {"id":"office","release":"2026-12-04","code":"86fe74d1c4c0deffc63ff071a771b7868d212c563c9ff44197ebebc3f6fc9731","post":null},
      {"id":"remoteHelp","release":"2026-12-11","code":"e081ed4bd173f80cec7e9fcb7f57f2a22834e1c4caca4bb3bedf449673a351fe","post":null}
     ]}
    """#

    /// The stored list when its bytes still verify and its serial is not below the bundled one's (its entries over the
    /// bundled ones, so a plugin it leaves out keeps its built-in day), else `bundled`. The App Store build: `bundled`.
    static func load(_ defaults: UserDefaults, bundled: PluginManifest = bundled) -> PluginManifest {
        #if MAS
        return bundled
        #else
        guard let d = defaults.data(forKey: PluginCenter.manifestKey), let s = defaults.data(forKey: PluginCenter.signatureKey),
              var m = try? PluginCheck.verify(d, signature: s), m.serial >= bundled.serial else { return bundled }
        m.releases = bundled.releases.merging(m.releases) { $1 }
        return m
        #endif
    }
}

// MARK: Rules

/// The pure rules: which plugin is open today, and what an Instagram code opens.
enum PluginRules {
    static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    static let triesPerMinute = 5

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Installed, or its day came ("yyyy-MM-dd" sorts as text), or its code was typed (`unlocked`; empty in the App
    /// Store build, which has no codes).
    static func isOpen(_ id: PluginID, today: String, manifest: PluginManifest, unlocked: Set<PluginID>) -> Bool {
        if id.isInstalled || unlocked.contains(id) { return true }
        return manifest.releases[id].map { today >= $0.day } ?? false
    }

    /// Upper case, A-Z and 0-9 only ("fly7-k2qz " -> "FLY7K2QZ").
    static func normalized(_ code: String) -> String {
        String(String.UnicodeScalarView(code.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }))
    }

    /// SHA256("charamonitor-plugin:" + id + ":" + normalized code), lowercase hex. tools/update/plugin_code.swift makes the same.
    /// ponytail: an 8-character code behind a public hash can be found offline; it is a growth gate, not security (the
    /// day opens it anyway).
    static func hash(_ id: PluginID, _ code: String) -> String {
        SHA256.hash(data: Data("charamonitor-plugin:\(id.rawValue):\(normalized(code))".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The plugin this code opens, if any.
    static func match(_ code: String, _ m: PluginManifest) -> PluginID? {
        guard !normalized(code).isEmpty else { return nil }
        return PluginID.drip.first { id in m.releases[id]?.codeHash.map { $0 == hash(id, code) } ?? false }
    }

    /// The tries still counted (the last minute's) and whether one more may go.
    static func recent(_ tries: [Date], now: Date) -> (kept: [Date], mayTry: Bool) {
        let kept = tries.filter { now.timeIntervalSince($0) < 60 && $0 <= now }
        return (kept, kept.count < triesPerMinute)
    }
}

// MARK: The center

/// Which plugins are open. Looked at again at launch, at midnight (NSCalendarDayChanged), after a fetch and after a
/// code; no timer for that. The direct build fetches the signed list 60 s after launch and then daily, only while some
/// plugin is still closed.
final class PluginCenter: ObservableObject {
    static let shared = PluginCenter()
    static let unlockedKey = "plugins.unlocked", manifestKey = "plugins.manifest", signatureKey = "plugins.manifestSig",
               announcedKey = "plugins.announced"

    @Published private(set) var open: Set<PluginID> = []
    @Published private(set) var manifest: PluginManifest

    enum Unlock: Equatable { case opened(PluginID), already(PluginID), wrong, wait }

    private let defaults: UserDefaults
    private let bundled: PluginManifest
    private var tries: [Date] = []
    private var fetchTimer: Timer?
    private var bag: Set<AnyCancellable> = []

    init(defaults: UserDefaults = AppDefaults.store, bundled: PluginManifest = .bundled) {
        self.defaults = defaults
        self.bundled = bundled
        // 놀이 기술 and 같이 놀기 are on once they open (their owners read these keys).
        defaults.register(defaults: ["play.moves": true, "netplay.on": true])
        manifest = PluginManifest.load(defaults, bundled: bundled)
        refresh()
    }

    /// Typed codes' plugins (never in 내 설정 파일).
    var unlocked: Set<PluginID> {
        #if MAS
        []
        #else
        Set((defaults.stringArray(forKey: Self.unlockedKey) ?? []).compactMap(PluginID.init))
        #endif
    }

    var allOpen: Bool { PluginID.drip.allSatisfy(open.contains) }

    /// Call once at launch.
    func start() {
        guard bag.isEmpty else { return }
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh(); self?.announce() }.store(in: &bag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.announce() }   // after the first bubbles
        #if !MAS
        scheduleFetch(after: 60)
        #endif
    }

    func refresh(now: Date = Date()) {
        let today = PluginRules.day(now), u = unlocked
        let next = Set(PluginID.allCases.filter { PluginRules.isOpen($0, today: today, manifest: manifest, unlocked: u) })
        if next != open { open = next }
    }

    /// The plugin's day as "11월 6일".
    func dayText(_ id: PluginID) -> String? {
        guard let p = manifest.releases[id]?.day.split(separator: "-"), p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return L("\(m)월 \(d)일")
    }

    /// 인스타에서 보기: the plugin's post, else the profile.
    func instagramURL(_ id: PluginID) -> URL { manifest.releases[id]?.post ?? manifest.profile }

    /// New plugins opened by their day: one line, once per plugin (it waits for a moment the bubble is free).
    private func announce() {
        var seen = Set(defaults.stringArray(forKey: Self.announcedKey) ?? [])
        let fresh = PluginID.drip.filter { open.contains($0) && !seen.contains($0.rawValue) }
        guard !fresh.isEmpty else { return }
        let names = fresh.map(\.name).joined(separator: ", ")
        guard SpeechBubbleCenter.shared.say(text: L("새 플러그인: \(names) (설정 > 플러그인)"), source: .system, aloud: false,
                                            repeats: true) else { return }
        fresh.forEach { seen.insert($0.rawValue) }
        defaults.set(Array(seen).sorted(), forKey: Self.announcedKey)
    }

    #if !MAS
    /// 코드 넣기. At most 5 tries a minute.
    @discardableResult
    func unlock(_ code: String, now: Date = Date()) -> Unlock {
        let r = PluginRules.recent(tries, now: now)
        tries = r.kept
        guard r.mayTry else { return .wait }
        tries.append(now)
        guard let id = PluginRules.match(code, manifest) else { return .wrong }
        guard !open.contains(id) else { return .already(id) }
        defaults.set((Array(unlocked) + [id]).map(\.rawValue).sorted(), forKey: Self.unlockedKey)
        var seen = Set(defaults.stringArray(forKey: Self.announcedKey) ?? [])
        seen.insert(id.rawValue)
        defaults.set(Array(seen).sorted(), forKey: Self.announcedKey)
        refresh(now: now)
        return .opened(id)
    }

    private func scheduleFetch(after: TimeInterval) {
        fetchTimer?.invalidate()
        fetchTimer = nil
        guard !allOpen else { return }   // never once all are open
        let t = Timer(fire: Date() + after, interval: 0, repeats: false) { [weak self] _ in self?.fetch() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        fetchTimer = t
    }

    private func fetch() {
        let minSerial = manifest.serial
        Task { @MainActor [weak self] in
            if let files = try? await PluginCheck.fetch(),
               (try? PluginCheck.verify(files.data, signature: files.signature, minSerial: minSerial)) != nil, let self {
                defaults.set(files.data, forKey: Self.manifestKey)
                defaults.set(files.signature, forKey: Self.signatureKey)
                manifest = PluginManifest.load(defaults, bundled: bundled)
            }
            self?.refresh()
            self?.announce()
            self?.scheduleFetch(after: 86_400)
        }
    }
    #endif
}

// MARK: 설정 > 플러그인

/// 설정 > 플러그인.
struct PluginsSection: View {
    @ObservedObject private var center = PluginCenter.shared
    @ObservedObject private var settings = AppSettings.shared
    // The stores behind the installed tiles' switches, so a switch flipped elsewhere shows here.
    @ObservedObject private var motion = MotionStore.shared
    @ObservedObject private var hanging = HangingStore.shared
    @ObservedObject private var weather = WeatherWindow.shared
    @ObservedObject private var meadow = MeadowStore.shared
    @ObservedObject private var folder = FolderStore.shared
    @ObservedObject private var rug = RugStore.shared
    @ObservedObject private var clones = CloneStore.shared
    @State private var selected: PluginID?
    @State private var code = ""
    @State private var note: String?
    @AppStorage("play.moves", store: AppDefaults.store) private var playMoves = true
    @AppStorage("netplay.on", store: AppDefaults.store) private var netPlay = true

    private var k: CGFloat { settings.settingsTextLarge ? 1.15 : 1 }
    private var accent: Color { settings.palette.accent ?? .accentColor }

    var body: some View {
        Panel(tint: settings.palette.accent) {
            HStack(spacing: 8) {
                Text(verbatim: "🧩").font(.system(size: 14 * k))
                    .frame(width: 26 * k, height: 26 * k)
                    .background(Circle().fill(accent.opacity(0.25)))
                    .accessibilityHidden(true)
                Text("플러그인").font(.system(size: 13 * k, weight: .bold, design: .rounded))
                Spacer()
                Text(verbatim: "\(PluginID.drip.filter(center.open.contains).count)/\(PluginID.drip.count)")
                    .font(.system(size: 11 * k)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(L("새 플러그인이 매주 하나씩 열려요. 인스타 @\(center.manifest.handle) 에서 먼저 공개해요"))
                .font(.system(size: 12 * k)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(PluginID.shown, id: \.self) { tile($0) }
            }
            if let s = selected { detail(for: s).padding(.top, 2) }
            #if !MAS
            codeRow
            #endif
        }
    }

    private func tile(_ id: PluginID) -> some View {
        let open = PluginGate.isOpen(id), chosen = selected == id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(verbatim: id.emoji).font(.system(size: 14 * k)).saturation(open ? 1 : 0).opacity(open ? 1 : 0.5)
                Text(verbatim: id.name).font(.system(size: 12 * k, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let t = id.desktopToggle {
                    Toggle(id.name, isOn: Binding(get: t.isOn, set: t.set)).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(accent)
                }
            }
            Text(verbatim: id.line).font(.system(size: 10 * k)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: state(id)).font(.system(size: 10 * k, weight: .semibold))
                .foregroundStyle(open ? accent : Color.secondary)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // a row's tiles share its height
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(open ? accent.opacity(0.14) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(chosen ? accent : open ? accent.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: chosen ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { if !id.isInstalled { selected = chosen ? nil : id } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(id.isInstalled ? [] : .isButton)
    }

    private func state(_ id: PluginID) -> String {
        if id.isInstalled { return L("설치됨") }
        if PluginGate.isOpen(id) { return L("열림 · 눌러서 설정") }
        return "🔒 " + (center.dayText(id).map { L("곧 공개 · \($0)") } ?? L("곧 공개"))
    }

    @ViewBuilder private func detail(for id: PluginID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(id.emoji) \(id.name)").font(.system(size: 12 * k, weight: .bold))
            if !PluginGate.isOpen(id) {
                Text(L("인스타 @\(center.manifest.handle) 에서 먼저 공개해요")).font(.system(size: 11 * k)).foregroundStyle(.secondary)
                #if !MAS
                Text("여는 날 전에 인스타에서 먼저 코드를 나눠요. 아래 코드 넣기에 넣으면 바로 열려요.")
                    .font(.system(size: 11 * k)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                #endif
                Button("인스타에서 보기") { External.open(center.instagramURL(id)) }.controlSize(.small)
            } else {
                switch id {
                case .wardrobe: WardrobeSettings()
                case .nearby, .walkieTalkie, .remoteHelp: NearbySettings(part: id)
                case .office: OfficeSettings()
                case .playMoves:
                    Toggle("놀이 기술 쓰기", isOn: $playMoves).toggleStyle(.switch).controlSize(.small).tint(accent)
                    Text("놀이 모드에서 ↑를 꾹 누르면 하늘을 날고, ↑를 빠르게 두 번 누르면 높이 점프해요. ← →를 빠르게 두 번 누르면 대시해요. 둘이 놀기의 친구는 W·A·D로 똑같이 해요.")
                        .font(.system(size: 11 * k)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .netPlay:
                    Toggle("친구의 같이 놀기 초대 받기", isOn: $netPlay).toggleStyle(.switch).controlSize(.small).tint(accent)
                    Text("근처 친구에서 맺은 친구의 메뉴에서 같이 뛰기나 별 대결을 골라요. 받는 쪽이 수락해야 시작해요.")
                        .font(.system(size: 11 * k)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                default: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if !MAS
    private var codeRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("코드 넣기").font(.system(size: 12 * k)).foregroundStyle(.secondary)
                TextField("인스타 코드 8자리", text: $code).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 130)
                    .onSubmit(enter)
                Button("확인", action: enter).controlSize(.small).disabled(PluginRules.normalized(code).isEmpty)
            }
            if let note { Text(verbatim: note).font(.system(size: 11 * k)).foregroundStyle(.secondary) }
        }
    }

    private func enter() {
        switch center.unlock(code) {
        case .opened(let id):
            code = ""
            let line = L("새 플러그인이 열렸어요: \(id.name)")
            note = line
            selected = id
            DesktopKit.celebrate.send(.wave)
            SpeechBubbleCenter.shared.say(text: line, source: .system, aloud: false, repeats: true)
        case .already(let id):
            code = ""
            note = L("\(id.name)은(는) 이미 열려 있어요")
        case .wrong: note = L("코드가 맞지 않아요")
        case .wait: note = L("잠시 뒤에 다시 넣어 주세요")
        }
    }
    #endif
}
