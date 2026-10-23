import AppKit
import SwiftUI

/// QA_ONLY=desktop renders: 데스크톱 친구 in 설정 (off, on), 대롱대롱 친구 as they hang, the 커서 친구 at each boost, 복제 친구, the 집중 위젯 and the 퀵물어보기 bubble.
/// The floating windows are made see-through (alpha 0) and their layers drawn offscreen, so nothing shows on the screen.
/// Everything lives in the QA's own defaults suite; no fetch, no sound.
enum DesktopQA {
    @MainActor
    static func render(to dir: URL) throws {
        let looks: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        func settings(_ name: String) throws {
            for (appearance, suffix) in looks {
                try DashboardSnapshot.snapshot(DesktopSettingsView().frame(width: 380).padding(), appearance: appearance,
                                               to: dir.appendingPathComponent("desktop-settings-\(name)-\(suffix).png"))
            }
        }
        try settings("off")
        MotionStore.shared.cursorBuddy = true
        HangingStore.shared.prefs.on = true
        HangingStore.shared.prefs.count = HangPrefs.maxCount
        HangingStore.shared.prefs.sound = false
        WeatherWindow.shared.on = true   // the switch only: WeatherWindow.start() never runs here, so nothing is fetched
        RugStore.shared.prefs.on = true   // the switch only: DesktopRug.start() never runs here
        FolderStore.shared.prefs.on = true   // the switch only: FolderFriends.start() never runs here (no window list read)
        var toys = ToyPrefs()   // the switch only: ToyBox.start() never runs here
        toys.on = true
        toys.add(.trampoline)
        toys.add(.ball)
        ToyStore.shared.prefs = toys
        MotionStore.shared.macBusy = true   // the switch only: MacReactions.start(monitor:) never runs here
        // 복제 친구: three out (the card says 3/8); DesktopClones.start() runs only for its own render below.
        CloneStore.shared.prefs = ClonePrefs(on: true, clones: (0..<3).map { CloneSpot(character: nil, x: 0.2 + 0.1 * Double($0), y: 0.05) })
        try settings("on")
        // 꾸미기: another 색 테마, big text and every 자세히 open, then back to the defaults.
        let look = AppSettings.shared
        (look.palette, look.settingsTextLarge, look.expandDetails) = (.lavender, true, true)
        AppDefaults.store.set(128, forKey: StarRules.bestKey)   // 별 줍기's 최고 기록 next to its buttons, at big text
        try settings("custom")
        AppDefaults.store.removeObject(forKey: StarRules.bestKey)
        (look.palette, look.settingsTextLarge, look.expandDetails) = (.strawberry, false, false)
        RugStore.shared.prefs.on = false
        FolderStore.shared.prefs.on = false
        ToyStore.shared.prefs = ToyPrefs()
        MotionStore.shared.macBusy = false

        // 대롱대롱 친구: five on the main screen, one of them a framed photo when my-dog/jelly-avatar.jpg is there.
        HangingFriends.qaHidden = true
        let photo = ProcessInfo.processInfo.environment["QA_CHARACTER"] ?? "my-dog/jelly-avatar.jpg"
        if FileManager.default.fileExists(atPath: photo) { HangingStore.shared.prefs.slots[2].imagePath = photo }
        HangingStore.shared.prefs.slots[1].rope = .ribbon
        HangingStore.shared.prefs.slots[3].rope = .beads
        HangingFriends.shared.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        if let layer = HangingFriends.shared.qaLayer {
            for (bg, suffix) in [(NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), "light"), (NSColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1), "dark")] {
                try png(layer, background: bg, to: dir.appendingPathComponent("desktop-hanging-\(suffix).png"))
            }
        }
        HangingStore.shared.prefs.on = false

        // 커서 친구 at each 빠르게 움직이면 step, at full boost: still, half, top (신남), and dizzy.
        CursorBuddy.qaHidden = true
        for boost in [BuddyBoost.normal, .big] {
            MotionStore.shared.buddyBoost = boost
            for (name, k, dizzy) in [("rest", 0.0, false), ("half", 0.5, false), ("top", 1.0, false), ("dizzy", 0.0, true)] {
                let view = CursorBuddy.shared.qaPose(k: CGFloat(k), dizzy: dizzy)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                guard let layer = view.layer else { continue }
                try png(layer, background: NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), scale: 3,
                        to: dir.appendingPathComponent("desktop-buddy-\(boost.rawValue)-\(name).png"))
            }
        }
        // 꾸욱 held before a throw, and tumbling through the air.
        for (name, windup, fly) in [("windup", true, nil), ("fly", false, CGFloat(0.6))] {
            let view = CursorBuddy.shared.qaPose(k: 0, windup: windup, fly: fly)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            guard let layer = view.layer else { continue }
            try png(layer, background: NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), scale: 3,
                    to: dir.appendingPathComponent("desktop-buddy-\(name).png"))
        }
        // Clicked: each reaction 40 % in, its mark held in place.
        FriendMark.qa = true
        var shown: NSView?
        for r in Reaction.allCases {
            let view = CursorBuddy.shared.qaPose(reaction: r, at: r.duration * 0.4)
            shown = view
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            guard let layer = view.layer else { continue }
            try png(layer, background: NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), scale: 3,
                    to: dir.appendingPathComponent("desktop-buddy-react-\(r.rawValue).png"))
        }
        shown?.layer?.sublayers?.filter { $0.name == FriendMark.name }.forEach { $0.removeFromSuperlayer() }
        FriendMark.qa = false
        MotionStore.shared.cursorBuddy = false

        // 복제 친구: five on the desktop, 움직이기 off so nothing ticks: sitting, mid-hop, blushing, two saying hi.
        DesktopClones.qaHidden = true
        FriendMark.qa = true
        CloneStore.shared.prefs = ClonePrefs(on: true, clones: [0.10, 0.17, 0.24, 0.31, 0.355].map { CloneSpot(character: nil, x: $0, y: 0.04) },
                                             moves: false)
        DesktopClones.shared.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let box = DesktopClones.shared.qaStage()
        if let layer = DesktopClones.shared.qaLayer, !box.isEmpty {
            for (bg, suffix) in [(NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), "light"), (NSColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1), "dark")] {
                try png(layer, background: bg, crop: box, to: dir.appendingPathComponent("desktop-clones-\(suffix).png"))
            }
        }
        FriendMark.qa = false
        CloneStore.shared.prefs = ClonePrefs()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        // 풀밭 친구들 clicked: six side by side, each 40 % into a reaction (every everyday one, then dizzy and a pout, then
        // a pet), first as the menu bar character, then as the first original (its 특기 frames); "still" as under 동작 줄이기.
        MeadowFriends.qaHidden = true
        FriendMark.qa = true
        let combos = [MeadowReaction(reaction: .dizzy, gait: .dizzy), MeadowReaction(reaction: .pout, gait: .stand)]
        let rows: [(String, [MeadowReaction], Bool)] = [
            ("a", Array(MeadowReaction.plays.prefix(4)) + combos, false),
            ("b", Array(MeadowReaction.plays.dropFirst(4)) + [.pet] + combos.prefix(1), false),
            ("still", [MeadowReaction.plays[0], .pet, MeadowReaction.plays[5], MeadowReaction.plays[6]] + combos, true),
        ]
        for (who, ids) in [("menubar", [String?](repeating: nil, count: 6)), ("original", [String?](repeating: OriginalCatalog.all.first?.id, count: 6))] {
            var prefs = MeadowPrefs(on: true, count: MeadowPrefs.maxCount)
            for (i, id) in ids.enumerated() where prefs.slots.indices.contains(i) { prefs.slots[i].character = id }
            MeadowStore.shared.prefs = prefs
            MeadowFriends.shared.start()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            for (row, shown, still) in rows {
                MeadowFriends.shared.qaLayer?.sublayers?.filter { $0.name == FriendMark.name }.forEach { $0.removeFromSuperlayer() }
                let box = MeadowFriends.shared.qaStage(shown, still: still)
                guard let layer = MeadowFriends.shared.qaLayer, !box.isEmpty else { continue }
                try png(layer, background: NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), crop: box,
                        to: dir.appendingPathComponent("desktop-meadow-react-\(who)-\(row).png"))
            }
        }
        FriendMark.qa = false
        MeadowStore.shared.prefs = MeadowPrefs()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        // 폴더 친구 on stand-in Finder windows (no real window is read): standing on the edge, walking, napping, clicked,
        // holding on while dragged; at each size, still as under 동작 줄이기, light and dark windows. Then as an original
        // (QA_FOLDER_CHARACTER, an original or a pack id such as pack-<slug>, else the first original) at 크게.
        FolderFriends.qaHidden = true
        FriendMark.qa = true
        let folderLooks: [(NSColor, Bool, String)] = [(NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), false, "light"),
                                                (NSColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1), true, "dark")]
        for size in [BuddySize.medium, .large] {
            FolderStore.shared.prefs.size = size
            for still in [false, true] {
                for (bg, dark, suffix) in folderLooks {
                    try png(FolderFriends.shared.qaScene(still: still, dark: dark), background: bg,
                            to: dir.appendingPathComponent("desktop-folder-\(size.rawValue)\(still ? "-still" : "")-\(suffix).png"))
                }
            }
        }
        let wanted = ProcessInfo.processInfo.environment["QA_FOLDER_CHARACTER"]
        // A pack (only read): the app loads them at launch, which a render skips.
        if let wanted, !OriginalCatalog.all.contains(where: { $0.id == wanted }) { OriginalCatalog.all += CharacterPack.loadAll() }
        if let original = OriginalCatalog.all.first(where: { $0.id == wanted }) ?? OriginalCatalog.all.first {
            FolderStore.shared.prefs.size = .large
            for (bg, dark, suffix) in folderLooks {
                try png(FolderFriends.shared.qaScene(still: false, dark: dark, character: original.id), background: bg,
                        to: dir.appendingPathComponent("desktop-folder-original-\(suffix).png"))
            }
        }
        FriendMark.qa = false
        FolderStore.shared.prefs = FolderPrefs()

        try focusWidgets(to: dir, looks: looks)
        try quickAsk(to: dir, looks: looks)
        try rugFaces(to: dir)
        #if !MAS
        try sponsor(to: dir)
        #endif
    }

    /// QA_ONLY=social: the 플러그인 card closed and open, each plugin's settings (옷 입히기, 근처 친구 with a code and two
    /// friends, 무전기, 원격 지원, 가상 오피스) and the 가상 오피스 board and a friend's chat. The friends are made up and
    /// live in memory; no listener, browser or link starts, nothing goes on the network.
    @MainActor
    static func social(to dir: URL) throws {
        let looks: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        func shot<V: View>(_ name: String, width: CGFloat = 380, _ view: @autoclosure () -> V) throws {
            for (appearance, suffix) in looks {
                try DashboardSnapshot.snapshot(view().frame(width: width).padding(), appearance: appearance,
                                               to: dir.appendingPathComponent("social-\(name)-\(suffix).png"))
            }
        }
        try shot("plugins-closed", PluginsSection())
        AppDefaults.store.set(PluginID.drip.map(\.rawValue), forKey: PluginCenter.unlockedKey)
        PluginCenter.shared.refresh()
        try shot("plugins-open", PluginsSection())
        try shot("wardrobe", WardrobeSettings())
        let bus = SocialBus.shared
        try shot("nearby-off", NearbySettings(part: .nearby))
        AppDefaults.store.set(true, forKey: "social.on")
        AppDefaults.store.set(true, forKey: "social.voice")
        AppDefaults.store.set(true, forKey: "social.remoteHelp")
        AppDefaults.store.set(true, forKey: OfficeCenter.onKey)
        let cat = FriendLook(character: .cat, id: CatCatalog.all.first?.id, profile: nil, colors: nil, cat: nil, outfit: nil)
        bus.setFriends([
            SocialFriend(id: "qa-a", nickname: "해인", look: cat, status: .meal, pairedAt: Date()),
            SocialFriend(id: "qa-b", nickname: "창연", look: .fallback, status: .focus, pairedAt: Date()),
            SocialFriend(id: "qa-c", nickname: "멀리 있는 친구", look: .fallback, status: .working, pairedAt: Date()),
        ])
        bus.setOnline(["qa-a", "qa-b"])
        bus.setOn(true)
        bus.code = "482913"
        bus.myStatus = .restroom
        try shot("nearby-on", NearbySettings(part: .nearby))
        try shot("walkie", NearbySettings(part: .walkieTalkie))
        try shot("remote", NearbySettings(part: .remoteHelp))
        try shot("office-settings", OfficeSettings())
        try shot("office-board", width: 360, OfficeBoardView(center: OfficeCenter.shared).frame(height: 300))
        SocialChat.shared.append("qa-a", "점심 먹으러 가요!", mine: false)
        SocialChat.shared.append("qa-a", "맛있게 먹고 와요", mine: true)
        try shot("chat", width: 340, FriendChatView(friendID: "qa-a").frame(height: 320))
        bus.setOn(false)
        bus.setFriends([])
        bus.setOnline([])
        bus.code = nil
    }

    #if !MAS
    /// 후원 친구 (QA_ONLY=sponsor, or with the rest): its 설정 card fresh and with gifts open, the card in each state and
    /// each service's colours, the covered frame, and the gifts' own art (구름 쿠션, 리본 폴더). Run with
    /// `-AppleLanguages '(en)'` for English. Only the QA's own defaults suite is touched; nothing is fetched.
    @MainActor
    static func sponsor(to dir: URL) throws {
        let looks: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        let lang = appIsEnglish ? "en" : "ko"
        func settings(_ name: String) throws {
            for (appearance, suffix) in looks {
                try DashboardSnapshot.snapshot(DesktopSettingsView(sponsorOnly: true).frame(width: 380).padding(), appearance: appearance,
                                               to: dir.appendingPathComponent("sponsor-settings-\(name)-\(lang)-\(suffix).png"))
            }
        }
        try settings("fresh")
        for _ in 0..<3 { SponsorGifts.shared.unlock() }
        SponsorCenter.shared.state.stats = SponsorStats(offers: 7, opens: 4, completes: 3, clicks: 1)
        SponsorCenter.shared.state.stop(now: Date())
        AppSettings.shared.expandDetails = true
        try settings("gifts")
        AppSettings.shared.expandDetails = false

        let cards = SponsorManifest.bundled.cards
        guard let first = cards.first else { return }
        let peach = SponsorGift.peach
        let states: [(String, SponsorCardView)] = [
            ("viewing", SponsorCardView(card: first, watched: 6)),
            ("paused", SponsorCardView(card: first, watched: 9, paused: true)),
            ("gift", SponsorCardView(card: first, watched: 15, done: (L("선물이 열렸어요: \(peach.emoji) \(peach.label)"), peach.howTo))),
            ("capped", SponsorCardView(card: first, watched: 15, done: (L("오늘 선물은 다 받았어요"), L("내일 또 열려요. 끝까지 봐 줘서 고마워요")))),
        ]
        for (name, view) in states {
            for (appearance, suffix) in looks {
                try DashboardSnapshot.snapshot(view.padding(14), appearance: appearance,
                                               to: dir.appendingPathComponent("sponsor-card-\(name)-\(lang)-\(suffix).png"))
            }
        }
        let all = VStack(spacing: 10) { ForEach(cards, id: \.id) { SponsorCardView(card: $0, watched: 10) } }
        try DashboardSnapshot.snapshot(all.padding(14), appearance: .aqua, to: dir.appendingPathComponent("sponsor-cards-all-\(lang).png"))

        let frame = SponsorFrame()
        try png(frame.qaLayer(), background: NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1), scale: 3,
                to: dir.appendingPathComponent("sponsor-frame.png"))
        let dog = DogSpriteCache(profile: .defaultDog, pixelSize: 8, style: .auto)
        var art: [(String, NSImage)] = [("toy-cloud", ToyArt.image(.cloud))]
        if let who = BuddyGait.frames(dog)[.stand]?.first {
            art.append(("folder-ribbon", FolderIcons.art(folder: NSWorkspace.shared.icon(for: .folder), character: FolderIcons.trimmed(who),
                                                         smooth: dog.smooth, style: .ribbon)))
        }
        for (name, image) in art {
            guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: dir.appendingPathComponent("sponsor-\(name).png"))
        }
        try rugFaces(to: dir)
    }
    #endif

    /// 바탕화면 러그's faces as flat textures: 캐릭터 for a pixel dog and an illustrated original in two 러그 색, a pixel
    /// original printed in dark mode, its back, and the old 무늬.
    @MainActor
    private static func rugFaces(to dir: URL) throws {
        let shiba = DogProfile.presets.first { $0.id == "shiba" }?.profile ?? .defaultDog
        var shots: [(String, NSImage)] = [
            ("character-dog-strawberry", RugArt.front(.character, color: .strawberry, character: RugArt.art(DogSpriteCache(profile: shiba, style: .pixel)))),
            ("back-strawberry", RugArt.back(.character, color: .strawberry)),
            ("pattern", RugArt.front(.pattern, color: .strawberry, character: nil)),
            ("stripes-mint", RugArt.front(.stripes, color: .mint, character: nil)),
            ("check-sky", RugArt.front(.check, color: .sky, character: nil)),
            ("dots-lavender", RugArt.front(.dots, color: .lavender, character: nil)),
            ("back-lemon", RugArt.back(.dots, color: .lemon)),
            ("hearts-peach", RugArt.front(.hearts, color: .peach, character: nil)),
            ("stars-lavender", RugArt.front(.stars, color: .lavender, character: nil)),
            ("rainbow-cocoa", RugArt.front(.rainbow, color: .cocoa, character: nil)),
        ]
        if let original = OriginalCatalog.all.first {
            shots.append(("character-original-mint", RugArt.front(.character, color: .mint, character: RugArt.art(DogSpriteCache(original, style: .illustration)))))
            // Printed while the Mac is dark: must match the light one (the frames' dark menu bar copy never shows).
            var dark: NSImage?
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                dark = RugArt.front(.character, color: .lemon, character: RugArt.art(DogSpriteCache(original, style: .pixel)))
            }
            if let dark { shots.append(("character-original-lemon-darkmode", dark)) }
        }
        for (name, image) in shots {
            guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: dir.appendingPathComponent("desktop-rug-\(name).png"))
        }
    }

    /// 퀵물어보기 (seeded, nothing asked): the greeting, a 오늘 진도 answer and a cheer side by side, per 색 테마, in light
    /// and dark; then 크게 without the face.
    @MainActor
    private static func quickAsk(to dir: URL, looks: [(NSAppearance.Name, String)]) throws {
        let store = MotionStore.shared
        let greet = FriendQuickAsk(), cheer = FriendQuickAsk()
        cheer.seed(answer: "최고예요! 오늘도 정말 잘하고 있어요!", chip: .cheer)
        let states = HStack(alignment: .bottom, spacing: 0) {
            FriendQuickAskView(model: greet)
            FriendQuickAskView(model: FriendQuickAsk.sample())
            FriendQuickAskView(model: cheer)
        }
        for t in QuickAskTheme.allCases {
            store.quickAskTheme = t
            for (appearance, suffix) in looks {
                try DashboardSnapshot.snapshot(states.padding(), appearance: appearance,
                                               to: dir.appendingPathComponent("desktop-quickask-\(t.rawValue)-\(suffix).png"))
            }
        }
        store.quickAskTheme = .peach
        store.quickAskTextSize = .large
        store.quickAskShowAvatar = false
        for (appearance, suffix) in looks {
            try DashboardSnapshot.snapshot(states.padding(), appearance: appearance,
                                           to: dir.appendingPathComponent("desktop-quickask-large-noface-\(suffix).png"))
        }
        store.quickAskTextSize = .regular
        store.quickAskShowAvatar = true
    }

    /// 집중 위젯 (seeded, nothing ticks): the states side by side, then each 위젯 색, in light and dark.
    @MainActor
    private static func focusWidgets(to dir: URL, looks: [(NSAppearance.Name, String)]) throws {
        let now = Date()
        func widget(_ minutes: Double, paused: Bool = false, task: String? = nil, theme: FocusTheme = .lavender,
                    size: FocusSize = .normal, goal: Int = 25) -> FocusWidget {
            let c = FocusCenter(defaults: AppDefaults.store)
            var s = FocusSession(start: now - minutes * 60)
            if paused { s.pause(now) }
            c.seed(session: s, task: task.map { FocusTask(id: "qa", title: $0) })
            c.theme = theme; c.size = size; c.goalMinutes = goal
            return FocusWidget(center: c)
        }
        let states = HStack(alignment: .bottom, spacing: 4) {
            widget(5, task: "주간 회의 자료 정리")
            widget(30)
            widget(12, paused: true)
            widget(52, goal: 50)
            widget(8, goal: 0)
            widget(18, task: "메일 답장", size: .large)
        }
        let themes = HStack(alignment: .bottom, spacing: 4) { ForEach(FocusTheme.allCases, id: \.self) { widget(18, theme: $0) } }
        for (appearance, suffix) in looks {
            try DashboardSnapshot.snapshot(states.padding(), appearance: appearance, to: dir.appendingPathComponent("focus-states-\(suffix).png"))
            try DashboardSnapshot.snapshot(themes.padding(), appearance: appearance, to: dir.appendingPathComponent("focus-themes-\(suffix).png"))
        }
    }

    /// `layer` (or its `crop` part) drawn at `scale` over `background` (the floating windows are clear; this stands in for the desktop).
    private static func png(_ layer: CALayer, background: NSColor, scale: CGFloat = 2, crop: CGRect? = nil, to url: URL) throws {
        let size = crop?.size ?? layer.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { throw CocoaError(.fileWriteUnknown) }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if let crop { ctx.translateBy(x: -crop.minX, y: -crop.minY) }
        layer.render(in: ctx)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
