import Foundation

// 비서가 행동하기: the owner's own AI asked for one structured proposal (AgentPlanner.schema) and, separately, for a review.
// API keys use each provider's structured output (Claude: a forced tool; OpenAI: json_schema; Gemini: JSON mime type);
// the claude CLI gets --json-schema when its help lists it; codex and gemini CLIs answer in text and the JSON is cut out.
// Every path keeps today's no-tools, no-MCP, no-session flags: the model proposes, the app acts.

extension BYOAPIClient {
    /// One JSON object following `schema`. Throws ChatError like `reply`.
    func structured(model: String, system: String, prompt: String, schema: [String: Any]) async throws -> [String: Any] {
        let url: URL, body: [String: Any]
        switch provider {
        case .claude:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            body = ["model": model, "max_tokens": 2000, "system": system,
                    "messages": [["role": "user", "content": prompt]],
                    "tools": [["name": "propose", "description": "The plan for this turn.", "input_schema": schema]],
                    "tool_choice": ["type": "tool", "name": "propose"]]
        case .chatgpt:
            url = URL(string: "https://api.openai.com/v1/responses")!
            body = ["model": model, "instructions": system, "input": prompt, "store": false,
                    "text": ["format": ["type": "json_schema", "name": "plan", "schema": schema, "strict": false]]]
        case .gemini:
            let id = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(id):generateContent")!
            // ponytail: JSON mime type plus the schema in the prompt; Gemini's responseSchema dialect differs from JSON Schema.
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": prompt + "\n\n[JSON 형식]\n" + String(decoding: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data(), as: UTF8.self)]]]],
                    "generationConfig": ["responseMimeType": "application/json"]]
        }
        var r = authorized(URLRequest(url: url, timeoutInterval: Self.timeout))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(r)
        guard let plan = Self.parseStructured(provider, data) else { throw ChatError.server(L("\(provider.label)가 제안 형식으로 답하지 않았어요.")) }
        return plan
    }

    static func parseStructured(_ provider: BYOProvider, _ data: Data) -> [String: Any]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if provider == .claude {
            return (json["content"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "tool_use" }?["input"] as? [String: Any]
        }
        return parseReply(provider, data).flatMap(AgentPlanner.extractJSON)
    }
}

#if !MAS   // the App Store build has no CLI engines
extension BYOCLIClient {
    /// Blocking (run it off the main thread). One JSON object; throws ChatError.
    /// `model`: claude only, e.g. "haiku" for the reviewer (the CLI's own default otherwise).
    func structured(system: String, prompt: String, schema: String, model: String? = nil) throws -> [String: Any] {
        guard let bin = path() else { throw ChatError.unavailable(L("이 맥에서 \(provider.cliName) 프로그램을 찾지 못했어요.")) }
        let env = childEnvironment(bin)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-agent-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = { (argv: [String], input: String?) in
            ChatGPTCharacterClient.run(argv, env: env, cwd: dir, input: input.map { Data($0.utf8) }, timeout: max(timeout, 60))
        }
        let asJSON = "\n\n[JSON 형식] 아래 스키마의 JSON 객체 하나로만 답해.\n" + schema
        switch provider {
        case .claude:
            let help = try BYOCLIClient.cachedHelp(bin) { run([bin, "--help"], nil) }
            var args = [bin] + BYOCLIClient.claudeArguments(help: help, system: system)
            if help.contains("--json-schema") { args += ["--json-schema", schema] }
            if let model, help.contains("--model") { args += ["--model", model] }
            let r = run(args, help.contains("--json-schema") ? prompt : prompt + asJSON)
            if r.timedOut { throw BYOAPIClient.tooSlow(provider) }
            let json = BYOCLIClient.lastJSON(r.out)
            if json?["is_error"] as? Bool != true {
                if let plan = json?["structured_output"] as? [String: Any] { return plan }
                if let plan = (json?["result"] as? String).flatMap(AgentPlanner.extractJSON) { return plan }
            }
            throw ChatError.server(ClaudeCharacterClient.failure(r.out, token: false)?.message ?? L("Claude가 제안을 만들지 못했어요."))
        case .chatgpt:
            if !BYOCLIClient.codexSignedIn(bin) {
                let s = run([bin, "login", "status"], nil)
                let status = s.timedOut ? .unknown : ChatGPTCharacterClient.parseLogin(s.out, codex: bin)
                guard status.isReady else { throw ChatError.unavailable(status.note ?? BYOCLIClient.notReady) }
                BYOCLIClient.markCodexSignedIn(bin)
            }
            let last = dir.appendingPathComponent("last-message.txt")
            let r = run([bin] + BYOCLIClient.codexArguments(workdir: dir, lastMessage: last), BYOCLIClient.oneText(system, prompt + asJSON))
            if r.timedOut { throw BYOAPIClient.tooSlow(provider) }
            if let text = try? String(contentsOf: last, encoding: .utf8), let plan = AgentPlanner.extractJSON(text) { return plan }
            throw ChatError.server(ChatGPTCharacterClient.failure(r.out)?.message ?? L("ChatGPT가 제안을 만들지 못했어요."))
        case .gemini:
            let r = run([bin] + BYOCLIClient.geminiArguments, BYOCLIClient.oneText(system, prompt + asJSON))
            if r.timedOut { throw BYOAPIClient.tooSlow(provider) }
            if let text = BYOCLIClient.lastJSON(r.out)?["response"] as? String, let plan = AgentPlanner.extractJSON(text) { return plan }
            throw ChatError.server(L("Gemini가 제안을 만들지 못했어요."))
        }
    }
}
#endif

extension BYOEngine {
    /// The proposal for one turn, from the owner's engine (its fallback is never used: a proposal needs the big model).
    func plan(system: String, prompt: String) async throws -> [String: Any] {
        try await structured(system: system, prompt: prompt, schema: AgentPlanner.schema, reviewer: false)
    }

    /// One JSON object from this engine; `reviewer` picks the cheapest tier the owner's key or CLI offers.
    func structured(system: String, prompt: String, schema: [String: Any], reviewer: Bool) async throws -> [String: Any] {
        switch method {
        case .apiKey:
            guard let key = key(), !key.isEmpty else { throw ChatError.unavailable(L("\(provider.label) API 키가 없어요. 비서 설정에서 넣어 주세요.")) }
            let client = BYOAPIClient(provider: provider, key: key, transport: transport)
            return try await client.structured(model: reviewer ? reviewModel : model, system: system, prompt: prompt, schema: schema)
        case .cli:
            #if MAS
            throw ChatError.unavailable(L("앱 스토어 버전은 이 맥의 AI 프로그램을 쓸 수 없어요. API 키로 연결해 주세요."))
            #else
            var cli = BYOCLIClient(provider: provider)
            if reviewer { cli.timeout = 20 }
            let text = String(decoding: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            let small = reviewer && provider == .claude ? "haiku" : nil
            return try await Task.detached { try cli.structured(system: system, prompt: prompt, schema: text, model: small) }.value
            #endif
        }
    }

    /// The cheapest chat model of the last 연결 확인 list (haiku, mini, flash-lite), else the chosen one.
    var reviewModel: String {
        let list = availableModels
        let small: [String] = provider == .claude ? ["haiku"] : provider == .chatgpt ? ["-nano", "-mini"] : ["flash-lite", "flash"]
        for word in small { if let m = list.first(where: { $0.contains(word) }) { return m } }
        return model
    }
}
