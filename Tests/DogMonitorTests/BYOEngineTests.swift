import XCTest
@testable import DogMonitor

/// 내 AI 연결: API clients with a fake HTTP layer (no real network), the engine's fallback, the privacy gate,
/// the Keychain under a test-only service, and the CLI route against fake scripts.
final class BYOEngineTests: XCTestCase {
    private func ok(_ json: String, sent: @escaping (URLRequest) -> Void = { _ in }) -> BYOAPIClient.Transport {
        { r in sent(r); return (Data(json.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
    }

    private func status(_ code: Int) -> BYOAPIClient.Transport {
        { r in (Data("{}".utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!) }
    }

    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    private func request(_ q: String, personal: [String] = [], facts: [String] = ["CPU: 25.0%"]) -> ChatRequest {
        ChatRequest(persona: Persona(name: "젤리", style: .friendly), summary: "", history: [], facts: facts, personal: personal, question: q)
    }

    // MARK: Model lists

    func testPicksNewestOpusFirstForClaude() {
        let json = #"{"data":[{"id":"claude-haiku-4-5","created_at":"2025-10-01T00:00:00Z"},{"id":"claude-opus-5","created_at":"2026-03-01T00:00:00Z"},{"id":"claude-sonnet-5-5","created_at":"2026-09-01T00:00:00Z"},{"id":"claude-opus-5-5","created_at":"2026-08-01T00:00:00Z"},{"id":"claude-mythos-5-1","created_at":"2026-09-20T00:00:00Z"}]}"#
        XCTAssertEqual(BYOAPIClient.rankModels(.claude, Data(json.utf8)), ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-haiku-4-5"])
    }

    func testPicksNewestChatGPTAndSkipsNonChatAndSnapshots() {
        let json = #"{"data":[{"id":"gpt-6-astra","created":300},{"id":"gpt-6-astra-2026-07-01","created":400},{"id":"gpt-image-2","created":500},{"id":"gpt-5.5","created":100},{"id":"text-embedding-3-large","created":600},{"id":"gpt-realtime","created":700}]}"#
        XCTAssertEqual(BYOAPIClient.rankModels(.chatgpt, Data(json.utf8)), ["gpt-6-astra", "gpt-5.5"])
    }

    func testChatGPTFullModelBeforeMiniAndNanoNeverPro() {
        let json = #"{"data":[{"id":"gpt-5","created":100},{"id":"gpt-5-pro","created":300},{"id":"gpt-5-mini","created":200},{"id":"gpt-5-nano","created":250},{"id":"gpt-4.1","created":50}]}"#
        XCTAssertEqual(BYOAPIClient.rankModels(.chatgpt, Data(json.utf8)), ["gpt-5", "gpt-4.1", "gpt-5-mini", "gpt-5-nano"])
    }

    func testPicksNewestStableFlashForGemini() {
        let json = #"{"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/gemini-3.1-pro-preview","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-3.5-flash-lite","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},{"name":"models/gemini-3.8-flash-image","supportedGenerationMethods":["generateContent"]}]}"#
        XCTAssertEqual(BYOAPIClient.rankModels(.gemini, Data(json.utf8)),
                       ["gemini-3.8-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro-preview"])
    }

    func testModelListSendsTheKeyInAHeaderNeverTheURL() async throws {
        for p in BYOProvider.allCases {
            var seen: URLRequest?
            let json = p == .gemini ? #"{"models":[{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]}]}"#
                                    : #"{"data":[{"id":"\#(p == .claude ? "claude-opus-5-5" : "gpt-6-astra")","created":1}]}"#
            let list = try await BYOAPIClient(provider: p, key: "SECRET-KEY", transport: ok(json) { seen = $0 }).models()
            XCTAssertEqual(list.count, 1)
            let r = try XCTUnwrap(seen)
            XCTAssertFalse(r.url!.absoluteString.contains("SECRET-KEY"), "\(p)")
            let headers = r.allHTTPHeaderFields ?? [:]
            XCTAssertTrue(headers.values.contains { $0.contains("SECRET-KEY") }, "\(p)")
            if p == .gemini { XCTAssertEqual(headers["x-goog-api-key"], "SECRET-KEY") }
            if p == .claude { XCTAssertEqual(headers["anthropic-version"], "2023-06-01") }
        }
    }

    func testWrongKeyAndLimitsSayWhatToDo() async {
        for (code, word) in [(401, "API 키"), (403, "API 키"), (429, "한도"), (402, "크레딧"), (404, "모델")] {
            do {
                _ = try await BYOAPIClient(provider: .claude, key: "k", transport: status(code), pause: { _ in }).models()
                XCTFail("\(code)")
            } catch let e as ChatError {
                XCTAssertTrue(e.message.contains(word), "\(code): \(e.message)")
            } catch { XCTFail("\(error)") }
        }
        // Gemini answers a bad key with 400.
        XCTAssertTrue(BYOAPIClient.failure(.gemini, status: 400).message.contains("API 키"))
        do {
            _ = try await BYOAPIClient(provider: .gemini, key: "k", transport: { _ in throw URLError(.notConnectedToInternet) }).models()
            XCTFail("offline")
        } catch { XCTAssertEqual(error as? ChatError, .network) }
    }

    // MARK: Chat

    func testChatRequestShapes() throws {
        let c = try BYOAPIClient(provider: .claude, key: "k").chatRequest(model: "claude-opus-5-5", system: "SYS", prompt: "Q")
        XCTAssertEqual(c.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(body(c)["system"] as? String, "SYS")
        XCTAssertEqual((body(c)["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual((body(c)["messages"] as? [[String: String]])?.first?["content"], "Q")
        let h = try BYOAPIClient(provider: .claude, key: "k").chatRequest(model: "claude-haiku-4-5", system: "S", prompt: "Q")
        XCTAssertNil(body(h)["output_config"], "Haiku 4.5 rejects effort")

        let o = try BYOAPIClient(provider: .chatgpt, key: "k").chatRequest(model: "gpt-6-astra", system: "SYS", prompt: "Q")
        XCTAssertEqual(o.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(o.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(body(o)["instructions"] as? String, "SYS")
        XCTAssertEqual(body(o)["store"] as? Bool, false)

        let g = try BYOAPIClient(provider: .gemini, key: "k").chatRequest(model: "gemini-3.8-flash", system: "SYS", prompt: "Q")
        XCTAssertEqual(g.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertNotNil(body(g)["systemInstruction"])
    }

    func testRepliesKeepOnlyTheAnswerText() {
        let claude = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"CPU는 25%야."}]}"#
        XCTAssertEqual(BYOAPIClient.parseReply(.claude, Data(claude.utf8)), "CPU는 25%야.")
        let openai = #"{"output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"괜찮아."}]}]}"#
        XCTAssertEqual(BYOAPIClient.parseReply(.chatgpt, Data(openai.utf8)), "괜찮아.")
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"생각 중","thought":true},{"text":"좋아."}]}}]}"#
        XCTAssertEqual(BYOAPIClient.parseReply(.gemini, Data(gemini.utf8)), "좋아.")
        XCTAssertNil(BYOAPIClient.parseReply(.claude, Data(#"{"content":[]}"#.utf8)))
    }

    // MARK: Engine

    private struct Fixed: ChatEngine {
        var text: String
        let label = "fixed"
        func reply(_ request: ChatRequest) async throws -> String { text }
    }

    private final class Reports { var list: [String?] = [] }
    private final class Sent { var urls: [String] = []; var used: String? }

    func testAnswersWithMyAIAndOnlyTheQuestionsNumbers() async throws {
        var sent: URLRequest?
        let reports = Reports()
        var e = BYOEngine(provider: .claude, method: .apiKey, model: "claude-opus-5-5")
        e.key = { "k" }
        e.transport = ok(#"{"content":[{"type":"text","text":"지금 CPU는 25%야."}]}"#) { sent = $0 }
        e.fallback = Fixed(text: "이 맥")
        e.report = { reports.list.append($0) }
        let r = request("고래는 포유류야?", personal: ["15:00 비밀 회의"])
        let answer = try await e.reply(r)
        XCTAssertEqual(answer, "지금 CPU는 25%야.")
        XCTAssertEqual(reports.list, [nil])
        let b = String(decoding: try XCTUnwrap(sent?.httpBody), as: UTF8.self)
        XCTAssertFalse(b.contains("비밀 회의"), "calendar lines never go with a general question")
        XCTAssertFalse(b.contains("CPU: 25.0%"), "no Mac numbers for a non-Mac question")
        XCTAssertTrue(b.contains("고래는 포유류야?"))
    }

    func testFailureFallsBackToThisMacAndSaysWhy() async throws {
        let reports = Reports()
        var e = BYOEngine(provider: .chatgpt, method: .apiKey, model: "gpt-6-astra")
        e.key = { "k" }
        e.transport = status(401)
        e.fallback = Fixed(text: "이 맥의 답")
        e.report = { reports.list.append($0) }
        let answer = try await e.reply(request("안녕"))
        XCTAssertEqual(answer, "이 맥의 답")
        XCTAssertTrue(reports.list.first??.contains("API 키") ?? false)

        // No key saved, no Apple Intelligence: the error goes up so the chat shows the template answer and why.
        var bare = BYOEngine(provider: .gemini, method: .apiKey, model: "gemini-3.8-flash")
        bare.fallback = nil
        bare.report = { _ in }
        do { _ = try await bare.reply(request("안녕")); XCTFail("no key") } catch let err as ChatError {
            if case .unavailable(let why) = err { XCTAssertTrue(why.contains("API 키")) } else { XCTFail("\(err)") }
        }
        let shown = await AssistantAnswer.make(request("고래는 포유류야?"), engine: bare)   // "안녕" is a fixed answer now
        XCTAssertNotNil(shown.error)
        XCTAssertFalse(shown.text.isEmpty)
    }

    /// Gemini busy: the lite model from the 연결 확인 list answers once, and the engine says which model that was.
    func testBusyGeminiTriesLiteOnce() async throws {
        let sent = Sent()
        var e = BYOEngine(provider: .gemini, method: .apiKey, model: "gemini-3.8-flash")
        e.key = { "k" }
        e.availableModels = ["gemini-3.8-flash", "gemini-3.8-flash-lite"]
        e.transport = { r in
            sent.urls.append(r.url!.absoluteString)
            let lite = r.url!.absoluteString.contains("lite")
            let json = #"{"candidates":[{"content":{"parts":[{"text":"가볍게 답했어요"}]}}]}"#
            return (Data((lite ? json : "{}").utf8), HTTPURLResponse(url: r.url!, statusCode: lite ? 200 : 503, httpVersion: nil, headerFields: nil)!)
        }
        e.fallback = nil
        e.report = { _ in }
        e.answered = { sent.used = $0 }
        let answer = try await e.reply(request("고래는 포유류야?"))
        XCTAssertEqual(answer, "가볍게 답했어요")
        XCTAssertEqual(sent.used, "gemini-3.8-flash-lite")
        XCTAssertEqual(sent.urls.filter { $0.contains("lite") }.count, 1)
        XCTAssertNil(BYOAPIClient.lite(["gemini-3.8-flash-lite"], current: "gemini-3.8-flash-lite"))
    }

    @MainActor func testOnlyWhenChosenAndAllowed() {
        let suite = "byo-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = BYOSettings(defaults: d)
        XCTAssertNil(BYOEngine.active(intent: .general, s), "기본 until chosen")
        s.provider = .claude
        XCTAssertEqual(BYOEngine.active(intent: .general, s)?.model, "claude-opus-5-5")
        XCTAssertNil(BYOEngine.active(intent: .schedule, s), "calendar stays on this Mac by default")
        XCTAssertNil(BYOEngine.active(intent: .inbox, s))
        s.sharePersonal = true
        XCTAssertNotNil(BYOEngine.active(intent: .schedule, s))
        // codex and gemini keep read-only tools: calendar lines (anyone's invitation) never go to them.
        s.method = .cli
        XCTAssertNotNil(BYOEngine.active(intent: .schedule, s), "claude CLI switches every tool off")
        for p in [BYOProvider.chatgpt, .gemini] {
            s.provider = p
            XCTAssertNil(BYOEngine.active(intent: .schedule, s), "\(p)")
            XCTAssertNil(BYOEngine.active(intent: .inbox, s), "\(p)")
            #if !MAS
            XCTAssertNotNil(BYOEngine.active(intent: .general, s), "\(p)")
            #endif
        }
        s.method = .apiKey
        XCTAssertNotNil(BYOEngine.active(intent: .schedule, s))
        s.provider = .claude
        // Saved and read back.
        s.setModel("claude-sonnet-5-5", for: .claude)
        let again = BYOSettings(defaults: d)
        XCTAssertEqual(again.provider, .claude)
        XCTAssertTrue(again.sharePersonal)
        XCTAssertEqual(again.model(.claude), "claude-sonnet-5-5")
        XCTAssertEqual(again.model(.gemini), "gemini-3.8-flash")
    }

    func testCheckPicksTheBestUnlessTheOwnersPickIsStillThere() {
        let suite = "byo-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = BYOSettings(defaults: d)
        s.use(["claude-opus-6", "claude-opus-5-5"], for: .claude)
        XCTAssertEqual(s.model(.claude), "claude-opus-6", "first check: the newest")
        s.setModel("claude-opus-5-5", for: .claude)
        s.use(["claude-opus-6", "claude-opus-5-5"], for: .claude)
        XCTAssertEqual(s.model(.claude), "claude-opus-5-5", "the owner's pick stays")
        s.use(["claude-opus-6"], for: .claude)
        XCTAssertEqual(s.model(.claude), "claude-opus-6", "a pick the key lost is replaced")
    }

    // MARK: Keychain (test-only service)

    func testKeychainRoundTripUnderATestService() throws {
        let saved = AIKeychain.servicePrefix
        AIKeychain.servicePrefix = "com.jelly.dogmonitor.test.ai-\(UUID().uuidString)."
        defer { BYOProvider.allCases.forEach(AIKeychain.delete); AIKeychain.servicePrefix = saved }
        XCTAssertFalse(AIKeychain.exists(.gemini))
        try AIKeychain.save("AIza-test", for: .gemini)
        XCTAssertTrue(AIKeychain.exists(.gemini))
        XCTAssertEqual(AIKeychain.load(.gemini), "AIza-test")
        XCTAssertNil(AIKeychain.load(.claude), "one item per provider")
        AIKeychain.delete(.gemini)
        XCTAssertFalse(AIKeychain.exists(.gemini))
        XCTAssertTrue(AIKeychain.service(.claude).hasSuffix(".claude"))
        XCTAssertEqual(saved, "com.jelly.dogmonitor.ai.")
    }

    // MARK: CLI (direct build)

    #if !MAS
    private func script(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("byo-fake-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testClaudeCLIRunsWithoutKeysOrTools() throws {
        let bin = try script("""
        if [ "$1" = "--help" ]; then echo "--restricted --tools --no-session-persistence --safe-mode --effort"; exit 0; fi
        q=$(cat)
        tools=no; prev=""; for a in "$@"; do if [ "$prev" = "--tools" ] && [ -z "$a" ]; then tools=empty; fi; prev="$a"; done
        echo "warning: something on stderr" >&2
        printf '{"type":"result","is_error":false,"result":"key=%s tools=%s q=%s"}\\n' "${ANTHROPIC_API_KEY:-none}" "$tools" "$(echo "$q" | tail -n 1)"
        """)
        var c = BYOCLIClient(provider: .claude, binary: bin)
        c.environment = ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk-ant-api-x", "CLAUDE_CODE_OAUTH_TOKEN": "t"]
        XCTAssertEqual(try c.reply(system: "SYS", prompt: "[사용자 질문]\nhello"), "key=none tools=empty q=hello")
        let args = BYOCLIClient.claudeArguments(help: "--restricted --tools --effort", system: "SYS")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(args[args.firstIndex(of: "--effort")! + 1], "low")
        XCTAssertFalse(args.contains("--no-session-persistence"), "only flags this CLI has")
    }

    func testClaudeCLIWithoutSafeFlagsIsRefused() throws {
        let bin = try script(#"if [ "$1" = "--help" ]; then echo "--print"; exit 0; fi; echo '{"result":"should not run"}'"#)
        XCTAssertThrowsError(try BYOCLIClient(provider: .claude, binary: bin).reply(system: "S", prompt: "Q"))
    }

    func testCodexNeedsChatGPTSignInAndReadsTheLastMessage() throws {
        let bin = try script("""
        if [ "$1" = "login" ]; then echo "Logged in using ChatGPT"; exit 0; fi
        out=""; prev=""; for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; done
        cat > /dev/null
        printf 'key=%s' "${OPENAI_API_KEY:-none}" > "$out"
        """)
        var c = BYOCLIClient(provider: .chatgpt, binary: bin)
        c.environment = ["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "sk-x"]
        XCTAssertEqual(try c.reply(system: "S", prompt: "Q"), "key=none")

        let apiKey = try script(#"if [ "$1" = "login" ]; then echo "Logged in using an API key"; exit 0; fi; exit 1"#)
        XCTAssertThrowsError(try BYOCLIClient(provider: .chatgpt, binary: apiKey).reply(system: "S", prompt: "Q")) {
            XCTAssertEqual($0 as? ChatError, .unavailable(ChatGPTCharacterClient.Status.apiKey.note!))
        }
    }

    func testGeminiCLIReadsJSONAfterNotes() throws {
        let bin = try script("""
        cat > /dev/null
        echo "Loaded cached credentials."
        printf '{\\n  "response": "key=%s",\\n  "stats": {}\\n}\\n' "${GEMINI_API_KEY:-none}"
        """)
        var c = BYOCLIClient(provider: .gemini, binary: bin)
        c.environment = ["PATH": "/usr/bin:/bin", "GEMINI_API_KEY": "AIza", "GOOGLE_API_KEY": "AIza"]
        XCTAssertEqual(try c.reply(system: "S", prompt: "Q"), "key=none")
        XCTAssertTrue(BYOCLIClient.geminiArguments.contains("--allowed-mcp-server-names"))
    }

    func testSlowCLIStopsAtTheTimeout() throws {
        let bin = try script("cat > /dev/null; sleep 5; echo '{\"response\":\"late\"}'")
        var c = BYOCLIClient(provider: .gemini, binary: bin)
        c.timeout = 1
        let start = Date()
        XCTAssertThrowsError(try c.reply(system: "S", prompt: "Q")) { XCTAssertTrue(($0 as? ChatError)?.message.contains("오래") ?? false) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.5)
        XCTAssertNil(BYOCLIClient(provider: .gemini, binary: "/nonexistent/gemini").path())
    }

    /// One real short turn with this Mac's signed-in claude (subscription). Off unless JELLY_BYO_LIVE_CLAUDE=1.
    func testLiveClaudeCLIOnce() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JELLY_BYO_LIVE_CLAUDE"] == "1", "live run only on request")
        let c = BYOCLIClient(provider: .claude)
        try XCTSkipIf(c.path() == nil, "no claude here")
        let start = Date()
        let text = try c.reply(system: Persona(name: "젤리", style: .friendly).instructions, prompt: "[사용자 질문]\n1 더하기 1은?")
        print("LIVE claude (\(String(format: "%.1f", Date().timeIntervalSince(start)))s): \(text)")
        XCTAssertTrue(text.contains("2"), text)
    }
    #endif
}
