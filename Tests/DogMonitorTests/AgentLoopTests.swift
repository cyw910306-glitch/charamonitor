import XCTest
@testable import DogMonitor

/// The API-key tool loop against a scripted HTTP layer (no network) and a fake tool host: the exact request bodies of
/// each provider's multi-turn protocol, control-tool stops, budgets, cancel and HTTP failures.
@MainActor
final class AgentLoopTests: XCTestCase {
    private final class Script {
        var replies: [(Int, String)]
        var sent: [URLRequest] = []
        init(_ replies: [(Int, String)]) { self.replies = replies }
        var transport: BYOAPIClient.Transport {
            { r in
                self.sent.append(r)
                let (code, body) = self.replies.removeFirst()
                return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private final class Host: ToolHost {
        var calls: [ToolCall] = []
        var stops: [String: LoopStop] = [:]
        var onRun: (ToolCall) -> Void = { _ in }
        func run(_ call: ToolCall) async -> ToolOutcome {
            calls.append(call)
            onRun(call)
            return ToolOutcome(text: "R:\(call.name)", stop: stops[call.name])
        }
    }

    private let tools = ["web_open", "web_find", "web_scroll", "ask_owner", "finish"].compactMap(AgentTools.named)

    private func loop(_ p: BYOProvider, _ script: Script, _ host: Host, limits: LoopLimits = .init(), now: @escaping () -> Date = Date.init,
                      events: ((LoopEvent) -> Void)? = nil) -> AgentLoop {
        AgentLoop(client: BYOAPIClient(provider: p, key: "KEY", transport: script.transport, pause: { _ in }), model: p.defaultModel, system: "SYS",
                  tools: tools, host: host, limits: limits, now: now, onEvent: events ?? { _ in })
    }

    private func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }
    private func norm(_ x: Any) -> NSDictionary {
        try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: x)) as! NSDictionary
    }
    private func body(_ r: URLRequest) -> NSDictionary {
        try! JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as! NSDictionary
    }

    // MARK: Claude

    private let c1 = #"{"content":[{"type":"thinking","thinking":"쿠팡부터","signature":"sig1"},{"type":"text","text":"쿠팡을 열어 볼게."},{"type":"tool_use","id":"toolu_1","name":"web_open","input":{"url":"https://www.coupang.com/np/search?q=x"}}],"stop_reason":"tool_use"}"#
    private let c2 = #"{"content":[{"type":"tool_use","id":"toolu_2","name":"web_find","input":{"text":"하기스"}}],"stop_reason":"tool_use"}"#
    private let c3 = #"{"content":[{"type":"text","text":"제일 싼 건 3만 원이야."}],"stop_reason":"end_turn"}"#

    func testClaudeThreadsToolResultsAndKeepsThinking() async {
        let script = Script([(200, c1), (200, c2), (200, c3)])
        let host = Host()
        var events: [LoopEvent] = []
        let stop = await loop(.claude, script, host, events: { events.append($0) }).run(prompt: "하기스 최저가")
        XCTAssertEqual(stop, .finished("제일 싼 건 3만 원이야."))
        XCTAssertEqual(host.calls.map(\.id), ["toolu_1", "toolu_2"])
        XCTAssertEqual(host.calls.first?.input["url"] as? String, "https://www.coupang.com/np/search?q=x")
        XCTAssertEqual(events, [.thinking, .say("쿠팡을 열어 볼게."), .tool(name: "web_open", note: "www.coupang.com"),
                                .thinking, .tool(name: "web_find", note: "하기스"), .thinking])
        XCTAssertEqual(script.sent.count, 3)
        XCTAssertEqual(script.sent[0].url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(script.sent[0].value(forHTTPHeaderField: "x-api-key"), "KEY")

        func content(_ s: String) -> Any { (json(s) as! [String: Any])["content"]! }
        var messages: [Any] = [["role": "user", "content": "하기스 최저가"],
                               ["role": "assistant", "content": content(c1)],
                               ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "R:web_open"]]]]
        func expected() -> NSDictionary {
            norm(["model": "claude-opus-5-5", "max_tokens": 4000, "system": "SYS", "tools": AgentTools.claude(tools), "messages": messages])
        }
        XCTAssertEqual(body(script.sent[1]), expected())
        messages += [["role": "assistant", "content": content(c2)],
                     ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_2", "content": "R:web_find"]]]]
        XCTAssertEqual(body(script.sent[2]), expected())
    }

    // MARK: OpenAI

    private let o1 = #"{"output":[{"type":"reasoning","id":"rs_1","encrypted_content":"ENC1","summary":[]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"web_open","arguments":"{\"url\":\"https://search.shopping.naver.com/search/all?query=x\"}","status":"completed"}]}"#
    private let o2 = #"{"output":[{"type":"reasoning","id":"rs_2","encrypted_content":"ENC2","summary":[]},{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"더 찾아볼게."}]},{"type":"function_call","id":"fc_2","call_id":"call_2","name":"web_scroll","arguments":"{\"direction\":\"down\"}","status":"completed"}]}"#
    private let o3 = #"{"output":[{"type":"reasoning","id":"rs_3","encrypted_content":"ENC3","summary":[]},{"type":"message","id":"msg_2","role":"assistant","content":[{"type":"output_text","text":"끝났어."}]}]}"#

    func testOpenAIEchoesEveryOutputItemIncludingReasoning() async {
        let script = Script([(200, o1), (200, o2), (200, o3)])
        let host = Host()
        var events: [LoopEvent] = []
        let stop = await loop(.chatgpt, script, host, events: { events.append($0) }).run(prompt: "네이버에서 찾아 줘")
        XCTAssertEqual(stop, .finished("끝났어."))
        XCTAssertEqual(host.calls.map(\.id), ["call_1", "call_2"])
        XCTAssertEqual(host.calls.last?.input["direction"] as? String, "down")
        XCTAssertEqual(events, [.thinking, .tool(name: "web_open", note: "search.shopping.naver.com"),
                                .thinking, .say("더 찾아볼게."), .tool(name: "web_scroll", note: "down"), .thinking])
        XCTAssertEqual(script.sent[0].url?.absoluteString, "https://api.openai.com/v1/responses")

        func output(_ s: String) -> [Any] { (json(s) as! [String: Any])["output"] as! [Any] }
        var input: [Any] = [["role": "user", "content": "네이버에서 찾아 줘"]] + output(o1)
            + [["type": "function_call_output", "call_id": "call_1", "output": "R:web_open"]]
        func expected() -> NSDictionary {
            norm(["model": "gpt-6-astra", "instructions": "SYS", "tools": AgentTools.openAI(tools), "input": input, "store": false,
                  "include": ["reasoning.encrypted_content"]])
        }
        XCTAssertEqual(body(script.sent[1]), expected())
        input += output(o2) + [["type": "function_call_output", "call_id": "call_2", "output": "R:web_scroll"]]
        XCTAssertEqual(body(script.sent[2]), expected())
    }

    // MARK: Gemini

    private let g1 = #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"web_open","args":{"url":"https://www.koreanair.com/booking"}},"thoughtSignature":"SIG1"}]}}]}"#
    private let g2 = #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"web_find","args":{"text":"김포"}},"thoughtSignature":"SIG2"},{"functionCall":{"name":"web_scroll","args":{"direction":"down"}}}]}}]}"#
    private let g3 = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"생각","thought":true},{"text":"찾았어."}]}}]}"#

    func testGeminiKeepsThoughtSignaturesAndAnswersInCallOrder() async {
        let script = Script([(200, g1), (200, g2), (200, g3)])
        let host = Host()
        let stop = await loop(.gemini, script, host).run(prompt: "제주 항공권")
        XCTAssertEqual(stop, .finished("찾았어."))
        XCTAssertEqual(host.calls.map(\.id), ["web_open#0", "web_find#0", "web_scroll#1"])
        XCTAssertEqual(script.sent[0].url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertEqual(script.sent[0].value(forHTTPHeaderField: "x-goog-api-key"), "KEY")

        func content(_ s: String) -> Any { ((json(s) as! [String: Any])["candidates"] as! [[String: Any]])[0]["content"]! }
        func response(_ name: String) -> Any { ["functionResponse": ["name": name, "response": ["result": "R:\(name)"]]] }
        var contents: [Any] = [["role": "user", "parts": [["text": "제주 항공권"]]], content(g1),
                               ["role": "user", "parts": [response("web_open")]]]
        func expected() -> NSDictionary {
            norm(["systemInstruction": ["parts": [["text": "SYS"]]], "tools": AgentTools.gemini(tools), "contents": contents])
        }
        XCTAssertEqual(body(script.sent[1]), expected())
        contents += [content(g2), ["role": "user", "parts": [response("web_find"), response("web_scroll")]]]
        XCTAssertEqual(body(script.sent[2]), expected())
        XCTAssertTrue(String(decoding: script.sent[2].httpBody!, as: UTF8.self).contains("SIG2"))
    }

    // MARK: Stops

    func testControlToolStopsTheRunRightAfterIt() async {
        let both = #"{"content":[{"type":"tool_use","id":"t1","name":"ask_owner","input":{"question":"어느 쪽?","choices":["A","B"]}},{"type":"tool_use","id":"t2","name":"web_open","input":{"url":"https://a.com"}}]}"#
        let script = Script([(200, both)])
        let host = Host()
        host.stops["ask_owner"] = .asked("어느 쪽?", ["A", "B"])
        let stop = await loop(.claude, script, host).run(prompt: "q")
        XCTAssertEqual(stop, .asked("어느 쪽?", ["A", "B"]))
        XCTAssertEqual(host.calls.map(\.name), ["ask_owner"])
        XCTAssertEqual(script.sent.count, 1)
    }

    func testStepBudget() async {
        let two = #"{"content":[{"type":"tool_use","id":"t1","name":"web_open","input":{"url":"https://a.com"}},{"type":"tool_use","id":"t2","name":"web_find","input":{"text":"x"}}]}"#
        let script = Script([(200, two)])
        let host = Host()
        let stop = await loop(.claude, script, host, limits: LoopLimits(steps: 1, seconds: 600)).run(prompt: "q")
        XCTAssertEqual(stop, .budget)
        XCTAssertEqual(host.calls.map(\.name), ["web_open"])
    }

    func testTimeBudgetWithAFakeClock() async {
        var t = Date(timeIntervalSince1970: 1_000_000)
        let script = Script([(200, c1), (200, c2)])
        let host = Host()
        host.onRun = { _ in t += 120 }   // a card that waited two minutes
        let stop = await loop(.claude, script, host, limits: LoopLimits(steps: 40, seconds: 60), now: { t }).run(prompt: "q")
        XCTAssertEqual(stop, .budget)
        XCTAssertEqual(script.sent.count, 1, "no model call after the deadline")
    }

    func testCancelStopsBeforeTheNextModelCall() async {
        let script = Script([(200, c1), (200, c2)])
        let host = Host()
        let l = loop(.claude, script, host)
        host.onRun = { _ in l.cancel() }
        let stop = await l.run(prompt: "q")
        XCTAssertEqual(stop, .cancelled)
        XCTAssertEqual(script.sent.count, 1)
    }

    func testRateLimitFailsWithTheProviderMessage() async {
        for p in BYOProvider.allCases {
            // A plain 429 is retried once (nothing was billed), then fails with the provider's reason.
            let script = Script([(429, "{}"), (429, "{}")])
            let stop = await loop(p, script, Host()).run(prompt: "q")
            XCTAssertEqual(stop, .failed(BYOAPIClient.failure(p, status: 429).message))
            XCTAssertEqual(script.sent.count, 2)
            if case .failed(let m) = stop { XCTAssertTrue(m.contains("한도"), m) }
        }
    }

    func testAToolTheRunWasNotGivenNeverReachesTheHost() async {
        let read = #"{"content":[{"type":"tool_use","id":"t1","name":"mail_read","input":{"id":"1"}}]}"#
        let script = Script([(200, read), (200, c3)])
        let host = Host()
        let stop = await loop(.claude, script, host).run(prompt: "q")
        XCTAssertEqual(stop, .finished("제일 싼 건 3만 원이야."))
        XCTAssertTrue(host.calls.isEmpty)
        XCTAssertTrue(String(decoding: script.sent[1].httpBody!, as: UTF8.self).contains("mail_read"))
    }
}
