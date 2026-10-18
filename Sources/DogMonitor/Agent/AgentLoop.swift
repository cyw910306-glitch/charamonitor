import Foundation

// 비서가 행동하기 v2, the API-key driver: the owner's model calls tools natively (Claude tool_use, OpenAI function_call,
// Gemini functionCall) and every call goes to the ToolHost, which alone touches anything. The model's own output is
// sent back verbatim each turn (Claude thinking blocks, OpenAI reasoning items, Gemini thoughtSignature parts): the
// providers reject or degrade a tool turn without them. Design: docs/AGENT-DESIGN.md sections 1-3, 14.

@MainActor
final class AgentLoop {
    /// One model turn with tools and a page snapshot can take longer than a chat answer (BYOAPIClient.timeout is 25 s).
    static let requestTimeout: TimeInterval = 90

    private let client: BYOAPIClient
    private let model: String
    private let system: String
    private let tools: [AgentTool]
    private let host: ToolHost
    private let limits: LoopLimits
    private let now: () -> Date
    private let onEvent: (LoopEvent) -> Void
    private var cancelled = false

    init(client: BYOAPIClient, model: String, system: String, tools: [AgentTool], host: ToolHost, limits: LoopLimits = .init(),
         now: @escaping () -> Date = Date.init, onEvent: @escaping (LoopEvent) -> Void = { _ in }) {
        self.client = client
        self.model = model
        self.system = system
        self.tools = tools
        self.host = host
        self.limits = limits
        self.now = now
        self.onEvent = onEvent
    }

    /// The owner pressed 멈추기: the run ends before its next model or tool call.
    func cancel() { cancelled = true }

    func run(prompt: String) async -> LoopStop {
        let deadline = now().addingTimeInterval(limits.seconds)
        var steps = 0
        var history = firstTurn(prompt)
        func halt() -> LoopStop? { cancelled ? .cancelled : now() > deadline ? .budget : nil }

        while true {
            if let stop = halt() { return stop }
            onEvent(.thinking)
            let turn: Turn
            do { turn = try await call(history) } catch { return .failed((error as? ChatError ?? .other).message) }
            history += turn.echo
            guard !turn.calls.isEmpty else {
                if cancelled { return .cancelled }
                return turn.text.isEmpty ? .failed(ChatError.other.message) : .finished(turn.text)
            }
            if !turn.text.isEmpty { onEvent(.say(turn.text)) }
            var results: [(ToolCall, String)] = []
            for c in turn.calls {
                if let stop = halt() { return stop }
                steps += 1
                if steps > limits.steps { return .budget }
                onEvent(.tool(name: c.name, note: Self.note(c)))
                // Only the tools this run offered: a personal read the run was not given is refused here, not by the host.
                let out = tools.contains { $0.name == c.name } ? await host.run(c)
                                                               : ToolOutcome(text: L("이번 일에서 쓸 수 없는 도구예요: \(c.name)"))
                if let stop = out.stop { return stop }
                results.append((c, out.text))
            }
            history += answers(results)
        }
    }

    // MARK: Wire formats

    /// One model turn: what to send back verbatim, its text, its tool calls in order.
    private struct Turn {
        var echo: [[String: Any]]
        var text: String
        var calls: [ToolCall]
    }

    private func firstTurn(_ prompt: String) -> [[String: Any]] {
        switch client.provider {
        case .claude, .chatgpt: return [["role": "user", "content": prompt]]
        case .gemini: return [["role": "user", "parts": [["text": prompt]]]]
        }
    }

    private func request(_ history: [[String: Any]]) throws -> URLRequest {
        let url: URL, body: [String: Any]
        switch client.provider {
        case .claude:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            body = ["model": model, "max_tokens": 4000, "system": system, "tools": AgentTools.claude(tools), "messages": history]
        case .chatgpt:
            url = URL(string: "https://api.openai.com/v1/responses")!
            body = ["model": model, "instructions": system, "tools": AgentTools.openAI(tools), "input": history, "store": false,
                    "include": ["reasoning.encrypted_content"]]
        case .gemini:
            let id = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(id):generateContent")!
            body = ["systemInstruction": ["parts": [["text": system]]], "tools": AgentTools.gemini(tools), "contents": history]
        }
        var r = client.authorized(URLRequest(url: url, timeoutInterval: Self.requestTimeout))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    private func call(_ history: [[String: Any]]) async throws -> Turn {
        let data = try await client.send(request(history))
        guard let turn = Self.parse(client.provider, data) else { throw ChatError.other }
        return turn
    }

    private static func parse(_ provider: BYOProvider, _ data: Data) -> Turn? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let text = BYOAPIClient.parseReply(provider, data) ?? ""
        switch provider {
        case .claude:
            guard let content = json["content"] as? [[String: Any]] else { return nil }
            let calls = content.filter { $0["type"] as? String == "tool_use" }.map {
                ToolCall(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", input: $0["input"] as? [String: Any] ?? [:])
            }
            return Turn(echo: [["role": "assistant", "content": content]], text: text, calls: calls)
        case .chatgpt:
            guard let output = json["output"] as? [[String: Any]] else { return nil }
            let calls = output.filter { $0["type"] as? String == "function_call" }.map { item -> ToolCall in
                let args = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                return ToolCall(id: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "", input: args as? [String: Any] ?? [:])
            }
            return Turn(echo: output, text: text, calls: calls)
        case .gemini:
            guard var content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any] else { return nil }
            content["role"] = "model"
            let fns = (content["parts"] as? [[String: Any]] ?? []).compactMap { $0["functionCall"] as? [String: Any] }
            let calls = fns.enumerated().map { i, f -> ToolCall in
                let name = f["name"] as? String ?? ""
                return ToolCall(id: "\(name)#\(i)", name: name, input: f["args"] as? [String: Any] ?? [:])
            }
            return Turn(echo: [content], text: text, calls: calls)
        }
    }

    private func answers(_ results: [(ToolCall, String)]) -> [[String: Any]] {
        switch client.provider {
        case .claude:
            return [["role": "user", "content": results.map { ["type": "tool_result", "tool_use_id": $0.0.id, "content": $0.1] }]]
        case .chatgpt:
            return results.map { ["type": "function_call_output", "call_id": $0.0.id, "output": $0.1] }
        case .gemini:
            return [["role": "user", "parts": results.map { ["functionResponse": ["name": $0.0.name, "response": ["result": $0.1]]] }]]
        }
    }

    /// The chat's progress line: where or what, from the call's input ("www.coupang.com", "하기스 4단계").
    static func note(_ call: ToolCall) -> String {
        if let u = call.input["url"] as? String { return URL(string: u)?.host ?? String(u.prefix(40)) }
        for k in ["query", "text", "name", "type", "direction"] {
            if let s = call.input[k] as? String, !s.isEmpty { return String(s.prefix(40)) }
        }
        return ""
    }
}
