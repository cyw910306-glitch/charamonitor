import Foundation

// The chat's "가장 최근에 온 문자 알려줘": what an inbox question asks for (InboxQuery), what the app found right then
// (InboxReport, filled by InboxCenter.report), and the answer said from it without a model (InboxReport.answer).
// Measured 2026-10-04: the model echoed the question back, and one line "nothing new in 6 hours" hid both the texts
// that came before the app started and a 전체 디스크 접근 permission lost in an update. Pure, so all of it is tested.

/// What an inbox question asks for.
struct InboxQuery: Equatable {
    var kinds: Set<InboxItem.Kind> = [.message, .mail, .notification]
    /// A kind was named (문자, 메일, 카톡): a switched-off kind is brought up only then.
    var named = false
    var limit = 3
    /// Already shown ("더 보여줘" after three): skipped.
    var skip = 0
    /// Sender or app, any of these spellings.
    var who: [String] = []
    /// Said with 한테서 or 가 보낸 (or an app named): applied even when nobody matches. A bare "엄마 문자" applies only
    /// when someone matches, so "광고 문자" or a word read wrong never hides everything.
    var strictWho = false
    var period: DateInterval?
    var periodName: String?
    /// "안 읽은 거 있어?": the app cannot tell read from unread for texts and notifications, so the answer says so.
    var unread = false

    static let maxLimit = 5
    static let kindWords: [(InboxItem.Kind, [String])] = [
        (.message, ["문자", "메시지", "메세지", "sms", "imessage", "text"]),
        (.mail, ["메일", "mail"]),
        (.notification, ["알림", "카톡", "카카오톡", "슬랙", "텔레그램", "디엠", "notification", "slack", " dm"]),
    ]
    static let apps: [([String], [String])] = [(["카톡", "카카오톡"], ["카카오톡", "kakaotalk"]), (["슬랙", "slack"], ["slack", "슬랙"]),
                                              (["텔레그램", "telegram"], ["telegram", "텔레그램"])]
    static let lastWords = ["마지막", "가장 최근", "제일 최근", "젤 최근", "방금 온", "latest", "last "]
    static let moreWords = ["더 보여", "더 알려", "더 읽어", "더 있", "더 줘", "더 없", "나머지", "그 전", "그전", "이전 거", "more"]
    /// Words that come before 문자 or 한테 without being a sender ("최근 문자", "나한테 온").
    static let notNames: Set<String> = ["최근", "최근에", "마지막", "마지막에", "받은", "새로", "새로온", "방금", "아까", "오늘", "어제", "가장",
                                        "제일", "그럼", "그러면", "그러니깐", "그러니까", "그니까", "무슨", "어떤", "누구", "누가", "누", "안읽은",
                                        "읽은", "모든", "전체", "다른", "단체", "광고", "나", "내", "저", "제", "우리", "혹시", "지금", "최신", "이번",
                                        "새", "온", "그", "이", "문자", "메일", "알림", "카톡", "메시지", "메세지", "the", "new", "my", "any"]

    /// `previous`: the question before, when it was an inbox one ("그럼 메일은?", "더 보여줘" keep what it asked).
    static func parse(_ question: String, previous: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> InboxQuery {
        var q = previous.map { parse($0, now: now, calendar: calendar) } ?? InboxQuery()
        let s = question.lowercased(), tight = s.filter { !$0.isWhitespace }
        // " dm" stays a word: "who texted me" squeezed has "dm" in it.
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) || !$0.hasPrefix(" ") && tight.contains($0.filter { !$0.isWhitespace }) } }

        let named = kindWords.filter { has($0.1) }.map(\.0)
        if !named.isEmpty, Set(named) != q.kinds || !q.named {
            q.kinds = Set(named); q.named = true; q.skip = 0; q.who = []; q.strictWho = false
        }
        if let app = apps.first(where: { has($0.0) }) { q.who = app.1; q.strictWho = true }
        if let name = sender(question, follow: previous != nil) {
            q.who = [name.0]; q.strictWho = name.strict; q.skip = 0
        }

        if previous != nil, has(moreWords) {
            q.skip += q.limit
            q.limit = maxLimit
        } else if let n = count(s) {
            q.limit = n; q.skip = 0
        } else if has(["다 보여", "다 알려", "다 읽어", "전부", "모두", "all "]) {
            q.limit = maxLimit; q.skip = 0
        } else if has(lastWords) {
            q.limit = 1; q.skip = 0
        } else if previous == nil, has(["누구", "누가", "who"]) {
            q.limit = maxLimit   // "누구한테 연락 왔어?": every sender there is, not three of four (measured 2026-10-04)
        }
        q.unread = has(["안 읽은", "안읽은", "unread"])

        let today = calendar.startOfDay(for: now)
        if has(["오늘", "today"]) {
            q.period = DateInterval(start: today, end: max(today, now)); q.periodName = L("오늘")
        } else if has(["어제", "yesterday"]), let y = calendar.date(byAdding: .day, value: -1, to: today) {
            q.period = DateInterval(start: y, end: today); q.periodName = L("어제")
        }
        return q
    }

    /// "엄마한테서 온 문자", "철수가 보낸 메일" (strict), "엄마 문자" (soft), and after an inbox question "엄마는?" (soft).
    static func sender(_ question: String, follow: Bool) -> (String, strict: Bool)? {
        let s = question.lowercased()
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
            let w = String(s[r])
            return notNames.contains(w) ? nil : w
        }
        if let w = first(#"(?:^|\s)([가-힣a-z0-9]{1,12}?)\s*(?:님)?\s*(?:한테서|한테|에게서|에게|으로부터|로부터|이 보낸|가 보낸)"#) { return (w, true) }
        if let w = first(#"(?:^|\s)([가-힣a-z]{2,12}?)\s*(?:님\s*)?(?:문자|메시지|메세지|메일|카톡|이메일)"#) { return (w, false) }
        if follow, let w = first(#"^\s*([가-힣a-z]{2,12}?)\s*(?:은|는)\s*\??\s*$"#), !kindWords.contains(where: { $0.1.contains(w) }) { return (w, false) }
        return nil
    }

    /// "3개", "두 통" -> 3, 2 (at most maxLimit). Not "몇 통".
    static func count(_ s: String) -> Int? {
        let words = ["한": 1, "두": 2, "세": 3, "네": 4, "다섯": 5, "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9, "열": 10]
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,2}|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)\s*(?:개|건|통|줄)"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        let w = String(s[r])
        guard let n = Int(w) ?? words[w], n > 0 else { return nil }
        return min(n, maxLimit)
    }

    func matches(_ i: InboxItem) -> Bool {
        who.contains { w in i.who.lowercased().contains(w) || (i.kind == .notification && i.preview?.lowercased().contains(w) == true) }
    }

    /// The asked ones, newest first, whether the sender filter was used, and whether more matched than were picked.
    func pick(_ items: [InboxItem]) -> (items: [InboxItem], byWho: Bool, more: Bool) {
        var m = items.filter { kinds.contains($0.kind) && (period?.contains($0.date) ?? true) }
        var byWho = false
        if !who.isEmpty {
            let hit = m.filter(matches)
            if strictWho || !hit.isEmpty { m = hit; byWho = true }
        }
        m.sort { $0.date > $1.date }
        // One left over is shown, not held back behind "더 있어" (measured 2026-10-04: 3 of 4, the 4th one dropped).
        let take = limit > 1 && m.count == skip + limit + 1 ? limit + 1 : limit
        return (Array(m.dropFirst(skip).prefix(take)), byWho, m.count > skip + take)
    }
}

/// What the app found for one inbox question, and how each asked kind stands.
struct InboxReport: Equatable {
    enum State: Equatable {
        case off                // its switch is off in 비서 설정
        case denied             // 전체 디스크 접근 never given
        case deniedAfterUpdate  // it worked before: an update re-signed the app
        case missing            // the database is not where this macOS keeps it
        case unavailable        // the App Store build cannot read it at all
        case ok
    }
    var query = InboxQuery()
    /// The answer's items, newest first (query.pick already applied).
    var items: [InboxItem] = []
    var states: [InboxItem.Kind: State] = [:]
    /// Kinds whose preview switch is off: their items carry no text.
    var previewOff: Set<InboxItem.Kind> = []
    var byWho = false
    /// More matched than the answer shows ("더 보여줘" goes on).
    var more = false
    /// What the app knows of a kind without single items ("안 읽은 메일 3통 (이지은, GitHub)"), said as is.
    var notes: [InboxItem.Kind: String] = [:]

    /// The same findings for `q`: all that was found goes in, the query picks.
    func answering(_ q: InboxQuery, found: [InboxItem]) -> InboxReport {
        var r = self
        r.query = q
        (r.items, r.byWho, r.more) = q.pick(found.map { var i = $0; if previewOff.contains(i.kind) { i.preview = nil }; return i })
        return r
    }

    /// --assistant-ask --inbox lines, made up: "14:05 문자 엄마: 저녁 먹었어?", "09:12 네이버 메일 이지은: 견적서" (a mail
    /// account's name before 메일), "10/3 23:50 알림 카카오톡: 엄마: 밥 먹었니" (a time with no date is today's), states
    /// "문자: 꺼짐" | "권한 없음" | "읽을 수 없음 (…)" | "권한 풀림" | "기록 없음" | "없음" | "미리보기 꺼짐", any other
    /// "메일: …" or a line naming kinds ("최근 6시간 동안 새로 온 문자·메일·알림은 없음") as a note said as is.
    /// Kinds never mentioned are off.
    static func made(_ lines: [String], query: InboxQuery, now: Date) -> InboxReport {
        var r = InboxReport(), found: [InboxItem] = []
        let kindOf: [String: InboxItem.Kind] = ["문자": .message, "메일": .mail, "알림": .notification]
        let cal = Calendar.current
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) {
            // "[M/d ]HH:mm [계정] 문자 who[: text]"
            var words = line.split(separator: " ").map(String.init)
            var day = cal.startOfDay(for: now)
            if let md = words.first, md.contains("/") {
                let n = md.split(separator: "/").compactMap { Int($0) }
                guard n.count == 2 else { continue }
                var c = cal.dateComponents([.year], from: now); c.month = n[0]; c.day = n[1]
                day = cal.date(from: c) ?? day
                if day > now { day = cal.date(byAdding: .year, value: -1, to: day) ?? day }
                words.removeFirst()
            }
            let hm = words.first?.split(separator: ":").compactMap { Int($0) } ?? []
            if hm.count == 2, words.count >= 3 {
                var via: String?
                var k = kindOf[words[1]]
                if k == nil, words.count >= 4, words[2] == "메일" { k = .mail; via = words[1] + " 메일" }
                guard let k else { continue }
                let body = words.dropFirst(via == nil ? 2 : 3).joined(separator: " ")
                let colon = body.range(of: ": ")
                found.append(InboxItem(kind: k, who: colon.map { String(body[..<$0.lowerBound]) } ?? body,
                                       preview: colon.map { String(body[$0.upperBound...]) },
                                       date: day.addingTimeInterval(TimeInterval(hm[0] * 3600 + hm[1] * 60)), via: via))
                r.states[k] = r.states[k] ?? .ok
                continue
            }
            if let colon = line.range(of: ": "), let k = kindOf[String(line[..<colon.lowerBound])] {
                let v = String(line[colon.upperBound...])
                if v.hasPrefix("미리보기 꺼짐") { r.previewOff.insert(k); r.states[k] = r.states[k] ?? .ok }
                else if v.hasPrefix("권한 풀림") { r.states[k] = .deniedAfterUpdate }
                else if v.hasPrefix("권한 없음") || v.hasPrefix("읽을 수 없음") { r.states[k] = .denied }
                else if v.hasPrefix("꺼짐") { r.states[k] = .off }
                else if v.hasPrefix("기록 없음") { r.states[k] = .missing }
                else if v == "없음" { r.states[k] = r.states[k] ?? .ok }
                else { r.notes[k] = v; r.states[k] = r.states[k] ?? .ok }
                continue
            }
            for (word, k) in kindOf where line.contains(word) { r.notes[k] = line; r.states[k] = r.states[k] ?? .ok }
        }
        for k in [InboxItem.Kind.message, .mail, .notification] where r.states[k] == nil { r.states[k] = .off }
        return r.answering(query, found: found)
    }

    // MARK: The answer

    static func noun(_ k: InboxItem.Kind) -> String { k == .message ? L("문자") : k == .mail ? L("메일") : L("알림") }

    /// "14:05" today, "10/3 23:50" before.
    static func time(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    /// The whole answer, as the app has it. Several items go one per line.
    func answer(polite: Bool, now: Date = Date()) -> String {
        func say(_ banmal: String, _ yo: String) -> String { polite ? yo : banmal }
        let q = query
        let asked = [InboxItem.Kind.message, .mail, .notification].filter(q.kinds.contains)
        func state(_ k: InboxItem.Kind) -> State { states[k] ?? .off }
        func list(_ ks: [InboxItem.Kind]) -> String { ks.map(Self.noun).joined(separator: "·") }
        func obj(_ ks: [InboxItem.Kind]) -> String { let w = list(ks); return w + Banmal.particle(w, "을", "를") }
        func top(_ ks: [InboxItem.Kind]) -> String { let w = list(ks); return w + Banmal.particle(w, "은", "는") }

        // Why some asked kinds cannot be read. A kind nobody named is brought up only when it is on but unreadable.
        var why: [String] = []
        let readable = asked.filter { state($0) == .ok }
        let off = asked.filter { state($0) == .off }
        if !off.isEmpty, q.named || readable.isEmpty && off.count == asked.count {
            let switches = off.map { k -> String in
                switch k {
                case .message: return L("'문자 메시지 알려주기'")
                case .notification: return L("'다른 앱 알림 알려주기'")
                case .mail:
                    #if MAS
                    return L("'메일 계정'")
                    #else
                    return L("'Apple Mail 새 메일 알림'이나 '메일 계정'")
                    #endif
                }
            }.joined(separator: ", ")
            why.append(say(L("\(list(off)) 연동이 꺼져 있어서 지금은 볼 수 없어. 비서 설정에서 \(switches)\(Self.objectParticle(switches)) 켜 줘."),
                           L("\(list(off)) 연동이 꺼져 있어서 지금은 볼 수 없어요. 비서 설정에서 \(switches)\(Self.objectParticle(switches)) 켜 주세요.")))
        }
        let place = L("시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근")
        let lost = asked.filter { state($0) == .deniedAfterUpdate }
        if !lost.isEmpty {
            why.append(say(L("업데이트하면서 전체 디스크 접근 권한이 풀려서 지금은 \(obj(lost)) 읽을 수 없어. \(place)에서 캐릭모니터를 다시 켜 줘."),
                           L("업데이트하면서 전체 디스크 접근 권한이 풀려서 지금은 \(obj(lost)) 읽을 수 없어요. \(place)에서 캐릭모니터를 다시 켜 주세요.")))
        }
        let denied = asked.filter { state($0) == .denied }
        if !denied.isEmpty {
            why.append(say(L("전체 디스크 접근 권한이 없어서 지금은 \(obj(denied)) 읽을 수 없어. \(place)에서 캐릭모니터를 켜 줘."),
                           L("전체 디스크 접근 권한이 없어서 지금은 \(obj(denied)) 읽을 수 없어요. \(place)에서 캐릭모니터를 켜 주세요.")))
        }
        if state(.message) == .missing, asked.contains(.message) {
            why.append(say(L("이 맥에서 메시지 기록을 찾지 못했어. 메시지 앱에 로그인했는지 확인해 줘."),
                           L("이 맥에서 메시지 기록을 찾지 못했어요. 메시지 앱에 로그인했는지 확인해 주세요.")))
        }
        if state(.notification) == .missing, asked.contains(.notification) {
            why.append(say(L("이 macOS에서는 알림 기록 위치가 바뀌어서 아직 알림을 읽을 수 없어."),
                           L("이 macOS에서는 알림 기록 위치가 바뀌어서 아직 알림을 읽을 수 없어요.")))
        }
        let store = asked.filter { state($0) == .unavailable }
        if !store.isEmpty, q.named || readable.isEmpty {
            why.append(say(L("App Store 버전은 \(obj(store)) 읽을 수 없어. 메일은 비서 설정의 메일 계정에서 연결할 수 있어."),
                           L("App Store 버전은 \(obj(store)) 읽을 수 없어요. 메일은 비서 설정의 메일 계정에서 연결할 수 있어요.")))
        }

        var out: [String] = []
        // "엄마한테서", "카카오톡에서".
        let whoFrom: String? = byWho ? q.who.first.map { w in
            InboxQuery.apps.contains { $0.1.contains(w) } ? L("\(Self.appShown(w))에서") : L("\(w)한테서")
        } : nil
        let from = { (i: InboxItem) in i.kind == .notification ? L("\(i.who)에서") : L("\(i.who)한테서") }
        if items.isEmpty {
            // What the app knows without items, said as is ("최근 6시간 동안 … 없음" says how far it looked).
            let noted = readable.compactMap { notes[$0] }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            out += noted.map { Self.said($0, polite: polite) }
            // Read and found nothing: said per kind, with what narrowed it.
            let none = readable.filter { $0 != .mail && notes[$0] == nil }
            if let whoFrom, !none.isEmpty {
                // Only the recent ones are read: "none from 엄마" among them, never "엄마 never texted" (measured 2026-10-04).
                let seen = (q.periodName.map { L("\($0) 받은 ") } ?? L("최근 받은 ")) + list(none)
                out.append(say(L("\(seen) 중엔 \(whoFrom) 온 게 없어."), L("\(seen) 중엔 \(whoFrom) 온 게 없어요.")))
            } else if !none.isEmpty {
                let head = q.skip > 0 ? L("그 전에 받은 ") : q.periodName.map { L("\($0) 받은 ") } ?? L("최근에 받은 ")
                out.append(say(L("\(head)\(top(none)) 없어."), L("\(head)\(top(none)) 없어요.")))
            }
            if readable.contains(.mail), notes[.mail] == nil {
                out.append(say(L("앱이 켜진 뒤로 새로 온 메일은 아직 없어."), L("앱이 켜진 뒤로 새로 온 메일은 아직 없어요.")))
            }
            if out.isEmpty && why.isEmpty {
                out.append(say(L("받은 메일이나 문자는 지금 내가 볼 수 없어. 비서 설정의 연동에서 켜 줘."),
                               L("받은 메일이나 문자는 지금 제가 볼 수 없어요. 비서 설정의 연동에서 켜 주세요.")))
            }
            return (why + out).joined(separator: " ")
        }

        let shownKinds = [InboxItem.Kind.message, .mail, .notification].filter { k in items.contains { $0.kind == k } }
        let unreadUnknown = q.unread && shownKinds.contains(where: { $0 != .mail })
        if unreadUnknown, items.count == 1 {
            out.append(say(L("읽었는지는 내가 알 수 없어서 최근 받은 걸 알려 줄게."), L("읽었는지는 제가 알 수 없어서 최근 받은 걸 알려 드릴게요.")))
        }
        if items.count == 1, !more || q.limit == 1 {
            let i = items[0], t = Self.time(i.date, now: now), n = Self.noun(i.kind)
            let text = i.preview.map { ": " + InboxLine.short($0, max: 100) } ?? "."
            if byWho {
                out.append(say(L("\(from(i)) \(t)에 온 \(n)\(Banmal.particle(n, "이야", "야"))"), L("\(from(i)) \(t)에 온 \(n)\(Banmal.particle(n, "이에요", "예요"))")) + text)
            } else if q.skip > 0 {
                out.append(say(L("그 전 \(n)\(Banmal.particle(n, "은", "는")) \(from(i)) \(t)에 온 거야"), L("그 전 \(n)\(Banmal.particle(n, "은", "는")) \(from(i)) \(t)에 온 거예요")) + text)
            } else if q.limit == 1 {
                let lead = (q.periodName.map { $0 + " " } ?? "") + L("가장 최근 \(n)\(Banmal.particle(n, "은", "는"))")
                out.append(say(L("\(lead) \(from(i)) \(t)에 온 거야"), L("\(lead) \(from(i)) \(t)에 온 거예요")) + text)
            } else {
                let lead = (q.periodName.map { L("\($0) 받은 ") } ?? L("최근 받은 ")) + top([i.kind])
                out.append(say(L("\(lead) 이거 하나야. \(from(i)) \(t)에 왔어"), L("\(lead) 이거 하나예요. \(from(i)) \(t)에 왔어요")) + text)
            }
        } else {
            let what = list(shownKinds), c = items.count
            // More matched than shown: "중 최근 3개", never a count that sounds like all of them (measured: "3개야" of 4).
            let n = more ? L("중 최근 \(c)개") : L("\(c)개")
            let head = q.skip > 0 ? L("그 전 \(what) \(c)개") : whoFrom.map { L("\($0) 온 \(what) \(n)") }
                ?? (q.periodName.map { L("\($0) 받은 \(what) \(n)") } ?? (more ? L("받은 \(what) \(n)") : L("최근 받은 \(what) \(n)")))
            // "안 읽은 거": one sentence that says what the list is instead (measured: four sentences before the list).
            out.append(unreadUnknown ? say(L("읽었는지는 내가 알 수 없어서 \(head)\(Banmal.particle(head, "을", "를")) 알려 줄게."),
                                           L("읽었는지는 제가 알 수 없어서 \(head)\(Banmal.particle(head, "을", "를")) 알려 드릴게요."))
                                     : say(L("\(head)야."), L("\(head)예요.")))
            for i in items {
                let tag = shownKinds.count > 1 ? Self.noun(i.kind) + " " : ""
                out.append("\(Self.time(i.date, now: now)) \(tag)\(i.who)" + (i.preview.map { ": " + InboxLine.short($0, max: 60) } ?? ""))
            }
        }
        // Preview off: only who and when, and where to turn it on.
        let hidden = shownKinds.filter(previewOff.contains)
        if !hidden.isEmpty {
            let toggles = hidden.map { $0 == .message ? L("'내용 미리보기'") : $0 == .notification ? L("'제목과 내용 미리보기'") : L("'메일 제목도 말하기'") }
                .joined(separator: ", ")
            out.append(say(L("\(list(hidden)) 내용 보기가 꺼져 있어서 보낸 사람과 시각만 알려 줬어. 내용까지 들으려면 비서 설정에서 \(toggles)\(Self.objectParticle(toggles)) 켜 줘."),
                           L("\(list(hidden)) 내용 보기가 꺼져 있어서 보낸 사람과 시각만 알려 드렸어요. 내용까지 들으시려면 비서 설정에서 \(toggles)\(Self.objectParticle(toggles)) 켜 주세요.")))
        }
        if more, q.limit > 1 { out.append(say(L("더 있어. '더 보여줘'라고 하면 이어서 알려 줄게."), L("더 있어요. '더 보여줘'라고 하시면 이어서 알려 드릴게요."))) }
        out += why
        return out.joined(separator: "\n")
    }

    /// A note as a sentence: "…없음" -> "…없어", "안 읽은 메일 3통 (이지은, GitHub)" -> "안 읽은 메일 3통이야: 이지은, GitHub."
    static func said(_ note: String, polite: Bool) -> String {
        if let open = note.range(of: " ("), note.hasSuffix(")") {
            let head = String(note[..<open.lowerBound]), inner = String(note[open.upperBound...].dropLast())
            let be = polite ? Banmal.particle(head, "이에요", "예요") : Banmal.particle(head, "이야", "야")
            return "\(head)\(be): \(inner)."
        }
        let s = AssistantPrompt.natural(note, polite: polite)
        return s + (".!?".contains(s.last ?? ".") ? "" : ".")
    }

    /// 을/를 after a quoted name ("'메일 계정'을").
    static func objectParticle(_ quoted: String) -> String { Banmal.particle(quoted.filter { $0 != "'" }, "을", "를") }

    /// "카카오톡" for the alias the question used.
    static func appShown(_ alias: String) -> String {
        alias == "kakaotalk" ? L("카카오톡") : alias == "slack" ? "Slack" : alias == "telegram" ? "Telegram" : alias
    }
}
