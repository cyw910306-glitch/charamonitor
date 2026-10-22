import AppKit

// CLI modes run once and exit. Anything else starts the menu bar app.
// Top-level code runs on the main thread; Swift 5 mode just does not know it.
MainActor.assumeIsolated {
    let args = CommandLine.arguments

    func runCLI(_ flag: String, _ work: (URL) throws -> Void) -> Never {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
            fputs("사용법: DogMonitor \(flag) <폴더>\n", stderr)
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = NSApplication.shared   // AppKit and SwiftUI rendering expect an app object
            try work(dir)
            exit(0)
        } catch {
            fputs("실패: \(error)\n", stderr)
            exit(1)
        }
    }

    if args.contains("--metrics-dump") {
        MetricsCLI.run()
        exit(0)
    }
    if args.contains("--speed-test") {
        guard let r = SpeedTest.measure() else { fputs("측정 실패\n", stderr); exit(1) }
        SpeedTest.shared.save(r)
        print("다운로드 \(SpeedRow.mbps(r.downMbps)) · 업로드 \(SpeedRow.mbps(r.upMbps))")
        exit(0)
    }
    #if !MAS
    if let i = args.firstIndex(of: "--check-update") {   // read-only: fetch, verify, print what would happen
        let folder = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? URL(fileURLWithPath: args[i + 1], isDirectory: true) : nil
        Task.detached { exit(await UpdateCheck.runCLI(folder: folder)) }
        dispatchMain()
    }
    if let i = args.firstIndex(of: "--check-sponsors") {   // read-only: the signed 후원 친구 list, as the app would take it
        let folder = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? URL(fileURLWithPath: args[i + 1], isDirectory: true) : nil
        Task.detached { exit(await SponsorCheck.runCLI(folder: folder)) }
        dispatchMain()
    }
    #endif
    #if !MAS   // install scripts only: the App Store build turns this on only from 설정 (2.4.5(iii))
    if args.contains("--enable-login-item") {
        // A bare build product would register itself (not the app) as a login item.
        guard Bundle.main.bundleURL.pathExtension == "app" else { print("앱 번들(DogMonitor.app) 안의 실행 파일로 실행해 주세요."); exit(2) }
        do { try LoginItem.setEnabled(true) } catch { print("등록하지 못했어요: \(error.localizedDescription)") }
        print("로그인 시 자동 실행: \(LoginItem.statusText)")
        exit(LoginItem.isEnabled ? 0 : 1)
    }
    #endif
    #if !MAS
    if args.contains("--cleaner-dry-run") {
        Cleaner.dryRun()
        exit(0)
    }
    if args.contains("--security-scan") {
        SecurityScanner.dryRun()
        exit(0)
    }
    #endif
    if args.contains("--assistant-ask") { AssistantCLI.run(args) }
    #if !MAS
    if let i = args.firstIndex(of: "--agent-bridge") {   // stdio MCP relay for ClaudeAgentRun, started by the claude CLI
        guard i + 1 < args.count else { fputs("사용법: DogMonitor --agent-bridge <소켓>\n", stderr); exit(2) }
        AgentBridge.relay(socketPath: args[i + 1])
    }
    #endif
    #if !MAS
    if args.contains("--agent-plan") { AgentCLI.run(args) }   // one proposal from the owner's AI, nothing runs
    if args.contains("--agent-browse") { AgentBrowser.probe(args) }   // read-only: one page offscreen, what the model would see
    if args.contains("--agent-run") { AgentCLI.runTools(args) }   // one v2 tool run, every card answered 취소
    #endif
    #if !MAS
    if let i = args.firstIndex(of: "--render-pack") {   // QA sheet of a local character pack (CharacterPack)
        guard i + 2 < args.count else { fputs("사용법: DogMonitor --render-pack <팩 폴더> <출력.png>\n", stderr); exit(2) }
        _ = NSApplication.shared
        do {
            try SpritePreview.renderPack(URL(fileURLWithPath: args[i + 1], isDirectory: true), to: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        } catch {
            fputs("실패: \(error)\n", stderr)
            exit(1)
        }
    }
    #endif
    if let i = args.firstIndex(of: "--render-style") {   // 그림 스타일 comparison sheet (SpritePreview.renderStyles)
        guard i + 1 < args.count else { fputs("사용법: DogMonitor --render-style <출력.png>\n", stderr); exit(2) }
        _ = NSApplication.shared
        do {
            try SpritePreview.renderStyles(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        } catch {
            fputs("실패: \(error)\n", stderr)
            exit(1)
        }
    }
    if args.contains("--render-sprites") { runCLI("--render-sprites") { try SpritePreview.renderAll(to: $0) } }
    if args.contains("--export-web-sprites") { runCLI("--export-web-sprites") { try WebSprites.export(to: $0) } }   // web/app/sprites
    if args.contains("--export-setup") {   // 내 설정 내보내기 without the save panel: <folder>/내 설정.charamonitor
        runCLI("--export-setup") { dir in
            let r = try SetupFile.export(to: dir.appendingPathComponent("내 설정.charamonitor"))
            print("팩 \(r.packs) · 캐릭터 \(r.characters) · 설정 \(r.settings) · 못 담은 것 \(r.skipped)")
        }
    }
    if let i = args.firstIndex(of: "--make-character") {
        let images = Array(args.dropFirst(i + 2).prefix(3))
        if images.isEmpty { fputs("사용법: DogMonitor --make-character <폴더> <쉴 때> [평소] [바쁠 때] (하나면 평소)\n", stderr); exit(2) }
        runCLI("--make-character") { try SpritePreview.makeCharacter(images, to: $0) }
    }
    #if !MAS   // no AI drawing in the App Store build
    if let i = args.firstIndex(of: "--make-character-chatgpt") {   // this Mac's ChatGPT via Codex; uses its usage
        var rest = Array(args.dropFirst(i + 2))
        var client = ChatGPTCharacterClient()
        if let c = rest.firstIndex(of: "--codex"), c + 1 < rest.count { client.codex = rest[c + 1]; rest.removeSubrange(c...(c + 1)) }
        let images = Array(rest.prefix(3))
        if images.isEmpty { fputs("사용법: DogMonitor --make-character-chatgpt <폴더> <쉴 때> [평소] [바쁠 때] [--codex <경로>] (하나면 평소)\n", stderr); exit(2) }
        runCLI("--make-character-chatgpt") { try SpritePreview.makeCharacterAI(images, to: $0, chatGPT: client) }
    }
    if let i = args.firstIndex(of: "--make-character-claude") {   // 내 Claude via Claude Code; uses that subscription
        var rest = Array(args.dropFirst(i + 2))
        var client = ClaudeCharacterClient.current()
        if ProcessInfo.processInfo.environment["JELLY_CLAUDE_CLI_LOGIN"] == "1" { client.useCLILogin = true }
        if let c = rest.firstIndex(of: "--claude"), c + 1 < rest.count { client.claude = rest[c + 1]; rest.removeSubrange(c...(c + 1)) }
        let images = Array(rest.prefix(3))
        if images.isEmpty { fputs("사용법: DogMonitor --make-character-claude <폴더> <쉴 때> [평소] [바쁠 때] [--claude <경로>] (하나면 평소)\n", stderr); exit(2) }
        runCLI("--make-character-claude") { try SpritePreview.makeCharacterClaude(images, to: $0, client: client) }
    }
    #endif
    if args.contains("--render-dashboard") {
        // Its own preferences, emptied before and after, so the owner's are never read or written.
        let suite = "qa.dogmonitor.snapshot"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-dashboard") {
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try DashboardSnapshot.render(to: $0)
        }
    }

    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = EditMenu.make()
    app.run()   // never returns, so appDelegate stays alive
}
