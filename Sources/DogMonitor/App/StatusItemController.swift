import AppKit
import Combine
import SwiftUI

/// Menu bar dog: animates a precomputed sprite, opens the dashboard popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let monitor: SystemMonitor
    private let settings: AppSettings
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var popover: NSPopover?
    private let menu = NSMenu()

    private var cache: DogSpriteCache
    private var look: SpriteLook
    private var filter = PoseFilter()
    /// Battery or special moment playing instead of the pose (SituationEngine), nil most of the time.
    private var extra: ExtraMotion? { didSet { Self.playing = extra } }
    /// Which drawn take of `extra` plays (DogSpriteCache.takeCount), picked anew each time it starts.
    private var take = 0 { didSet { Self.playingTake = take } }
    /// What the menu bar plays right now (motion and take), so the dashboard header shows the same moment.
    static private(set) var playing: ExtraMotion?
    static private(set) var playingTake = 0
    /// The SituationEngine.burst last seen (its end), so a new moment asking for the motion already showing still starts anew.
    private var seenBurst: Date?
    private var engine = SituationEngine()
    private let batterySampler = BatterySampler()
    private var battery: BatteryStats?
    private var batteryRead = Date.distantPast
    // The dog is a layer-backed subview over a transparent placeholder image that reserves its space.
    // Swapping layer contents costs far less than setting button.image every frame.
    private let sprite = SpriteView()

    // Frame timer: created once, rescheduled each frame by moving its fireDate.
    private var timer: Timer?
    private var screensAsleep = false
    private var systemAsleep = false
    private var sessionInactive = false
    private var isPaused: Bool { screensAsleep || systemAsleep || sessionInactive }

    private var shownPercent = -1
    // Latest busyness (CPU, memory pressure, heat). The sink runs before monitor.load is stored, so keep our own.
    private var load = 0.0
    private var bag = Set<AnyCancellable>()
    private let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .baselineOffset: 0.5,
    ]

    init(monitor: SystemMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings
        self.look = SpriteLook(settings)
        self.cache = DogSpriteCache(look, pixelSize: 1)
        super.init()

        filter = PoseFilter(pose: DogPose.forCPU(monitor.load))
        sprite.setFrames(cache.frames(for: filter.pose), smooth: cache.smooth)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = Self.placeholder(cache.imageSize)
            button.addSubview(sprite)
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(placeSprite),
                                                   name: NSView.frameDidChangeNotification, object: button)
        }
        buildMenu()
        updateTitle(cpu: monitor.cpuUsage, force: true)
        observe()
        startTimer()
        PermissionFlow.reopen = { [weak self] in self?.permissionFlowEnded() }
        PermissionFlow.started = { [weak self] in self?.shownAtBegin = self?.popover?.isShown ?? false }
        // A friend's right click menu ends in 설정 열기; the 커서 친구's double click opens the AI 비서.
        FriendMenu.openSettings = { [weak self] in MainActor.assumeIsolated { self?.showPopover(page: .settings) } }
        CursorBuddy.shared.openAssistant = { [weak self] in MainActor.assumeIsolated { self?.showPopover(page: .assistant) } }
    }

    // MARK: Observation

    /// Posted by pages that finish a choice (picking a character) so the popover closes and the menu bar shows it.
    static let closeRequest = Notification.Name.jellyClosePopover

    private func observe() {
        NotificationCenter.default.publisher(for: Self.closeRequest)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.closePopover() }
            .store(in: &bag)
        // @Published emits the new value before it is stored, so use the emitted value.
        // load is published last in each tick, so cpuUsage and memory are already current here.
        monitor.$load
            .sink { [weak self] load in self?.tick(load: load) }
            .store(in: &bag)

        // 집중 중: the time counts up in the menu bar instead of the CPU number.
        FocusCenter.shared.$menuTitle
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                guard let self, let button = self.statusItem.button else { return }
                guard let title else { self.updateTitle(cpu: self.monitor.cpuUsage, force: true); return }
                button.imagePosition = .imageLeading
                button.attributedTitle = NSAttributedString(string: " " + title, attributes: self.titleAttributes)
                self.placeSprite()
            }
            .store(in: &bag)

        settings.$showCPUPercent
            .dropFirst()
            .sink { [weak self] show in
                guard let self else { return }
                self.updateTitle(cpu: self.monitor.cpuUsage, force: true, show: show)
            }
            .store(in: &bag)

        // Color pickers fire many changes; rebuild the sprite once they settle. Any settings or saved
        // custom character change may matter; rebuildSprites skips the ones that leave the look alone.
        settings.objectWillChange.merge(with: CustomCharacterStore.shared.objectWillChange)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSprites() }
            .store(in: &bag)

        let nc = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Selector)] = [
            (NSWorkspace.screensDidSleepNotification, #selector(screensDidSleep)),
            (NSWorkspace.screensDidWakeNotification, #selector(screensDidWake)),
            (NSWorkspace.willSleepNotification, #selector(systemWillSleep)),
            (NSWorkspace.didWakeNotification, #selector(systemDidWake)),
            (NSWorkspace.sessionDidResignActiveNotification, #selector(sessionDidResign)),
            (NSWorkspace.sessionDidBecomeActiveNotification, #selector(sessionDidBecome)),
        ]
        for (name, sel) in pairs { nc.addObserver(self, selector: sel, name: name, object: nil) }
    }

    private func tick(load: Double) {
        self.load = load
        if let pose = filter.feed(load) { setPose(pose) }
        updateExtra()
        updateTitle(cpu: monitor.cpuUsage)
        updateTooltip()
    }

    private func setPose(_ pose: DogPose) {
        sprite.setFrames(cache.frames(for: pose, extra: extra, variant: take), smooth: cache.smooth)
        if !isPaused { scheduleNextFrame() }   // new pose may run much faster than the old one
    }

    /// Battery is read every 10 s (the 1 s ticks only sample it while the dashboard is open).
    private func updateExtra() {
        let now = Date()
        if now.timeIntervalSince(batteryRead) >= 10 {
            batteryRead = now
            battery = monitor.snapshot.flatMap { now.timeIntervalSince($0.timestamp) < 10 ? $0.battery : nil } ?? batterySampler.sample(now: now)
            PetSignals.shared.send(.sample(battery: battery, load: load, idle: PetSignals.idleSeconds()))
        }
        engine.prefs = MotionStore.shared.prefs
        let fresh = engine.update(battery: battery, pose: filter.pose, available: cache.availableExtras, now: now)
            ?? PetModel.shared.menuBarMotion(now: now, available: cache.availableExtras)   // 펫 키우기 hungry or out
        let burst = SituationEngine.burst
        let newBurst = burst != nil && burst?.until != seenBurst && burst?.prefer.first == fresh
        seenBurst = burst?.until
        guard fresh != extra || newBurst else { return }
        extra = fresh
        take = fresh.map { LinePick.pick("take." + $0.rawValue, Array(0..<max(1, cache.takeCount($0)))) } ?? 0
        // A moment (SituationEngine.play) showing the very motion it asked for first: that take's own line, if the
        // character has one. A motion it fell back to keeps the caller's line.
        if let fresh, SituationEngine.burst?.prefer.first == fresh {
            let lines = cache.lines(forExtra: fresh, variant: take)
            if !lines.isEmpty { SpeechBubbleCenter.shared.say(text: LinePick.pick("say.\(fresh.rawValue).\(take)", lines), source: .pet) }
        }
        setPose(filter.pose)
    }

    private func rebuildSprites() {
        let fresh = SpriteLook(settings)
        guard fresh != look else { return }
        look = fresh
        cache = DogSpriteCache(fresh, pixelSize: 1)
        extra = nil
        batteryRead = .distantPast   // the new character may have the moment the old one lacked
        updateExtra()
        setPose(filter.pose)
    }

    private static func placeholder(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { _ in true }
    }

    /// Puts the sprite exactly where the button draws its (transparent) image.
    @objc private func placeSprite() {
        guard let button = statusItem.button else { return }
        button.layoutSubtreeIfNeeded()
        let rect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let size = cache.imageSize
        let origin = NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded())
        let frame = NSRect(origin: origin, size: size)
        if sprite.frame != frame { sprite.frame = frame }
    }

    // MARK: Title and tooltip

    private func updateTitle(cpu: Double, force: Bool = false, show: Bool? = nil) {
        guard let button = statusItem.button, FocusCenter.shared.menuTitle == nil else { return }
        let show = show ?? settings.showCPUPercent
        guard show else {
            if force {
                button.attributedTitle = NSAttributedString()
                button.imagePosition = .imageOnly
                shownPercent = -1
                placeSprite()
            }
            return
        }
        let percent = Int((cpu * 100).rounded())
        guard force || percent != shownPercent else { return }
        shownPercent = percent
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: " \(percent)%", attributes: titleAttributes)
        if force { placeSprite() }
    }

    private func updateTooltip() {
        var text = "CPU \(Int((monitor.cpuUsage * 100).rounded()))%"
        if let mem = monitor.memory, mem.total > 0 {
            text += L(" · 메모리 \(Int((Double(mem.used) / Double(mem.total) * 100).rounded()))%")
            text += L(" (압력 \(Int((mem.pressure * 100).rounded()))%)")
        }
        if filter.pose != .lying, let why = monitor.loadCause.reason { text += " · \(why)" }
        if let pet = PetModel.shared.menuBarNote { text += " · \(pet)" }
        if statusItem.button?.toolTip != text { statusItem.button?.toolTip = text }
    }

    // MARK: Animation

    private func startTimer() {
        let t = Timer(timeInterval: 3600, target: self, selector: #selector(advanceFrame), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)   // keeps running while menus track
        timer = t
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        guard let timer else { return }
        let d = cache.frameDuration(for: filter.pose, cpu: load, extra: extra)
        timer.tolerance = d * 0.1
        timer.fireDate = Date(timeIntervalSinceNow: d)
    }

    @objc private func advanceFrame() {
        guard !isPaused else { timer?.fireDate = .distantFuture; return }
        if sprite.frameCount > 1 { sprite.show(sprite.index + 1) }
        scheduleNextFrame()
    }

    /// Asleep, screens off or locked: stop both the frame timer and the 1 s sampling.
    private func pauseChanged() {
        if isPaused {
            timer?.fireDate = .distantFuture
            monitor.stop()
            RunawayTracker.shared.stop()
        } else {
            monitor.start()
            RunawayTracker.shared.start()
            scheduleNextFrame()
        }
    }

    @objc private func screensDidSleep() { screensAsleep = true; pauseChanged() }
    @objc private func screensDidWake() { screensAsleep = false; pauseChanged() }
    @objc private func systemWillSleep() { systemAsleep = true; pauseChanged() }
    @objc private func systemDidWake() { systemAsleep = false; pauseChanged() }
    @objc private func sessionDidResign() { sessionInactive = true; pauseChanged() }
    @objc private func sessionDidBecome() { sessionInactive = false; pauseChanged() }

    // MARK: Clicks, popover, menu

    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// Explicit close: the colour panel goes too, otherwise popoverShouldClose would keep the popover open.
    private func closePopover() {
        Self.closeColorPanel()
        Self.holdOpen = false
        if PermissionFlow.isActive {   // popoverShouldClose would refuse; the user's own close still wins
            closedDuringFlow = true
            popover?.close()
        } else {
            popover?.performClose(nil)
        }
    }

    /// Closed by the user (icon, menu, a page's close request) while a permission prompt was up: not reopened.
    private var closedDuringFlow = false
    /// The popover was open when the flow started. Closed before it (the cleaner's wait for apps to quit): not reopened.
    private var shownAtBegin = false

    /// A permission prompt is answered: the focus comes back to the popover, or it opens again on the same page
    /// if the prompt took it away (open at the start, not closed by the user).
    private func permissionFlowEnded() {
        defer { closedDuringFlow = false; shownAtBegin = false }
        if let popover, popover.isShown {
            PopoverMemory.shared.stayed()
            NSApp.activate(ignoringOtherApps: true)
            setPopoverLowered(false)
            popover.contentViewController?.view.window?.makeKey()
        } else if shownAtBegin && !closedDuringFlow {
            showPopover()
        }
    }

    /// Set while the character creator is open: a click in Finder or Photos (to drag the next picture in, or
    /// just to look for one) must not close the popover and throw the half-made character away.
    static var holdOpen = false

    /// Nothing the user may be in the middle of: the automatic update waits for this before it quits the app.
    var isIdle: Bool { !(popover?.isShown ?? false) && !Self.holdOpen && !PermissionFlow.isActive }

    private static func closeColorPanel() {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    /// Also used by the --open-dashboard launch flag (QA). `page`: open on it instead of the remembered one
    /// (an open popover stays as it is).
    func showPopover(page: DashboardPage? = nil) {
        guard let button = statusItem.button else { return }
        if popover?.isShown == true, page != nil { return }
        monitor.detailed = true   // full snapshot before layout, so the popover opens at its final size
        let popover = self.popover ?? makePopover(page: page)
        self.popover = popover
        NSApp.activate(ignoringOtherApps: true)   // transient popovers need key focus to close on outside clicks
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installLayering()
    }

    /// Other windows must be able to come above the popover: our own panels, and any app the user switches to.
    private var popoverLevel: NSWindow.Level?
    private var layerObservers: [NSObjectProtocol] = []

    private func installLayering() {
        guard layerObservers.isEmpty else { return }
        PopoverLayer.lower = { [weak self] in self?.setPopoverLowered(true) }
        PopoverLayer.restore = { [weak self] in self?.setPopoverLowered(false) }
        let nc = NotificationCenter.default
        layerObservers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPopoverLowered(true) }
            },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPopoverLowered(false) }
            },
            // One of our own windows (colour panel, cursor buddy excluded: it never becomes key) is clicked:
            // it comes to the front, and the popover rises again once it is clicked itself.
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow else { return }
                    self.windowWasUsed(window)
                }
            },
        ]
        // The colour panel never becomes key from a click on its wheel or swatches, so watch the clicks themselves.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let window = event.window { MainActor.assumeIsolated { self?.windowWasUsed(window) } }
            return event
        }
    }

    private var clickMonitor: Any?

    /// A click or key focus in `window`: the popover (or a sheet or child of it) rises, any other window of ours
    /// (colour panel, photo picker) comes above it. The menu bar icon itself is left alone.
    private func windowWasUsed(_ window: NSWindow) {
        guard let mine = popover?.contentViewController?.view.window, window !== statusItem.button?.window else { return }
        var w: NSWindow? = window
        while let current = w, current !== mine { w = current.sheetParent ?? current.parent }
        setPopoverLowered(w == nil)
    }

    private func setPopoverLowered(_ lowered: Bool) {
        guard let window = popover?.contentViewController?.view.window else { return }
        if popoverLevel == nil { popoverLevel = window.level }
        window.level = lowered ? .normal : (popoverLevel ?? window.level)
    }

    private func makePopover(page: DashboardPage? = nil) -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        let host = NSHostingController(
            rootView: DashboardView(monitor: monitor, settings: settings, onQuit: { NSApp.terminate(nil) },
                                    startPage: page.map { p in _ = PopoverMemory.shared.reopen(now: Date()); return p }
                                        ?? PopoverMemory.shared.reopen(now: Date()))
        )
        // Let the popover own every resize. Otherwise SwiftUI grows the window from its bottom-left
        // origin when the content gets taller (first data, page switch) and the top leaves the screen.
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        return p
    }

    func popoverDidShow(_ notification: Notification) { monitor.detailed = true }

    /// Clicks in the colour panel or the photo picker count as outside clicks; keep the popover while they are up,
    /// while the creator is open and while macOS asks for a permission (its prompt takes the focus away, PermissionFlow).
    /// Clicking the menu bar icon still closes it (closePopover).
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let colorPanelUp = NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible
        return !colorPanelUp && NSApp.modalWindow == nil && !Self.holdOpen && !PermissionFlow.isActive
    }

    func popoverDidClose(_ notification: Notification) {
        layerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layerObservers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        popoverLevel = nil
        monitor.detailed = false
        PopoverMemory.shared.closed(at: Date())
        Self.holdOpen = false
        Self.closeColorPanel()
        // Drop the SwiftUI tree so nothing keeps rendering while hidden. showPopover rebuilds it.
        popover?.contentViewController = nil
        popover = nil
    }

    private func buildMenu() {
        let items: [(String, Selector, String)] = [
            (L("대시보드 열기"), #selector(menuOpenDashboard), ""),
            (L("활성 상태 보기"), #selector(menuOpenActivityMonitor), ""),
            (L("종료"), #selector(menuQuit), "q"),
        ]
        for (i, (title, sel, key)) in items.enumerated() {
            if i == 2 {
                let desktop = NSMenuItem(title: L("데스크톱 친구"), action: nil, keyEquivalent: "")
                desktop.submenu = desktopMenu
                desktopMenu.delegate = self
                menu.addItem(desktop)
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
    }

    /// Quick on/off for each 데스크톱 친구 (DesktopFriends.toggles), rebuilt each time it opens so the checks are current.
    private let desktopMenu = NSMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === desktopMenu else { return }
        menu.removeAllItems()
        FriendMenu.desktopItems().forEach(menu.addItem)
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        closePopover()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func menuOpenDashboard() { showPopover() }

    @objc private func menuOpenActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }
}
