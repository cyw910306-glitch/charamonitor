import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor(interval: 1.0)
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        WhatsNew.noteUpgrade()                   // before AssistantSettings writes this launch's keys
        AssistantCenter.shared.listenForURLs()   // charamonitor://say, including the one that launched the app
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !MAS
        ActivityTracker.shared.start()   // the cleaner's idle times count from here
        #endif
        RunawayTracker.shared.start()    // runaway processes need a few minutes of history
        monitor.start()
        #if !MAS
        SecurityCenter.shared.start()    // one scan a few seconds in, then daily
        Updater.shared.start()           // signed update.json 30 s in, then daily
        #endif
        OriginalCatalog.all += CharacterPack.loadAll()   // the user's own packs (docs/PACKS.md), before anything draws one
        statusItem = StatusItemController(monitor: monitor, settings: AppSettings.shared)
        CursorBuddy.shared.start()       // idle unless the 커서 친구 toggle is on
        HangingFriends.shared.start()    // the same for 대롱대롱 친구
        WeatherWindow.shared.start()     // the same for the 날씨 창문; its weather GETs only while it shows
        MeadowFriends.shared.start()     // the same for 풀밭 친구들
        FolderFriends.shared.start()     // the same for the 폴더 친구 (no timer while no Finder window is out)
        #if !MAS
        FolderIcons.shared.start()       // folders wearing the character follow a new character
        #endif
        DesktopRug.shared.start()        // the same for the 바탕화면 러그
        DesktopClones.shared.start()     // the same for the 복제 친구 (over the rug)
        // 우리 동네 바람 follows the 날씨 창문's city while the window is on (no fetch of its own), else 산들.
        HangingFriends.localWind = { WeatherWindow.shared.on ? WeatherService.shared.current?.wind : nil }
        AssistantCenter.shared.start()   // speech bubble, 먼저 말 걸기, opt-in integrations
        WhatsNew.check()                 // a newer version says its one-liner once
        Tour.startIfNew()                // the first bubbles explain the character, 3 s in
        SetupFlow.helloLater()           // once, after 내 설정 가져오기 restarted the app
        AutoRefine.shared.check()        // which AI, if any, can draw 자동 다듬기 on this Mac
        OpenSourceCleanup.run()          // 2.3: the paid era's settings and the guitar girl, once
        #if !MAS
        OpenSourceCleanup.sayGoodbyeLater()
        // 2.0 dropped the Claude 연결 card, the only way to remove its token: remove it once, here.
        if !AppDefaults.store.bool(forKey: "claudeTokenCleared") {
            ClaudeToken.delete()
            AppDefaults.store.set(true, forKey: "claudeTokenCleared")
        }
        // Also waits for a 자동 다듬기 drawing a closed creator is still finishing.
        Updater.isIdle = { [weak self] in (self?.statusItem?.isIdle ?? true) && CreatorModel.inFlight == 0 }
        #endif
        if CommandLine.arguments.contains("--open-dashboard") {   // QA: open the popover right after launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.statusItem?.showPopover()
            }
        }
    }

    /// A double-clicked .charamonitor: the same confirm as 설정 > 내 설정 가져오기.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL && $0.pathExtension.lowercased() == SetupFile.ext }) else { return }
        DispatchQueue.main.async { SetupFlow.confirmAndImport(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        #if !MAS
        ChatGPTCharacterClient.stopAll()
        #endif
    }
}

/// 2.3, the first free open-source build, tidies up once: the settings only removed code wrote (Pro, licenses, the
/// store, 고급 대화) and the retired guitar girl. Two upgrade checks read "proLicenseKey" and "proLicenses" as markers
/// and save what they decided, both in applicationWillFinishLaunching, which runs before `run`, so by then they have
/// settled and deleting the keys cannot make an update look like a new install.
enum OpenSourceCleanup {
    static let doneKey = "openSourceCleaned"
    /// Set until the guitar girl's goodbye bubble really showed.
    static let goodbyeKey = "girlGoodbyePending"
    /// Every key Pro/License.swift wrote (2.0's single-key ones included) and 고급 대화's switch. Nothing reads them now.
    static let removedKeys = ["proLicenses", "proNotice", "proActivatedKeys", "proLegacyMigratedKey", "proLicenseKey",
                              "proLicenseSource", "proLastVerifiedAt", "proUses", "proEmail", "proActivatedKey",
                              "assistant.advanced"]

    static func run(_ d: UserDefaults = AppDefaults.store, settings: AppSettings = .shared) {
        guard !d.bool(forKey: doneKey) else { return }
        // A safety net only: at launch both checks have already run and saved (no-ops here). They stay so a caller that
        // runs this earlier still settles them before the marker keys go; noteUpgrade first, it reads "assistant.nudges".
        WhatsNew.noteUpgrade(d)
        if d.string(forKey: "assistant.nudges") == nil { d.set(AssistantSettings.firstNudges(d).rawValue, forKey: "assistant.nudges") }
        removedKeys.forEach(d.removeObject(forKey:))
        #if !MAS   // the App Store build never had her
        retireGirl(d, settings)
        #endif
        d.set(true, forKey: doneKey)
    }

    #if !MAS
    /// Whoever had the guitar girl gets the dog (already standing in for her) and one goodbye bubble; her name and
    /// colours and her 지운 캐릭터 entry go.
    static func retireGirl(_ d: UserDefaults, _ settings: AppSettings) {
        // "girl" since 1.4; before that her name, kept reversed so it is not in the binary.
        if let raw = d.string(forKey: "character"), raw == "girl" || raw == String("irotih".reversed()) {
            settings.character = .dog
            d.set(true, forKey: goodbyeKey)
        }
        if settings.hiddenCharacters.contains("girl") { settings.hiddenCharacters.removeAll { $0 == "girl" } }
        d.removeObject(forKey: "girl")
    }

    static var goodbye: String { L("기타 소녀는 오픈 소스판에서 은퇴했어요. 그동안 함께해 줘서 고마워요! 이제 강아지가 메뉴바를 지킬게요.") }

    /// 20 s after launch, after 업데이트 한마디 has gone.
    static func sayGoodbyeLater(_ d: UserDefaults = AppDefaults.store) {
        guard d.bool(forKey: goodbyeKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { sayGoodbye(d) }
    }

    /// Once: the flag goes only when the bubble really showed (a call app in front mutes it, so the next launch tries).
    @discardableResult
    static func sayGoodbye(_ d: UserDefaults = AppDefaults.store, on center: SpeechBubbleCenter = .shared) -> Bool {
        guard d.bool(forKey: goodbyeKey), center.say(text: goodbye, source: .system) else { return false }
        d.removeObject(forKey: goodbyeKey)
        return true
    }
    #endif
}
