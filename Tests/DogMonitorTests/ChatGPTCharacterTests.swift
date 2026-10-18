import AppKit
import XCTest
@testable import DogMonitor

/// 내 ChatGPT with a fake `codex` shell script: it never reaches ChatGPT, logs its env, arguments and stdin, and
/// answers like the real CLI (FAKE_MODE: ok, apikey, signedout, limit, slow, stubborn, noimage).
final class ChatGPTCharacterTests: XCTestCase {
    private var dir: URL!

    private static let fake = #"""
    #!/bin/sh
    log="$FAKE_LOG"
    env > "$log/env-$1.txt"
    printf '%s\n' "$@" > "$log/args-$1.txt"
    case "$1" in
    login)
      case "$FAKE_MODE" in
        apikey) echo "Logged in using an API key - sk-proj-***ABCD" ;;
        signedout) echo "Not logged in"; exit 1 ;;
        *) echo "Logged in using ChatGPT" ;;
      esac ;;
    exec)
      echo x >> "$log/exec-count"
      prompt=$(cat)
      printf '%s' "$prompt" > "$log/prompt.txt"
      case "$FAKE_MODE" in
        limit)
          echo '{"type":"thread.started","thread_id":"t"}'
          echo '{"type":"error","message":"You'"'"'ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 5th, 2026 7:44 AM."}'
          echo '{"type":"turn.failed","error":{"message":"usage limit"}}'
          exit 1 ;;
        slow) exec sleep 30 ;;
        stubborn) trap '' TERM; sleep 30 & echo $! > "$log/child.pid"; wait; wait ;;
        noimage) echo '{"type":"turn.completed"}'; exit 0 ;;
      esac
      out=$(printf '%s\n' "$prompt" | sed -n 's/^Save exactly one final PNG to this path: //p')
      cp "$FAKE_PNG" "$out"
      echo '{"type":"turn.completed"}' ;;
    esac
    """#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chatgpt-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let codex = dir.appendingPathComponent("codex")
        try Self.fake.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let png = NSBitmapImageRep(cgImage: magentaArt()).representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("drawn.png"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("style-ref.png"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func client(_ mode: String = "ok", timeout: TimeInterval = 20) -> ChatGPTCharacterClient {
        var c = ChatGPTCharacterClient()
        c.codex = dir.appendingPathComponent("codex").path
        c.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "FAKE_LOG": dir.path, "FAKE_MODE": mode,
                         "FAKE_PNG": dir.appendingPathComponent("drawn.png").path,
                         "OPENAI_API_KEY": "sk-test", "OPENAI_BASE_URL": "https://example.invalid", "OPENAI_ORG_ID": "org",
                         "OPENAI_PROJECT_ID": "proj", "CODEX_ACCESS_TOKEN": "tok", "NODE_OPTIONS": "--inspect",
                         "CODEX_API_KEY": "sk-codex", "OPENAI_IDENTITY_TOKEN_FILE": "/x", "OPENAI_WORKLOAD_IDENTITY_CONTEXT": "w"]
        c.timeout = timeout
        c.styleReference = dir.appendingPathComponent("style-ref.png")
        return c
    }

    private func log(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    /// A 14x12 art-pixel character, 32 image px per art pixel, on flat magenta: what the image generation is asked for.
    private func magentaArt() -> CGImage {
        let size = 768, cell = 32
        let ctx = DogRenderer.context(width: size, height: size)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for y in 0..<12 { for x in 0..<14 {
            let edge = x == 0 || y == 0 || x == 13 || y == 11
            ctx.setFillColor(edge ? CGColor(srgbRed: 0.2, green: 0.1, blue: 0.15, alpha: 1) : CGColor(srgbRed: 0.9, green: 0.6, blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 160 + x * cell, y: 200 + y * cell, width: cell, height: cell))
        } }
        return ctx.makeImage()!
    }

    private func photo() -> CGImage {
        let ctx = DogRenderer.context(width: 900, height: 700)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 100, width: 700, height: 500))
        return ctx.makeImage()!
    }

    private func message(_ work: () throws -> Any) -> String? {
        do { _ = try work(); return nil } catch { return (error as? AICharacterClient.Failure)?.message ?? "\(error)" }
    }

    // MARK: Sign-in

    func testOnlyAChatGPTSignInIsAccepted() {
        XCTAssertEqual(client("ok").status(), .ready(codex: dir.appendingPathComponent("codex").path))
        XCTAssertEqual(client("apikey").status(), .apiKey)
        XCTAssertEqual(client("signedout").status(), .signedOut)
        var none = client()
        none.codex = dir.appendingPathComponent("nope").path
        XCTAssertEqual(none.status(), .missing)
        XCTAssertEqual(log("args-login.txt"), "login\nstatus\n")
    }

    func testAnAPIKeySignInNeverDraws() {
        XCTAssertEqual(message { try self.client("apikey").draw(photos: [.normal: self.photo()]) },
                       ChatGPTCharacterClient.Status.apiKey.note)
        XCTAssertEqual(message { try self.client("signedout").draw(photos: [.normal: self.photo()]) },
                       ChatGPTCharacterClient.Status.signedOut.note)
        XCTAssertEqual(log("exec-count"), "", "no codex exec turn")
    }

    func testTheChildNeverSeesOpenAIKeys() throws {
        _ = try client().draw(photos: [.normal: photo()])
        for name in ["env-login.txt", "env-exec.txt"] {
            let env = log(name)
            XCTAssertFalse(env.isEmpty, name)
            for key in ChatGPTCharacterClient.removedEnv { XCTAssertFalse(env.contains("\(key)="), "\(key) in \(name)") }
            XCTAssertFalse(env.contains("CODEX_API_KEY="), "an API key codex would bill while login status says ChatGPT")
            XCTAssertFalse(env.contains("sk-"), name)
            XCTAssertTrue(env.contains("PATH=\(dir.path):"), "codex folder first on PATH")
            XCTAssertTrue(env.contains("FAKE_MODE=ok"), "the rest is kept")
        }
    }

    // MARK: Drawing

    func testEveryPoseIsOneTurnWithTheStyleThenThePhotoAttached() throws {
        var steps: [String] = []
        let images = try client().draw(photos: [.normal: photo()]) { steps.append("\($0)/\($1)") }
        XCTAssertEqual(steps, ["1/3", "2/3", "3/3"])
        XCTAssertEqual(log("exec-count"), "x\nx\nx\n", "one after another, empty slots from the 평소 photo like the server")
        XCTAssertEqual(Set(images.keys), [.rest, .normal, .busy])

        let args = log("args-exec.txt").split(separator: "\n").map(String.init)
        for flag in ["--ignore-user-config", "--skip-git-repo-check", "--ephemeral", "--json", #"approval_policy="never""#,
                     #"model_reasoning_effort="low""#] { XCTAssertTrue(args.contains(flag), flag) }
        XCTAssertEqual(args[args.firstIndex(of: "--sandbox")! + 1], "workspace-write")
        for flag in ["sandbox_workspace_write.exclude_slash_tmp=true", "sandbox_workspace_write.exclude_tmpdir_env_var=true"] {
            XCTAssertTrue(args.contains(flag), "\(flag): writes only in the turn's folder, not all of /tmp and $TMPDIR")
        }
        XCTAssertFalse(args.contains { $0.contains("api-key") || $0.contains("dangerously") })
        let images2 = args.indices.filter { args[$0] == "--image" }.map { args[$0 + 1] }
        XCTAssertEqual(images2.count, 2)
        XCTAssertEqual(images2[0], dir.appendingPathComponent("style-ref.png").path, "style guide first")
        XCTAssertTrue(images2[1].hasSuffix("/photo-busy.jpg"), images2[1])
        let work = args[args.firstIndex(of: "-C")! + 1]
        XCTAssertEqual((images2[1] as NSString).deletingLastPathComponent, work, "photo inside the turn's own temp folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work), "temp folder removed")
        XCTAssertEqual(args.last, "-", "instruction on stdin")

        let prompt = log("prompt.txt")
        XCTAssertTrue(prompt.contains(ChatGPTCharacterClient.prompt(.busy)))
        XCTAssertTrue(prompt.contains("Save exactly one final PNG to this path: \(work)/out-busy.png"))
        let cut = try XCTUnwrap(CustomSprite.checkedCutout(try XCTUnwrap(images[.busy]), useVision: false, aiArt: true))
        XCTAssertTrue(CustomSprite.isPixelArt(cut.image), "into the AI-art pipeline: magenta keyed out, own grid")
        XCTAssertEqual(cut.image.width, 14)
    }

    func testTheUsageLimitShowsWhenToTryAgain() {
        XCTAssertEqual(message { try self.client("limit").draw(photos: [.rest: self.photo(), .busy: self.photo()]) },
                       "ChatGPT 사용 한도에 도달했어요. 10월 5일 오전 7:44 이후에 다시 시도해 주세요.")
        XCTAssertEqual(log("exec-count"), "x\n", "stops after the first limit instead of spending more turns")
    }

    func testATurnThatOverrunsIsStopped() {
        let start = Date()
        XCTAssertEqual(message { try self.client("slow", timeout: 1).draw(photos: [.normal: self.photo()]) },
                       "ChatGPT가 너무 오래 걸려요. 잠시 뒤 다시 해 주세요.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    /// codex is a node wrapper around the native binary: the kill must reach the whole subtree, not just the wrapper.
    func testAStuckTurnIsKilledWithEverythingItStarted() throws {
        let start = Date()
        XCTAssertEqual(message { try self.client("stubborn", timeout: 1).draw(photos: [.normal: self.photo()]) },
                       "ChatGPT가 너무 오래 걸려요. 잠시 뒤 다시 해 주세요.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        let child = try XCTUnwrap(pid_t(log("child.pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<20 where alive { alive = kill(child, 0) == 0; if alive { usleep(100_000) } }
        XCTAssertFalse(alive, "the grandchild that ignores SIGTERM is gone too")
    }

    func testClosingTheCreatorStopsTheDrawing() async {
        let c = client("slow", timeout: 60)
        let task = Task.detached { try c.draw(photos: [.normal: self.photo()]) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError, "\(error)") } else { XCTFail("drew anyway") }
        XCTAssertEqual(log("exec-count"), "x\n", "no further poses after cancel")
    }

    func testNoPictureIsAShortMessage() {
        XCTAssertEqual(message { try self.client("noimage").draw(photos: [.normal: self.photo()]) }, ChatGPTCharacterClient.noPicture)
        XCTAssertEqual(log("exec-count"), "x\nx\nx\n", "a missing picture does not stop the other poses")
    }

    func testCodexErrorsAreMappedToKorean() {
        let f = { ChatGPTCharacterClient.failure($0)?.message }
        XCTAssertEqual(f(#"{"type":"error","message":"You've hit your usage limit. Try again at 7:44 AM."}"#),
                       "ChatGPT 사용 한도에 도달했어요. 오전 7:44 이후에 다시 시도해 주세요.")
        XCTAssertEqual(f("You've hit your usage limit. Upgrade to Plus to continue."), "ChatGPT 사용 한도에 도달했어요. 한도가 풀린 뒤 다시 시도해 주세요.")
        XCTAssertEqual(f("Error: Not logged in. Please run codex login"), ChatGPTCharacterClient.Status.signedOut.note)
        XCTAssertEqual(f(#"{"message":"Image generation is not available on the Free plan."}"#),
                       "지금 ChatGPT 요금제에서는 그림 만들기를 쓸 수 없어요.")
        XCTAssertNil(f(#"{"type":"turn.completed","id":"401"}"#))
    }
}
