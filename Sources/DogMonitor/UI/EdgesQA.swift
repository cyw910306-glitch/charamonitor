import AppKit
import SwiftUI

/// `--render-edges`: 친구 상주 자리 on a small pretend screen (bottom whole, top half with a bubble under, right third),
/// 창에 매달기 (standing on a window, pulled out mid-spring, hanging by its side), the 의자 empty and sat on, and both
/// settings; light and dark. Runs on its own preferences suite (main.swift); no window list is read.
enum EdgesQA {
    /// The pretend screen: a menu bar on top, a Dock below.
    static let screen = CGSize(width: 840, height: 460)
    static let visible = CGRect(x: 0, y: 56, width: 840, height: 460 - 56 - 24)

    static func render(to dir: URL) throws {
        let looks: [FriendLook] = [
            FriendLook(character: .cat, id: CatCatalog.all.first?.id, profile: nil, colors: nil, cat: nil, outfit: nil),
            .fallback,
            FriendLook(character: .cat, id: CatCatalog.all.dropFirst().first?.id, profile: nil, colors: nil, cat: nil, outfit: nil),
        ]
        func seats() -> [RoomSeat] {
            zip(["해인", "창연", "보리"], looks).map { RoomSeat(SocialFriend(id: $0, nickname: $0, look: $1, status: .working, pairedAt: Date())) }
        }
        var sofa = looks[0]
        sofa.seat = "chair-sofa"
        let sitter = RoomSeat(SocialFriend(id: "s", nickname: "해인", look: sofa, status: .working, pairedAt: Date()))
        let fake = [ScreenSignature(id: 1, name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2),
                    ScreenSignature(id: 2, name: "DELL U2723QE", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 2)]
        let dog = DogSpriteCache(SpriteLook(friend: .fallback), pixelSize: 2)
        let cat = DogSpriteCache(SpriteLook(friend: looks[0]), pixelSize: 2)

        for (a, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            func shot<V: View>(_ name: String, _ v: V) throws {
                try DashboardSnapshot.snapshot(v.padding(), appearance: a, to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
            try shot("place-bottom-full", PlaceScene(edge: .bottom, length: .full, seats: seats()))
            try shot("place-top-half", PlaceScene(edge: .top, length: .half, seats: seats(), bubble: "해인: " + EmoteKind.kiss.line))
            try shot("place-right-third", PlaceScene(edge: .right, length: .third, seats: seats()))
            try shot("hang", HangScene(seats: seats()))
            try shot("chairs", VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(ChairCatalog.all, id: \.id) { c in ChairLayer(chair: c, rows: 0..<c.height, px: 2) }
                }
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(ChairCatalog.all.indices, id: \.self) { i in
                        ChairSeatView(chair: ChairCatalog.all[i], cache: i == 1 ? cat : dog)
                    }
                }
                HStack(alignment: .bottom) { RoomFriendView(seat: sitter, t: 0.5) }
                    .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.55, green: 0.72, blue: 0.48)))
            })
            try shot("settings", VStack(alignment: .leading, spacing: 16) {
                RoomPlaceSettings(screens: fake)
                Divider()
                ChairSettings(owned: ["chair-sofa"])
            }.frame(width: 380))
        }
    }
}

/// A desktop in miniature: menu bar, Dock, the band the seats use (dashed) and the seats on it.
private struct PlaceScene: View {
    let edge: RoomEdge
    let length: RoomLength
    let seats: [RoomSeat]
    var bubble: String?

    var body: some View {
        let s = EdgesQA.screen, band = RoomPlace.band(EdgesQA.visible, edge: edge, length: length)
        ZStack(alignment: .topLeading) {
            Desk()
            Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(Color.white.opacity(0.8))
                .frame(width: band.width, height: band.height).offset(x: band.minX, y: s.height - band.maxY)
            ForEach(seats.indices, id: \.self) { i in
                let o = RoomRules.origin(i, edge: edge, size: seats[i].size, in: band)
                RoomFriendView(seat: seats[i], t: 0.5).offset(x: o.x, y: s.height - o.y - seats[i].size.height)
            }
            if let bubble, let first = seats.first {
                let o = RoomRules.origin(0, edge: edge, size: first.size, in: band)
                SpeechBubbleView(text: bubble, tailUp: true).fixedSize()
                    .offset(x: o.x + first.body.width / 2 - 70, y: s.height - o.y + 2)
            }
            Text(verbatim: "\(edge.label) · \(length.label)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(6).offset(x: 8, y: 26)
        }
        .frame(width: s.width, height: s.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Another app's window with three friends on it: standing on its top edge, pulled up and springing back, and hanging
/// off its right side; the bands as the app draws them.
private struct HangScene: View {
    let seats: [RoomSeat]

    var body: some View {
        let s = EdgesQA.screen, w = CGRect(x: 120, y: 70, width: 520, height: 230)
        let size = seats[0].size
        // Standing still on the edge.
        let stand = CGPoint(x: 240, y: w.maxY)
        // Pulled up and right, let go 0.1 s ago.
        var pulled = RubberBand(anchor: CGPoint(x: 420, y: w.maxY), floor: HangRules.floor(.top, on: w), position: CGPoint(x: 520, y: w.maxY + 90))
        pulled.release(CGVector(dx: 0, dy: 200))
        pulled.step(dt: 0.1)
        // By the right side, settled.
        var side = RubberBand(anchor: CGPoint(x: w.maxX + size.width / 2, y: w.maxY - 30), floor: nil, position: CGPoint(x: w.maxX + size.width / 2, y: w.maxY - 30))
        for _ in 0..<80 { side.step(dt: RubberBand.maxLag) }
        let spots: [(CGPoint, CGPoint?)] = [(stand, nil), (pulled.position, pulled.anchor), (side.position, HangRules.knot(.right, anchor: side.anchor, width: size.width))]
        func y(_ v: CGFloat) -> CGFloat { s.height - v }
        return ZStack(alignment: .topLeading) {
            Desk()
            AppWindow().frame(width: w.width, height: w.height).offset(x: w.minX, y: y(w.maxY))
            ForEach(spots.indices, id: \.self) { i in
                if let a = spots[i].1 {
                    let b = CGPoint(x: spots[i].0.x, y: spots[i].0.y + seats[i].body.height / 2)
                    Path { p in p.move(to: CGPoint(x: a.x, y: y(a.y))); p.addLine(to: CGPoint(x: b.x, y: y(b.y))) }
                        .stroke(Color(red: 0.86, green: 0.36, blue: 0.42).opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    Circle().fill(Color(red: 0.86, green: 0.36, blue: 0.42)).frame(width: 6, height: 6).offset(x: a.x - 3, y: y(a.y) - 3)
                }
                RoomFriendView(seat: seats[i], t: 0.5)
                    .offset(x: spots[i].0.x - seats[i].size.width / 2, y: y(spots[i].0.y) - seats[i].size.height)
            }
        }
        .frame(width: s.width, height: s.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A plain sky desktop with a menu bar and a Dock.
private struct Desk: View {
    var body: some View {
        let s = EdgesQA.screen
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.42, green: 0.58, blue: 0.82), Color(red: 0.78, green: 0.66, blue: 0.80)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color.white.opacity(0.55)).frame(height: 24)
            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.35)).frame(width: 420, height: 48)
                .offset(y: s.height - 52)
        }
        .frame(width: s.width, height: s.height)
    }
}

/// Some other app's window: a title bar with three lights and a few grey lines.
private struct AppWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 30).background(Color(nsColor: .windowBackgroundColor))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.22)).frame(width: CGFloat(380 - i * 37 % 160), height: 9)
                }
            }
            .padding(18)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
