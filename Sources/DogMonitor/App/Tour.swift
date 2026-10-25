import Foundation

/// 첫 실행 말풍선 투어: the character explains itself in four bubbles under the menu bar icon; a click on the bubble
/// shows the next. "tourSeen" is set only once the first bubble really showed (a call app in front mutes it, so the
/// next launch tries again). 설정 > 사용법 다시 보기 starts it over.
enum Tour {
    static let seenKey = "tourSeen"
    /// Seconds a tour bubble waits for its click (the usual 6 to 15 s is too short to read and find the next).
    static let stay: TimeInterval = 60

    /// The step showing and its exact words; a click on any other bubble just closes it.
    private(set) static var step: Int?
    private static var shown: String?
    /// 사용법 다시 보기: the user asked, so it shows even while muted (잠시 조용히, a call app in front).
    private static var asked = false

    /// The four lines, banmal or 존댓말; the last invites a first question.
    static func lines(polite: Bool) -> [String] {
        let pairs = [
            (L("(1/4) 맥이 바쁘면 내가 뛰고, 한가하면 쉬어. 말풍선을 누르면 다음 이야기야."),
             L("(1/4) 맥이 바쁘면 제가 뛰고, 한가하면 쉬어요. 말풍선을 누르면 다음 이야기예요.")),
            (L("(2/4) 메뉴바의 나를 누르면 대시보드가 열려."), L("(2/4) 메뉴바의 저를 누르면 대시보드가 열려요.")),
            (L("(3/4) 캐릭터는 대시보드의 캐릭터 선택에서 바꿀 수 있어."), L("(3/4) 캐릭터는 대시보드의 캐릭터 선택에서 바꿀 수 있어요.")),
            (L("(4/4) 대시보드의 AI 비서에서 나한테 말 걸어 봐."), L("(4/4) 대시보드의 AI 비서에서 저한테 말 걸어 보세요.")),
        ]
        return pairs.map { polite ? $0.1 : $0.0 }
    }

    /// 3 s after launch, unless it was seen.
    static func startIfNew(_ d: UserDefaults = AppDefaults.store) {
        guard !d.bool(forKey: seenKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { start(d) }
    }

    /// From the first step. Main thread. `asked`: 사용법 다시 보기, shown even while muted.
    static func start(_ d: UserDefaults = AppDefaults.store, on center: SpeechBubbleCenter = .shared, asked: Bool = false) {
        let before = self.asked
        self.asked = asked
        if show(0, on: center) { d.set(true, forKey: seenKey) } else { self.asked = before }
    }

    /// A click on the bubble showing `text`: the next step, true when the tour took the click. Main thread.
    @discardableResult
    static func advance(_ text: String, on center: SpeechBubbleCenter = .shared) -> Bool {
        guard let s = step, text == shown else { return false }
        if s + 1 < 4 { _ = show(s + 1, on: center) } else { step = nil; shown = nil; center.dismiss() }
        return true
    }

    private static func show(_ i: Int, on center: SpeechBubbleCenter) -> Bool {
        let persona = AssistantModel.persona()
        let line = lines(polite: !persona.style.banmal)[i]
        // The step mark stays first; the character's flair goes on the words after it.
        let mark = String(line.prefix(6)), text = mark + persona.flavor(String(line.dropFirst(6)))
        // Under the menu bar icon even while the 커서 친구 is on: the steps talk about that icon.
        guard center.say(text: text, source: .system, repeats: true, hold: true, seconds: stay, atIcon: true, asked: asked) else { return false }
        step = i
        shown = text
        return true
    }
}

/// 업데이트 후 한마디: the first launch of a newer version says `line` once. A first install only remembers the version.
enum WhatsNew {
    static let key = "lastSeenVersion"
    /// This release's one-liner; empty = say nothing. Change it per release.
    static let line = L("별 줍기의 별이 더 높이, 하늘까지 떠요. 놀이 기술을 켜고 ↑를 꾹 눌러 날아서 잡아 보세요.")

    /// Whether `current` is newer than the version seen last. Pure.
    static func announces(last: String?, current: String) -> Bool {
        guard let last else { return false }
        return last.compare(current, options: .numeric) == .orderedAscending
    }

    /// Keys a build before this one wrote ("assistant.nudges" is set on every 2.1+ launch). Read in
    /// applicationWillFinishLaunching, before AssistantSettings writes them for this launch.
    static let upgradeMarkers = AssistantSettings.upgradeMarkers + ["assistant.nudges"]

    /// An update from a build before lastSeenVersion existed: it counts as an update (so `line` shows) and the
    /// tour is skipped, since they already know the character.
    static func noteUpgrade(_ d: UserDefaults = AppDefaults.store) {
        guard d.string(forKey: key) == nil, upgradeMarkers.contains(where: { d.object(forKey: $0) != nil }) else { return }
        d.set("0", forKey: key)
        d.set(true, forKey: Tour.seenKey)
    }

    /// At launch. The tour, when it still has to show, goes first and this waits for the next update.
    static func check(_ d: UserDefaults = AppDefaults.store) {
        let last = d.string(forKey: key), current = AppInfo.version
        d.set(current, forKey: key)
        guard announces(last: last, current: current), !line.isEmpty, d.bool(forKey: Tour.seenKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            SpeechBubbleCenter.shared.say(text: L("업데이트됐어요! ") + line, source: .system)
        }
    }
}
