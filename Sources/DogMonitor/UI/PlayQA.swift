import AppKit
import SwiftUI

/// --render-play: the 놀이 card with its 2P 캐릭터 row, and P1 and P2 standing side by side as a session draws them
/// (a picked cat, a picked original, nothing picked: P1 tinted), light and dark. Its own defaults suite, nothing on screen.
enum PlayQA {
    @MainActor
    static func render(to dir: URL) throws {
        let looks: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        AppDefaults.store.set(true, forKey: PlayMode.twoPlayerKey)
        var picks: [(String, String)] = [("", "same")]
        if let cat = CatCatalog.all.first { picks.append(("cat:\(cat.id)", "cat")) }
        if let o = OriginalCatalog.all.first { picks.append(("original:\(o.id)", "original")) }
        for (pick, name) in picks {
            P2Character.pick = pick
            for (appearance, suffix) in looks {
                try DashboardSnapshot.snapshot(DesktopSettingsView(playOnly: true).frame(width: 380).padding(), appearance: appearance,
                                               to: dir.appendingPathComponent("play-settings-\(name)-\(suffix).png"))
            }
            try DashboardSnapshot.snapshot(Scene(), appearance: .aqua, to: dir.appendingPathComponent("play-scene-\(name).png"))
        }
        P2Character.pick = ""
    }

    /// P1 (the character chosen now) and P2 on a window's top edge, the way PlayMode dresses them.
    private struct Scene: View {
        var body: some View {
            let p1 = MeadowFriends.cache(character: nil, pixelSize: MotionStore.shared.buddySize.pixelSize)
            let p2 = PlayMode.p2Look(.buddy)
            let f1 = p1.frames(for: .walk).first ?? NSImage()
            let f2 = p2.cache.frames(for: .walk).first.map { f in p2.tint.map { PlayMode.tinted(f, $0) } ?? f } ?? NSImage()
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.78, green: 0.88, blue: 0.98), Color(red: 0.93, green: 0.96, blue: 1)], startPoint: .top, endPoint: .bottom)
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)).frame(width: 420, height: 90)
                    .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.82)).frame(height: 22) }
                    .offset(y: 0)
                HStack(alignment: .bottom, spacing: 40) {
                    player("1P", f1, size: p1.imageSize, flip: false)
                    player("2P", f2, size: p2.cache.imageSize, flip: true)
                }
                .offset(y: -90)
            }
            .frame(width: 520, height: 260)
        }

        private func player(_ tag: String, _ image: NSImage, size: NSSize, flip: Bool) -> some View {
            VStack(spacing: 2) {
                Text("🎮 \(tag)").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: size.width * 2, height: size.height * 2)
                    .scaleEffect(x: flip ? -1 : 1, y: 1)
            }
        }
    }
}
