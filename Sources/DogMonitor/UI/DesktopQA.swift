import AppKit
import SwiftUI

/// QA_ONLY=desktop renders: 데스크톱 친구 in 설정 (off, on), 대롱대롱 친구 as they hang, the 커서 친구 at each boost, the 집중 위젯 and the 퀵물어보기 bubble.
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
        try settings("on")
        // 꾸미기: another 색 테마, big text and every 자세히 open, then back to the defaults.
        let look = AppSettings.shared
        (look.palette, look.settingsTextLarge, look.expandDetails) = (.lavender, true, true)
        try settings("custom")
        (look.palette, look.settingsTextLarge, look.expandDetails) = (.strawberry, false, false)
        RugStore.shared.prefs.on = false

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
        MotionStore.shared.cursorBuddy = false

        try focusWidgets(to: dir, looks: looks)
        try quickAsk(to: dir, looks: looks)
        try rugFaces(to: dir)
    }

    /// 바탕화면 러그's faces as flat textures: 캐릭터 for a pixel dog and an illustrated original in two 러그 색, a pixel
    /// original printed in dark mode, its back, and the old 무늬.
    @MainActor
    private static func rugFaces(to dir: URL) throws {
        let shiba = DogProfile.presets.first { $0.id == "shiba" }?.profile ?? .defaultDog
        var shots: [(String, NSImage)] = [
            ("character-dog-strawberry", RugArt.front(.character, color: .strawberry, character: RugArt.art(DogSpriteCache(profile: shiba, style: .pixel)))),
            ("back-strawberry", RugArt.back(.character, color: .strawberry)),
            ("pattern", RugArt.front(.pattern, color: .strawberry, character: nil)),
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

    /// `layer` drawn at `scale` over `background` (the floating windows are clear; this stands in for the desktop).
    private static func png(_ layer: CALayer, background: NSColor, scale: CGFloat = 2, to url: URL) throws {
        let size = layer.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { throw CocoaError(.fileWriteUnknown) }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        layer.render(in: ctx)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
