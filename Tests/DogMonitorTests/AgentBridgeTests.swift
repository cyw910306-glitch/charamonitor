#if !MAS
import XCTest
@testable import DogMonitor

/// The claude CLI bridge: MCP over a real Unix socket in a temp folder with a fake host, the stdio relay, stream-json
/// parsing and the fail-closed argument list. No network, no real claude (except testLiveSpike with CHARA_LIVE=1).
@MainActor
final class AgentBridgeTests: XCTestCase {
    private final class FakeHost: ToolHost {
        var calls: [ToolCall] = []
        var outcome = ToolOutcome(text: "결과")
        func run(_ call: ToolCall) async -> ToolOutcome {
            calls.append(call)
            return outcome
        }
    }

    private var dir: URL!

    override func setUp() async throws {
        // Short, so the socket path fits in sun_path.
        dir = URL(fileURLWithPath: "/tmp/cb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func server(_ host: FakeHost, tools: [AgentTool] = AgentTools.all) -> AgentBridgeServer {
        let s = AgentBridgeServer(tools: tools, host: host)
        s.directory = dir
        return s
    }

    /// Connects, writes `lines`, reads replies until `count` arrive or the server closes (off the main actor, which
    /// the server needs for the host).
    private func exchange(_ path: String, _ lines: [String], count: Int) async -> [[String: Any]] {
        await Task.detached {
            guard var addr = AgentBridge.address(path) else { return [] }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0, AgentBridge.writeAll(fd, Data(lines.map { $0 + "\n" }.joined().utf8)) else { return [] }
            let reader = AgentBridge.LineReader(fd: fd), deadline = Date().addingTimeInterval(5)
            var out: [[String: Any]] = []
            while out.count < count, let line = reader.next(stop: { Date() > deadline }) {
                out.append((try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:])
            }
            return out
        }.value
    }

    private func hello(_ token: String) -> String { #"{"token":"\#(token)"}"# }

    // MARK: Server

    func testWrongTokenClosesWithoutReading() async throws {
        let host = FakeHost()
        let s = server(host)
        let (path, token) = try s.start()
        defer { s.stop() }
        XCTAssertEqual(token.count, 64)
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"finish","arguments":{"say":"x"}}}"#
        let wrong = String(token.reversed())
        for first in [hello(wrong), #"{"jsonrpc":"2.0","id":0,"method":"ping"}"#, hello("")] {
            let replies = await exchange(path, [first, call], count: 1)
            XCTAssertTrue(replies.isEmpty)
        }
        XCTAssertTrue(host.calls.isEmpty)
        XCTAssertEqual(s.steps, 0)
    }

    func testMCPRoundTrip() async throws {
        let host = FakeHost()
        host.outcome = ToolOutcome(text: "끝났어요", stop: .finished("안녕"))
        let s = server(host)
        var stopped = 0
        s.onStop = { stopped += 1 }
        let (path, token) = try s.start()
        defer { s.stop() }
        let replies = await exchange(path, [
            hello(token),
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"finish","arguments":{"say":"안녕"}}}"#,
            #"{"jsonrpc":"2.0","id":"x4","method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"finish","arguments":{"say":"또"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}"#,
        ], count: 7)
        XCTAssertEqual(replies.count, 7)
        XCTAssertEqual(replies.map { "\($0["id"] ?? "")" }, ["1", "2", "3", "x4", "5", "6", "7"])

        let initResult = replies[0]["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((initResult?["serverInfo"] as? [String: Any])?["name"] as? String, "chara")
        XCTAssertNotNil((initResult?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNotNil((replies[1]["result"] as? [String: Any])?["tools"] as? [Any])

        func text(_ r: [String: Any]) -> (String?, Bool?) {
            let result = r["result"] as? [String: Any]
            return (((result?["content"] as? [[String: Any]])?.first)?["text"] as? String, result?["isError"] as? Bool)
        }
        XCTAssertEqual(text(replies[2]).0, "끝났어요")
        XCTAssertEqual(text(replies[2]).1, false)
        XCTAssertEqual(host.calls.count, 1)
        XCTAssertEqual(host.calls.first?.id, "3")
        XCTAssertEqual(host.calls.first?.name, "finish")
        XCTAssertEqual(host.calls.first?.input["say"] as? String, "안녕")
        XCTAssertEqual(s.lastStop, .finished("안녕"))
        XCTAssertEqual(stopped, 1)

        XCTAssertEqual((replies[3]["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNotNil(replies[4]["result"])
        // After a stop nothing more reaches the host, and a tool outside the run's list never does.
        XCTAssertEqual(text(replies[5]).0, "run_stopped")
        XCTAssertEqual(text(replies[6]).1, true)
        XCTAssertEqual(host.calls.count, 1)
    }

    func testStepBudget() async throws {
        let host = FakeHost()
        let s = server(host)
        s.maxSteps = 1
        let (path, token) = try s.start()
        defer { s.stop() }
        let call = { (id: Int) in #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"memory_read","arguments":{}}}"# }
        let replies = await exchange(path, [hello(token), call(1), call(2)], count: 2)
        let texts = replies.map { (($0["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String }
        XCTAssertEqual(texts, ["결과", "budget_exhausted"])
        XCTAssertEqual(host.calls.count, 1)
        XCTAssertEqual(s.steps, 2)
    }

    func testSocketIsOwnerOnlyAndRemovedOnStop() throws {
        let s = server(FakeHost())
        let (path, _) = try s.start()
        func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int ?? 0) & 0o777 }
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode(dir.path), 0o700)
        XCTAssertTrue(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("run-"))
        s.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: Relay

    func testRelayCarriesLinesBothWays() async throws {
        let host = FakeHost()
        let s = server(host)
        let (path, token) = try s.start()
        defer { s.stop() }
        let input = Pipe(), output = Pipe()
        let inFD = input.fileHandleForReading.fileDescriptor, outFD = output.fileHandleForWriting.fileDescriptor
        let relay = Task.detached { AgentBridge.relay(socketPath: path, token: token, input: inFD, output: outFD) }
        // Two requests in one write, the third split across writes: framing must not care.
        let w = input.fileHandleForWriting
        try w.write(contentsOf: Data((#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n").utf8))
        try w.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","#.utf8))
        try w.write(contentsOf: Data((#""params":{"name":"memory_read","arguments":{}}}"# + "\n").utf8))
        let lines: [String] = await Task.detached {
            let reader = AgentBridge.LineReader(fd: output.fileHandleForReading.fileDescriptor), deadline = Date().addingTimeInterval(5)
            var out: [String] = []
            while out.count < 3, let l = reader.next(stop: { Date() > deadline }) { out.append(String(decoding: l, as: UTF8.self)) }
            return out
        }.value
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { !$0.contains("\n") && $0.hasPrefix("{") })
        XCTAssertTrue(lines[2].contains("결과"))
        try w.close()
        let status = await relay.value
        XCTAssertEqual(status, 0)
        XCTAssertEqual(host.calls.map(\.name), ["memory_read"])
    }

    func testRelayWithoutServerFails() {
        XCTAssertEqual(AgentBridge.relay(socketPath: dir.appendingPathComponent("none.sock").path, token: "t", input: -1, output: -1), 1)
    }

    // MARK: CLI arguments

    private let fullHelp = ClaudeAgentRun.requiredFlags.map { "  \($0) <x>   words" }.joined(separator: "\n")

    func testArgumentsExact() {
        XCTAssertEqual(ClaudeAgentRun.arguments(help: fullHelp, system: "규칙", mcpConfig: "/tmp/x/mcp.json", model: nil),
                       ["-p", "--output-format", "stream-json", "--verbose", "--tools", "", "--restricted", "--strict-mcp-config",
                        "--mcp-config", "/tmp/x/mcp.json", "--allowedTools", "mcp__chara__*", "--permission-mode", "dontAsk",
                        "--no-session-persistence", "--system-prompt", "규칙"])
        XCTAssertEqual(ClaudeAgentRun.arguments(help: fullHelp, system: "s", mcpConfig: "c", model: "haiku").map { Array($0.suffix(2)) }, ["--model", "haiku"])
        XCTAssertFalse(ClaudeAgentRun.arguments(help: fullHelp, system: "s", mcpConfig: "c", model: nil)!.contains("--safe-mode"))
    }

    func testFailsClosedWhenHelpLacksAFlag() {
        for flag in ClaudeAgentRun.requiredFlags {
            let help = ClaudeAgentRun.requiredFlags.filter { $0 != flag }.map { "  \($0) <x>" }.joined(separator: "\n")
            XCTAssertNil(ClaudeAgentRun.arguments(help: help, system: "s", mcpConfig: "c", model: nil), flag)
        }
        // --strict-mcp-config alone does not count as --mcp-config.
        let noConfig = fullHelp.replacingOccurrences(of: "  --mcp-config <x>", with: "")
        XCTAssertTrue(noConfig.contains("--strict-mcp-config"))
        XCTAssertNil(ClaudeAgentRun.arguments(help: noConfig, system: "s", mcpConfig: "c", model: nil))
    }

    func testMCPConfigCarriesTokenInEnvNotArgs() throws {
        let data = ClaudeAgentRun.mcpConfig(executable: "/A/DogMonitor", socketPath: "/s.sock", token: "abc")
        let chara = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["mcpServers"] as? [String: Any]
        let server = chara?["chara"] as? [String: Any]
        XCTAssertEqual(server?["command"] as? String, "/A/DogMonitor")
        XCTAssertEqual(server?["args"] as? [String], ["--agent-bridge", "/s.sock"])
        XCTAssertEqual(server?["env"] as? [String: String], ["CHARA_BRIDGE_TOKEN": "abc"])
    }

    // MARK: stream-json

    /// init, thinking and tool_use trimmed from a real run through the bridge (claude 2.1.289, --model haiku, 2026-10-06);
    /// that run ended at the finish call, so the text and result lines follow the documented shape.
    static let sample = [
        #"{"type":"system","subtype":"init","cwd":"/tmp/x","session_id":"s","tools":["mcp__chara__finish"],"mcp_servers":[{"name":"chara","status":"connected","source":"dynamic"}],"model":"claude-haiku-4-5-20251001","permissionMode":"dontAsk"}"#,
        #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50,"session_id":"s"}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"Ep8E"}]},"session_id":"s"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"알겠어요."}]},"session_id":"s"}"#,
        #"{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"mcp__chara__finish","input":{"say":"안녕"},"caller":{"type":"direct"}}],"stop_reason":null},"session_id":"s"}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"s"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok","tool_use_id":"toolu_01"}]},"session_id":"s"}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"안녕이라고 말했어요.","session_id":"s"}"#,
    ]

    func testParsesStreamJSON() {
        let items = Self.sample.flatMap(ClaudeAgentRun.parse)
        XCTAssertEqual(items, [.event(.say("알겠어요.")), .event(.tool(name: "finish", note: "안녕")),
                               .result("안녕이라고 말했어요.", isError: false)])
        XCTAssertEqual(ClaudeAgentRun.parse(#"{"type":"result","is_error":true,"result":"limit"}"#), [.result("limit", isError: true)])
        XCTAssertEqual(ClaudeAgentRun.parse("not json"), [])
        // A tool that is not ours is not reported.
        XCTAssertEqual(ClaudeAgentRun.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#), [])
    }

    // MARK: Runner with a fake CLI

    private func fakeCLI(help: String, body: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude").path
        let script = "#!/bin/sh\nif [ \"$1\" = \"--help\" ]; then cat <<'EOF'\n\(help)\nEOF\nexit 0; fi\n\(body)\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    func testRunReportsResultAndConfigIsPrivate() async throws {
        // Echoes the config file's mode as the result, after reading the prompt.
        let bin = try fakeCLI(help: fullHelp, body: """
            cat > /dev/null
            while [ "$1" != "--mcp-config" ]; do shift; done
            echo '\(Self.sample[4])'
            echo "{\\"type\\":\\"result\\",\\"is_error\\":false,\\"result\\":\\"$(stat -f %Lp "$2")\\"}"
            """)
        var events: [LoopEvent] = []
        let run = ClaudeAgentRun(system: "s", tools: AgentTools.all, host: FakeHost(), onEvent: { events.append($0) })
        run.cli = BYOCLIClient(provider: .claude, binary: bin)
        run.socketDirectory = dir
        let stop = await run.run(prompt: "안녕")
        XCTAssertEqual(stop, .finished("600"))
        XCTAssertEqual(events, [.tool(name: "finish", note: "안녕")])
    }

    func testRunFailsClosedOnOldCLI() async throws {
        let bin = try fakeCLI(help: "  --tools <x>\n  --restricted", body: "echo should-not-run; exit 1")
        let run = ClaudeAgentRun(system: "s", tools: AgentTools.all, host: FakeHost())
        run.cli = BYOCLIClient(provider: .claude, binary: bin)
        let stop = await run.run(prompt: "x")
        XCTAssertEqual(stop, .failed(ClaudeAgentRun.tooOld))
    }

    func testRunTimesOutAndCancels() async throws {
        let bin = try fakeCLI(help: fullHelp, body: "cat > /dev/null; sleep 30")
        let slow = ClaudeAgentRun(system: "s", tools: AgentTools.all, host: FakeHost(), limits: LoopLimits(steps: 40, seconds: 0.5))
        slow.cli = BYOCLIClient(provider: .claude, binary: bin)
        slow.socketDirectory = dir
        var t0 = Date()
        let timedOut = await slow.run(prompt: "x")
        XCTAssertEqual(timedOut, .budget)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)

        let run = ClaudeAgentRun(system: "s", tools: AgentTools.all, host: FakeHost())
        run.cli = BYOCLIClient(provider: .claude, binary: bin)
        run.socketDirectory = dir
        t0 = Date()
        Task { try? await Task.sleep(nanoseconds: 500_000_000); run.cancel() }
        let cancelled = await run.run(prompt: "x")
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    // MARK: Live spike (real claude, uses the owner's subscription): CHARA_LIVE=1 swift test --filter testLiveSpike

    func testLiveSpike() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHARA_LIVE"] == "1")
        let host = FakeHost()
        host.outcome = ToolOutcome(text: AgentTools.wrap("전달했어요"), stop: .finished("안녕"))
        var events: [LoopEvent] = []
        let run = ClaudeAgentRun(system: "너는 비서야. 사용자의 부탁을 chara 도구로만 처리해.", tools: [AgentTools.named("finish")!],
                                 host: host, limits: LoopLimits(steps: 5, seconds: 120), model: "haiku", onEvent: { events.append($0) })
        run.executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("DogMonitor").path
        let stop = await run.run(prompt: "finish 도구로 '안녕'이라고 말해")
        print("LIVE stop=\(stop) events=\(events) calls=\(host.calls.map { "\($0.name) \($0.input)" })")
        XCTAssertEqual(host.calls.first?.name, "finish")
        XCTAssertEqual(stop, .finished("안녕"))
    }
}
#endif
