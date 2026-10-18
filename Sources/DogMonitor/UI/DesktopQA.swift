import AppKit
import SwiftUI

/// QA_ONLY=desktop renders: 데스크톱 친구 in 설정 (off, on), 대롱대롱 친구 as they hang, and the 커서 친구 at each boost.
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
        try settings("on")

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
