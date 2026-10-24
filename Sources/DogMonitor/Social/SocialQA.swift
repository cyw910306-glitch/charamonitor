#if !MAS
import AppKit
import Combine
import Foundation

/// QA only (`--qa-defaults <suite>`, direct build): two copies of the built app on one Mac go through every 근처 친구
/// feature over the real Bonjour + TLS path, with no clicks (qa/social-e2e.sh runs them). The preferences live in
/// that suite and friend keys in memory, so the owner's are never touched; every plugin is open (PluginGate) and every
/// question answers itself (`decide`). `--qa-host <file>` shows a code and writes it to the file and answers;
/// `--qa-join <file>` reads it, joins the Mac showing a code and drives the steps. Each step prints `QA PASS <step>`
/// or `QA FAIL <step>` to stderr; `QA ready <what>` and `QA shot <name>` are for the script (freeze, kill, capture).
enum SocialQA {
    static var active = false
    private static var bag = Set<AnyCancellable>()
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func log(_ s: String) { fputs("QA \(s)\n", stderr) }

    /// What came in from the friend, for the checks.
    private static var chats: [String] = []
    private static var plays = 0
    private static var lastPlay: TimeInterval = 0
    private static var taken: [Int] = []
    private static var playEnds = 0
    private static var answers: [(accept: Bool, on: Bool)] = []
    private static var decided: [String: Int] = [:]
    /// Emotes in from the friend (after the link's limit), and when the last one came.
    private static var emotes: [EmoteKind] = []
    private static var lastEmote: TimeInterval = 0
    /// 낙서 쪽지 in from the friend.
    private static var doodles = 0
    /// 던지기 놀이 hits in from the friend, and their 기절 seconds.
    private static var hits = 0
    private static var kos: [Int] = []

    /// 무전기 as the hearing side measures it: from the talker's `qa-voice <t0>` chat to its voiceEnd.
    private struct VoiceStats {
        var t0: TimeInterval
        var first: UInt32?, last: UInt32?
        var frames = 0, outOfOrder = 0, played = 0, playedLate = 0
        var latency: [TimeInterval] = []
        var ended: TimeInterval?
    }
    private static var voice: VoiceStats?

    /// The answer a question gets in QA: yes, except the first 원격 지원 ask (no), so both answers go across.
    static func decide(_ kind: String) -> Bool {
        let n = decided[kind, default: 0]
        decided[kind] = n + 1
        let yes = kind != "remote" || n > 0
        log("decide \(kind) \(yes ? "yes" : "no")")
        return yes
    }

    /// 무전기, hearing side: `played` frames left the jitter buffer for this one.
    static func heard(played: Int) {
        guard var v = voice else { return }
        v.played += played
        if now - v.t0 > VoiceTalk.maxSeconds + 0.5 { v.playedLate += played }
        voice = v
    }

    /// Keeps the QA copies out of App Nap: a backgrounded copy's 원격 모임 poll timer otherwise slips to minutes.
    private static var awake: NSObjectProtocol?

    static func start(_ args: [String]) {
        active = true
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "QA")
        let bus = SocialBus.shared
        bus.keys = .memory()
        // The suite is throwaway: every switch the steps need, on.
        for key in ["social.on", "social.voice", "social.remoteHelp", OfficeCenter.onKey, "netplay.on", ThrowCenter.key] { bus.defaults.set(true, forKey: key) }
        func arg(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        bus.$isOn.removeDuplicates().sink { log("on \($0)") }.store(in: &bag)
        bus.$online.removeDuplicates().sink { log("online \($0.sorted().map { $0.prefix(8) })") }.store(in: &bag)
        bus.$friends.removeDuplicates().sink { log("friends \($0.map { "\($0.nickname):\($0.status.rawValue)" })") }.store(in: &bag)
        bus.inbox.sink { got($0.message) }.store(in: &bag)
        if let file = arg("--qa-host") {
            bus.$code.compactMap { $0 }.sink { c in
                log("code shown")
                try? c.write(toFile: file, atomically: true, encoding: .utf8)
            }.store(in: &bag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { log("show code"); bus.showCode() }
            run(hostSteps())
        }
        if let file = arg("--qa-join") { run(joinSteps(file)) }
        // 원격 모임 through a local relay (qa/relay-e2e.sh): both copies join `--qa-meet <code>`; `--qa-first` sends first.
        if let url = arg("--qa-relay").flatMap(URL.init(string:)), let code = arg("--qa-meet") {
            MeetRelay.endpoint = url
            MeetRelay.pollSeconds = 4...5   // two copies on one address stay well under the relay's 90 a minute
            MeetRelay.fastSeconds = 4...5
            RemoteMeet.shared.codeStore = .memory()
            bus.defaults.set(true, forKey: "meet.on")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { RemoteMeet.shared.join(code) }
            run(meetSteps(first: args.contains("--qa-first")))
        }
    }

    private static func got(_ m: SocialMessage) {
        switch m {
        case .chat(let t):
            chats.append(t)
            log("chat in \(t)")
            if t.hasPrefix("qa-voice "), let t0 = TimeInterval(t.dropFirst(9)) { voice = VoiceStats(t0: t0) }
        case .play:
            plays += 1
            lastPlay = now
        case .starTaken(let i):
            taken.append(i)
            log("starTaken in \(i)")
        case .playEnd:
            playEnds += 1
            log("playEnd in")
        case let .remoteAnswer(accept, on):
            answers.append((accept, on))
            log("remoteAnswer in accept=\(accept) screenSharingOn=\(on)")
        case let .voice(seq, _):
            guard var v = voice else { return }
            if let last = v.last, seq != last &+ 1 { v.outOfOrder += 1 }
            let first = v.first ?? seq
            v.first = first
            v.last = seq
            v.frames += 1
            // When the talker's clock made this frame (frame n is done 20 ms after frame n-1), to when it got here.
            v.latency.append(now - (v.t0 + Double(seq &- first &+ 1) * Double(VoiceCodec.frameSamples) / VoiceCodec.sampleRate))
            voice = v
        case .voiceEnd:
            voice?.ended = now
            log("voiceEnd in")
        case .emote(let k):
            emotes.append(k)
            lastEmote = now
            log("emote in \(k.rawValue)")
        case .doodle:
            doodles += 1
            log("doodle in")
        case .hit(let item):
            hits += 1
            log("hit in \(item)")
        case .ko(let seconds):
            kos.append(seconds)
            log("ko in \(seconds)")
        default:
            break
        }
    }

    // MARK: Steps

    /// One step: `run` once, then `check` every 0.2 s until it says PASS (true) or FAIL (false), or `wait` runs out.
    private struct Step {
        var name: String
        var wait: TimeInterval
        var run: () -> Void = {}
        var check: () -> Bool?
    }

    private static func run(_ steps: [Step]) {
        var i = 0, fails = 0
        var began: TimeInterval?
        let t = Timer(timeInterval: 0.2, repeats: true) { t in
            guard i < steps.count else {
                t.invalidate()
                log("DONE \(fails == 0 ? "PASS" : "FAIL \(fails)")")
                return
            }
            let s = steps[i]
            if began == nil { began = now; s.run() }
            let r = s.check() ?? (now - began! > s.wait ? false : nil)
            guard let ok = r else { return }
            if !ok { fails += 1 }
            log("\(ok ? "PASS" : "FAIL") \(s.name) (\(String(format: "%.1f", now - began!)) s)")
            i += 1
            began = nil
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private static var bus: SocialBus { .shared }
    private static var friend: SocialFriend? { bus.friends.first }
    private static var friendOnline: Bool { friend.map { bus.online.contains($0.id) } ?? false }
    private static var game: NetGame? { NetPlay.shared.session?.game }

    /// The stars out now, the same list on both Macs when they share a seed.
    private static func logStars() {
        log("stars " + StarGame.shared.spots.prefix(5).map { "\($0.id):\(Int($0.spot.center.x)),\(Int($0.spot.center.y))\($0.spot.treat ? "t" : "")" }
            .joined(separator: " "))
    }

    /// Waits for a session of `g` with the friend's state coming in.
    private static func session(_ g: NetGame, states: Int) -> () -> Bool? {
        var from: Int?   // counted from the step's first check
        return {
            let f = from ?? plays
            from = f
            return game == g && PlayMode.shared.isPlaying && plays - f >= states ? true : nil
        }
    }

    /// Host: ready for the joiner's next invite (it waits for this, so neither side runs ahead).
    private static func go(_ what: String) { friend.map { _ = bus.chat("qa-go \(what)", to: $0.id) } }

    /// Joiner: invites once the host said it is ready for `what`.
    private static var invited: Set<String> = []
    private static func inviteWhen(_ what: String) {
        guard chats.contains("qa-go \(what)"), invited.insert(what).inserted, let f = friend else { return }
        NetPlay.shared.invite(f.id, .play)
    }

    /// A small doodle (three points) for the 낙서 쪽지 steps.
    private static let doodle = Doodle(strokes: [Data([10, 10, 32, 40, 54, 10])])

    /// Once `came`, the doodle shows over a character and goes after 5 s. On this Mac in a call or a recording it
    /// never shows, so that is a FAIL here (close the call or recorder and run again).
    private static func shownThenGone(_ came: @escaping () -> Bool) -> () -> Bool? {
        var seen: TimeInterval?
        return {
            guard came() else { return nil }
            if seen == nil {
                guard DoodleCenter.showing else {
                    log("doodle not shown\(FriendVisit.quiet() ? " (call or recording)" : "")")
                    return false
                }
                seen = now
            }
            guard let s = seen, !DoodleCenter.showing else { return nil }
            log(String(format: "doodle shown %.2fs", now - s))
            return abs(now - s - DoodleCenter.showSeconds) < 0.6
        }
    }

    /// The free chair (no season needed), for 의자 동기화.
    private static var freeChair: ChairArt? { ChairCatalog.all.first { !$0.season } }

    /// A 600×400 PNG with a gradient, for 사진 메시지.
    private static func qaPhoto() -> Data? {
        let img = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { r in
            NSGradient(starting: .systemOrange, ending: .systemTeal)?.draw(in: r, angle: 30)
            return true
        }
        return img.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }

    /// The draw this Mac shows, for the other side to compare: id and winner.
    private static func drawn(_ r: DrawRecord) -> String { "\(r.id) \(r.winner)" }

    private static func ended() -> Bool? { !PlayMode.shared.isPlaying && NetPlay.shared.session == nil ? true : nil }

    /// The host: answers, and checks what the joiner did.
    private static func hostSteps() -> [Step] {
        var ends = 0
        var since: TimeInterval = 0
        return [
            Step(name: "페어링 (host)", wait: 150) { friendOnline ? true : nil },
            Step(name: "채팅 받기", wait: 20) { chats.contains("QA 안녕") ? true : nil },
            Step(name: "채팅 보내기", wait: 5) { friend.map { bus.chat("QA 반가워", to: $0.id) } },
            Step(name: "상태 받기 (식사)", wait: 20) { friend?.status == .meal ? true : nil },
            Step(name: "상태 보내기 (회의)", wait: 5, run: { OfficeCenter.shared.set(.meeting) }) { bus.myStatus == .meeting },
            Step(name: "가상 오피스 상태판", wait: 10, run: { OfficeCenter.shared.show(); log("shot office") }) {
                OfficeCenter.shared.on && friend?.status == .meal ? true : nil
            },
            Step(name: "친구 상주 (독 위)", wait: 10) {
                friend.map { FriendRoom.shared.seatIDs.contains($0.id) } == true ? true : nil
            },
            Step(name: "다같이 뽀뽀·똥·던지기 받기", wait: 30) {
                Array(emotes.prefix(3)) == [.kiss, .poop, .toss] ? true : (emotes.count >= 3 ? false : nil)
            },
            Step(name: "다같이 뽀뽀 보내기", wait: 10) { FriendRoom.shared.sendAll(.kiss) ? true : nil },
            Step(name: "받는 쪽 rate limit (몰아 보낸 6개 중 3개)", wait: 40) {
                // The burst comes 10.5 s after the toss, in a fresh 10 s window; done once 2 s pass with nothing new.
                emotes.count > 3 && now - lastEmote > 2 ? emotes.count - 3 == 3 : nil
            },
            Step(name: "모임 정원 2명 꽉 참 축하", wait: 10, run: { bus.defaults.set(2, forKey: Gathering.key) }) {
                guard OfficeCenter.shared.capacity == 2, OfficeCenter.shared.celebrating else { return nil }
                log("shot office-full")
                return Gathering.waiting(capacity: 2, friends: bus.friends.count) == 0
            },
            Step(name: "오늘 한마디 받기", wait: 20) { friend.flatMap { bus.notes[$0.id]?.line } == "QA 한마디" ? true : nil },
            Step(name: "퇴근한 척 → 친구에겐 퇴근", wait: 20) { friend?.status == .off ? true : nil },
            Step(name: "운세 다시 뽑기·점심 공유 받기", wait: 20) {
                guard let n = friend.flatMap({ bus.notes[$0.id] }), n.fortune == 1, let lunch = n.lunch else { return nil }
                return chats.contains("qa-lunch \(lunch)") ? true : nil
            },
            Step(name: "프로필 카드 데이터", wait: 20) {
                guard let f = friend, let c = bus.card(f.id), let n = c.note,
                      let want = chats.first(where: { $0.hasPrefix("qa-fortune ") }) else { return nil }
                FriendCardPanel.show(c)
                log("shot profile-card")
                return c.name == f.nickname && c.status == .off && n.day == WorkHours.day(Date()) && n.line == "QA 한마디"
                    && n.lunch != nil && "qa-fortune " + n.reading.headline == want
            },
            Step(name: "낙서 쪽지 받기·5초 뒤 사라짐", wait: 30, run: { go("doodle") }, check: shownThenGone { doodles >= 1 }),
            Step(name: "낙서 쪽지 보내기", wait: 5) { friend.map { DoodleCenter.send(doodle, to: .friend($0.id)) } },
            Step(name: "투척물 5번 맞기 → 기절 알림", wait: 40) {
                // My Mac counts them (StunRule) and tells the friend, whose screen shows the stars.
                hits >= StunRule.hits ? true : nil
            },
            Step(name: "그룹 뽑기 같은 결과", wait: 30) {
                guard let want = chats.last(where: { $0.hasPrefix("qa-draw ") }) else { return nil }
                guard let r = GroupDraw.shared.book.records.last(where: { !$0.mine }) else { return false }
                log("drawn \(drawn(r))")
                return "qa-draw " + drawn(r) == want
            },
            Step(name: "사진 받기 (근처, 원본 포함)", wait: 30) {
                guard let f = friend, let e = SocialChat.shared.log[f.id]?.last(where: { !$0.mine && $0.photo != nil }) else { return nil }
                let ok = e.photo?.full.flatMap(NSImage.init(data:)) != nil && NSImage(data: e.photo!.thumb) != nil
                log("photo in full=\(e.photo?.full?.count ?? 0) thumb=\(e.photo?.thumb.count ?? 0)")
                return ok
            },
            Step(name: "의자 동기화 (친구가 앉음)", wait: 30) {
                guard let f = friend, let c = freeChair, f.look.seat == c.id else { return nil }
                return FriendRoom.shared.seats.first { $0.id == f.id }?.chair?.id == c.id ? true : nil
            },
            Step(name: "무전기 듣기", wait: 60) {
                guard let v = voice, let end = v.ended else { return nil }
                let lat = v.latency.sorted(), p95 = lat.isEmpty ? 0 : lat[lat.count * 95 / 100]
                let avg = lat.isEmpty ? 0 : lat.reduce(0, +) / Double(lat.count)
                let talk = end - v.t0, expected = Int(VoiceTalk.maxSeconds * VoiceCodec.sampleRate) / VoiceCodec.frameSamples
                log(String(format: "voice frames=%d/%d outOfOrder=%d played=%d playedAfter30s=%d talk=%.2fs latency avg=%.0fms p95=%.0fms max=%.0fms",
                           v.frames, expected, v.outOfOrder, v.played, v.playedLate, talk, avg * 1000, p95 * 1000, (lat.last ?? 0) * 1000))
                return v.frames >= expected * 95 / 100 && v.frames <= expected + 2 && v.outOfOrder == 0 && v.played >= v.frames - 3
                    && v.playedLate == 0 && abs(talk - VoiceTalk.maxSeconds) < 1.5 && p95 < 0.25
            },
            Step(name: "원격 지원 요청 거절 응답", wait: 30) { decided["remote", default: 0] >= 1 ? true : nil },
            Step(name: "원격 지원 요청 수락 응답", wait: 30) { decided["remote", default: 0] >= 2 ? true : nil },
            Step(name: "같이 뛰기 초대 수락 (host)", wait: 40, check: { decided["invite", default: 0] >= 1 && game == .play && plays >= 20 ? true : nil }),
            Step(name: "같이 뛰기 내가 끝내기", wait: 5, run: { PlayMode.shared.end() }, check: ended),
            Step(name: "별 대결 시작 (host)", wait: 40) {
                guard game == .starDuel, StarGame.shared.isOn else { return nil }
                logStars()
                ends = playEnds   // the friend may end it before the next steps look
                return true
            },
            Step(name: "별 대결 starTaken·점수 받기", wait: 40) {
                guard let id = taken.last, StarGame.shared.scores[1] >= 1 else { return nil }
                logStars()
                return !StarGame.shared.spots.contains { $0.id == id }
            },
            Step(name: "별 대결 친구가 끝내기 (playEnd)", wait: 30) {
                playEnds > ends && ended() == true ? true : nil
            },
            Step(name: "같이 뛰기 (침묵 테스트) 시작", wait: 40, run: { go("silence") }, check: session(.play, states: 10)),
            Step(name: "친구 5초 침묵 → 종료 (host)", wait: 30) {
                guard ended() == true else { return nil }
                let gap = now - lastPlay
                log(String(format: "silence gap %.2fs", gap))
                return gap >= NetPlayLink.silence && gap < NetPlayLink.silence + 1.5
            },
            Step(name: "같이 뛰기 (오프라인 테스트) 시작", wait: 60, run: { go("offline") }, check: session(.play, states: 10)),
            Step(name: "친구 오프라인 → 종료 (host)", wait: 20, run: { since = now }) {
                guard ended() == true, !friendOnline else { return nil }
                log(String(format: "offline end after %.2fs", now - since))
                return true
            },
        ]
    }

    /// The joiner: drives every step.
    private static func joinSteps(_ file: String) -> [Step] {
        var joined = false
        var talk: TimeInterval = 0
        var tossed: TimeInterval = 0
        return [
            Step(name: "페어링 (join)", wait: 150) {
                if !joined, let mac = bus.nearby.first, let code = try? String(contentsOfFile: file, encoding: .utf8) {
                    joined = true
                    log("join \(mac.nickname)")
                    bus.join(mac, code: code)
                }
                return friendOnline ? true : nil
            },
            Step(name: "채팅 보내기", wait: 5) { friend.map { bus.chat("QA 안녕", to: $0.id) } },
            Step(name: "채팅 받기", wait: 20) { chats.contains("QA 반가워") ? true : nil },
            Step(name: "상태 보내기 (식사)", wait: 5, run: { OfficeCenter.shared.set(.meal) }) { bus.myStatus == .meal },
            Step(name: "상태 받기 (회의)", wait: 20) { friend?.status == .meeting ? true : nil },
            Step(name: "가상 오피스 상태판", wait: 10, run: { OfficeCenter.shared.show() }) {
                OfficeCenter.shared.on && friend?.status == .meeting ? true : nil
            },
            Step(name: "다같이 뽀뽀 보내기", wait: 10) { FriendRoom.shared.sendAll(.kiss) ? true : nil },
            Step(name: "다같이 똥 보내기", wait: 10) { FriendRoom.shared.sendAll(.poop) ? true : nil },   // after the 2 s cooldown
            Step(name: "친구 던지기 (Fling)", wait: 10) {
                guard let f = friend, FriendRoom.shared.seatIDs.contains(f.id) else { return nil }
                FriendRoom.shared.toss(f.id)
                tossed = now
                return true
            },
            Step(name: "다같이 뽀뽀 받기", wait: 30) { emotes.contains(.kiss) ? true : nil },
            Step(name: "이모트 6개 몰아 보내기", wait: 30) {
                // In a fresh 10 s window on the friend's side; it should take 3.
                guard now - tossed >= 10.5, let f = friend else { return nil }
                for _ in 0..<6 { bus.send(.emote(.kiss), to: f.id) }
                return true
            },
            Step(name: "오늘 한마디 쓰기", wait: 5, run: { bus.setTodayLine("QA 한마디") }) { bus.todayLine() == "QA 한마디" },
            Step(name: "퇴근한 척 (자동 전환에도 그대로)", wait: 5, run: {
                OfficeCenter.shared.set(.pretendOff)
                OfficeCenter.shared.check()
            }) { bus.myStatus == .pretendOff },
            Step(name: "운세 다시 뽑기·점심 뽑기 공유", wait: 5, run: {
                Fortune.show(redraw: true)
                var rng = SystemRandomNumberGenerator()
                let lunch = Lunch.shared.pull(using: &rng)?.pick.menu.name
                guard let f = friend else { return }
                bus.chat("qa-fortune \(Fortune.today().headline)", to: f.id)
                // The friend takes one chat a second (SocialRateLimit), so the second waits.
                lunch.map { l in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { _ = bus.chat("qa-lunch \(l)", to: f.id) } }
            }) { Fortune.today().draw == 1 && Lunch.today != nil },
            Step(name: "낙서 쪽지 보내기 (3초 안에 또는 안 감)", wait: 30) {
                guard chats.contains("qa-go doodle"), let f = friend else { return nil }
                return DoodleCenter.send(doodle, to: .friend(f.id)) && !DoodleCenter.send(doodle, to: .friend(f.id))
            },
            Step(name: "낙서 쪽지 받기·5초 뒤 사라짐", wait: 30, check: shownThenGone { doodles >= 1 }),
            // First: the friend takes one chat a second, and qa-voice follows the last of these steps.
            Step(name: "그룹 뽑기 보내기", wait: 5) {
                GroupDraw.shared.items = ["QA 김밥", "QA 라면", "QA 우동", "QA 쫄면"]
                guard GroupDraw.shared.start(), let r = GroupDraw.shared.book.records.last, let f = friend else { return false }
                log("drawn \(drawn(r))")
                return bus.chat("qa-draw " + drawn(r), to: f.id)
            },
            Step(name: "투척물 5개 던지기", wait: 20) {
                guard let f = friend, let s = FriendRoom.shared.seats.first(where: { $0.id == f.id }) else { return nil }
                for _ in 0..<StunRule.hits { FriendRoom.shared.throwAt(s) }
                return true
            },
            Step(name: "친구 기절 별 보임 (KO 동기화)", wait: 30) {
                guard let f = friend, !kos.isEmpty else { return nil }
                log("shot ko-stars")
                return FriendRoom.shared.seats.first { $0.id == f.id }?.koUntil != nil && kos.first == Int(StunRule.seconds)
            },
            Step(name: "사진 보내기 (근처)", wait: 20, run: {
                guard let f = friend, let d = qaPhoto() else { return }
                bus.sendPhoto(d, to: f.id) { why in log(why.map { "photo refused \($0)" } ?? "photo sent") }
            }) { SocialChat.shared.log[friend?.id ?? ""]?.contains { $0.mine && $0.photo != nil } == true ? true : nil },
            Step(name: "의자에 앉기 (친구에게 보임)", wait: 5, run: {
                ChairCenter.shared.choose(freeChair?.id)
                ChairCenter.shared.sit(true)
            }) { ChairCenter.shared.seat == freeChair?.id },
            Step(name: "무전기 30초 말하기·자동 끊김", wait: 45, run: {
                guard let f = friend else { return }
                talk = now
                bus.chat("qa-voice \(talk)", to: f.id)
                VoiceTalk.shared.begin(f.id)
                log("voice live \(VoiceTalk.shared.live != nil)")
            }) {
                guard VoiceTalk.shared.live == nil else { return nil }
                let s = now - talk
                log(String(format: "voice cut after %.2fs", s))
                return abs(s - VoiceTalk.maxSeconds) < 1
            },
            Step(name: "원격 지원 요청 → 거절", wait: 30, run: { friend.map { RemoteHelp.shared.ask($0.id) } }) {
                answers.first.map { !$0.accept }
            },
            Step(name: "원격 지원 요청 → 수락", wait: 30, run: { friend.map { RemoteHelp.shared.ask($0.id) } }) {
                answers.count >= 2 ? answers[1].accept : nil
            },
            Step(name: "같이 뛰기 초대 → 수락됨", wait: 40, run: { friend.map { NetPlay.shared.invite($0.id, .play) } }, check: {
                guard game == .play, PlayMode.shared.isPlaying, plays >= 20 else { return nil }
                log("shot together-run")
                return true
            }),
            Step(name: "같이 뛰기 친구가 끝내기 (playEnd)", wait: 30) { playEnds >= 1 && ended() == true ? true : nil },
            Step(name: "별 대결 초대 → 수락됨", wait: 40, run: {
                // The host's 같이 뛰기 has to be over first; a moment for its end to land.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { friend.map { NetPlay.shared.invite($0.id, .starDuel) } }
            }) {
                guard game == .starDuel, StarGame.shared.isOn else { return nil }
                logStars()
                log("shot star-duel")
                return true
            },
            Step(name: "별 줍기 → starTaken 보내기", wait: 30) {
                guard StarGame.shared.scores[0] == 0 else { logStars(); return true }
                // Stand P1 on the first star: the game's own touch test picks it up next frame.
                if let s = StarGame.shared.spots.first, let r = PlayMode.shared.player() {
                    PlayMode.shared.update(0) { $0.x = s.spot.center.x; $0.y = s.spot.center.y - r.height / 2; $0.vx = 0; $0.vy = 0 }
                }
                return nil
            },
            Step(name: "별 대결 내가 끝내기", wait: 5, run: { PlayMode.shared.end() }, check: ended),
            Step(name: "같이 뛰기 (침묵 테스트) 시작", wait: 40) {
                inviteWhen("silence")
                guard game == .play, PlayMode.shared.isPlaying, plays >= 10 else { return nil }
                log("ready silence")   // the script stops this process for 8 s
                return true
            },
            Step(name: "멈췄다 깨어난 뒤 종료", wait: 40, check: ended),
            Step(name: "같이 뛰기 (오프라인 테스트) 시작", wait: 40) {
                inviteWhen("offline")
                guard game == .play, PlayMode.shared.isPlaying, plays >= 10 else { return nil }
                log("ready offline")   // the script ends this process
                return true
            },
        ]
    }
    /// The 3-line 한마디 the first copy sends twice under one id (as cleaned: 200 characters).
    private static let longLine = MeetWire.chat("QA 첫 줄 " + String(repeating: "가", count: 70) + "\nQA 둘째 줄 " + String(repeating: "나", count: 70)
                                                + "\nQA 셋째 줄 " + String(repeating: "다", count: 70))

    /// 원격 모임 through the local relay. The first copy writes a 한마디 and sends a 낙서 쪽지; the other goes 퇴근한 척,
    /// draws its 운세 again and sends 🎉. Each side checks the other's events in its own log and notes. Then the first
    /// types for 8 s (입력 중), sends the 200-character 3-line 한마디, sends it again under the same id and a last line;
    /// the other sees the first's character in 친구 상주, the dots, the bubble over its head and the line only once.
    private static func meetSteps(first: Bool) -> [Step] {
        let meet = RemoteMeet.shared
        let talk = TalkLog.shared
        func seat(_ name: String) -> RoomSeat? { FriendRoom.shared.seats.first { $0.remote && $0.nickname == name && $0.panel?.isVisible == true } }
        func sent(_ text: String) -> Bool? { talk.entries.last { $0.mine && $0.text == text }?.state == .sent ? true : nil }
        var typingFrom: TimeInterval?
        func heard(_ e: MeetEvent) -> Bool { meet.log.contains { !$0.mine && $0.text == MeetWire.describe(e) } }
        func theirs() -> FriendNote? { meet.notes.values.first?.note }   // only others' notes are kept
        let start = [
            Step(name: "원격 모임 연결 (2명)", wait: 60) { meet.phase == .live(members: 2) ? true : nil },
            Step(name: "원격 모임 들어옴 받기", wait: 30) { heard(MeetEvent(kind: .hello, name: "")) ? true : nil },
        ]
        let off = MeetEvent(kind: .status, name: "", status: .off)
        if first {
            return start + [
                Step(name: "원격 오늘 한마디 보내기", wait: 5, run: { bus.setTodayLine("QA 원격 한마디") }) { bus.todayLine() == "QA 원격 한마디" },
                Step(name: "원격 퇴근한 척 → 퇴근 받기", wait: 30) { heard(off) ? true : nil },
                Step(name: "원격 운세 다시 뽑기 받기 (note)", wait: 30) { theirs()?.fortune == 1 ? true : nil },
                Step(name: "원격 낙서 쪽지 보내기", wait: 5) { DoodleCenter.send(doodle, to: .meet) },
                Step(name: "원격 🎉 받기", wait: 60) { heard(MeetEvent(kind: .emote, name: "", text: "🎉")) ? true : nil },
                Step(name: "원격 친구 상주에 B 캐릭터 (hello 모습)", wait: 30) { seat("QA맥B") != nil ? true : nil },
                Step(name: "원격 입력 중 보내기 (8초)", wait: 12) {
                    meet.typed()
                    typingFrom = typingFrom ?? now
                    return now - typingFrom! >= 8 ? true : nil
                },
                Step(name: "원격 200자 3줄 한마디 → 보냄", wait: 20, run: { meet.sendLine(longLine) }) { sent(longLine) },
                Step(name: "원격 같은 ID로 다시 보내기 → 보냄", wait: 20, run: {
                    guard let id = talk.entries.last(where: { $0.mine && $0.text == longLine })?.msgID else { return }
                    meet.sendLine(longLine, again: id)
                }) { talk.entries.filter { $0.mine && $0.text == longLine }.count == 1 ? sent(longLine) : false },
                // Two polls later: the bubble shows a member's latest line, and B checks the long one first.
                Step(name: "원격 끝 표시 보내기", wait: 25, run: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { meet.sendLine("QA 끝") }
                }) { sent("QA 끝") },
                Step(name: "원격 그룹 뽑기 보내기", wait: 5) {
                    GroupDraw.shared.items = ["QA 김밥", "QA 라면", "QA 우동"]
                    guard GroupDraw.shared.start(), let r = GroupDraw.shared.book.records.last else { return false }
                    log("drawn \(drawn(r))")
                    return true
                },
                Step(name: "원격 투척물 5개 → B", wait: 10) {
                    guard let b = meet.members.first(where: { $0.value.name == "QA맥B" })?.key else { return nil }
                    for _ in 0..<StunRule.hits { meet.sendHit(ThrowCenter.shared.item.wire, to: b) }
                    return true
                },
                Step(name: "원격 B 기절 별 보임 (KO 동기화)", wait: 40) {
                    guard let s = seat("QA맥B"), s.koUntil != nil else { return nil }
                    log("shot remote-ko")
                    return true
                },
            ]
        }
        return start + [
            Step(name: "원격 오늘 한마디 받기 (note)", wait: 30) { theirs()?.line == "QA 원격 한마디" ? true : nil },
            Step(name: "원격 퇴근한 척 보내기", wait: 5, run: { OfficeCenter.shared.set(.pretendOff) }) { bus.myStatus == .pretendOff },
            Step(name: "원격 운세 다시 뽑기 보내기", wait: 5, run: { Fortune.show(redraw: true) }) { Fortune.today().draw == 1 },
            Step(name: "원격 낙서 쪽지 받기·5초 뒤 사라짐", wait: 60,
                 check: shownThenGone { heard(MeetEvent(kind: .doodle, name: "", doodle: doodle)) }),
            Step(name: "원격 🎉 보내기", wait: 5, run: { meet.sendEmote("🎉") }) { meet.log.contains { $0.mine && $0.text == "🎉" } },
            Step(name: "원격 친구 상주에 A 캐릭터 (hello 모습)", wait: 30) { seat("QA맥A") != nil ? true : nil },
            Step(name: "원격 입력 중 받기", wait: 60) { meet.heardTyping > 0 ? true : nil },
            Step(name: "원격 200자 3줄 말풍선 받기 (머리 위)", wait: 60) {
                guard let s = seat("QA맥A"), s.talk.line == longLine else { return nil }
                log("shot remote-bubble")
                return s.bubble?.isVisible == true
            },
            Step(name: "원격 같은 ID 한마디는 한 번만", wait: 60) {
                guard talk.entries.contains(where: { !$0.mine && $0.text == "QA 끝" }) else { return nil }
                return talk.entries.filter { !$0.mine && $0.text == longLine }.count == 1
            },
            Step(name: "원격 그룹 뽑기 받기", wait: 40) {
                guard let r = GroupDraw.shared.book.records.last(where: { !$0.mine }) else { return nil }
                log("drawn \(drawn(r))")   // qa/relay-e2e.sh compares it with A's
                return true
            },
            Step(name: "원격 투척물 맞고 기절 → ko 보냄", wait: 40) {
                meet.log.contains { $0.mine && $0.text == MeetWire.describe(MeetEvent(kind: .ko, name: "")) } ? true : nil
            },
        ]
    }
}
#endif
