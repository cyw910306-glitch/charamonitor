import AppKit
import SwiftUI

extension DashboardSnapshot {
    /// 펫 키우기 states beyond the plain page: a furnished room on every section (pet-<tab>), the focus desk
    /// (pet-focus), a hungry pet (pet-hungry) and the 가출 letter (pet-away).
    /// The model's state is replaced for the run (AppDefaults is a throwaway suite here).
    static func renderPet(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        let model = PetModel.shared
        let saved = model.state
        defer { model.state = saved }
        let now = Date()
        func page(_ tab: PetTab) -> some View {
            PetHomeView(monitor: monitor, settings: settings, tab: tab, onBack: {}).frame(width: 400)
        }
        QARender.fullHeight = true
        defer { QARender.fullHeight = false }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for tab in PetTab.allCases {
                model.state = furnished(now: now, focus: tab == .focus)
                try snapshot(page(tab), appearance: appearance, to: dir.appendingPathComponent("pet-\(tab)-\(suffix).png"))
            }
            var hungry = PetState(now: now)
            hungry.adopted = true
            hungry.food = 18
            hungry.mood = 42
            model.state = hungry
            try snapshot(page(.shop), appearance: appearance, to: dir.appendingPathComponent("pet-hungry-\(suffix).png"))
            hungry.awaySince = now
            hungry.food = 0
            model.state = hungry
            try snapshot(page(.missions), appearance: appearance, to: dir.appendingPathComponent("pet-away-\(suffix).png"))
        }
    }

    /// A pet a few weeks in: level 16 (꽃 화관), a full room, a couple of missions done, a short diary.
    static func furnished(now: Date, focus: Bool) -> PetState {
        var s = PetState(now: now)
        s.adopted = true
        s.food = 72; s.mood = 88; s.energy = 54; s.clean = 31
        s.level = 16; s.xp = 120; s.coins = 230
        s.owned.formUnion(["window", "clock", "shelf", "plant", "desk", "lamp", "paper-mint", "floor-tile"])
        s.slots = ["window", "clock", "shelf", "bed", "desk", "plant"]
        s.wallpaper = "paper-mint"
        s.attendStreak = 6
        s.lastAttendDay = PetState.dayNumber(now)
        // Two of today's missions done, the third one short of its goal.
        var events: [PetEvent] = []
        for (i, kind) in s.today.missions.enumerated() {
            for _ in 0..<(i < 2 ? kind.target : kind.target - 1) { s.count(kind, events: &events) }
        }
        s.coins = 230
        // The same keys PetState.diaryLine uses, so the English render reads English.
        let lines = [[L("밥 \(3)번"), L("쓰다듬기 \(4)번"), L("집중 \(2)번")].joined(separator: ", ") + "." + L(" 미션 \(3)개 완료.") + L(" 코인 \(62)개."),
                     [L("밥 \(2)번"), L("목욕 \(1)번"), L("쉬는 시간 \(3)번")].joined(separator: ", ") + "." + L(" 미션 \(2)개 완료.")
                        + L(" 레벨 \(16)까지 컸어요.") + L(" 코인 \(45)개."),
                     L("조용한 하루였어요.")]
        s.diary = lines.enumerated().map { i, text in
            PetDiaryEntry(day: s.today.day - i - 1, date: now.addingTimeInterval(-Double(i + 1) * 86_400), text: text)
        }
        for (back, n) in [(1, 2), (2, 4), (3, 1), (5, 3), (8, 1), (9, 2), (15, 1), (22, 3), (30, 2)] { s.focusLog[s.today.day - back] = n }
        if focus { s.focus = PetFocus(mode: .work, endsAt: now.addingTimeInterval(17 * 60 + 40)) }
        return s
    }
}
