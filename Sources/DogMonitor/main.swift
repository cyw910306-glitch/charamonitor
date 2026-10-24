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
    if let i = args.firstIndex(of: "--check-plugins") {   // read-only: the signed 플러그인 list (days, codes' hashes)
        let folder = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? URL(fileURLWithPath: args[i + 1], isDirectory: true) : nil
        Task.detached { exit(await PluginCheck.runCLI(folder: folder)) }
        dispatchMain()
    }
    if let i = args.firstIndex(of: "--check-season") {   // read-only: the signed 시즌 뽑기판 file (days, items, numbers)
        let folder = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? URL(fileURLWithPath: args[i + 1], isDirectory: true) : nil
        Task.detached { exit(await SeasonCheck.runCLI(folder: folder)) }
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
    if let i = args.firstIndex(of: "--import-gpt-pet") {   // ChatGPT 펫 (sheet, pet folder, zip) as a pack in <팩 폴더>
        guard i + 2 < args.count else { fputs("사용법: DogMonitor --import-gpt-pet <시트|펫 폴더|zip> <팩 폴더>\n", stderr); exit(2) }
        _ = NSApplication.shared
        do {
            let pack = try GPTPet.importPack(GPTPet.read(URL(fileURLWithPath: args[i + 1])), root: URL(fileURLWithPath: args[i + 2], isDirectory: true))
            print("\(pack.id) · \(pack.displayName) · " + DogPose.allCases.map { "\(FrameArt.key($0)) \(pack.frames(for: $0).count)" }.joined(separator: " ")
                  + " · special \(pack.extraVariants(.special).map(\.count))")
            exit(0)
        } catch {
            fputs("실패: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    if let i = args.firstIndex(of: "--export-gpt-pet") {   // one of our characters as a ChatGPT 펫 v2: <폴더>/<id>/
        let all = GPTPet.exportables()
        guard i + 2 < args.count, let e = all.first(where: { $0.id == args[i + 1] }) else {
            fputs("사용법: DogMonitor --export-gpt-pet <id> <폴더>\nid: \(all.map(\.id).joined(separator: " "))\n", stderr)
            exit(2)
        }
        runCLI("--export-gpt-pet") { _ in print(try GPTPet.export(e, to: URL(fileURLWithPath: args[i + 2], isDirectory: true)).path) }
    }
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
    if args.contains("--render-sticky") {   // 포스트잇 notes, card, typing; its own preferences and notes, as --render-dashboard
        let suite = "qa.dogmonitor.sticky"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-sticky") {
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try StickyQA.render(to: $0)
        }
    }
    if args.contains("--render-sprites") { runCLI("--render-sprites") { try SpritePreview.renderAll(to: $0) } }
    if args.contains("--render-hotspot") {   // what each 데스크톱 친구 hotspot takes clicks on, over its drawing
        let suite = "qa.dogmonitor.hotspot"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-hotspot") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try MainActor.assumeIsolated { try DesktopQA.renderHotspots(to: dir) }
        }
    }
    if args.contains("--render-fortune") { runCLI("--render-fortune") { try Fortune.renderQA(to: $0) } }   // 운세 bubble, light and dark
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
    if args.contains("--render-season") {   // 시즌 뽑기판: fresh, half torn, a prize, a finished board, settings; light and dark
        let suite = "qa.dogmonitor.season"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-season") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try SeasonQA.render(to: dir)
        }
    }
    if args.contains("--render-lunch") {   // 점심 뽑기 panel, empty and with a result, light and dark
        let suite = "qa.dogmonitor.lunch"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-lunch") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            let lunch = Lunch()
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try DashboardSnapshot.snapshot(LunchLeverView(lunch: lunch), appearance: appearance, to: dir.appendingPathComponent("lunch-empty-\(suffix).png"))
            }
            lunch.add("회사 앞 국수집")
            lunch.add("편의점 도시락")
            var rng = SplitMix64(seed: 7)
            let pick = lunch.pull(using: &rng)?.pick
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try DashboardSnapshot.snapshot(LunchLeverView(lunch: lunch, preset: pick), appearance: appearance,
                                               to: dir.appendingPathComponent("lunch-result-\(suffix).png"))
            }
        }
    }

    #if !MAS
    if args.contains("--render-meet") {   // 원격 모임 settings in each state, no network and no Keychain
        let suite = "qa.dogmonitor.meet"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-meet") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try MeetQA.render(to: dir)
        }
    }
    if args.contains("--render-drift") {   // 딴짓 지킴이: settings, the three cards, the cat sheet and paw frames, today's line
        let suite = "qa.dogmonitor.drift"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-drift") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try DriftQA.render(to: dir)
        }
    }
    if args.contains("--drift-dry-run") {   // read-only: what 딴짓 지킴이 makes of the app in front, nothing is closed
        _ = NSApplication.shared
        DriftCenter.dryRun = true
        DriftCLI.dryRun(args)
    }
    if args.contains("--drift-qa-terminate") {   // the paw's real quit path, on a qa.charamonitor.* helper app only
        _ = NSApplication.shared
        DriftCLI.qaTerminate(args)
    }
    if args.contains("--render-hotkeys") {   // 단축키 card off and on, 대화 모아보기 window; no combo is registered
        let suite = "qa.dogmonitor.hotkeys"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-hotkeys") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try HotkeysQA.render(to: dir)
        }
    }
    if args.contains("--render-draw") {   // 그룹 뽑기: each game mid-show and landed, light and dark
        let suite = "qa.dogmonitor.draw"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-draw") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try GroupDrawQA.render(to: dir)
        }
    }
    if args.contains("--render-throw") {   // 던지기 놀이: items, arc, 기절 stars, a seat knocked out, settings
        let suite = "qa.dogmonitor.throw"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-throw") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try ThrowQA.render(to: dir)
        }
    }
    if args.contains("--render-remote") {   // 원격 모임 members in 친구 상주 with bubbles and 입력 중, 대화 모아보기, light and dark
        let suite = "qa.dogmonitor.remote"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-remote") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try RemoteRoomQA.render(to: dir)
        }
    }
    if args.contains("--render-edges") {   // 친구 상주 자리, 창에 매달기, 의자: scenes and settings, light and dark
        let suite = "qa.dogmonitor.edges"
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        runCLI("--render-edges") { dir in
            defer { AppDefaults.store.removePersistentDomain(forName: suite) }
            try EdgesQA.render(to: dir)
        }
    }
    if args.contains("--render-photo") {   // 사진 메시지: chat both ways, an old friend, the pop-up bubble, the big view
        runCLI("--render-photo") { dir in try PhotoQA.render(to: dir) }
    }
    if args.contains("--render-friend-notes") {   // 프로필 카드, 낙서 쪽지 pad and note, light and dark
        runCLI("--render-friend-notes") { dir in try FriendNotesQA.render(to: dir) }
    }
    #endif

    #if !MAS
    if let i = args.firstIndex(of: "--qa-defaults"), i + 1 < args.count {   // QA: a throwaway preferences suite (SocialQA)
        AppDefaults.store = UserDefaults(suiteName: args[i + 1])!
        SocialQA.start(args)
    }
    #endif

    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = EditMenu.make()
    app.run()   // never returns, so appDelegate stays alive
}
