import Foundation

/// --assistant-ask "질문" [--style calm] [--nudge] [--personal "15:00 회의|18:30 저녁"]
/// [--inbox "14:05 문자 엄마: 저녁 먹었어?|10/3 23:50 알림 카카오톡: 밥|메일: 꺼짐|문자: 권한 풀림|문자: 미리보기 꺼짐"] [--previous "앞 질문"]
/// [--busy "Xcode|Safari" (busiest apps; "" = none busy; left out = measured here, as the app does)] [--calendar-on] [--intent-debug (routing only)]: one real answer from this Mac's engine, printed with the intent, the prompt, the raw
/// model text and what the chat would show. For tuning the prompt; nothing is saved and nothing personal is read (the
/// calendar and inbox lines are only what the flags pass, InboxReport.made). Uses Apple Intelligence on this Mac (free), never the cloud.
enum AssistantCLI {
    static func run(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--assistant-ask"), i + 1 < args.count else {
            fputs("사용법: DogMonitor --assistant-ask \"질문\" [--style friendly|calm|shy|proud|bright|polite] [--nudge] [--personal \"a|b\"] [--inbox \"a|b\"] [--previous \"앞 질문\"] [--history \"q1|q2\"] [--busy \"a|b\"] [--calendar-on] [--work-hours] [--intent-debug]\n", stderr)
            exit(2)
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func list(_ flag: String) -> [String] { value(flag)?.components(separatedBy: "|").filter { !$0.isEmpty } ?? [] }
        let question = args[i + 1]
        let style = value("--style").flatMap(PersonaStyle.init) ?? .friendly
        let persona = Persona(name: "젤리", style: style)
        let monitor = SystemMonitor()
        monitor.sampleNow()
        #if !MAS   // busy apps as the app has them: two samples of the owner's processes, a second apart
        if !args.contains("--busy") { RunawayTracker.shared.sample() }
        #endif
        Thread.sleep(forTimeInterval: 1)
        #if !MAS
        if !args.contains("--busy") { RunawayTracker.shared.sample() }
        #endif
        let snap = monitor.sampleNow()
        let history = (list("--history") + (value("--previous").map { [$0] } ?? [])).map { ChatTurn(user: $0, reply: "") }
        var request = ChatRequest(persona: persona, summary: "", history: history, facts: SystemSnapshotText.lines(snap, busyApps: args.contains("--busy") ? list("--busy") : SystemSnapshotText.busyApps()), personal: list("--personal"), question: question)
        request.hints = SystemSnapshotText.verdicts(snap)
        if request.resolvedIntent == .inbox, args.contains("--inbox") {
            request.inbox = InboxReport.made(list("--inbox"), query: request.inboxQuery, now: request.now)
        }
        request.calendarLinked = args.contains("--calendar-on") || !request.personal.isEmpty
        request.remindersLinked = request.calendarLinked
        if args.contains("--work-hours") { var w = WorkHours(); w.greet = [.leave]; request.workHours = w }   // 퇴근 18:00
        print("== 의도: \(request.resolvedIntent.rawValue)" + (TemplateEngine.fixed(request) != nil ? " (고정 답변)" : ""))
        if args.contains("--intent-debug") { exit(0) }   // routing only, no model
        if Pivot.applies(request) { print("== 영어 경유: 영어로 답을 얻은 뒤 캐릭터 말투로 옮김") }
        print("== 엔진: \(OnDeviceEngine.unavailableReason ?? "온디바이스")\n== 지시문\n\(persona.instructions)\n== 프롬프트\n\(request.prompt)")
        Task {
            let t0 = Date()
            if args.contains("--nudge") {
                do {
                    let raw = try await OnDeviceEngine.shared.line(persona, situation: question)
                    print(String(format: "== 원문 (%.2f초)\n", Date().timeIntervalSince(t0)) + raw)
                    print("== 화면\n" + AssistantPrompt.clean(raw, persona: persona, max: 120))
                    exit(0)
                } catch {
                    print("== 오류: \(error)")
                    exit(1)
                }
            }
            // --engine claude-cli|codex-cli|gemini-cli: 내 AI 연결 through this Mac's signed-in CLI, no fallback (QA).
            var engine: ChatEngine = OnDeviceEngine.shared
            var req = request
            #if !MAS   // the App Store build runs no other programs (2.5.2)
            if let name = value("--engine"), let p = BYOProvider(rawValue: name.replacingOccurrences(of: "-cli", with: "")) {
                var byo = BYOEngine(provider: p, method: .cli, model: p.defaultModel)
                byo.fallback = nil
                engine = byo
                req.strong = true
                req.maxCharacters = AssistantPrompt.strongAnswer
                print("== 엔진: 내 AI 연결 \(p.label) CLI\n== 프롬프트(강한 모델)\n\(req.prompt)")
            }
            #endif
            let r = await AssistantAnswer.make(req, engine: engine)
            if let e = r.error {
                print("== 오류: \(e.message)\n== 기본 답변\n" + r.text)
                exit(1)
            }
            print(String(format: "== 원문 (%.2f초)\n", Date().timeIntervalSince(t0)) + (r.raw ?? "(고정 답변, 모델 안 씀)"))
            print("== 화면\n" + r.text)
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}
