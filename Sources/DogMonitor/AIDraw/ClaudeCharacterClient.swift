#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import AppKit

/// "내 Claude (Sonnet 5)": the owner's own Claude subscription, through the Claude Code CLI on this Mac, draws the
/// character as ASCII frames like the bundled originals' (FrameArt). Never an API key and never a server. The subscription is the
/// personal `claude setup-token` token from the Keychain (passed as CLAUDE_CODE_OAUTH_TOKEN), or, only when the user
/// turned it on, whatever account this Mac's CLI is signed into. Two turns: draw, then look at the app's own render
/// of the frames and fix them (한 번 더 다듬기).
struct ClaudeCharacterClient {
    enum Status: Equatable {
        case ready(claude: String, token: Bool)
        case missing
        case notConnected
        case unknown

        var isReady: Bool { if case .ready = self { return true }; return false }
        var note: String? {
            switch self {
            case .ready: return nil
            case .missing: return L("이 맥에 Claude Code가 없어요. Claude Code를 설치하면 쓸 수 있어요.")
            case .notConnected: return L("설정 > Claude 연결에서 개인 토큰을 넣거나 이 맥의 Claude Code 로그인 사용을 켜 주세요.")
            case .unknown: return L("Claude Code를 실행하지 못했어요. 다시 확인해 주세요.")
            }
        }
    }

    static let model = "claude-sonnet-5"
    /// Anything that could send the turn to an API key, another endpoint or another identity (every ANTHROPIC_*),
    /// a cloud provider, or a debugger, and the markers of a parent Claude Code session (QA runs from one).
    /// CLAUDE_CODE_OAUTH_TOKEN is set again only from the Keychain.
    static let removedEnv = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE",
                             "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_SERVICE_ACCOUNT_ID", "ANTHROPIC_WORKSPACE_ID",
                             "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                             "CLAUDE_CODE_OAUTH_TOKEN", "NODE_OPTIONS", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"]
    /// Every CLAUDE_CODE_* too: provider switches and a parent session's id, socket and token. CLAUDE_CONFIG_DIR stays.
    static let removedPrefixes = ["ANTHROPIC_", "CLAUDE_CODE_"]
    static let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]

    /// nil = the first installed candidate. QA and tests point this at a fake.
    var claude: String?
    var environment = ProcessInfo.processInfo.environment
    /// The Keychain token; nil uses the CLI's own sign-in, and only when `useCLILogin`.
    var token: String?
    /// Read the token from the Keychain only inside `status()` (existence) and `draw()` (data), off the main thread:
    /// an ad-hoc signed rebuild makes every data read show the Keychain's allow dialog.
    var keychain = false
    var useCLILogin = false
    /// 한 번 더 다듬기: a second turn that sees the rendered sheet.
    var refine = true
    var versionTimeout: TimeInterval = 15
    var timeout: TimeInterval = 600
    var maxTurns = 8
    var styleReference: URL? = ChatGPTCharacterClient.bundledStyleReference

    /// As the settings say now: the Keychain token, the CLI-login opt-in and 한 번 더 다듬기.
    static func current(_ settings: AppSettings = .shared) -> ClaudeCharacterClient {
        var c = ClaudeCharacterClient()
        c.keychain = true
        c.useCLILogin = settings.claudeUseCLILogin
        c.refine = settings.claudeRefine
        return c
    }

    /// This session's answer; saving or clearing the token, or 다시 확인, drops it. Main thread only.
    static var cached: Status?

    func claudePath() -> String? {
        let paths = claude.map { [$0] } ?? Self.candidates.map { ($0 as NSString).expandingTildeInPath }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func childEnvironment(claude: String) -> [String: String] {
        var env = environment.filter { key, _ in
            !Self.removedEnv.contains(key) && !Self.removedPrefixes.contains { key.hasPrefix($0) }
        }
        let dirs = [(claude as NSString).deletingLastPathComponent,
                    ((claude as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent,
                    "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (dirs + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        if let token { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        return env
    }

    /// `claude --version`, blocking (up to `versionTimeout`); run it off the main thread. Never starts a turn.
    func status() -> Status {
        guard let claude = claudePath() else { return .missing }
        let hasToken = token != nil || (keychain && ClaudeToken.exists())
        guard hasToken || useCLILogin else { return .notConnected }
        let r = ChatGPTCharacterClient.run([claude, "--version"], env: childEnvironment(claude: claude), timeout: versionTimeout)
        guard !r.timedOut, r.status == 0, r.out.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil else { return .unknown }
        return .ready(claude: claude, token: hasToken)
    }

    // MARK: Drawing

    static let noFrames = L("Claude가 그림(frames.json)을 만들지 못했어요. 다시 해 보거나 다른 방법을 골라 주세요.")
    static let tooSlow = L("Claude가 너무 오래 걸려요. 잠시 뒤 다시 해 주세요.")
    static let noSafeMode = L("이 Claude Code 버전은 안전 모드를 지원하지 않아요. 업데이트해 주세요.")
    /// frames.json is 7 poses x 8 frames x 20 rows x 34 columns at most, about 40 KB; anything far past that is not frames.
    static let maxFramesBytes = 256 * 1024

    /// Pass 1 draws frames.json from the photos and the style guide; pass 2 (when `refine`) reads the app's 8x render
    /// of it and writes a better one. A failed or broken pass 2 keeps pass 1. `progress(step, steps)`.
    func draw(photos: [CustomSlot: CGImage], progress: (Int, Int) -> Void = { _, _ in }) throws -> FrameArt {
        if keychain {   // the token's data, read here on the drawing thread, never on main
            var c = self
            c.keychain = false
            c.token = token ?? ClaudeToken.load()
            return try c.draw(photos: photos, progress: progress)
        }
        guard !photos.isEmpty else { throw AICharacterClient.Failure(message: L("그림을 한 장 이상 넣어 주세요.")) }
        guard let claude = claudePath() else { throw AICharacterClient.Failure(message: Status.missing.note!) }
        guard token != nil || useCLILogin else { throw AICharacterClient.Failure(message: Status.notConnected.note!) }
        guard let style = styleReference, FileManager.default.fileExists(atPath: style.path) else {
            throw AICharacterClient.Failure(message: L("스타일 기준 그림을 찾지 못했어요. 앱을 다시 설치해 주세요."))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Everything Claude may Read sits in its own working folder: the only place its file tools reach.
        try FileManager.default.copyItem(at: style, to: dir.appendingPathComponent("style-ref.png"))
        var names: [String] = []
        for slot in CustomSlot.allCases {
            guard let photo = photos[slot] else { continue }
            guard let jpeg = AICharacterClient.jpeg(photo) else { throw AICharacterClient.Failure(message: L("사진을 준비하지 못했어요. 다른 사진으로 해 보세요.")) }
            try jpeg.write(to: dir.appendingPathComponent("photo-\(slot.rawValue).jpg"))
            names.append("photo-\(slot.rawValue).jpg")
        }
        let env = childEnvironment(claude: claude)
        // Fail closed: no turn unless this CLI can confine it (--tools, --restricted).
        let h = ChatGPTCharacterClient.run([claude, "--help"], env: env, timeout: versionTimeout)
        try Task.checkCancellation()
        guard !h.timedOut, h.status == 0 else { throw AICharacterClient.Failure(message: Status.unknown.note!) }
        let help = h.out
        guard help.contains("--restricted"), help.contains("--tools") else { throw AICharacterClient.Failure(message: Self.noSafeMode) }
        let argv = [claude] + Self.arguments(help: help, maxTurns: maxTurns)
        let steps = refine ? 2 : 1

        try Task.checkCancellation()
        progress(1, steps)
        let first = ChatGPTCharacterClient.run(argv, env: env, cwd: dir, input: Data(Self.drawPrompt(photos: names).utf8), timeout: timeout)
        try Task.checkCancellation()
        if first.timedOut { throw AICharacterClient.Failure(message: Self.tooSlow) }
        let art = try pickup(dir, first.out)
        guard refine else { return art }

        try Task.checkCancellation()
        progress(2, steps)
        try Self.png(SpritePreview.sheet(art.nativeFrames())).write(to: dir.appendingPathComponent("sheet.png"))
        let second = ChatGPTCharacterClient.run(argv, env: env, cwd: dir, input: Data(Self.refinePrompt(photos: names).utf8), timeout: timeout)
        try Task.checkCancellation()
        guard !second.timedOut else { return art }
        return (try? pickup(dir, second.out)) ?? art
    }

    /// frames.json from the turn's folder, checked and repaired; else the turn's own error in Korean.
    private func pickup(_ dir: URL, _ output: String) throws -> FrameArt {
        let url = dir.appendingPathComponent("frames.json")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxFramesBytes, let data = try? Data(contentsOf: url) else {
            throw Self.failure(output, token: token != nil) ?? AICharacterClient.Failure(message: Self.noFrames)
        }
        do { return try FrameArt.parse(data) } catch {
            throw Self.failure(output, token: token != nil) ?? error
        }
    }

    /// Print mode, JSON result, the Sonnet 5 model, no prompts, only Read and Write, a few turns, no MCP servers, no
    /// user settings/hooks/plugins, file tools confined to the folder (`draw` refuses a CLI without --tools and
    /// --restricted), and when this CLI has them no saved session and no customizations.
    /// No shell anywhere: the app spawns claude directly and the prompt comes on stdin.
    static func arguments(help: String, maxTurns: Int) -> [String] {
        var a = ["-p", "--model", model, "--output-format", "json", "--permission-mode", "acceptEdits",
                 "--tools", "Read,Write", "--restricted",
                 "--allowedTools", "Read(./**)", "Write(./frames.json)",
                 "--disallowedTools", "Bash,WebFetch,WebSearch,Edit,MultiEdit,NotebookEdit,Task,Agent",
                 "--max-turns", String(maxTurns), "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        for flag in ["--no-session-persistence", "--safe-mode"] where help.contains(flag) { a.append(flag) }
        if help.contains("--permission-prompts") { a += ["--permission-prompts", "none"] }
        return a
    }

    // MARK: Prompts

    static let contract = """
    frames.json is one JSON object:
    {"palette": {"<one character>": "#RRGGBB", ...}, "poses": {"lying": [frame, ...], "slowWalk": [...], "walk": [...], "fastWalk": [...], "run": [...], "sprint": [...], "exhausted": [...]}}
    - A frame is an array of exactly 20 strings, each exactly 34 characters: one character per art pixel, "." is transparent.
    - Every character used must be a palette key (one printable ASCII character, not "." or a space). At most 16 colours, flat, no near-duplicates.
      Include a dark outline colour.
    - The subject faces RIGHT, chibi: big head about half its height, small body, about 14 to 18 rows tall and at most 28 columns wide.
    - A continuous 1-pixel dark outline around the whole silhouette. Flat shading, at most one shade and one highlight per area.
    - Feet (or paws) on the same ground row, row 19 (the last row), in every frame except hops. Keep the body in the same
      place between frames of a pose so it does not jitter.
    - lying: 1 to 3 frames, asleep (eyes closed, lying down), slow breathing between frames.
    - slowWalk, walk, fastWalk: 4 frames each, a walk cycle with the legs alternating; faster poses lean a little forward.
    - run, sprint: 4 to 6 frames each, a gallop (legs stretched, then gathered, body bobbing, ears/hair flying back).
    - exhausted: 4 to 6 frames, panicking: tongue out, sweat drops, flailing, still running.
    - No text, no ground line, no background, nothing outside the character except sweat drops in exhausted.
    """

    /// The tan cat's first walking frame, to show the format and the level of detail (its palette is not the subject's).
    static var example: String {
        (try? FrameArt.parse(Data(OriginalArt.tanCat.utf8)))?.poses[FrameArt.key(.walk)]?.first?.joined(separator: "\n") ?? ""
    }

    static func drawPrompt(photos: [String]) -> String {
        """
        You are drawing a tiny pixel-art character for a macOS menu bar app. Work only in the current folder.

        1. Read style-ref.png: the style guide (hand-drawn dogs and a cat at 8x). Match its chunky pixels, 1-pixel dark
           outline, flat colours and chibi proportions. Its characters are NOT the subject.
        2. Read \(photos.joined(separator: ", ")): the subject. Keep its species, colours, markings, hair and clothes.
        3. Write frames.json with every pose of the subject, following this contract exactly:

        \(contract)

        The format, shown with the app's own tan cat (walk, first frame; rows top to bottom):
        \(example)

        Count every row: 20 rows of 34 characters. Use only the Read and Write tools, write only frames.json, nothing else.
        Reply with the single word: done
        """
    }

    static func refinePrompt(photos: [String]) -> String {
        """
        You drew frames.json in the current folder for a macOS menu bar pixel-art character. Improve it.

        1. Read \(photos.joined(separator: ", ")) (the subject), style-ref.png (the style guide, not the subject),
           frames.json (your frames) and sheet.png (the app's own render of frames.json at 8x: rows top to bottom are
           lying, slowWalk, walk, fastWalk, run, sprint, exhausted; columns are the frames).
        2. List briefly what looks wrong compared with the photo and the style guide: likeness and colours, outline gaps,
           proportions, stray pixels, feet off the last row, legs not alternating, jitter between frames, poses that read wrong.
        3. Write an improved frames.json that fixes them, following the same contract exactly:

        \(contract)

        Count every row: 20 rows of 34 characters. Use only the Read and Write tools, write only frames.json, nothing else.
        Reply with the list, then the word: done
        """
    }

    // MARK: Errors

    /// A failed turn's JSON result and stderr as a short Korean reason; nil when none fits. `token`: a Keychain token
    /// was used (so an auth error means that token, not the CLI's sign-in).
    static func failure(_ output: String, token: Bool) -> AICharacterClient.Failure? {
        let t = output.lowercased()
        if t.contains("hit your limit") || t.contains("usage limit") || t.contains("limit reached") || t.contains("rate_limit") {
            return .init(message: L("Claude 사용 한도에 도달했어요. \(resetTime(output).map { L("\($0) 이후에") } ?? L("한도가 풀린 뒤")) 다시 시도해 주세요."))
        }
        let badToken = ["invalid bearer token", "oauth token revoked", "oauth token has expired", "token_invalid", "invalid api key",
                        "authentication_error", "401 unauthorized", "api error: 401", "status 401"].contains { t.contains($0) }
        let signedOut = ["not logged in", "please run /login", "run /login", "authentication required"].contains { t.contains($0) }
        if badToken || signedOut {
            if token { return .init(message: L("저장한 개인 토큰이 맞지 않거나 만료됐어요. 터미널에서 claude setup-token 으로 새 토큰을 만들어 설정 > Claude 연결에 넣어 주세요.")) }
            return .init(message: signedOut ? L("이 맥의 Claude Code에 로그인되어 있지 않아요. 터미널에서 claude 를 열어 /login 하거나, 설정 > Claude 연결에 개인 토큰을 넣어 주세요.")
                                            : L("이 맥의 Claude Code 로그인이 만료됐어요. 터미널에서 claude 를 열어 /login 해 주세요."))
        }
        if t.contains(model), t.range(of: #"not[_ ]found|does not exist|not available|invalid model|isn't available"#, options: .regularExpression) != nil {
            return .init(message: L("이 계정에서는 \(model) 모델을 쓸 수 없어요."))
        }
        return nil
    }

    /// "resets 7pm (Asia/Seoul)" as "오후 7:00", "…limit reached|1759302000" as "10월 1일 오후 4:00"; the raw words otherwise.
    static func resetTime(_ output: String) -> String? {
        let show = DateFormatter()
        show.locale = appLocale
        if let r = output.range(of: #"limit reached\|\d{9,11}"#, options: .regularExpression),
           let epoch = Double(output[r].split(separator: "|").last ?? "") {
            show.setLocalizedDateFormatFromTemplate("MMMdhmm")   // 10월 1일 오후 4:00
            return show.string(from: Date(timeIntervalSince1970: epoch))
        }
        guard let r = output.range(of: #"resets (at )?[^\n"·\\]+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = output[r].replacingOccurrences(of: #"^resets (at )?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        // Shown as templates in the app's locale: "hmm" = 오후 7:00, "MMMdhmm" = 10월 1일 오후 4:00.
        for (format, shown) in [("ha", "hmm"), ("h:mma", "hmm"), ("h a", "hmm"), ("h:mm a", "hmm"),
                                ("MMM d, ha", "MMMdhmm"), ("MMM d, h:mma", "MMMdhmm"),
                                ("MMM d 'at' ha", "MMMdhmm"), ("MMM d 'at' h:mma", "MMMdhmm")] {
            parse.dateFormat = format
            if let date = parse.date(from: raw) { show.setLocalizedDateFormatFromTemplate(shown); return show.string(from: date) }
        }
        return raw.isEmpty ? nil : raw
    }

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
#endif
