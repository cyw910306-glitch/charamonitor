import CoreGraphics
import Foundation

/// A piece for the 펫 키우기 room, bought with coins. Furniture art is ASCII rows ("." see-through) in
/// `PetRoomArt.palette` colours, outlined automatically; wallpapers and floors are patterns.
struct PetItem: Identifiable, Equatable {
    enum Kind: Equatable { case wall, floor, wallpaper, floorTile }
    let id: String
    let name: String
    let kind: Kind
    let price: Int
    var rows: [String] = []
}

enum PetCatalog {
    static let starterWallpaper = "paper-cream", starterFloor = "floor-wood", starterBed = "bed"
    static let starterItems: Set<String> = [starterWallpaper, starterFloor, starterBed]

    static let all: [PetItem] = [
        // Wall
        PetItem(id: "window", name: L("창문"), kind: .wall, price: 40, rows: [
            "WWWWWWWWWWWWWWWW",
            "WbbbbbbWWbbbbbbW",
            "WbwwbbbWWbbbbbbW",
            "WbwbbbbWWbbbbwbW",
            "WbbbbbbWWbbbwwbW",
            "WbbbbbbWWbbbbbbW",
            "WWWWWWWWWWWWWWWW",
            "WbbbbbbWWbbbbbbW",
            "WbbbbbbWWbbbbbbW",
            "WBBBBBBWWBBBBBBW",
            "WWWWWWWWWWWWWWWW",
            "tttttttttttttttt",
        ]),
        PetItem(id: "frame", name: L("꽃 액자"), kind: .wall, price: 30, rows: [
            "TTTTTTTTTTTTTT",
            "TttttttttttttT",
            "TtwwwwwwwwwwtT",
            "TtwwwpwpwwwwtT",
            "TtwwppyppwwwtT",
            "TtwwwpppwwwwtT",
            "TtwwwwGwwwwwtT",
            "TtwwwgGwwwwwtT",
            "TtwwwwGgwwwwtT",
            "TtggggGgggggtT",
            "TttttttttttttT",
            "TTTTTTTTTTTTTT",
        ]),
        PetItem(id: "clock", name: L("벽시계"), kind: .wall, price: 35, rows: [
            "...rrrrrr...",
            "..rwwwywwr..",
            ".rwwwwkwwwr.",
            "rwwwwwkwwwwr",
            "rywwwwkwwwyr",
            "rwwwwwkkkwwr",
            "rwwwwwwwwwwr",
            "rwwwwwwwwwwr",
            ".rwwwwywwwr.",
            "..rwwwwwwr..",
            "...rrrrrr...",
        ]),
        PetItem(id: "shelf", name: L("화분 선반"), kind: .wall, price: 45, rows: [
            ".g.g........p.p...",
            "gGgGg......pyp....",
            ".gGg........G.....",
            ".ooo.......ooo....",
            ".ooo.......ooo....",
            "tttttttttttttttttt",
            "TTTTTTTTTTTTTTTTTT",
            ".T..............T.",
            ".TT............TT.",
        ]),
        PetItem(id: "garland", name: L("깃발 가랜드"), kind: .wall, price: 25, rows: [
            "TTTTTTTTTTTTTTTTTTTTTT",
            ".rrr..yyy..lll..ppp...",
            "..r....y....l....p....",
        ]),
        // Floor
        PetItem(id: "bed", name: L("폭신 침대"), kind: .floor, price: 60, rows: [
            "ttt.....................",
            "tTt.....................",
            "tTtwww..................",
            "tTtwwwwppppppppppppppp..",
            "tTtwwwWpppPpppPppppppptt",
            "tTtWWWWpppppppppppppPPtt",
            "tTtWWWWPPPPPPPPPPPPPPPtt",
            "tTttttttttttttttttttttTt",
            "tTTTTTTTTTTTTTTTTTTTTTTt",
            "tT....................Tt",
        ]),
        PetItem(id: "plant", name: L("큰 화분"), kind: .floor, price: 35, rows: [
            "......g.......",
            "....g.gG.g....",
            "...gGg.GgGg...",
            "..gGgGgGgGgg..",
            ".gGgggGgggGgg.",
            "gGgGgGgGgGgGgG",
            ".ggGgggGgggGg.",
            "..gGgg.GggGg..",
            "...g..GG..g...",
            "......GG......",
            "...oooooooo...",
            "...oyyyyyyo...",
            "....oooooo....",
            "....oooooo....",
            ".....oooo.....",
        ]),
        PetItem(id: "desk", name: L("책상과 스탠드"), kind: .floor, price: 70, rows: [
            "..................yyyy..",
            ".................yyyyyy.",
            "....................n...",
            "....................n...",
            "..rr................n...",
            "..rrbb..............n...",
            "..rrbbll...........nnn..",
            "tttttttttttttttttttttttt",
            "TTTTTTTTTTTTTTTTTTTTTTTT",
            ".TT..............tttttT.",
            ".TT..............tyyytT.",
            ".TT..............tttttT.",
            ".TT..............tyyytT.",
            ".TT..............tttttT.",
            ".TT..................TT.",
        ]),
        PetItem(id: "sofa", name: L("라벤더 소파"), kind: .floor, price: 90, rows: [
            "...vvvvvvvvvvvvvvvvvvvv...",
            "..vvvvvvvvvvVvvvvvvvvvvv..",
            "..vvvvvvvvvvVvvvvvvvvvvv..",
            "vvvvvvvvvvvvVvvvvvvvvvvvvv",
            "vVvvvvvvvvvvVvvvvvvvvvvvVv",
            "vVwwwwwwwwwwwwwwwwwwwwwwVv",
            "vVwwwwwwwwwwWwwwwwwwwwwwVv",
            "vVVVVVVVVVVVVVVVVVVVVVVVVv",
            "vVVVVVVVVVVVVVVVVVVVVVVVVv",
            ".T......................T.",
        ]),
        PetItem(id: "bookshelf", name: L("책장"), kind: .floor, price: 80, rows: [
            "tttttttttttttttttt",
            "tTTTTTTTTTTTTTTTTt",
            "tTrrbbTyyTllvvTpTt",
            "tTrrbbTyyTllvvTpTt",
            "tTrRbBTyYTlLvVTpTt",
            "tTrrbbTyyTllvvTpTt",
            "tttttttttttttttttt",
            "tTggoTrrrrTbbTyyTt",
            "tTggoTrrrrTbbTyyTt",
            "tTGgoTRRRRTBbTYyTt",
            "tTggoTrrrrTbbTyyTt",
            "tttttttttttttttttt",
            "tTTlllTTvvvvTToTTt",
            "tTTlllTTvvvvTToTTt",
            "tTTLLLTTVVVVTToTTt",
            "tttttttttttttttttt",
            "TT..............TT",
        ]),
        PetItem(id: "toybox", name: L("장난감 상자"), kind: .floor, price: 40, rows: [
            "...yy.........rr..",
            "..yyyy.......rwrr.",
            "...yy...ll...rrrr.",
            "...Y...llll...rr..",
            "oooooooooooooooooo",
            "oyyyyyyyyyyyyyyyyo",
            "oooooooooooooooooo",
            "ooooooowwwwooooooo",
            "ooooooowrrwooooooo",
            "ooooooowwwwooooooo",
            "oooooooooooooooooo",
            "OOOOOOOOOOOOOOOOOO",
        ]),
        PetItem(id: "lamp", name: L("스탠드 조명"), kind: .floor, price: 45, rows: [
            "...yyyyyy...",
            "..yyyyyyyy..",
            ".yyyyyyyyyy.",
            ".YYYYYYYYYY.",
        ] + Array(repeating: ".....nn.....", count: 14) + [
            "....nnnn....",
            "...nnnnnn...",
        ]),
        PetItem(id: "fishbowl", name: L("어항"), kind: .floor, price: 75, rows: [
            "...NNNNNNNN...",
            "..bwbbbbbbbb..",
            ".bwbbbbbbbbbb.",
            ".bbbbbbbbbbbb.",
            ".bbbboooobobb.",
            ".bbbbooooobbb.",
            ".bbbboooobobb.",
            ".BbbbbbbbbbbB.",
            "..BBgbbbbgBB..",
            "...BBBBBBBB...",
            "..tttttttttt..",
            "...T......T...",
            "...T......T...",
            "...T......T...",
            "..TT......TT..",
        ]),
        // Wallpaper and floor
        PetItem(id: "paper-cream", name: L("크림 줄무늬"), kind: .wallpaper, price: 0),
        PetItem(id: "paper-mint", name: L("민트 물방울"), kind: .wallpaper, price: 30),
        PetItem(id: "paper-berry", name: L("딸기 체크"), kind: .wallpaper, price: 30),
        PetItem(id: "paper-night", name: L("밤하늘 별"), kind: .wallpaper, price: 50),
        PetItem(id: "floor-wood", name: L("원목 마루"), kind: .floorTile, price: 0),
        PetItem(id: "floor-tile", name: L("체크 타일"), kind: .floorTile, price: 30),
        PetItem(id: "floor-carpet", name: L("하늘 카펫"), kind: .floorTile, price: 40),
    ]

    static func item(_ id: String) -> PetItem? { all.first { $0.id == id } }
    static func items(_ kind: PetItem.Kind) -> [PetItem] { all.filter { $0.kind == kind } }
}

/// Draws the 펫 키우기 room and its pieces as pixel art (1 art px per point, the page scales it up).
enum PetRoomArt {
    static let width = 124, height = 60
    /// Wall above, a 2 px baseboard, floor below. Floor pieces stand with their feet a little into the floor.
    static let baseboard = 42, floorTop = 44, floorFeet = 48
    /// Centre x of each slot (0...2 wall, 3...5 floor), and the wall pieces' top row.
    static let slotX = [21, 62, 103, 20, 62, 104]
    static let wallTop = 7
    /// Pixel scale the page draws everything at (the character too, see SpriteHolder.pixelSize).
    static let scale: CGFloat = 3

    static let outline = PixelColor(hex: "#5A3E36")
    static let palette: [Character: PixelColor] = Dictionary(uniqueKeysWithValues: [
        ("k", "#5A3E36"), ("w", "#FFF8EC"), ("W", "#E9DCC6"), ("b", "#9FD3F0"), ("B", "#6FB2DD"),
        ("r", "#F07C7C"), ("R", "#D65A63"), ("p", "#F8B5C8"), ("P", "#E68FAA"), ("y", "#FFD66B"),
        ("Y", "#E9B44C"), ("g", "#8FCB7A"), ("G", "#5FA35A"), ("o", "#F2A65A"), ("O", "#D9853F"),
        ("t", "#C98E5E"), ("T", "#A06B45"), ("l", "#7FC4B5"), ("L", "#5AA597"), ("v", "#B9A3E3"),
        ("V", "#9480C9"), ("n", "#7A7F8C"), ("N", "#C9CED6"),
    ].map { ($0.0.first!, PixelColor(hex: $0.1)) })

    /// RGBA canvas with the few drawing operations the room needs.
    struct Canvas {
        let width: Int, height: Int
        var px: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            px = [UInt8](repeating: 0, count: width * height * 4)
        }

        mutating func set(_ x: Int, _ y: Int, _ c: PixelColor) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let i = (y * width + x) * 4
            px[i] = c.r; px[i + 1] = c.g; px[i + 2] = c.b; px[i + 3] = 255
        }

        /// Pastes another canvas, see-through pixels skipped.
        mutating func paste(_ s: Canvas, x: Int, y: Int) {
            for sy in 0..<s.height { for sx in 0..<s.width {
                let i = (sy * s.width + sx) * 4
                guard s.px[i + 3] != 0 else { continue }
                set(x + sx, y + sy, PixelColor(r: s.px[i], g: s.px[i + 1], b: s.px[i + 2]))
            } }
        }

        var image: CGImage { DogRenderer.cgImage(px, width: width, height: height) }
    }

    /// ASCII art with a 1 px outline all round (the result is 2 px wider and taller than the rows).
    static func sprite(_ rows: [String]) -> Canvas {
        let w = (rows.map(\.count).max() ?? 0) + 2, h = rows.count + 2
        var solid = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        var c = Canvas(width: w, height: h)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = palette[ch] else { continue }
                c.set(x + 1, y + 1, color)
                solid[y + 1][x + 1] = true
            }
        }
        for y in 0..<h { for x in 0..<w where !solid[y][x] {
            let near = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            if near.contains(where: { $0.0 >= 0 && $0.1 >= 0 && $0.0 < w && $0.1 < h && solid[$0.1][$0.0] }) { c.set(x, y, outline) }
        } }
        return c
    }

    // MARK: Covers

    /// Wallpaper colour at (x, y): a base and a pattern colour.
    static func wallpaper(_ id: String, _ x: Int, _ y: Int) -> PixelColor {
        switch id {
        case "paper-mint":
            let base = PixelColor(hex: "#DDF1E6"), dot = PixelColor(hex: "#B6DEC8")
            let ox = (y / 8) % 2 == 0 ? 0 : 5
            return (x + ox) % 10 < 2 && y % 8 < 2 ? dot : base
        case "paper-berry":
            let a = PixelColor(hex: "#FBE3E8"), b = PixelColor(hex: "#F5CDD6"), seed = PixelColor(hex: "#F09AAE")
            if x % 12 == 6, y % 12 == 6 { return seed }
            return ((x / 6) + (y / 6)) % 2 == 0 ? b : a
        case "paper-night":
            let base = PixelColor(hex: "#3B4170"), star = PixelColor(hex: "#F7E7A1"), dim = PixelColor(hex: "#6D73A8")
            let h = (x * 7919 + y * 104_729) % 97
            if h == 0 { return star }
            if h == 1 || h == 2 { return dim }
            // A few plus-shaped stars at fixed spots.
            for (sx, sy) in [(14, 6), (58, 30), (96, 12), (36, 22), (116, 34)] where abs(x - sx) + abs(y - sy) <= 1 && (x == sx || y == sy) {
                return star
            }
            return base
        default:   // paper-cream
            return x % 8 < 2 ? PixelColor(hex: "#F1DFC4") : PixelColor(hex: "#FAF0DF")
        }
    }

    static func floor(_ id: String, _ x: Int, _ y: Int) -> PixelColor {
        let row = y - floorTop
        switch id {
        case "floor-tile":
            return ((x / 5) + (row / 4)) % 2 == 0 ? PixelColor(hex: "#EADFCB") : PixelColor(hex: "#D7C5A5")
        case "floor-carpet":
            return (x + row) % 3 == 0 ? PixelColor(hex: "#97B6DA") : PixelColor(hex: "#A9C6E8")
        default:   // floor-wood: planks 4 rows high, seams staggered
            if row % 4 == 3 { return PixelColor(hex: "#A97B52") }
            return (x + (row / 4) * 13) % 26 == 0 ? PixelColor(hex: "#A97B52") : PixelColor(hex: "#C99A6B")
        }
    }

    // MARK: Room

    private static var lastRoom: (key: String, image: CGImage)?

    /// The room without the character: covers, baseboard, then the six slots. The last one is kept (the page redraws
    /// it on every walking step).
    static func room(wallpaper: String, floor: String, slots: [String?]) -> CGImage {
        let key = ([wallpaper, floor] + slots.map { $0 ?? "-" }).joined(separator: "|")
        if let lastRoom, lastRoom.key == key { return lastRoom.image }
        let image = drawRoom(wallpaper: wallpaper, floor: floor, slots: slots)
        lastRoom = (key, image)
        return image
    }

    private static func drawRoom(wallpaper: String, floor: String, slots: [String?]) -> CGImage {
        var c = Canvas(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            if y < baseboard { c.set(x, y, Self.wallpaper(wallpaper, x, y)) }
            else if y < floorTop { c.set(x, y, y == baseboard ? PixelColor(hex: "#FFFDF7") : PixelColor(hex: "#D9C3A3")) }
            else { c.set(x, y, Self.floor(floor, x, y)) }
        } }
        for (slot, id) in slots.enumerated() {
            guard let id, let item = PetCatalog.item(id), slot < slotX.count else { continue }
            let s = sprite(item.rows)
            let x = slotX[slot] - s.width / 2
            c.paste(s, x: x, y: slot < 3 ? wallTop : floorFeet - s.height)
        }
        return c.image
    }

    /// A shop tile: furniture as drawn, wallpaper and floor as a small swatch.
    static func preview(_ item: PetItem) -> CGImage {
        switch item.kind {
        case .wall, .floor: return sprite(item.rows).image
        case .wallpaper, .floorTile:
            var c = Canvas(width: 20, height: 14)
            for y in 0..<14 { for x in 0..<20 {
                c.set(x, y, item.kind == .wallpaper ? wallpaper(item.id, x + 10, y + 2) : floor(item.id, x, floorTop + y))
            } }
            return c.image
        }
    }

    /// 집중 desk drawn in front of the character (it hides the legs, so stepping in place reads as typing).
    static let desk = sprite([
        "...........NNNNNNNN...........",
        "...........NbbbbbbN...........",
        "...........NbbwbbbN...........",
        ".........nnnnnnnnnnnn.........",
        "tttttttttttttttttttttttttttttt",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        ".TT........................TT.",
        ".TT........................TT.",
    ])

    /// Evolution accessory over the character's head, nil for the baby stage.
    static func accessory(_ stage: PetStage) -> Canvas? {
        switch stage {
        case .baby: return nil
        case .ribbon: return sprite([
            "pp.....pp",
            "pppp.pppp",
            "ppPprpPpp",
            "pppp.pppp",
            "pp.....pp",
        ])
        case .flowers: return sprite([
            ".p...y...p.",
            "prpGyoyGprp",
            ".pGGGGGGGp.",
        ])
        case .crown: return sprite([
            "y...y...y",
            "yy.yby.yy",
            "yyyyyyyyy",
            "yryybyyry",
            "YYYYYYYYY",
        ])
        }
    }
}
