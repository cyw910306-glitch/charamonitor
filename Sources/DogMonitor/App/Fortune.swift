import AppKit
import SwiftUI

/// One day's 오늘의 운세: a headline for the bubble, one line per area for the card, a lucky item and color.
/// Made only from (day, draw), so the same day reads the same after a restart and on a friend's Mac.
struct FortuneReading: Equatable {
    struct Area: Equatable {
        let name: String
        let line: String
    }

    let day: String
    /// 0 the day's first draw, 1 after 다시 뽑기.
    let draw: Int
    let headline: String
    let areas: [Area]
    let item: String
    let color: String
    /// 3 to 5: 운세 is never bad here.
    let stars: Int
}

/// 오늘의 운세: one draw a day seeded by the date, one 다시 뽑기 a day. The lines are our own, office humor, never ominous.
/// Pure apart from `today`/`redraw`/`show`, which keep the day's draw in AppDefaults.store ("fortune.*").
enum Fortune {
    static let redrawsPerDay = 1
    /// The morning nudge comes in the first app minute between these hours.
    static let morningHours = 5..<12

    // MARK: lines

    static var headlines: [String] {
        [L("오늘은 메일 답장이 술술 써지는 날이에요."), L("회의가 예정보다 5분 일찍 끝날 기운이 보여요."),
         L("커피가 유난히 맛있게 내려지는 하루예요."), L("오늘 한 일은 내일의 내가 고마워할 거예요."),
         L("퇴근 시간이 평소보다 가깝게 느껴지는 날이에요."), L("미뤄 둔 일 하나가 생각보다 금방 끝나요."),
         L("엘리베이터 운이 좋아요. 기다리면 바로 와요."), L("작은 칭찬 하나가 하루를 데워 줄 거예요."),
         L("키보드가 손에 착 붙는 날이에요. 오타도 적어요."), L("점심 메뉴 고민이 3초 만에 끝나는 날이에요."),
         L("오늘의 나는 생각보다 일을 잘해요."), L("할 일 목록에 체크 표시가 늘어나는 기운이 있어요."),
         L("와이파이도 나도 오늘은 신호가 좋아요."), L("느긋하게 시작해도 결국 다 해내는 날이에요."),
         L("누군가 내 자리에 간식을 두고 갈지도 몰라요.")]
    }

    static var work: [String] {
        [L("첫 메일 하나만 보내면 나머지는 따라와요."), L("회의록은 내가 쓰면 칭찬받아요."),
         L("파일 이름을 잘 지어 두면 오후가 편해요."), L("어려운 일은 오전에, 쉬운 일은 오후에."),
         L("저장 버튼을 자주 누르면 행운이 따라요."), L("오늘 고친 문제는 다시 안 나와요."),
         L("질문 하나가 한 시간을 아껴 줘요."), L("슬라이드 한 장을 덜면 발표가 가벼워져요."),
         L("답장은 짧게, 인사는 다정하게."), L("탭을 몇 개 닫으면 머리도 맑아져요."),
         L("오늘 정한 마감은 여유 있게 지켜져요."), L("미뤄 둔 그 일, 10분만 해 보면 반은 끝나요.")]
    }

    static var money: [String] {
        [L("커피 쿠폰 도장이 하나 더 찍히는 날이에요."), L("장바구니는 하루 묵히면 더 현명해져요."),
         L("잊고 있던 포인트를 발견할 수 있어요."), L("오늘의 지출은 나를 위한 작은 투자예요."),
         L("무료 배송 기준을 딱 맞출 운이에요."), L("주머니에서 반가운 동전이 나와요."),
         L("구독 하나를 점검하면 지갑이 웃어요."), L("할인 알림이 반가운 소식을 가져와요."),
         L("오늘은 사는 것보다 아끼는 게 더 신나요."), L("영수증을 챙기면 나중에 도움이 돼요.")]
    }

    static var people: [String] {
        [L("먼저 건넨 인사가 좋은 대화로 이어져요."), L("옆자리 동료와 웃을 일이 생겨요."),
         L("오랜만에 연락 온 사람이 반가운 소식을 줘요."), L("고맙다는 말 한마디가 두 배로 돌아와요."),
         L("오늘은 들어 주는 쪽이 이기는 날이에요."), L("이모티콘 하나로 분위기가 풀려요."),
         L("점심을 같이 먹는 사람과 더 친해져요."), L("부탁할 일이 있다면 오늘이 좋아요."),
         L("칭찬은 구체적으로 하면 효과가 커요."), L("단톡방에서 내 농담이 통해요.")]
    }

    static var snack: [String] {
        [L("오후 3시의 초콜릿 한 조각이 기운을 줘요."), L("따뜻한 차 한 잔이 머리를 맑게 해요."),
         L("바삭한 과자가 회의 뒤 피로를 씻어 줘요."), L("오늘은 과일 간식이 행운을 불러요."),
         L("편의점 신상 간식이 성공할 확률이 높아요."), L("물을 한 잔 더 마시면 컨디션이 올라가요."),
         L("달콤한 빵은 반만 먹고 반은 나눠 주세요."), L("아이스보다 따뜻한 음료가 잘 맞아요."),
         L("견과류 한 줌이 오후를 버티게 해 줘요."), L("간식 서랍을 정리하면 숨은 보물이 나와요.")]
    }

    static var items: [String] {
        [L("노란 포스트잇"), L("파란 볼펜"), L("머그컵"), L("무선 이어폰"), L("핸드크림"), L("형광펜"),
         L("텀블러"), L("사원증 줄"), L("스테이플러"), L("작은 화분"), L("귤"), L("보조 배터리")]
    }

    static var colors: [String] {
        [L("하늘색"), L("민트"), L("귤색"), L("연두"), L("라벤더"), L("크림색"), L("남색"), L("살구색"), L("버건디"), L("레몬색")]
    }

    /// Every line a reading can carry (the tests count them and look for repeats).
    static var allLines: [String] { headlines + work + money + people + snack + items + colors }

    // MARK: drawing

    /// The reading for `day` ("2026-10-24") and `draw`. Each field steps by a nonzero amount per draw, so 다시 뽑기
    /// always changes every line.
    static func reading(day: String, draw: Int) -> FortuneReading {
        let seed = fnv(day)
        func pick(_ pool: [String], _ slot: UInt64) -> String {
            let n = pool.count
            let base = Int(mix(seed &+ slot &* 2) % UInt64(n))
            let step = 1 + Int(mix(seed &+ slot &* 2 &+ 1) % UInt64(n - 1))
            return pool[(base + draw * step) % n]
        }
        let areas = [(L("업무"), work), (L("돈"), money), (L("사람"), people), (L("간식"), snack)]
            .enumerated().map { FortuneReading.Area(name: $0.element.0, line: pick($0.element.1, UInt64($0.offset + 1))) }
        return FortuneReading(day: day, draw: draw, headline: pick(headlines, 0), areas: areas, item: pick(items, 5), color: pick(colors, 6),
                              stars: 3 + Int(mix(seed &+ 100 &+ UInt64(draw)) % 3))
    }

    /// Which draw `day` is on, given the saved (day, draw): a new day starts at 0.
    static func draw(on day: String, savedDay: String?, savedDraw: Int) -> Int {
        savedDay == day ? min(max(savedDraw, 0), redrawsPerDay) : 0
    }

    /// The morning nudge: on, in the morning, and today's 운세 not shown yet.
    static func morningDue(on: Bool, hour: Int, day: String, shownDay: String?) -> Bool {
        on && morningHours.contains(hour) && shownDay != day
    }

    /// 64-bit FNV-1a: stable across launches and Macs (Hasher is seeded per process).
    static func fnv(_ s: String) -> UInt64 {
        s.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// SplitMix64's finalizer.
    static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    // MARK: today (AppDefaults.store)

    /// Today's reading as it stands (after a 다시 뽑기, the new one). Other features read this.
    static func today(now: Date = Date(), store: UserDefaults = AppDefaults.store) -> FortuneReading {
        let day = WorkHours.day(now)
        return reading(day: day, draw: draw(on: day, savedDay: store.string(forKey: "fortune.day"), savedDraw: store.integer(forKey: "fortune.draw")))
    }

    static func canRedraw(now: Date = Date(), store: UserDefaults = AppDefaults.store) -> Bool {
        today(now: now, store: store).draw < redrawsPerDay
    }

    /// 다시 뽑기: the new reading, or nil when today's is used up.
    @discardableResult
    static func redraw(now: Date = Date(), store: UserDefaults = AppDefaults.store) -> FortuneReading? {
        let cur = today(now: now, store: store)
        guard cur.draw < redrawsPerDay else { return nil }
        store.set(cur.day, forKey: "fortune.day")
        store.set(cur.draw + 1, forKey: "fortune.draw")
        return today(now: now, store: store)
    }

    // MARK: app

    /// 오늘의 운세 ▸ 보기 / 다시 뽑기, for every friend's right-click menu (FriendMenu.build).
    static func menuItems() -> [NSMenuItem] {
        let again = canRedraw()
        let redo = FriendMenu.item(again ? L("다시 뽑기 (하루 한 번)") : L("다시 뽑기는 내일 또 돼요")) { show(redraw: true) }
        if !again { redo.action = nil }   // the menu greys out an item with no action
        return [FriendMenu.item(L("오늘 운세 보기")) { show() }, redo]
    }

    /// The headline in a bubble over the speaking friend, the card under it. Asked from a menu, it shows even when muted;
    /// the bubble panel never appears in a screen share or recording anyway (SpeechBubbleWindow).
    static func show(redraw again: Bool = false, asked: Bool = true) {
        let r = again ? (redraw() ?? today()) : today()
        if again { SocialBus.shared.shareNote() }   // friends' cards follow the new draw
        AppDefaults.store.set(r.day, forKey: "fortune.shown")
        let title = r.draw > 0 ? L("다시 뽑은 운세") : L("오늘의 운세")
        SpeechBubbleCenter.shared.say(text: "\(title): \(r.headline)", source: .system, aloud: false, repeats: true, seconds: 15,
                                      fortune: r, anchor: DesktopFriends.speaker, asked: asked)
    }

    /// Once a minute (AssistantCenter): the morning 운세, when 설정 has it on. Skipped in a call or a recording.
    static func morningCheck(now: Date = Date()) {
        let day = WorkHours.day(now)
        guard morningDue(on: AssistantSettings.shared.fortuneMorning, hour: Calendar.current.component(.hour, from: now), day: day,
                         shownDay: AppDefaults.store.string(forKey: "fortune.shown")),
              !SpeechBubbleCenter.shared.isMuted(), !FriendVisit.quiet() else { return }
        show(asked: false)
    }

    /// QA (--render-fortune): today's bubble and its 다시 뽑기, light and dark.
    static func renderQA(to dir: URL) throws {
        let day = WorkHours.day(Date())
        for draw in 0...redrawsPerDay {
            let r = reading(day: day, draw: draw)
            let view = SpeechBubbleView(text: "\(draw > 0 ? L("다시 뽑은 운세") : L("오늘의 운세")): \(r.headline)", tailUp: false, tailDown: true, fortune: r)
            for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try DashboardSnapshot.snapshot(view, appearance: look, to: dir.appendingPathComponent("fortune-\(draw)-\(name).png"))
            }
        }
    }
}

/// The small card under a 운세 bubble: stars, one line per area, the lucky item and color.
struct FortuneCardView: View {
    let reading: FortuneReading

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(repeating: "★", count: reading.stars) + String(repeating: "☆", count: 5 - reading.stars))
                .font(.system(size: 12)).foregroundStyle(Color(red: 0.95, green: 0.68, blue: 0.1))
                .accessibilityLabel(L("별 \(reading.stars)개"))
            ForEach(reading.areas, id: \.name) { a in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(a.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: appIsEnglish ? 40 : 26, alignment: .leading)
                    Text(a.line).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text(L("행운의 물건: \(reading.item) · 행운의 색: \(reading.color)")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
