import AppKit
import SwiftUI

extension DashboardSnapshot {
    /// AI 비서 QA: assistant-chat (a sample conversation), assistant-settings-{plain|full} (whole page) and the
    /// speech bubble (bubble). The sample answers are written here, not by a model.
    static func renderAssistant(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        let model = MainActor.assumeIsolated { AssistantModel.shared }
        defer {
            MainActor.assumeIsolated { model.clear() }; QARender.fullHeight = false
            BYOSettings.shared.provider = nil; BYOSettings.shared.lastFailure = nil; MailAccounts.shared.showForQA([], [:])
        }
        let facts = FactChips.chips(["CPU: 23.4%", "메모리: 66.0% (15.8 GB / 24.0 GB, 압력 보통)", "저장 공간: 1.73 TB 남음 (전체 2.00 TB)", "배터리: 54% (충전 중)", "발열: 보통"])
        MainActor.assumeIsolated {
            model.messages = [
                ChatMessage(role: .user, text: appIsEnglish ? "Why is my Mac slow?" : "내 맥 왜 느려?"),
                ChatMessage(role: .character, text: appIsEnglish ? "I don't see a clear reason in the numbers. CPU and memory both have room. It's been on a while, so how about a restart?"
                                                     : "지금 숫자로는 느릴 이유가 딱히 안 보여. CPU도 메모리도 여유 있거든. 오래 켜 뒀으니 한 번 재시동해 보는 건 어때?",
                            chips: facts, actions: [.activityMonitor]),
                ChatMessage(role: .user, text: appIsEnglish ? "Anything to clean up in storage?" : "저장 공간 정리할 거 있어?"),
                ChatMessage(role: .notice, text: ChatError.rateLimited.message),
                ChatMessage(role: .character, text: appIsEnglish ? "You have 1.73 TB left. If you still want to tidy up, let's look in the Cleaner together."
                                                     : "저장 공간은 1.73 TB 남았어. 그래도 정리하고 싶으면 클리너에서 같이 보자.", chips: facts, actions: [.cleaner]),
                ChatMessage(role: .user, text: appIsEnglish ? "Any texts?" : "문자 온 거 있어?"),
                ChatMessage(role: .character, text: TemplateEngine.answer(Self.inboxSample)),
            ]
        }
        let width = { (v: any View) in AnyView(v.frame(width: 400)) }
        AssistantSettings.shared.nudges = .rarely   // a new install's default (the suite's own writes look like an update)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            QARender.fullHeight = true   // the whole conversation, down to the 문자 answer
            try snapshot(width(AssistantView(monitor: monitor, settings: settings, onBack: {})), appearance: appearance,
                         to: dir.appendingPathComponent("assistant-chat-\(suffix).png"))
            // plain: a new install; full: every option set up.
            for (full, state) in [(false, "plain"), (true, "full")] {
                AssistantSettings.shared.phone = full   // the iPhone options (ntfy QR) on the full render
                #if !MAS
                // 문자·알림·메일 on, so the full render shows their options (QA's own defaults suite, not the user's).
                InboxSettings.shared.messages = full
                InboxSettings.shared.notifications = full
                AssistantSettings.shared.mail = full
                #endif
                // 내 AI (Claude, API 키, with a fallback reason) and two 메일 계정 (one fine, one whose login failed) on the full render.
                BYOSettings.shared.provider = full ? .claude : nil
                BYOSettings.shared.method = .apiKey
                BYOSettings.shared.lastFailure = full ? ChatError.rateLimited.message : nil
                let gmail = MailAccount(preset: .gmail, host: MailPreset.gmail.host, port: 993, user: "jelly.sample@gmail.com", on: true)
                let naver = MailAccount(preset: .naver, host: MailPreset.naver.host, port: 993, user: "jellysample", on: true)
                MailAccounts.shared.showForQA(full ? [gmail, naver] : [],
                                              full ? [gmail.id: .ok(Date()), naver.id: .login(L("로그인에 실패했어요. ") + MailPreset.naver.help)] : [:])
                try snapshot(width(AssistantView(monitor: monitor, settings: settings, onBack: {}, startOnSettings: true)), appearance: appearance,
                             to: dir.appendingPathComponent("assistant-settings-\(state)-\(suffix).png"))
            }
            QARender.fullHeight = false
            try snapshot(SpeechBubbleView(text: Nudge.batteryLow(9).templates(polite: false)[0]), appearance: appearance,
                         to: dir.appendingPathComponent("bubble-\(suffix).png"))
            try snapshot(SpeechBubbleView(text: Nudge.calendar(title: appIsEnglish ? "Design review" : "디자인 리뷰", minutes: 10).templates(polite: false)[0]), appearance: appearance,
                         to: dir.appendingPathComponent("bubble-short-\(suffix).png"))
            #if !MAS
            let mom = appIsEnglish ? "Mom" : "엄마"
            let text = InboxLine.line([InboxItem(kind: .message, who: mom, preview: appIsEnglish ? "Did you have dinner? Coming home late today?" : "저녁 먹었어? 오늘 늦게 와? 반찬 해 놨어", date: Date())], polite: false) ?? ""
            try snapshot(SpeechBubbleView(text: text), appearance: appearance, to: dir.appendingPathComponent("bubble-inbox-\(suffix).png"))
            #endif
        }
    }

    /// QA_ONLY=extras: the moments and settings added together. 설정 whole (사용법 다시 보기·문제 보내기) and its
    /// 문제 보내기 sheet, 비서 설정 with 대사 고치기 open, 출근·점심·퇴근 on and 일정 알림 시점, a chat
    /// ending in 응원해 줘 with the quick chips, the 집중 잔디, the creator with 울음소리 말투, and the new bubbles.
    static func renderExtras(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        let a = AssistantSettings.shared, model = MainActor.assumeIsolated { AssistantModel.shared }
        defer {
            MainActor.assumeIsolated { model.clear() }; QARender.fullHeight = false
            AssistantSettingsView.qaShowLines = false; a.lines = [:]; a.workHours = WorkHours(); a.calendar = false
        }
        let width = { (v: any View) in AnyView(v.frame(width: 400)) }
        settings.character = .dog
        a.workHours.greet = Set(WorkHours.Kind.allCases)
        a.calendar = true
        a.calendarLeads = [15, 5]
        a.lines = [LineOverrides.slots[0].id: "배터리 {배터리}% 남았어! 충전 부탁해."]
        AssistantSettingsView.qaShowLines = true
        let cheer = TemplateEngine.cheerLines[0].0
        MainActor.assumeIsolated {
            model.messages = [ChatMessage(role: .user, text: AssistantView.starters[4]), ChatMessage(role: .character, text: cheer)]
        }
        // A saved custom character with its own 울음소리, opened in the creator.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dogmonitor-qa-\(UUID().uuidString)", isDirectory: true)
        let store = CustomCharacterStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = ProcessInfo.processInfo.environment["QA_CHARACTER"] ?? "my-dog/jelly-avatar.jpg"
        let cut = CustomSprite.load(url: URL(fileURLWithPath: path)).flatMap { CustomSprite.cutout($0) }
        let crying = try cut.map { try store.save(name: "사진 젤리", lightRim: false, inputs: [.normal: $0], voice: .cry, cries: ["멍!", "왕왕"]) }

        let bubbles: [(String, String)] = [
            ("tour-first", Tour.lines(polite: false)[0]), ("tour-last-polite", Tour.lines(polite: true)[3]),
            ("whatsnew", L("업데이트됐어요! ") + WhatsNew.line),
            ("calendar-moment", Nudge.calendar(title: "디자인 리뷰", minutes: 15, place: "3층 회의실").templates(polite: false)[0]),
            ("morning", Nudge.morning(brief: "오늘 일정 2개 · 첫 일정 10:00 '팀 회의' · 미리알림 3개").templates(polite: true)[0]),
            ("lunch", Nudge.lunch.templates(polite: false)[0]), ("leave", Nudge.leave(minutes: 10).templates(polite: true)[0]),
            ("dance", TemplateEngine.danceLines[3].0), ("cheer-polite", TemplateEngine.cheerLines[3].1),
            ("cry", Persona(name: "젤리", style: .cry, cries: ["멍!"]).dress(Nudge.batteryLow(9).templates(polite: false)[0])),
        ]
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            func shot(_ v: any View, _ name: String) throws {
                try snapshot(AnyView(v), appearance: appearance, to: dir.appendingPathComponent("extras-\(name)-\(suffix).png"))
            }
            QARender.fullHeight = true
            try shot(width(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .settings)), "settings")
            let report = MainActor.assumeIsolated { Diagnostics.report() }
            try shot(HelpSheet(report: report, onClose: {}).frame(width: 400, height: 420), "help-sheet")
            try shot(GuideSheet(onTour: {}, onClose: {}).frame(width: 400, height: 480), "guide-sheet")
            try shot(width(AssistantView(monitor: monitor, settings: settings, onBack: {})), "chat-chips")
            try shot(width(AssistantView(monitor: monitor, settings: settings, onBack: {}, startOnSettings: true)), "assistant-settings")
            PetModel.shared.state = furnished(now: Date(), focus: false)
            try shot(width(PetHomeView(monitor: monitor, settings: settings, tab: .focus, onBack: {})), "pet-focus")
            if let crying {
                try shot(width(CharacterCreatorView(settings: settings, store: store, editing: crying, onDone: {})), "creator-cry")
            }
            QARender.fullHeight = false
            for (name, text) in bubbles { try shot(SpeechBubbleView(text: text), "bubble-\(name)") }
        }
    }

    /// "문자 온 거 있어?" with two made-up texts and a mail, as InboxCenter.report finds them.
    @MainActor static var inboxSample: ChatRequest {
        var r = ChatRequest(persona: AssistantModel.persona(), summary: "", history: [], facts: [], personal: [], question: "문자 온 거 있어?")
        r.intent = .inbox
        r.inbox = InboxReport.made(appIsEnglish ? ["14:05 문자 Mom: Did you have dinner?", "13:40 문자 Jamie Park: Running late"]
                                                : ["14:05 문자 엄마: 저녁 먹었어? 오늘 늦게 와?", "13:40 문자 박지훈: 10분 늦어요"],
                                   query: r.inboxQuery, now: Date())
        return r
    }
}
