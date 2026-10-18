import AppKit
import XCTest
@testable import DogMonitor

/// 내 Claude with a fake `claude` shell script: it never reaches Claude, logs its env, arguments, working folder,
/// the files it was given and stdin, and answers like `claude -p --output-format json`
/// (FAKE_MODE: ok, limit, badtoken, signedout, slow, stubborn, broken, pass2broken, nothing).
final class ClaudeCharacterTests: XCTestCase {
    private var dir: URL!

    static let fake = #"""
    #!/bin/sh
    log="$FAKE_LOG"
    case "$1" in
    --version) env > "$log/env-version.txt"; echo "2.1.286 (Claude Code)"; exit 0 ;;
    --help) case "$FAKE_MODE" in nohelp) exit 0 ;; oldhelp) echo "  --tools <tools...>"; exit 0 ;; failhelp) exit 3 ;; esac; echo "  --tools <tools...>"; echo "  --no-session-persistence"; echo "  --safe-mode"; echo "  --restricted"; echo "  --permission-prompts <target>"; exit 0 ;;
    esac
    n=$(( $(cat "$log/count" 2>/dev/null || echo 0) + 1 ))
    echo $n > "$log/count"
    env > "$log/env-$n.txt"
    printf '%s\n' "$@" > "$log/args-$n.txt"
    pwd -P > "$log/cwd-$n.txt"
    ls > "$log/ls-$n.txt"
    cat > "$log/prompt-$n.txt"
    case "$FAKE_MODE" in
      limit) echo '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your limit · resets 7pm (Asia/Seoul)"}'; exit 1 ;;
      badtoken) echo '{"type":"result","is_error":true,"result":"Failed to authenticate. API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"Invalid bearer token\"}}"}'; exit 1 ;;
      signedout) echo '{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}'; exit 1 ;;
      slow) exec sleep 30 ;;
      stubborn) trap '' TERM; sleep 30 & echo $! > "$log/child.pid"; wait; wait ;;
      huge) head -c 300000 /dev/zero | tr '\0' ' ' > frames.json ;;
      broken) printf '{"palette":{"o":"#FFFFFF"},"poses":{}}' > frames.json ;;
      nothing) ;;
      pass2broken) if [ "$n" = 1 ]; then cp "$FAKE_FRAMES" frames.json; else echo "not json" > frames.json; fi ;;
      *) if [ "$n" = 1 ]; then cp "$FAKE_FRAMES" frames.json; else cp "${FAKE_FRAMES2:-$FAKE_FRAMES}" frames.json; fi ;;
    esac
    echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
    """#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claude = dir.appendingPathComponent("claude")
        try Self.fake.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        try Self.art(legs: 0).json.write(to: dir.appendingPathComponent("frames1.json"))
        try Self.art(legs: 1).json.write(to: dir.appendingPathComponent("frames2.json"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("style-ref.png"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    static let removedSamples = ["ANTHROPIC_API_KEY": "sk-ant-api03-x", "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_BASE_URL": "https://example.invalid",
                                 "ANTHROPIC_PROFILE": "work", "ANTHROPIC_FEDERATION_RULE_ID": "r", "ANTHROPIC_IDENTITY_TOKEN_FILE": "/x",
                                 "ANTHROPIC_ORGANIZATION_ID": "org", "ANTHROPIC_SERVICE_ACCOUNT_ID": "sa", "ANTHROPIC_WORKSPACE_ID": "ws",
                                 "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1", "CLAUDE_CODE_USE_FOUNDRY": "1",
                                 "CLAUDE_CODE_OAUTH_TOKEN": "inherited-company-token", "NODE_OPTIONS": "--inspect", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "parent", "CLAUDE_CODE_MESSAGING_TOKEN": "m"]

    private func client(_ mode: String = "ok", token: String? = "sk-ant-oat01-personal", cli: Bool = false,
                        refine: Bool = true, timeout: TimeInterval = 20) -> ClaudeCharacterClient {
        var c = ClaudeCharacterClient()
        c.claude = dir.appendingPathComponent("claude").path
        c.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "FAKE_LOG": dir.path, "FAKE_MODE": mode,
                         "FAKE_FRAMES": dir.appendingPathComponent("frames1.json").path,
                         "FAKE_FRAMES2": dir.appendingPathComponent("frames2.json").path].merging(Self.removedSamples) { a, _ in a }
        c.token = token
        c.useCLILogin = cli
        c.refine = refine
        c.timeout = timeout
        c.styleReference = dir.appendingPathComponent("style-ref.png")
        return c
    }

    private func log(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    private func lines(_ name: String) -> [String] { log(name).split(separator: "\n").map(String.init) }

    private func photo() -> CGImage {
        let ctx = DogRenderer.context(width: 900, height: 700)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 100, width: 700, height: 500))
        return ctx.makeImage()!
    }

    private func message(_ work: () throws -> Any) -> String? {
        do { _ = try work(); return nil } catch { return (error as? AICharacterClient.Failure)?.message ?? "\(error)" }
    }

    /// A 12x8 outlined block standing on row 19, `legs` shifting one leg per frame so frames differ.
    static func art(legs: Int) -> FrameArt {
        func frame(_ i: Int) -> [String] {
            var rows = Array(repeating: String(repeating: ".", count: 34), count: 20)
            func put(_ x: Int, _ y: Int, _ c: Character) {
                var r = Array(rows[y]); r[x] = c; rows[y] = String(r)
            }
            for y in 10...17 { for x in 10...21 { put(x, y, y == 10 || y == 17 || x == 10 || x == 21 ? "o" : "b") } }
            let leg = 12 + (i + legs) % 2 * 6
            put(leg, 18, "o"); put(leg, 19, "o"); put(leg + 1, 18, "o"); put(leg + 1, 19, "o")
            return rows
        }
        var poses: [String: [[String]]] = [:]
        for pose in DogPose.allCases { poses[FrameArt.key(pose)] = (0..<(pose == .lying ? 2 : 4)).map(frame) }
        return FrameArt(palette: ["o": "#2A2230", "b": "#F2C9A0"], poses: poses)
    }

    // MARK: Connection

    func testNoTokenAndNoOptInNeverRuns() {
        let c = client(token: nil, cli: false)
        XCTAssertEqual(c.status(), .notConnected)
        XCTAssertEqual(message { try c.draw(photos: [.normal: self.photo()]) }, ClaudeCharacterClient.Status.notConnected.note)
        XCTAssertEqual(log("count"), "", "no claude turn")
        XCTAssertEqual(log("env-version.txt"), "", "not even --version")
    }

    func testStatusChecksOnlyTheVersion() {
        XCTAssertEqual(client().status(), .ready(claude: dir.appendingPathComponent("claude").path, token: true))
        XCTAssertEqual(client(token: nil, cli: true).status(), .ready(claude: dir.appendingPathComponent("claude").path, token: false))
        var none = client()
        none.claude = dir.appendingPathComponent("nope").path
        XCTAssertEqual(none.status(), .missing)
        XCTAssertEqual(log("count"), "", "status never starts a turn")
    }

    func testTheTokenGoesOnlyThroughTheEnvironmentAndEverythingElseIsScrubbed() throws {
        _ = try client().draw(photos: [.normal: photo()])
        for name in ["env-1.txt", "env-2.txt"] {
            let env = lines(name)
            XCTAssertFalse(env.isEmpty, name)
            XCTAssertEqual(env.filter { $0.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN=") }, ["CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-personal"], name)
            for key in Self.removedSamples.keys where key != "CLAUDE_CODE_OAUTH_TOKEN" {
                XCTAssertFalse(env.contains { $0.hasPrefix("\(key)=") }, "\(key) in \(name)")
            }
            XCTAssertFalse(env.contains { $0.hasPrefix("ANTHROPIC_") }, name)
            XCTAssertFalse(log(name).contains("inherited-company-token"), name)
            XCTAssertTrue(env.contains { $0.hasPrefix("PATH=\(dir.path):") }, "claude folder first on PATH")
            XCTAssertTrue(env.contains("FAKE_MODE=ok"), "the rest is kept")
        }
        for n in 1...2 {
            XCTAssertFalse(log("args-\(n).txt").contains("sk-ant"), "never on the command line")
            XCTAssertFalse(log("prompt-\(n).txt").contains("sk-ant"), "never in the prompt")
        }
    }

    func testTheCLISignInSetsNoToken() throws {
        _ = try client(token: nil, cli: true, refine: false).draw(photos: [.normal: photo()])
        XCTAssertFalse(log("env-1.txt").contains("CLAUDE_CODE_OAUTH_TOKEN"), "neither the inherited one nor any other")
        XCTAssertFalse(log("env-1.txt").contains("ANTHROPIC_"))
    }

    // MARK: Drawing

    func testArgumentsAreSonnetFiveReadWriteOnlyInTheTurnsOwnFolder() throws {
        var steps: [String] = []
        let art = try client().draw(photos: [.normal: photo()]) { steps.append("\($0)/\($1)") }
        XCTAssertEqual(steps, ["1/2", "2/2"])
        XCTAssertEqual(art, Self.art(legs: 1), "pass 2's frames win")

        let args = lines("args-1.txt")
        XCTAssertEqual(args.first, "-p")
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value("--model"), "claude-sonnet-5")
        XCTAssertEqual(value("--output-format"), "json")
        XCTAssertEqual(value("--permission-mode"), "acceptEdits")
        XCTAssertEqual(value("--tools"), "Read,Write")
        XCTAssertEqual(value("--allowedTools"), "Read(./**)")
        XCTAssertEqual(args.firstIndex(of: "--allowedTools").map { args[$0 + 2] }, "Write(./frames.json)", "only its own file")
        XCTAssertEqual(value("--max-turns"), "8")
        XCTAssertEqual(value("--mcp-config"), #"{"mcpServers":{}}"#)
        XCTAssertEqual(value("--permission-prompts"), "none")
        let denied = Set((value("--disallowedTools") ?? "").split(separator: ",").map(String.init))
        XCTAssertTrue(["Bash", "WebFetch", "WebSearch", "Edit", "Task"].allSatisfy(denied.contains), "\(denied)")
        for flag in ["--strict-mcp-config", "--no-session-persistence", "--safe-mode", "--restricted"] { XCTAssertTrue(args.contains(flag), flag) }
        XCTAssertFalse(args.contains { $0.contains("dangerously") || $0.contains("bypass") || $0 == "-c" || $0.hasSuffix("sh") })
        XCTAssertEqual(lines("args-2.txt"), args, "pass 2 is the same fresh call")

        let cwd = log("cwd-1.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(cwd.contains("/jelly-claude-"), cwd)
        XCTAssertEqual(log("cwd-2.txt").trimmingCharacters(in: .whitespacesAndNewlines), cwd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd), "turn folder removed")
        XCTAssertEqual(lines("ls-1.txt"), ["photo-normal.jpg", "style-ref.png"], "only the style guide and the photo")
        XCTAssertEqual(lines("ls-2.txt"), ["frames.json", "photo-normal.jpg", "sheet.png", "style-ref.png"], "pass 2 sees the render")

        let first = log("prompt-1.txt"), second = log("prompt-2.txt")
        XCTAssertTrue(first.contains("Read style-ref.png") && first.contains("photo-normal.jpg") && first.contains("frames.json"))
        XCTAssertTrue(first.contains(ClaudeCharacterClient.contract))
        XCTAssertFalse(ClaudeCharacterClient.example.isEmpty)
        XCTAssertTrue(first.contains(ClaudeCharacterClient.example), "the tan cat's frame shows the format")
        XCTAssertTrue(second.contains("sheet.png") && second.contains("what looks wrong") && second.contains(ClaudeCharacterClient.contract))
    }

    /// The lock-down flags come from --help: a CLI that cannot confine the turn (or says nothing) gets no turn.
    func testNoSafeModeMeansNoTurn() {
        for mode in ["nohelp", "oldhelp"] {
            XCTAssertEqual(message { try self.client(mode).draw(photos: [.normal: self.photo()]) }, ClaudeCharacterClient.noSafeMode, mode)
        }
        XCTAssertEqual(message { try self.client("failhelp").draw(photos: [.normal: self.photo()]) }, ClaudeCharacterClient.Status.unknown.note)
        XCTAssertEqual(log("count"), "", "no turn at all")
    }

    func testAnOversizedFramesFileIsRejectedUnread() {
        XCTAssertEqual(message { try self.client("huge", refine: false).draw(photos: [.normal: self.photo()]) }, ClaudeCharacterClient.noFrames)
    }

    func testRefineOffIsOneTurn() throws {
        var steps: [String] = []
        let art = try client(refine: false).draw(photos: [.rest: photo(), .busy: photo()]) { steps.append("\($0)/\($1)") }
        XCTAssertEqual(steps, ["1/1"])
        XCTAssertEqual(log("count").trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertEqual(art, Self.art(legs: 0))
        XCTAssertEqual(lines("ls-1.txt"), ["photo-busy.jpg", "photo-rest.jpg", "style-ref.png"])
    }

    func testABrokenSecondPassKeepsTheFirst() throws {
        XCTAssertEqual(try client("pass2broken").draw(photos: [.normal: photo()]), Self.art(legs: 0))
        XCTAssertEqual(log("count").trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testBrokenOrMissingFramesAreShortKoreanErrors() {
        XCTAssertEqual(message { try self.client("broken").draw(photos: [.normal: self.photo()]) },
                       "Claude가 그린 그림이 규칙에 맞지 않아요 (테두리용 어두운 색이 없어요). 다시 그려 주세요.")
        XCTAssertEqual(message { try self.client("nothing").draw(photos: [.normal: self.photo()]) }, ClaudeCharacterClient.noFrames)
    }

    func testUsageLimitAndSignInErrorsAreMapped() {
        XCTAssertEqual(message { try self.client("limit").draw(photos: [.normal: self.photo()]) },
                       "Claude 사용 한도에 도달했어요. 오후 7:00 이후에 다시 시도해 주세요.")
        XCTAssertEqual(log("count").trimmingCharacters(in: .whitespacesAndNewlines), "1", "no second pass after a limit")
        XCTAssertEqual(message { try self.client("badtoken").draw(photos: [.normal: self.photo()]) },
                       "저장한 개인 토큰이 맞지 않거나 만료됐어요. 터미널에서 claude setup-token 으로 새 토큰을 만들어 설정 > Claude 연결에 넣어 주세요.")
        XCTAssertEqual(message { try self.client("signedout", token: nil, cli: true).draw(photos: [.normal: self.photo()]) },
                       "이 맥의 Claude Code에 로그인되어 있지 않아요. 터미널에서 claude 를 열어 /login 하거나, 설정 > Claude 연결에 개인 토큰을 넣어 주세요.")
    }

    func testErrorTextAndResetTimes() {
        let f = { ClaudeCharacterClient.failure($0, token: false)?.message }
        XCTAssertEqual(f("5-hour limit reached ∙ resets Oct 5, 7:44am"), "Claude 사용 한도에 도달했어요. 10월 5일 오전 7:44 이후에 다시 시도해 주세요.")
        XCTAssertEqual(f("Claude usage limit reached. Upgrade."), "Claude 사용 한도에 도달했어요. 한도가 풀린 뒤 다시 시도해 주세요.")
        let show = DateFormatter()
        show.locale = Locale(identifier: "ko_KR")
        show.dateFormat = "M월 d일 a h:mm"
        XCTAssertEqual(ClaudeCharacterClient.resetTime("Claude AI usage limit reached|1759302000"),
                       show.string(from: Date(timeIntervalSince1970: 1_759_302_000)))
        XCTAssertEqual(f("OAuth token has expired"), "이 맥의 Claude Code 로그인이 만료됐어요. 터미널에서 claude 를 열어 /login 해 주세요.")
        XCTAssertEqual(f(#"{"result":"There's an issue with the selected model (claude-sonnet-5). It may not exist or you may not have access to it. not_found_error"}"#),
                       "이 계정에서는 claude-sonnet-5 모델을 쓸 수 없어요.")
        XCTAssertNil(f(#"{"type":"result","result":"done"}"#))
    }

    func testATurnThatOverrunsIsStopped() {
        let start = Date()
        XCTAssertEqual(message { try self.client("slow", timeout: 1).draw(photos: [.normal: self.photo()]) }, ClaudeCharacterClient.tooSlow)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    /// claude is a node program: the kill must reach the whole process group, not just the first process.
    func testAStuckTurnIsKilledWithEverythingItStarted() throws {
        XCTAssertEqual(message { try self.client("stubborn", timeout: 1).draw(photos: [.normal: self.photo()]) }, ClaudeCharacterClient.tooSlow)
        let child = try XCTUnwrap(pid_t(log("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<20 where alive { alive = kill(child, 0) == 0; if alive { usleep(100_000) } }
        XCTAssertFalse(alive, "the grandchild that ignores SIGTERM is gone too")
    }

    func testClosingTheCreatorStopsTheDrawing() async throws {
        let c = client("stubborn", timeout: 60)
        let task = Task.detached { try c.draw(photos: [.normal: self.photo()]) }
        for _ in 0..<50 where log("child.pid").isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError, "\(error)") } else { XCTFail("drew anyway") }
        let child = try XCTUnwrap(pid_t(log("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<20 where alive { alive = kill(child, 0) == 0; if alive { usleep(100_000) } }
        XCTAssertFalse(alive, "cancel kills the whole group")
        XCTAssertEqual(log("count").trimmingCharacters(in: .whitespacesAndNewlines), "1", "no second pass after cancel")
    }

    // MARK: Frames

    func testFramesRoundTripAndRender() throws {
        let art = Self.art(legs: 0)
        XCTAssertEqual(try FrameArt.parse(art.json), art)
        let native = art.nativeFrames()
        XCTAssertEqual(native.map(\.count), [2, 4, 4, 4, 4, 4, 4])
        XCTAssertEqual(native[0][0].count, 34 * 20 * 4, "the shared canvas")
        let dense = art.frames()
        XCTAssertEqual(dense[0][0].count, CustomSprite.w * CustomSprite.h * 4, "custom characters' canvas, same menu bar size")
        XCTAssertEqual(CustomSprite.halved(dense[2][1]), native[2][1], "exactly the drawn pixels at 1x")
        // Row 19, column 12 is a foot in frame 0; flipped it is column 21.
        let i = (19 * 34 + 12) * 4, j = (19 * 34 + 21) * 4
        XCTAssertEqual(native[2][0][i + 3], 255)
        XCTAssertEqual(art.nativeFrames(flipped: true)[2][0][j + 3], 255)
    }

    func testTrivialSlipsAreRepairedAndTheRestRejected() throws {
        var messy = Self.art(legs: 0)
        var walk = messy.poses["walk"]!
        walk[0] = Array(walk[0].dropFirst())                            // 19 rows: sky padded back
        walk[1] = walk[1].map { $0 + ".." }                             // 36 columns: trimmed
        walk[2][12] = String(walk[2][12].prefix(15)) + "Z" + String(walk[2][12].dropFirst(16))   // unknown: transparent
        messy.poses["walk"] = walk
        let text = "```json\n" + String(decoding: messy.json, as: UTF8.self) + "\n```"
        let fixed = try FrameArt.parse(Data(text.utf8))
        XCTAssertEqual(fixed.poses["walk"]![0], Self.art(legs: 0).poses["walk"]![0])
        XCTAssertEqual(fixed.poses["walk"]![1], Self.art(legs: 0).poses["walk"]![1])
        XCTAssertEqual(Array(fixed.poses["walk"]![2][12])[15], ".")
        XCTAssertTrue(fixed.poses.values.joined().allSatisfy { $0.count == 20 && $0.allSatisfy { $0.count == 34 } })

        func rejects(_ change: (inout FrameArt) -> Void) -> String? {
            var a = Self.art(legs: 0); change(&a)
            do { _ = try FrameArt.parse(a.json); return nil } catch { return (error as? AICharacterClient.Failure)?.message }
        }
        XCTAssertNotNil(rejects { $0.poses["run"] = nil }, "a pose missing")
        XCTAssertNotNil(rejects { $0.poses["walk"] = [$0.poses["walk"]![0]] }, "one walking frame")
        XCTAssertNotNil(rejects { $0.poses["sprint"]![0] = Array($0.poses["sprint"]![0].prefix(10)) }, "half a frame")
        XCTAssertNotNil(rejects { $0.poses["exhausted"]![0][3] = String(repeating: ".", count: 60) }, "a row far too long")
        XCTAssertNotNil(rejects { for (i, c) in "0123456789ABCDEFG".enumerated() { $0.palette[String(c)] = String(format: "#1%05X", i) } }, "17 colours")
        XCTAssertNotNil(rejects { $0.palette["o"] = "#FFFFFF" }, "no dark outline")
        XCTAssertNotNil(rejects { $0.palette["b"] = "pink" })
        XCTAssertNotNil(rejects { $0.poses["lying"] = [Array(repeating: String(repeating: ".", count: 34), count: 20)] }, "an empty frame")
        XCTAssertThrowsError(try FrameArt.parse(Data("no json here".utf8)))
        XCTAssertNotNil(rejects { $0.poses["walk"]![0] = Array(repeating: "", count: 50_000) + $0.poses["walk"]![0] }, "a flood of empty rows")
        XCTAssertNotNil(rejects { $0.palette["\n"] = "#000000" }, "a control character as a colour")
        XCTAssertNotNil(rejects { $0.palette[" "] = "#000000" }, "a space as a colour")
    }

    func testAFramesCharacterSavesAndLoadsLikeTheOthers() throws {
        let root = dir.appendingPathComponent("store", isDirectory: true)
        let store = CustomCharacterStore(root: root)
        let art = Self.art(legs: 0)
        let saved = try store.save(name: "클로드", lightRim: false, flipped: true, inputs: [:], art: art)
        let folder = store.folder(saved.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("frames.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sheet.png").path), "thumbnail sheet")
        let loaded = try XCTUnwrap(CustomCharacterStore(root: root).character(saved.id.uuidString))
        XCTAssertEqual(loaded.art, art)
        XCTAssertEqual(loaded.frames, art.frames(flipped: true))
        XCTAssertEqual(DogSpriteCache(profile: .defaultDog, custom: loaded.frames).imageSize, DogSpriteCache(profile: .defaultDog).imageSize)
        // An edited frames.json that breaks the rules is skipped, not loaded.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("frames.json"))
        XCTAssertNil(CustomCharacterStore(root: root).character(saved.id.uuidString))
    }

    // MARK: Keychain

    func testTheTokenLivesInTheKeychain() throws {
        let service = "com.jelly.dogmonitor.claude.test-\(UUID().uuidString)"
        defer { ClaudeToken.delete(service: service) }
        XCTAssertNil(ClaudeToken.load(service: service))
        try ClaudeToken.save("sk-ant-oat01-first", service: service)
        XCTAssertEqual(ClaudeToken.load(service: service), "sk-ant-oat01-first")
        try ClaudeToken.save("sk-ant-oat01-second", service: service)
        XCTAssertEqual(ClaudeToken.load(service: service), "sk-ant-oat01-second", "saving again replaces it")
        XCTAssertTrue(ClaudeToken.exists(service: service))
        ClaudeToken.delete(service: service)
        XCTAssertNil(ClaudeToken.load(service: service))
        XCTAssertFalse(ClaudeToken.exists(service: service))
        XCTAssertNil(AppDefaults.store.dictionaryRepresentation().values.first { "\($0)".contains("sk-ant-oat01") }, "never in UserDefaults")
    }

    /// `current()` never reads the secret; status() only checks it exists and draw() reads it on its own thread.
    func testTheKeychainTokenIsReadOnlyWhenDrawing() throws {
        let service = ClaudeToken.service
        ClaudeToken.service = "com.jelly.dogmonitor.claude.test-\(UUID().uuidString)"
        defer { ClaudeToken.delete(); ClaudeToken.service = service }
        var c = client(token: nil, refine: false)
        c.keychain = true
        XCTAssertEqual(c.status(), .notConnected)
        try ClaudeToken.save("sk-ant-oat01-from-keychain")
        XCTAssertEqual(c.status(), .ready(claude: dir.appendingPathComponent("claude").path, token: true))
        XCTAssertFalse(log("env-version.txt").contains("sk-ant"), "--version needs no token")
        _ = try c.draw(photos: [.normal: photo()])
        XCTAssertTrue(lines("env-1.txt").contains("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-from-keychain"))
    }

    func testOnlySetupTokensAreAccepted() {
        XCTAssertEqual(try? ClaudeToken.check("  sk-ant-oat01-AbC_d-9\n").get(), "sk-ant-oat01-AbC_d-9")
        XCTAssertNil(try? ClaudeToken.check("sk-ant-api03-abc").get(), "an API key bills per use")
        XCTAssertNil(try? ClaudeToken.check("").get())
        XCTAssertNil(try? ClaudeToken.check("sk-ant-oat01-a b").get())
        XCTAssertNil(try? ClaudeToken.check("hello").get())
    }

    /// For the QA run of --make-character-claude with a fake claude: a preset dog as frames.json.
    func testPresetDogsFitTheContract() throws {
        let art = try XCTUnwrap(DogProfile.presets.lazy.compactMap { FrameArt.from(DogRenderer.frames($0.profile)) }.first,
                                "a preset dog within 16 colours")
        XCTAssertEqual(try FrameArt.parse(art.json).nativeFrames(), art.nativeFrames())
        if let out = ProcessInfo.processInfo.environment["CLAUDEGEN_EXPORT"] { try art.json.write(to: URL(fileURLWithPath: out)) }
    }
}
