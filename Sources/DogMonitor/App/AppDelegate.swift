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
        DesktopRug.shared.start()        // the same for the 바탕화면 러그
        // 우리 동네 바람 follows the 날씨 창문's city while the window is on (no fetch of its own), else 산들.
        HangingFriends.localWind = { WeatherWindow.shared.on ? WeatherService.shared.current?.wind : nil }
        AssistantCenter.shared.start()   // speech bubble, 먼저 말 걸기, opt-in integrations
        WhatsNew.check()                 // a newer version says its one-liner once
        Tour.startIfNew()                // the first bubbles explain the character, 3 s in
        AutoRefine.shared.check()        // which AI, if any, can draw 자동 다듬기 on this Mac
        #if !MAS
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

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        #if !MAS
        ChatGPTCharacterClient.stopAll()
        #endif
    }
}
