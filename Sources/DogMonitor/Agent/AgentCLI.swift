import Foundation

#if !MAS   // QA through this Mac's AI CLIs: the App Store build runs no other programs (2.5.2)
/// --agent-plan "부탁" [--engine claude-cli|codex-cli|gemini-cli] [--contact "이름=주소|이름=주소"] [--pointed "보낸사람 주소"]
/// [--history "q1|q2"]: one proposal from the owner's connected AI, printed raw and as the parsed plan. Nothing runs and
/// nothing is saved: QA for the planner prompt and the eval set (uses the owner's AI usage).
enum AgentCLI {
    static func run(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--agent-plan"), i + 1 < args.count else {
            fputs("사용법: DogMonitor --agent-plan \"부탁\" [--engine claude-cli] [--contact \"이름=주소|…\"] [--pointed 주소] [--history \"q1|q2\"]\n", stderr)
            exit(2)
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func list(_ flag: String) -> [String] { value(flag)?.components(separatedBy: "|").filter { !$0.isEmpty } ?? [] }
        let words = args[i + 1]
        let name = (value("--engine") ?? "claude-cli").replacingOccurrences(of: "-cli", with: "")
        guard let provider = BYOProvider(rawValue: name) else { fputs("엔진: claude-cli, codex-cli, gemini-cli\n", stderr); exit(2) }
        var contacts: [String: [String]] = [:]
        for pair in list("--contact") {
            let p = pair.components(separatedBy: "=")
            if p.count == 2 { contacts[p[0], default: []].append(p[1]) }
        }
        let history = list("--history").map { ChatTurn(user: $0, reply: "") }
        let persona = Persona(name: "젤리", style: .friendly)
        let now = Date()
        var engine = BYOEngine(provider: provider, method: .cli, model: provider.defaultModel)
        engine.fallback = nil
        Task {
            let t0 = Date()
            do {
                let json = try await engine.plan(system: AgentPlanner.system(persona: persona),
                                                 prompt: AgentPlanner.prompt(ownerWords: words, history: history, now: now))
                let raw = String(decoding: (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
                print(String(format: "== 원문 (%.1f초)\n", Date().timeIntervalSince(t0)) + raw)
                let plan = AgentPlanner.parse(json, ownerWords: words, pointedFrom: value("--pointed"), lookup: { contacts[$0] ?? [] }, now: now)
                print("== say\n\(plan.say)")
                if !plan.ask.isEmpty { print("== ask\n" + plan.ask.joined(separator: " / ")) }
                if let a = plan.action {
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    enc.dateEncodingStrategy = .iso8601
                    print("== action \(a.type.rawValue)\n" + String(decoding: (try? enc.encode(a)) ?? Data(), as: UTF8.self))
                    let concerns = AgentGuard.check(a, origin: .chat, proposedAt: now, now: Date(), ownerWords: words,
                                                    todayCounts: AgentGuard.Counts(), receivedTexts: [], knownAirport: Airports.isKnown)
                    let decision = AgentPolicy.decide(a, origin: .chat, settings: AgentPolicy.Settings(), ownerAddresses: [],
                                                      ruleUsesToday: [:], concerns: concerns, now: Date())
                    print("== 판정 \(decision.tier.label)" + (concerns.isEmpty ? "" : " · " + concerns.map(\.message).joined(separator: " / ")))
                    let t1 = Date()
                    let v = await ActionReviewer.review(engine: engine, ownerWords: words, action: a, origin: .chat)
                    print(String(format: "== 2차 검토 (%.1f초) ", Date().timeIntervalSince(t1)) + (v.map { "\($0.kind.rawValue): \($0.reason)" } ?? "못 함"))
                } else {
                    print("== action 없음")
                }
                exit(0)
            } catch {
                print("== 오류: \((error as? ChatError)?.message ?? "\(error)")")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}

/// --agent-run "부탁" [--model sonnet] [--steps 20]: one v2 tool run with the claude CLI and an offscreen browser (no
/// cookies, no personal reads). Every card is printed and answered "취소" (nothing is clicked, sent or saved): QA for
/// the loop's choices and the tool host's tiers. Uses the owner's AI usage.
extension AgentCLI {
    static func runTools(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--agent-run"), i + 1 < args.count else {
            fputs("사용법: DogMonitor --agent-run \"부탁\" [--model sonnet] [--steps 20]\n", stderr)
            exit(2)
        }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let words = args[i + 1]
        let t0 = Date()
        func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(t0)) }
        Task { @MainActor in
            let browser = AgentBrowser(offscreen: true)
            let host = AgentToolHost(ownerWords: words, browser: browser, reads: nil) { action, origin, _, _ in
                print("\(stamp()) == 카드 (\(origin.rawValue)) \(ActionReviewer.describe(action).replacingOccurrences(of: "\n", with: " | "))")
                return .cancelled
            }
            var limits = LoopLimits()
            limits.steps = value("--steps").flatMap(Int.init) ?? 20
            limits.seconds = 6 * 60
            let tools = AgentTools.available(personal: false, browser: true)
            let run = ClaudeAgentRun(system: AgentToolHost.system(persona: Persona(name: "젤리", style: .friendly), browser: true, personal: false),
                                     tools: tools, host: host, limits: limits, model: value("--model")) { e in
                switch e {
                case .thinking: break
                case .say(let s): print("\(stamp()) 말: \(s.prefix(200))")
                case .tool(let n, let note): print("\(stamp()) 도구 \(n) \(note)")
                }
            }
            let stop = await run.run(prompt: AgentCenter.runPrompt(words, history: [], now: Date(), context: []))
            print("\(stamp()) == 끝: \(stop)")
            if let page = try? await browser.snapshot() { print("== 마지막 페이지 \(page.url)") }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}
#endif
