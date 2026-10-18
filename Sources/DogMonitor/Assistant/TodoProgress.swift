import Foundation

/// Today's to-dos (미리알림): how many are done of how many. `done` counts reminders completed today, `total` adds the
/// ones still open that are due today (CalendarLink.todayProgress). Pure.
struct TodoProgress: Equatable {
    var done: Int
    var total: Int

    var allDone: Bool { total > 0 && done >= total }

    /// What a friend says when the count moved from `old` to `new`: a fresh tick gets "벌써 2/4!", the last one a
    /// special line in the persona's way; nil for the first read, nothing new, or fewer done (one was unticked).
    static func milestone(old: TodoProgress?, new: TodoProgress, style: PersonaStyle) -> String? {
        guard let old, new.done > old.done, new.total > 0 else { return nil }
        let d = new.done, t = new.total
        if new.allDone {
            switch style {
            case .proud: return L("뭐야, 오늘 할 일 \(t)개 다 끝냈어? 흥, 제법인걸.")
            case .shy: return L("오늘 할 일 \(t)개 다 했네… 정말 대단해.")
            case .bright: return L("오늘 할 일 \(t)개 완주! 최고야!")
            case .calm: return L("오늘 할 일 \(t)개 다 했어. 수고했어.")
            case .polite: return L("오늘 할 일 \(t)개를 다 끝내셨어요. 정말 수고하셨어요!")
            case .auto, .friendly, .cry: return L("오늘 할 일 \(t)개 다 끝냈어! 정말 잘했어.")
            }
        }
        switch style {
        case .proud: return L("흠! 벌써 \(d)/\(t)! 나쁘지 않네.")
        case .polite: return L("벌써 \(d)/\(t)! 잘 가고 계세요.")
        default: return L("벌써 \(d)/\(t)! 잘 가고 있어.")
        }
    }

    /// "오늘 할 일 얼마나 했어?": nil `p` = reminders not connected.
    static func answer(_ p: TodoProgress?, polite: Bool) -> String {
        func say(_ banmal: String, _ yo: String) -> String { polite ? yo : banmal }
        guard let p else {
            return say(L("미리알림이 연결돼 있지 않아서 몰라. 비서 설정에서 미리알림을 켜 줘."),
                       L("미리알림이 연결돼 있지 않아서 알 수 없어요. 비서 설정에서 미리알림을 켜 주세요."))
        }
        if p.total == 0 { return say(L("오늘까지 할 일은 없어."), L("오늘까지 할 일은 없어요.")) }
        if p.allDone { return say(L("오늘 할 일 \(p.total)개 다 했어!"), L("오늘 할 일 \(p.total)개를 다 했어요!")) }
        return say(L("오늘 할 일 \(p.total)개 중 \(p.done)개 했어. \(p.total - p.done)개 남았어."),
                   L("오늘 할 일 \(p.total)개 중 \(p.done)개 했어요. \(p.total - p.done)개 남았어요."))
    }

    /// "지금 할 일 뭐 있어?": the first open one to start with, then the rest as bullets (at most 3 in all).
    static func next(_ titles: [String], polite: Bool) -> String {
        guard let first = titles.first else {
            return polite ? L("오늘 남은 할 일은 없어요.") : L("오늘 남은 할 일은 없어.")
        }
        let head = polite ? L("지금은 '\(first)'부터 해 보면 좋겠어요.") : L("지금은 '\(first)'부터 해 보자.")
        return ([head] + titles.dropFirst().prefix(2).map { "• " + $0 }).joined(separator: "\n")
    }
}
