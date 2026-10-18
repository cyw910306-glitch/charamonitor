import Foundation

// 내 AI 연결 (bring your own AI): the AI 비서 answers with the owner's own Claude, ChatGPT or Gemini, either through an
// API key they pasted (billed to them) or, in the direct build, through a CLI already signed in on this Mac (their
// subscription). It is one more ChatEngine: intent routing, fixed answers and AssistantPrompt.clean run as before,
// and only what ChatRequest.prompt holds goes out (the Mac numbers the question needs; calendar lines only when the
// owner turned sharePersonal on). Any failure answers with this Mac's engine instead.

enum BYOProvider: String, CaseIterable, Codable {
    case claude, chatgpt, gemini

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }

    /// Used only when the model list cannot be read. claude: the claude-api skill (cached 2026-09-25). chatgpt:
    /// developers.openai.com/api/docs/models and guides/text. gemini: ai.google.dev/gemini-api/docs/models (2026-10-04).
    var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-5-5"
        case .chatgpt: return "gpt-6-astra"
        case .gemini: return "gemini-3.8-flash"
        }
    }

    /// Where the owner makes a key.
    var keyURL: URL {
        switch self {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .chatgpt: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    #if !MAS   // the App Store build runs no other programs (2.5.2)
    /// The CLI that can answer with the owner's subscription.
    var cliName: String {
        switch self {
        case .claude: return "claude"
        case .chatgpt: return "codex"
        case .gemini: return "gemini"
        }
    }
    #endif
}

enum BYOMethod: String, CaseIterable, Codable {
    case apiKey, cli
}

/// 내 AI 연결 options, in AppDefaults.store under "assistant.byo.*". Nothing is chosen until the owner picks one.
final class BYOSettings: ObservableObject {
    static let shared = BYOSettings()
    private let d: UserDefaults

    /// nil = 기본 (this Mac's Apple Intelligence, or the template answers).
    @Published var provider: BYOProvider? { didSet { d.set(provider?.rawValue, forKey: "assistant.byo.provider") } }
    @Published var method: BYOMethod { didSet { d.set(method.rawValue, forKey: "assistant.byo.method") } }
    /// 받은 메시지·일정도 내 AI로: off = calendar questions stay on this Mac, as before.
    @Published var sharePersonal: Bool { didSet { d.set(sharePersonal, forKey: "assistant.byo.sharePersonal") } }
    @Published private var models: [String: String] { didSet { d.set(models, forKey: "assistant.byo.models") } }
    /// The last 연결 확인 list per provider, this session only.
    @Published var available: [BYOProvider: [String]] = [:]
    /// Why the last answer fell back to this Mac's engine; cleared by the next good answer.
    @Published var lastFailure: String?
    /// The model that wrote the last good answer (a Gemini lite stand-in included).
    @Published var lastModel: String?

    init(defaults: UserDefaults = AppDefaults.store) {
        d = defaults
        provider = defaults.string(forKey: "assistant.byo.provider").flatMap(BYOProvider.init)
        method = defaults.string(forKey: "assistant.byo.method").flatMap(BYOMethod.init) ?? .apiKey
        sharePersonal = defaults.bool(forKey: "assistant.byo.sharePersonal")
        models = defaults.dictionary(forKey: "assistant.byo.models") as? [String: String] ?? [:]
    }

    #if MAS
    /// App Review 5.1.2(i): the owner agreed, once per provider, to what goes to it. Nothing goes before that.
    func consented(_ p: BYOProvider) -> Bool { d.bool(forKey: "assistant.byo.consent.\(p.rawValue)") }
    func consent(_ p: BYOProvider) { objectWillChange.send(); d.set(true, forKey: "assistant.byo.consent.\(p.rawValue)") }
    #endif

    func model(_ p: BYOProvider) -> String { models[p.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel }
    func setModel(_ m: String, for p: BYOProvider) { models[p.rawValue] = m }

    /// After 연결 확인: keeps the owner's pick when the key still has it, else the list's best (its first).
    func use(_ list: [String], for p: BYOProvider) {
        available[p] = list
        if let first = list.first, models[p.rawValue] == nil || !list.contains(model(p)) { setModel(first, for: p) }
    }
}

// MARK: - API keys

/// One provider's HTTP API with the owner's key. The transport is swappable so tests never touch the network.
struct BYOAPIClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    var provider: BYOProvider
    var key: String
    var transport: Transport = { try await BYOAPIClient.session.data(for: $0) }
    /// The wait before send's one retry; tests skip it.
    var pause: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, min($0.isFinite ? $0 : 0, 10)) * 1_000_000_000)) }

    static let timeout: TimeInterval = 25
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // no cookies or cache on disk
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    // MARK: Models

    func modelsRequest() -> URLRequest {
        let url: URL
        switch provider {
        case .claude: url = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        case .chatgpt: url = URL(string: "https://api.openai.com/v1/models")!
        case .gemini: url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!
        }
        return authorized(URLRequest(url: url, timeoutInterval: Self.timeout))
    }

    /// The key's chat models, best first (the first is the automatic choice). Throws ChatError (a wrong key says so).
    func models() async throws -> [String] {
        try chatModels(try await send(modelsRequest()))
    }

    private func chatModels(_ data: Data) throws -> [String] {
        let list = Self.rankModels(provider, data)
        guard !list.isEmpty else { throw ChatError.server(L("\(provider.label)에서 대화용 모델을 찾지 못했어요.")) }
        return list
    }

    /// Words of the ids that are not for chat (images, voice, embeddings, search, code agents...).
    static let notChat = ["embed", "image", "tts", "audio", "realtime", "transcribe", "search", "moderation", "live", "dall",
                          "whisper", "codex", "computer", "robotics", "native", "veo", "imagen", "lyria", "aqa", "gemma",
                          "learnlm", "oss", "instruct", "babbage", "davinci", "deep-research", "mythos"]

    static func rankModels(_ provider: BYOProvider, _ data: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func chat(_ id: String) -> Bool { !notChat.contains { id.lowercased().contains($0) } }
        switch provider {
        case .claude:
            // Newest Opus first (the default tier), then the other tiers, newest first in each.
            let rows = (json["data"] as? [[String: Any]] ?? []).compactMap { r -> (String, String)? in
                guard let id = r["id"] as? String, id.hasPrefix("claude-"), chat(id) else { return nil }
                return (id, r["created_at"] as? String ?? "")
            }
            func tier(_ id: String) -> Int { ["opus", "sonnet", "fable", "haiku"].firstIndex { id.contains($0) } ?? 4 }
            return rows.sorted { (tier($0.0), $1.1) < (tier($1.0), $0.1) }.map(\.0)
        case .chatgpt:
            // The full model first, then mini, then nano, newest first in each. Dated snapshots, non-chat models and
            // -pro (minutes per answer at a high price: past the 25 s limit every time) left out.
            let rows = (json["data"] as? [[String: Any]] ?? []).compactMap { r -> (String, Int)? in
                guard let id = r["id"] as? String, id.hasPrefix("gpt-"), chat(id), !id.contains("-pro"),
                      id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil else { return nil }
                return (id, r["created"] as? Int ?? 0)
            }
            func tier(_ id: String) -> Int { id.contains("-nano") ? 2 : id.contains("-mini") ? 1 : 0 }
            return rows.sorted { (tier($0.0), $1.1, $0.0) < (tier($1.0), $0.1, $1.0) }.map(\.0)
        case .gemini:
            // Stable before preview, newest version first, flash (fast, the docs' pick for chat) before pro and lite.
            let rows = (json["models"] as? [[String: Any]] ?? []).compactMap { r -> String? in
                guard let name = r["name"] as? String,
                      (r["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? false else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                return id.hasPrefix("gemini-") && chat(id) && !id.contains("exp") ? id : nil
            }
            func version(_ id: String) -> Double {
                id.range(of: #"(?<=gemini-)\d+(\.\d+)?"#, options: .regularExpression).flatMap { Double(id[$0]) } ?? 0
            }
            func key(_ id: String) -> (Int, Double, Int) {
                let tier = id.contains("lite") ? 2 : id.contains("flash") ? 0 : id.contains("pro") ? 1 : 3
                return (id.contains("preview") ? 1 : 0, -version(id), tier)
            }
            return rows.sorted { (key($0).0, key($0).1, key($0).2, $0) < (key($1).0, key($1).1, key($1).2, $1) }
        }
    }

    // MARK: Chat

    func chatRequest(model: String, system: String, prompt: String) throws -> URLRequest {
        let url: URL, body: [String: Any]
        switch provider {
        case .claude:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            var b: [String: Any] = ["model": model, "max_tokens": 4000, "system": system,
                                    "messages": [["role": "user", "content": prompt]]]
            // A short chat answer needs little thinking. Only the 5-generation models take effort (Haiku 4.5 400s on it).
            if ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"].contains(where: model.hasPrefix) { b["output_config"] = ["effort": "low"] }
            body = b
        case .chatgpt:
            url = URL(string: "https://api.openai.com/v1/responses")!
            body = ["model": model, "instructions": system, "input": prompt, "store": false]
        case .gemini:
            let id = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(id):generateContent")!
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": prompt]]]]]
        }
        var r = authorized(URLRequest(url: url, timeoutInterval: Self.timeout))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    func reply(model: String, system: String, prompt: String) async throws -> String {
        try await answer(model: model, system: system, prompt: prompt).text
    }

    /// The answer and the model that gave it. `lite` (Gemini only): a lighter model tried once when the first is busy
    /// or too slow, before the caller falls back to this Mac.
    func answer(model: String, system: String, prompt: String, lite: String? = nil) async throws -> (text: String, model: String) {
        var used = model
        let data: Data
        do {
            data = try await send(chatRequest(model: model, system: system, prompt: prompt))
        } catch let e as ChatError where provider == .gemini && (e == Self.failure(provider, status: 503) || e == Self.tooSlow(provider)) {
            guard let lite, lite != model else { throw e }
            used = lite
            data = try await send(chatRequest(model: lite, system: system, prompt: prompt))
        }
        guard let text = Self.parseReply(provider, data), !text.isEmpty else { throw ChatError.other }
        return (text, used)
    }

    /// The first "lite" model of a 연결 확인 list that is not `current`. Pure.
    static func lite(_ list: [String], current: String) -> String? {
        list.first { $0.lowercased().contains("lite") && $0 != current }
    }

    static func tooSlow(_ p: BYOProvider) -> ChatError { .server(L("\(p.label)가 너무 오래 걸려요.")) }

    /// The answer's text only (thinking and tool items left out).
    static func parseReply(_ provider: BYOProvider, _ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let texts: [String]
        switch provider {
        case .claude:
            texts = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        case .chatgpt:
            texts = (json["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }
        case .gemini:
            let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            texts = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }
        }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Plumbing

    /// The key goes in a header for every provider (never in the URL, where logs and proxies keep it).
    func authorized(_ request: URLRequest) -> URLRequest {
        var r = request
        switch provider {
        case .claude:
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .chatgpt:
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        return r
    }

    /// One retry for a busy provider (BYOAPIClient.retryable), after min(Retry-After, 3 s). A wait over 10 s is not taken.
    func send(_ request: URLRequest) async throws -> Data {
        var (status, data, wait) = try await fetch(request)
        if status != 200, Self.retryable(status: status, body: data), (wait ?? 0) <= 10 {
            await pause(min(wait ?? 2, 3))
            (status, data, wait) = try await fetch(request)
        }
        guard status == 200 else { throw Self.failure(provider, status: status, body: data) }
        return data
    }

    private func fetch(_ request: URLRequest) async throws -> (status: Int, body: Data, retryAfter: TimeInterval?) {
        let data: Data, response: URLResponse
        do { (data, response) = try await transport(request) } catch {
            throw (error as? URLError)?.code == .timedOut ? Self.tooSlow(provider) : ChatError.network
        }
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, data, http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil })
    }

    /// 연결 확인: the key's chat models, best first. A 429, 503 or 529 still means the key was accepted, so it comes
    /// back with no models and a note saying the key works (the caller saves it). Other failures throw ChatError.
    func check() async throws -> (models: [String], note: String?) {
        let (status, data, _) = try await fetch(modelsRequest())
        if [429, 503, 529].contains(status) {
            return ([], ErrorBody(data).quota ? L("연결은 됐어요. ") + Self.failure(provider, status: status, body: data).message
                                              : L("연결은 됐어요. 잠깐 요청이 많았어요. 조금 뒤 연결 확인을 다시 해 주세요."))
        }
        guard status == 200 else { throw Self.failure(provider, status: status, body: data) }
        return (try chatModels(data), nil)
    }

    /// What the provider said, loosely: error.code / type / status / message, and Gemini's quotaId.
    struct ErrorBody {
        var code = "", message = "", quotaIDs: [String] = []

        init(_ data: Data) {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let e = json["error"] as? [String: Any] ?? [:]
            code = [e["code"], e["type"], e["status"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            message = e["message"] as? String ?? ""
            quotaIDs = (e["details"] as? [[String: Any]] ?? []).flatMap { $0["violations"] as? [[String: Any]] ?? [] }
                .compactMap { $0["quotaId"] as? String }
        }

        /// A limit that waiting a few seconds does not lift: no OpenAI credit, a used-up Gemini day.
        var quota: Bool { code.contains("insufficient_quota") || quotaIDs.contains { $0.contains("PerDay") } }
    }

    /// Busy or rate limited, not used up: nothing was billed for the turn, so one retry costs nothing.
    static func retryable(status: Int, body: Data) -> Bool {
        status == 503 || status == 529 || (status == 429 && !ErrorBody(body).quota)
    }

    /// Limit lines say 한도: GoalRunner.limitReset waits for the reset on that word.
    static func failure(_ provider: BYOProvider, status: Int, body: Data = Data()) -> ChatError {
        let e = ErrorBody(body), name = provider.label
        switch status {
        case 400 where provider == .claude && e.message.lowercased().contains("credit balance"), 402:
            return .server(L("\(name) 크레딧이 부족해요. \(name) 콘솔에서 결제를 확인해 주세요."))
        case 400 where provider == .gemini, 401, 403:   // Gemini answers a wrong key with 400 API_KEY_INVALID
            return .server(L("\(name) API 키가 맞지 않거나 권한이 없어요. 키를 다시 확인해 주세요."))
        case 429 where provider == .chatgpt && e.code.contains("insufficient_quota"):
            return .server(L("OpenAI 크레딧이 없어요. ChatGPT 구독과 API 요금은 따로예요. OpenAI 콘솔에서 결제를 확인해 주세요."))
        case 429 where provider == .gemini && e.quota:
            return .server(L("오늘 무료 사용 한도를 다 썼어요. 무료 키는 모델마다 하루 횟수가 정해져 있어요. 내일 다시 해 주세요."))
        case 429: return .server(L("\(name) 요청 한도에 잠깐 걸렸어요. 잠시 뒤 다시 물어봐 주세요."))
        case 404: return .server(L("\(name)에서 이 모델을 찾지 못했어요. 비서 설정에서 연결 확인을 다시 해 주세요."))
        case 503, 529: return .server(L("\(name) 서버가 붐벼요. 잠시 뒤 다시 물어봐 주세요."))
        case 500...599: return .server(L("\(name) 서버가 잠시 응답하지 않아요."))
        default:
            // The provider's own words help here; any key it echoes is masked, and nothing of ours is in them.
            let said = Redact.secrets(String(e.message.prefix(160)))
            return .server(L("\(name)가 답하지 못했어요 (\(status)).") + (said.isEmpty ? "" : " " + said))
        }
    }
}

// MARK: - Signed-in CLIs (direct build)

#if !MAS
/// The owner's subscription through a CLI signed in on this Mac: claude -p, codex exec, gemini -p. Same guard rails as
/// 내 Claude / 내 ChatGPT drawing: no API-key variables in the child, no MCP, no saved session, an empty working
/// folder, its own process group stopped on timeout. The question comes on stdin. Only claude switches every tool
/// off; codex (read-only sandbox) and gemini (tools that need no approval) keep read-only tools, so calendar lines
/// never go to them (BYOEngine.sendsPersonal).
struct BYOCLIClient {
    var provider: BYOProvider
    /// nil = found on PATH or in the usual folders. Tests point this at a fake.
    var binary: String?
    var environment = ProcessInfo.processInfo.environment
    var timeout: TimeInterval = 25

    static let folders = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.npm-global/bin"]
    /// Gemini CLI reads these for an API key or Vertex: without them it can only use its Google sign-in.
    static let geminiRemovedEnv = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA",
                                   "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "GOOGLE_APPLICATION_CREDENTIALS",
                                   "GEMINI_MODEL", "NODE_OPTIONS"]

    func path() -> String? {
        if let binary { return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil }
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (onPath + Self.folders.map { ($0 as NSString).expandingTildeInPath })
            .map { ($0 as NSString).appendingPathComponent(provider.cliName) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func childEnvironment(_ bin: String) -> [String: String] {
        switch provider {
        case .claude:
            var c = ClaudeCharacterClient()
            c.environment = environment   // token stays nil: the CLI's own sign-in, every ANTHROPIC_*/CLAUDE_CODE_* removed
            return c.childEnvironment(claude: bin)
        case .chatgpt:
            var c = ChatGPTCharacterClient()
            c.environment = environment
            return c.childEnvironment(codex: bin)
        case .gemini:
            var env = environment
            for k in Self.geminiRemovedEnv { env[k] = nil }
            let dirs = [(bin as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin"]
            env["PATH"] = (dirs + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
            return env
        }
    }

    static let notReady = L("이 맥의 AI 프로그램이 준비되지 않았어요.")

    /// Blocking (up to `timeout` per run); call it off the main thread. Throws ChatError.
    func reply(system: String, prompt: String) throws -> String {
        guard let bin = path() else { throw ChatError.unavailable(L("이 맥에서 \(provider.cliName) 프로그램을 찾지 못했어요.")) }
        let env = childEnvironment(bin)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-byo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = { (argv: [String], input: String?) in
            ChatGPTCharacterClient.run(argv, env: env, cwd: dir, input: input.map { Data($0.utf8) }, timeout: timeout)
        }
        switch provider {
        case .claude:
            // Fail closed, as the drawing does: no turn unless this CLI can switch every tool off.
            let help = try Self.cachedHelp(bin) { run([bin, "--help"], nil) }
            let r = run([bin] + Self.claudeArguments(help: help, system: system), prompt)
            if r.timedOut { throw BYOAPIClient.tooSlow(provider) }
            let json = Self.lastJSON(r.out)
            if let text = json?["result"] as? String, json?["is_error"] as? Bool != true, !text.isEmpty { return text }
            throw ChatError.server(ClaudeCharacterClient.failure(r.out, token: false)?.message ?? L("Claude가 답하지 못했어요."))
        case .chatgpt:
            // Only a ChatGPT sign-in (subscription), never an API key login.
            if !Self.codexSignedIn(bin) {
                let s = run([bin, "login", "status"], nil)
                let status = s.timedOut ? .unknown : ChatGPTCharacterClient.parseLogin(s.out, codex: bin)
                guard status.isReady else { throw ChatError.unavailable(status.note ?? Self.notReady) }
                Self.markCodexSignedIn(bin)
            }
            let last = dir.appendingPathComponent("last-message.txt")
            let r = run([bin] + Self.codexArguments(workdir: dir, lastMessage: last), Self.oneText(system, prompt))
            if r.timedOut { throw BYOAPIClient.tooSlow(provider) }
            if r.status == 0, let text = try? String(contentsOf: last, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty { return text }
            throw ChatError.server(ChatGPTCharacterClient.failure(r.out)?.message ?? L("ChatGPT가 답하지 못했어요."))
        case .gemini:
            let r = run([bin] + Self.geminiArguments, Self.oneText(system, prompt))
            if r.timedOut { throw BYOAPIClient.tooSlow(provider) }
            if let text = Self.lastJSON(r.out)?["response"] as? String, !text.isEmpty { return text }
            let t = r.out.lowercased()
            if t.contains("quota") || t.contains("429") { throw ChatError.server(L("Gemini 사용 한도에 도달했어요. 잠시 뒤 다시 해 주세요.")) }
            if t.contains("auth") || t.contains("login") || t.contains("credential") {
                throw ChatError.unavailable(L("이 맥의 Gemini CLI에 Google 계정으로 로그인되어 있지 않아요. 터미널에서 gemini 를 열어 로그인해 주세요."))
            }
            throw ChatError.server(L("Gemini가 답하지 못했어요."))
        }
    }

    /// `--version`, for 연결 확인 (never starts a turn). nil = ready, else why not.
    func check() -> String? {
        guard let bin = path() else { return L("이 맥에서 \(provider.cliName) 프로그램을 찾지 못했어요.") }
        let env = childEnvironment(bin)
        if provider == .chatgpt {
            let s = ChatGPTCharacterClient.run([bin, "login", "status"], env: env, timeout: 15)
            let status = s.timedOut ? .unknown : ChatGPTCharacterClient.parseLogin(s.out, codex: bin)
            if status.isReady { Self.markCodexSignedIn(bin) }
            return status.note
        }
        let r = ChatGPTCharacterClient.run([bin, "--version"], env: env, timeout: 15)
        return !r.timedOut && r.status == 0 ? nil : L("\(provider.cliName) 프로그램을 실행하지 못했어요.")
    }

    // MARK: Arguments

    /// Print mode, JSON result, no tools at all, no settings/hooks/plugins/MCP, no saved session, low effort.
    static func claudeArguments(help: String, system: String) -> [String] {
        var a = ["-p", "--output-format", "json", "--tools", "", "--restricted",
                 "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--system-prompt", system]
        for flag in ["--no-session-persistence", "--safe-mode"] where help.contains(flag) { a.append(flag) }
        if help.contains("--permission-prompts") { a += ["--permission-prompts", "none"] }
        if help.contains("--effort") { a += ["--effort", "low"] }
        return a
    }

    /// Non-interactive, no user config, no saved session, read-only sandbox in the empty folder, never asks.
    static func codexArguments(workdir: URL, lastMessage: URL) -> [String] {
        ["exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--color", "never", "--sandbox", "read-only",
         "-c", #"approval_policy="never""#, "-c", #"model_reasoning_effort="low""#,
         "-C", workdir.path, "-o", lastMessage.path, "-"]
    }

    /// Headless, JSON out, no extensions, no MCP server allowed, tools that need approval are never run.
    static let geminiArguments = ["-p", "위 [사용자 질문]에 답해.", "--output-format", "json", "--approval-mode", "default",
                                  "-e", "none", "--allowed-mcp-server-names", "none"]

    /// codex and gemini take no separate system prompt here: the rules go first in the same text.
    static func oneText(_ system: String, _ prompt: String) -> String { "[답하는 규칙]\n\(system)\n\n\(prompt)" }

    /// The last JSON object printed (stderr notes like "Loaded cached credentials." come before it).
    static func lastJSON(_ out: String) -> [String: Any]? {
        let lines = out.components(separatedBy: "\n")
        for i in lines.indices.reversed() where lines[i].hasPrefix("{") {
            let tail = lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let o = (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any] { return o }
        }
        return nil
    }


    // MARK: Per-run memory (claude --help, codex sign-in)

    private static let lock = NSLock()
    private static var helps: [String: String] = [:]
    private static var codexOK = Set<String>()

    static func cachedHelp(_ bin: String, _ run: () -> (status: Int32, out: String, timedOut: Bool)) throws -> String {
        if let h = lock.withLock({ helps[bin] }) { return h }
        let r = run()
        guard !r.timedOut, r.status == 0 else { throw ChatError.unavailable(ClaudeCharacterClient.Status.unknown.note!) }
        guard r.out.contains("--restricted"), r.out.contains("--tools") else { throw ChatError.unavailable(ClaudeCharacterClient.noSafeMode) }
        lock.withLock { helps[bin] = r.out }
        return r.out
    }

    static func codexSignedIn(_ bin: String) -> Bool { lock.withLock { codexOK.contains(bin) } }
    static func markCodexSignedIn(_ bin: String) { lock.withLock { _ = codexOK.insert(bin) } }
}
#endif

// MARK: - The engine

/// 내 AI as a ChatEngine. A failed answer (key, limit, network, 25 s) is answered by this Mac's engine instead, and the
/// reason waits in BYOSettings.lastFailure (비서 설정 and the line under the chat show it).
struct BYOEngine: ChatEngine {
    var provider: BYOProvider
    var method: BYOMethod
    var model: String
    /// Tests swap these; the app uses the Keychain and the network.
    var key: () -> String? = { nil }
    var transport: BYOAPIClient.Transport = { try await BYOAPIClient.session.data(for: $0) }
    var fallback: ChatEngine? = OnDeviceEngine.isAvailable ? OnDeviceEngine.shared : nil
    var report: (String?) async -> Void = { why in await MainActor.run { BYOSettings.shared.lastFailure = why } }
    /// The model that wrote a good answer (the chat shows it under the bubble).
    var answered: (String) async -> Void = { m in await MainActor.run { BYOSettings.shared.lastModel = m } }
    /// The last 연결 확인 model list (the agent's reviewer picks the cheapest from it).
    var availableModels: [String] = []

    var strong: Bool { true }

    var label: String {
        let how = method == .cli ? L("구독 계정") : L("내 API 키")
        return L("\(provider.label)(\(how))로 답해요. 질문과 필요한 맥 숫자만 보내요.")
    }

    /// The engine for this question when the owner connected one and the question may leave the
    /// Mac (calendar and inbox questions only with sharePersonal). nil = the usual engines.
    @MainActor static func active(intent: AssistantIntent?, _ s: BYOSettings = .shared) -> BYOEngine? {
        guard let p = s.provider else { return nil }
        if !sendsPersonal(s), intent == .schedule || intent == .inbox { return nil }
        #if MAS
        if s.method == .cli || !s.consented(p) { return nil }
        #endif
        var e = BYOEngine(provider: p, method: s.method, model: s.model(p))
        e.key = { AIKeychain.load(p) }
        e.availableModels = s.available[p] ?? []
        return e
    }

    /// Calendar titles can come from anyone (an invitation). codex and gemini keep read-only tools that could act on
    /// a title's instructions and read files, so through those CLIs they stay on this Mac whatever the switch says.
    @MainActor static func sendsPersonal(_ s: BYOSettings) -> Bool {
        s.sharePersonal && !(s.method == .cli && s.provider != .claude)
    }

    func reply(_ request: ChatRequest) async throws -> String {
        do {
            let (text, used) = try await primary(request)
            await answered(used)
            await report(nil)
            return text
        } catch {
            let why = (error as? ChatError)?.message ?? ChatError.other.message
            await report(why)
            guard let fallback else { throw error }   // no Apple Intelligence: the template answer, with why
            return try await fallback.reply(request)
        }
    }

    private func primary(_ r: ChatRequest) async throws -> (String, String) {
        let system = r.persona.instructions(strong: true)
        switch method {
        case .apiKey:
            guard let key = key(), !key.isEmpty else { throw ChatError.unavailable(L("\(provider.label) API 키가 없어요. 비서 설정에서 넣어 주세요.")) }
            let lite = provider == .gemini ? BYOAPIClient.lite(availableModels, current: model) : nil
            let a = try await BYOAPIClient(provider: provider, key: key, transport: transport).answer(model: model, system: system, prompt: r.prompt, lite: lite)
            return (a.text, a.model)
        case .cli:
            #if MAS
            throw ChatError.unavailable(L("앱 스토어 버전은 이 맥의 AI 프로그램을 쓸 수 없어요. API 키로 연결해 주세요."))
            #else
            let cli = BYOCLIClient(provider: provider)
            let prompt = r.prompt
            return (try await Task.detached { try cli.reply(system: system, prompt: prompt) }.value, model)
            #endif
        }
    }
}
