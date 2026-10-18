#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import AppKit

/// "내 ChatGPT": pixel art (or, for 자동 다듬기, the missing poses) drawn by the Codex CLI signed in with ChatGPT on
/// this Mac, for this Mac's own user. Only ChatGPT sign-in is accepted (never an API key, never a server), the child gets an
/// environment without OpenAI keys, and ~/.codex is never read by the app.
struct ChatGPTCharacterClient {
    enum Status: Equatable {
        case ready(codex: String)
        case missing
        case signedOut
        case apiKey
        case unknown

        var isReady: Bool { if case .ready = self { return true }; return false }
        /// Why 내 ChatGPT is off, under the picker.
        var note: String? {
            switch self {
            case .ready: return nil
            case .missing: return L("이 맥에 Codex(ChatGPT)가 없어요. Codex를 설치하고 ChatGPT로 로그인하면 쓸 수 있어요.")
            case .signedOut: return L("Codex에 ChatGPT로 로그인되어 있지 않아요. 터미널에서 codex login 으로 로그인해 주세요.")
            case .apiKey: return L("Codex가 API 키로 로그인되어 있어요. 내 ChatGPT는 ChatGPT 로그인에서만 써요.")
            case .unknown: return L("ChatGPT 로그인을 확인하지 못했어요.")
            }
        }
    }

    /// Every credential the codex binary reads from the environment: with any of them codex could bill an API key or
    /// another identity while `codex login status` still says ChatGPT.
    static let removedEnv = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_REFRESH_TOKEN_URL_OVERRIDE",
                             "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID", "OPENAI_FEDERATION_RULE_ID",
                             "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_WORKLOAD_IDENTITY_CONTEXT", "NODE_OPTIONS"]
    static let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]

    /// nil = the first installed candidate. QA and tests point this at a fake.
    var codex: String?
    var environment = ProcessInfo.processInfo.environment
    var loginTimeout: TimeInterval = 15
    var timeout: TimeInterval = 180
    var styleReference: URL? = Self.bundledStyleReference

    /// Contents/Resources/style-ref.png in the app, Resources/style-ref.png when run from the project folder.
    static var bundledStyleReference: URL? {
        Bundle.main.url(forResource: "style-ref", withExtension: "png")
            ?? [URL(fileURLWithPath: "Resources/style-ref.png")].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func codexPath() -> String? {
        let paths = codex.map { [$0] } ?? Self.candidates.map { ($0 as NSString).expandingTildeInPath }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The caller's environment without OpenAI keys, with the codex folder (and Homebrew's, for its `node`) on PATH:
    /// an app started from Finder has only /usr/bin:/bin.
    func childEnvironment(codex: String) -> [String: String] {
        var env = environment
        for key in Self.removedEnv { env[key] = nil }
        let dirs = [(codex as NSString).deletingLastPathComponent,
                    ((codex as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent,
                    "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (dirs + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }

    // MARK: Sign-in

    /// `codex login status`, blocking (up to `loginTimeout`); run it off the main thread.
    func status() -> Status {
        guard let codex = codexPath() else { return .missing }
        let r = Self.run([codex, "login", "status"], env: childEnvironment(codex: codex), timeout: loginTimeout)
        return r.timedOut ? .unknown : Self.parseLogin(r.out, codex: codex)
    }

    static func parseLogin(_ text: String, codex: String) -> Status {
        let t = text.lowercased()
        if t.contains("logged in using chatgpt") { return .ready(codex: codex) }
        if t.range(of: #"api[- ]key"#, options: .regularExpression) != nil { return .apiKey }
        if t.contains("not logged in") || t.contains("signed out") { return .signedOut }
        return .unknown
    }

    /// This session's answer, so opening the creator again does not rerun codex; 다시 확인 refreshes it. Main thread only.
    static var cached: Status?

    // MARK: Drawing

    /// One codex turn per pose, one after another. A pose without its own photo is drawn from the nearest one
    /// (CustomSlot.source order). Keeps whatever came back; throws when nothing did.
    /// `real`: the creator's automatic 다듬기, photos of only the poses without a photo (realPrompt).
    func draw(photos: [CustomSlot: CGImage], real: Bool = false, progress: (Int, Int) -> Void = { _, _ in }) throws -> [CustomSlot: CGImage] {
        guard !photos.isEmpty else { throw AICharacterClient.Failure(message: L("그림을 한 장 이상 넣어 주세요.")) }
        guard let codex = codexPath() else { throw AICharacterClient.Failure(message: Status.missing.note!) }
        let login = Self.run([codex, "login", "status"], env: childEnvironment(codex: codex), timeout: loginTimeout)
        let auth = login.timedOut ? .unknown : Self.parseLogin(login.out, codex: codex)
        guard auth.isReady else { throw AICharacterClient.Failure(message: auth.note!) }
        let style = real ? nil : styleReference
        guard real || style.map({ FileManager.default.fileExists(atPath: $0.path) }) == true else {
            throw AICharacterClient.Failure(message: L("스타일 기준 그림을 찾지 못했어요. 앱을 다시 설치해 주세요."))
        }
        let jobs = CustomSlot.allCases.filter { !real || photos[$0] == nil }
            .compactMap { slot in slot.source(among: Set(photos.keys)).flatMap { photos[$0] }.map { (slot, $0) } }
        var out: [CustomSlot: CGImage] = [:], firstError: AICharacterClient.Failure?
        for (i, (slot, photo)) in jobs.enumerated() {
            try Task.checkCancellation()   // the creator was closed: no more turns
            progress(i + 1, jobs.count)
            do {
                out[slot] = try drawOne(slot, photo, style: style, real: real, codex: codex)
            } catch let failure as AICharacterClient.Failure {
                firstError = firstError ?? failure
                if failure.message != Self.noPicture { break }   // limit, sign-in, plan, timeout: the next would fail too
            }
        }
        if out.isEmpty { throw firstError ?? AICharacterClient.Failure(message: Self.noPicture) }
        return out
    }

    static let noPicture = L("ChatGPT가 그림을 만들지 못했어요. 사진을 다시 넣으면 다시 그려요.")

    private func drawOne(_ slot: CustomSlot, _ photo: CGImage, style: URL?, real: Bool, codex: String) throws -> CGImage {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-chatgpt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photoURL = dir.appendingPathComponent("photo-\(slot.rawValue).jpg")
        let output = dir.appendingPathComponent("out-\(slot.rawValue).png")
        guard let jpeg = AICharacterClient.jpeg(photo) else { throw AICharacterClient.Failure(message: L("사진을 준비하지 못했어요. 다른 사진으로 해 보세요.")) }
        try jpeg.write(to: photoURL)
        let args = Self.arguments(workdir: dir, lastMessage: dir.appendingPathComponent("last-message.txt"),
                                  images: (style.map { [$0] } ?? []) + [photoURL])
        let text = real ? Self.realInstruction(slot, output: output) : Self.instruction(slot, output: output)
        let r = Self.run([codex] + args, env: childEnvironment(codex: codex), cwd: dir, input: Data(text.utf8), timeout: timeout)
        try Task.checkCancellation()
        if r.timedOut { throw AICharacterClient.Failure(message: L("ChatGPT가 너무 오래 걸려요. 잠시 뒤 다시 해 주세요.")) }
        if r.status == 0, let image = CustomSprite.load(url: output) { return image }
        throw Self.failure(r.out) ?? AICharacterClient.Failure(message: Self.noPicture)
    }

    /// Non-interactive, no user config, no saved session, writes only inside `workdir` (not /tmp or $TMPDIR, which
    /// workspace-write opens by default), never asks. The attachments go
    /// in order (style guide, then photo) and the instruction comes on stdin ("-").
    static func arguments(workdir: URL, lastMessage: URL, images: [URL]) -> [String] {
        ["exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--json", "--color", "never",
         "--sandbox", "workspace-write",
         "-c", "sandbox_workspace_write.exclude_slash_tmp=true", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
         "-c", #"approval_policy="never""#, "-c", #"model_reasoning_effort="low""#]
            + images.flatMap { ["--image", $0.path] }
            + ["-C", workdir.path, "-o", lastMessage.path, "-"]
    }

    /// The drawing prompt (prompt()), passed through unchanged, and where to save the result.
    static func instruction(_ slot: CustomSlot, output: URL) -> String {
        """
        Use $imagegen exactly once through Codex's built-in image generation capability.
        Pass both attached images into that one call, in order: attached image 1 is the style guide, attached image 2 is the photo.
        Pass the text between BEGIN PROMPT and END PROMPT through unchanged as the image prompt. Square 1:1 image.

        BEGIN PROMPT
        \(prompt(slot))
        END PROMPT

        Use only the signed-in ChatGPT subscription. Never use OPENAI_API_KEY, the Images API or any other provider.
        Save exactly one final PNG to this path: \(output.path)
        Do not create or change any other file. Your final response must contain only the saved path.
        """
    }

    /// realPrompt word for word, with the photo as the only attachment.
    static func realInstruction(_ slot: CustomSlot, output: URL) -> String {
        """
        Use $imagegen exactly once through Codex's built-in image generation capability.
        Pass the attached image into that one call. Pass the text between BEGIN PROMPT and END PROMPT through unchanged
        as the image prompt. Square 1:1 image.

        BEGIN PROMPT
        \(realPrompt(slot))
        END PROMPT

        Use only the signed-in ChatGPT subscription. Never use OPENAI_API_KEY, the Images API or any other provider.
        Save exactly one final PNG to this path: \(output.path)
        Do not create or change any other file. Your final response must contain only the saved path.
        """
    }

    static func realPrompt(_ slot: CustomSlot) -> String {
        let pose: String
        switch slot {
        case .rest: pose = "lying down asleep on its belly, eyes closed, head resting low (a person: lying down asleep)"
        case .normal: pose = "walking to the right, one front leg forward (a person: walking, one foot forward)"
        case .busy: pose = "running fast to the right, mid-stride, body stretched low (a pet: ears flying back, tongue out; a person: sprinting)"
        }
        return "The subject of the attached image again, the very same individual: keep its exact species or breed, face, "
            + "fur or hair colour, markings, body shape and clothes, and keep the image's own style (a photo stays a photo, "
            + "an illustration stays in that same drawing style). Natural colours, sharp, clean, high detail, soft even light. "
            + "Full body with a small margin, side view facing right. Pose: \(pose). "
            + "Exactly one subject, centred, on a plain flat light grey (#E8E8E8) background. "
            + "No other animals or people, no objects, no furniture, no text, no watermark, no border, no ground shadow."
    }

    /// The pose words (the renderer adds sweat, speed lines and the Z itself).
    static func prompt(_ slot: CustomSlot) -> String {
        let pose: String
        switch slot {
        case .rest: pose = "lying down flat on its belly, eyes closed, facing right (a person: lying down asleep)"
        case .normal: pose = "walking to the right, one front leg forward (a person: one foot forward)"
        case .busy: pose = "running fast to the right, body stretched low (a pet: ears flying back, tongue out)"
        }
        return "The FIRST image is a style guide only: match its chunky pixels, 1-pixel dark outline, flat shading and chibi proportions. "
            + "The animals in it are NOT the subject. "
            + "Draw the subject of the SECOND image (a photo) as ONE full-body chibi pixel-art character: keep its own species, "
            + "colours, markings, hair and clothes; big head about half the height, small body. "
            + "Side view facing right. Pose: \(pose). "
            + "The character is about 17 art pixels tall and at most 26 wide. Draw every art pixel as one same-size square block "
            + "of about 32x32 image pixels, all aligned to one grid. At most 12 flat colours, no anti-aliasing, no dithering, "
            + "no gradients, no semi-transparent pixels. One continuous 1-pixel dark outline around the whole silhouette. "
            + "Exactly one character, centred, on a flat pure magenta (#FF00FF) background, a colour that appears nowhere on the character. "
            + "No sweat, no motion lines, no Z, no hearts, no effects, no text, no frame, no border, no shadow, no ground, no other objects."
    }

    // MARK: Errors

    /// A failed turn's JSONL events and stderr, mapped to a short Korean reason; nil when none fits.
    static func failure(_ output: String) -> AICharacterClient.Failure? {
        let t = output.lowercased()
        if t.contains("usage limit") {
            return .init(message: L("ChatGPT 사용 한도에 도달했어요. \(retryTime(output).map { L("\($0) 이후에") } ?? L("한도가 풀린 뒤")) 다시 시도해 주세요."))
        }
        if t.contains("not logged in") || t.contains("please log in") || t.contains("401 unauthorized") {
            return .init(message: Status.signedOut.note!)
        }
        if t.range(of: #"image[ _]gen\w*[^\n]{0,160}(not available|unavailable|not enabled|not supported)"#, options: .regularExpression) != nil
            || t.range(of: #"free plan[^\n]{0,160}image"#, options: .regularExpression) != nil {
            return .init(message: L("지금 ChatGPT 요금제에서는 그림 만들기를 쓸 수 없어요."))
        }
        return nil
    }

    /// "try again at Oct 5th, 2026 7:44 AM." as "10월 5일 오전 7:44"; the raw words when they do not parse.
    static func retryTime(_ output: String) -> String? {
        guard let r = output.range(of: #"try again (at|after) [^.\n"]+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = output[r].replacingOccurrences(of: #"^try again (at|after) "#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        let clean = raw.replacingOccurrences(of: #"(\d+)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        let show = DateFormatter()
        show.locale = appLocale
        // Shown as templates in the app's locale: "MMMdhmm" = 10월 5일 오전 7:44, "hmm" = 오전 7:44.
        for (format, shown) in [("MMM d, yyyy h:mm a", "MMMdhmm"), ("MMM d, yyyy, h:mm a", "MMMdhmm"),
                                ("MMM d h:mm a", "MMMdhmm"), ("h:mm a", "hmm")] {
            parse.dateFormat = format
            if let date = parse.date(from: clean) { show.setLocalizedDateFormatFromTemplate(shown); return show.string(from: date) }
        }
        return raw
    }

    // MARK: Process

    private final class Box { var data = Data() }

    /// Process groups of the codex turns still running, stopped when the app quits so none is left using ChatGPT.
    private static var live = Set<pid_t>()
    private static let liveLock = NSLock()

    static func stopAll() {
        liveLock.lock(); let groups = live; liveLock.unlock()
        for g in groups { kill(-g, SIGTERM) }
    }

    /// stdout and stderr together. The child leads its own process group (codex is a node wrapper around the native
    /// binary), so overrunning `timeout` or cancelling the task sends SIGTERM, then SIGKILL, to that whole subtree.
    static func run(_ argv: [String], env: [String: String], cwd: URL? = nil, input: Data? = nil,
                    timeout: TimeInterval) -> (status: Int32, out: String, timedOut: Bool) {
        let out = Pipe(), stdin = Pipe()
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        if input == nil {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        } else {
            posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd.path) }
        // Own group (pgid = pid), and no other descriptor of the app leaks into codex.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        try? out.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        guard spawned == 0 else { try? stdin.fileHandleForWriting.close(); return (-1, "", false) }
        liveLock.lock(); live.insert(pid); liveLock.unlock()
        defer { liveLock.lock(); live.remove(pid); liveLock.unlock() }

        if let input {
            DispatchQueue.global().async { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
        } else {
            try? stdin.fileHandleForWriting.close()
        }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            guard Task.isCancelled || Date() >= deadline else { continue }
            kill(-pid, SIGTERM)
            if done.wait(timeout: .now() + 2) == .timedOut { kill(-pid, SIGKILL) }
            var st: Int32 = 0
            while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
            return (-1, "", true)
        }
        var st: Int32 = 0
        while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
        let code = st & 0x7f == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
        return (code, String(decoding: box.data, as: UTF8.self), false)
    }
}
#endif
