import XCTest
@testable import DogMonitor

/// 친구 상주 자리 (RoomPlace), 창에 매달기 (RubberBand, HangRules) and 의자 (ChairCatalog, FriendLook.seat).
final class RoomEdgesTests: XCTestCase {
    private let vf = CGRect(x: 0, y: 80, width: 1500, height: 900)

    // MARK: 자리

    func testBandIsTheMiddleShareOfTheEdge() {
        XCTAssertEqual(RoomPlace.band(vf, edge: .bottom, length: .full), vf)
        XCTAssertEqual(RoomPlace.band(vf, edge: .top, length: .half), CGRect(x: 375, y: 80, width: 750, height: 900))
        XCTAssertEqual(RoomPlace.band(vf, edge: .bottom, length: .third), CGRect(x: 500, y: 80, width: 500, height: 900))
        XCTAssertEqual(RoomPlace.band(vf, edge: .right, length: .half), CGRect(x: 0, y: 305, width: 1500, height: 450))
    }

    func testSeatsStayInsideTheirBand() {
        let size = CGSize(width: 98, height: 84)
        for edge in RoomEdge.allCases {
            let band = RoomPlace.band(vf, edge: edge, length: .third)
            for i in 0..<3 {
                let o = RoomRules.origin(i, edge: edge, size: size, in: band)
                XCTAssertTrue(band.contains(CGRect(origin: o, size: size)), "\(edge) \(i)")
            }
        }
        XCTAssertEqual(RoomRules.origin(0, edge: .top, size: size, in: vf).y, vf.maxY - size.height)
        XCTAssertTrue(RoomPlace.bubbleBelow(.top))
        XCTAssertFalse(RoomPlace.bubbleBelow(.bottom))
    }

    func testAScreenIsFoundAgainByItsSignature() {
        let built = ScreenSignature(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        let dell = ScreenSignature(id: 7, name: "DELL U2723QE", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 2)
        XCTAssertNil(RoomPlace.match(nil, in: [built, dell]))
        XCTAssertEqual(RoomPlace.match(dell, in: [built, dell]), 1)
        // Plugged back in: a new id, moved to the left side.
        var back = dell
        back.id = 9
        back.frame.origin = CGPoint(x: -2560, y: 0)
        XCTAssertEqual(RoomPlace.match(dell, in: [built, back]), 1)
        // A different monitor in the same place still counts; nothing like it does not.
        let other = ScreenSignature(id: 4, name: "LG", frame: dell.frame, scale: 1)
        XCTAssertEqual(RoomPlace.match(dell, in: [built, other]), 1)
        XCTAssertNil(RoomPlace.match(dell, in: [built]))
        let coded = try? JSONDecoder().decode(ScreenSignature.self, from: JSONEncoder().encode(dell))
        XCTAssertEqual(coded, dell)
    }

    // MARK: 고무줄

    private func band(onTopOf f: CGRect, at x: CGFloat) -> RubberBand {
        RubberBand(anchor: CGPoint(x: x, y: f.maxY), floor: HangRules.floor(.top, on: f), position: CGPoint(x: x, y: f.maxY))
    }

    private func run(_ b: inout RubberBand, seconds: Double, check: (RubberBand) -> Void = { _ in }) {
        for _ in 0..<Int(seconds * 60) { b.step(dt: 1.0 / 60); check(b) }
    }

    func testPulledUpAndLetGoItBouncesBackOntoTheWindow() {
        let w = CGRect(x: 200, y: 200, width: 600, height: 400)
        var b = band(onTopOf: w, at: 500)
        b.position = CGPoint(x: 560, y: w.maxY + 150)
        b.release(CGVector(dx: 0, dy: 300))
        XCTAssertFalse(b.isSettled)
        run(&b, seconds: 6)
        XCTAssertTrue(b.isSettled)
        XCTAssertTrue(b.standing)
        XCTAssertEqual(b.position.y, w.maxY)
        XCTAssertLessThanOrEqual(abs(b.position.x - 500), RubberBand.length)
        XCTAssertGreaterThanOrEqual(b.bounces, 1)
    }

    func testBySideItHangsWhereTheBandHoldsItUp() {
        var b = RubberBand(anchor: CGPoint(x: 100, y: 500), floor: nil, position: CGPoint(x: 100, y: 500))
        run(&b, seconds: 10)
        XCTAssertTrue(b.isSettled)
        XCTAssertEqual(b.anchor.y - b.position.y, RubberBand.length + b.gravity / b.stiffness, accuracy: 3)
        XCTAssertEqual(b.position.x, 100, accuracy: 0.5)
    }

    func testSpeedAndLetGoAreCapped() {
        var b = RubberBand(anchor: .zero, floor: nil, position: CGPoint(x: 0, y: -3000))
        run(&b, seconds: 2) { XCTAssertLessThanOrEqual(hypot($0.velocity.dx, $0.velocity.dy), RubberBand.maxSpeed + 0.01) }
        b.release(CGVector(dx: -5000, dy: 5000))
        XCTAssertEqual(b.velocity, CGVector(dx: -650, dy: 850))
    }

    func testPulledFarItSnaps() {
        var b = RubberBand(anchor: .zero, floor: nil, position: CGPoint(x: 0, y: -RubberBand.length * 3))
        XCTAssertFalse(b.snapped)
        b.position.y = -RubberBand.length * RubberBand.snapAt - 1
        XCTAssertTrue(b.snapped)
    }

    func testFixedStepsWhateverTheFrameRate() {
        var a = RubberBand(anchor: .zero, floor: nil, position: CGPoint(x: 30, y: 0))
        var b = a
        a.step(dt: 0.1)
        for _ in 0..<3 { b.step(dt: 1.0 / 30) }
        XCTAssertEqual(a.position.x, b.position.x, accuracy: 1e-9)
        XCTAssertEqual(a.position.y, b.position.y, accuracy: 1e-9)
        // A stall catches up at most maxLag.
        var c = RubberBand(anchor: .zero, floor: nil, position: .zero), d = c
        c.step(dt: 5)
        d.step(dt: RubberBand.maxLag)
        XCTAssertEqual(c.position.y, d.position.y, accuracy: 1e-9)
    }

    func testItMovesWithTheWindow() {
        let w = CGRect(x: 200, y: 200, width: 600, height: 400)
        var b = band(onTopOf: w, at: 500)
        let moved = w.offsetBy(dx: -50, dy: 30)
        let o = HangRules.offset(.top, anchor: b.anchor, on: w)
        b.follow(HangRules.anchor(.top, offset: o, on: moved), floor: HangRules.floor(.top, on: moved))
        XCTAssertEqual(b.position, CGPoint(x: 450, y: moved.maxY))
        XCTAssertTrue(b.standing)
    }

    // MARK: 붙을 곳

    private let me: pid_t = 42

    func testADropCatchesTheFrontWindowsEdge() {
        let back = ListedWindow(id: 2, pid: 7, frame: CGRect(x: 0, y: 100, width: 800, height: 600))
        let front = ListedWindow(id: 1, pid: 8, frame: CGRect(x: 300, y: 200, width: 600, height: 300))
        let list = [front, back]
        XCTAssertEqual(HangRules.spot(feet: CGPoint(x: 400, y: 510), width: 98, in: list, me: me),
                       HangRules.Spot(window: front, side: .top, anchor: CGPoint(x: 400, y: 500)))
        // The back window's top edge out from under the front one.
        XCTAssertEqual(HangRules.spot(feet: CGPoint(x: 100, y: 690), width: 98, in: list, me: me)?.window, back)
        // Dropped in the middle of the front window: the one behind does not count.
        XCTAssertNil(HangRules.spot(feet: CGPoint(x: 500, y: 350), width: 98, in: list, me: me))
        let side = HangRules.spot(feet: CGPoint(x: 905, y: 300), width: 98, in: list, me: me)
        XCTAssertEqual(side?.side, .right)
        XCTAssertEqual(side?.anchor, CGPoint(x: 949, y: 348))
        XCTAssertEqual(HangRules.knot(.right, anchor: side!.anchor, width: 98), CGPoint(x: 900, y: 348))   // on the window's side
        XCTAssertEqual(HangRules.knot(.left, anchor: CGPoint(x: 51, y: 10), width: 98), CGPoint(x: 100, y: 10))
        XCTAssertEqual(HangRules.knot(.top, anchor: CGPoint(x: 51, y: 10), width: 98), CGPoint(x: 51, y: 10))
        XCTAssertNil(HangRules.spot(feet: CGPoint(x: 1400, y: 900), width: 98, in: list, me: me))
    }

    func testOnlyOtherAppsNormalBigWindows() {
        let f = CGRect(x: 0, y: 0, width: 600, height: 400)
        let list = [ListedWindow(id: 1, pid: me, frame: f), ListedWindow(id: 2, pid: 7, layer: 3, frame: f),
                    ListedWindow(id: 3, pid: 7, frame: f, alpha: 0), ListedWindow(id: 4, pid: 7, frame: CGRect(x: 0, y: 0, width: 150, height: 90)),
                    ListedWindow(id: 5, pid: 7, frame: f)]
        XCTAssertEqual(HangRules.hangable(list, me: me).map(\.id), [5])
    }

    func testTheAnchorKeepsItsPlaceOnTheWindow() {
        let w = CGRect(x: 100, y: 100, width: 500, height: 300)
        let a = CGPoint(x: 549, y: 350)
        let o = HangRules.offset(.right, anchor: a, on: w)
        XCTAssertEqual(HangRules.anchor(.right, offset: o, on: CGRect(x: 0, y: 0, width: 700, height: 500)), CGPoint(x: 649, y: 450))
        // A top anchor stays over the edge of a narrower window.
        let t = HangRules.offset(.top, anchor: CGPoint(x: 550, y: 400), on: w)
        XCTAssertEqual(HangRules.anchor(.top, offset: t, on: CGRect(x: 100, y: 100, width: 200, height: 300)), CGPoint(x: 300, y: 400))
    }

    func testGoneCoveredOrThere() {
        let w = ListedWindow(id: 1, pid: 7, frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let friend = CGRect(x: 100, y: 400, width: 68, height: 40)
        XCTAssertEqual(HangRules.status(1, rect: friend, in: [w], me: me), .at(w))
        XCTAssertEqual(HangRules.status(1, rect: friend, in: [], me: me), .gone)
        let over = ListedWindow(id: 2, pid: 8, frame: CGRect(x: 50, y: 300, width: 300, height: 300))
        XCTAssertEqual(HangRules.status(1, rect: friend, in: [over, w], me: me), .covered)
        XCTAssertEqual(HangRules.status(1, rect: friend, in: [ListedWindow(id: 3, pid: me, frame: over.frame), w], me: me), .at(w))
    }

    // MARK: 의자

    func testChairArtIsWellFormed() {
        XCTAssertEqual(Set(ChairCatalog.all.map(\.id)).count, ChairCatalog.all.count)
        for c in ChairCatalog.all {
            XCTAssertTrue(c.id.hasPrefix("chair-"))
            XCTAssertGreaterThan(c.width, 0)
            XCTAssertTrue(c.rows.allSatisfy { $0.count == c.width }, c.id)
            XCTAssertTrue(c.rows.joined().allSatisfy { $0 == "." || c.colors[$0] != nil }, c.id)
            XCTAssertTrue((0..<c.height).contains(c.seatRow) && (1..<c.height).contains(c.frontFrom), c.id)
            XCTAssertLessThanOrEqual(c.seatRow, c.frontFrom, c.id)
        }
        XCTAssertEqual(ChairCatalog.all.filter { !$0.season }.map(\.id), ["chair-wood"])
    }

    func testTheSitterSitsOnTheSeat() {
        let c = ChairCatalog.chair("chair-wood")!
        let sprite = CGSize(width: 68, height: 40)
        let l = c.layout(sprite: sprite, px: 2)
        XCTAssertEqual(l.sitter.y + sprite.height, l.chair.y + CGFloat(c.seatRow + 1) * 2)
        XCTAssertGreaterThanOrEqual(l.sitter.y, 0)
        XCTAssertGreaterThanOrEqual(l.size.width, CGFloat(c.width) * 2)
        XCTAssertEqual(l.size.height, l.chair.y + CGFloat(c.height) * 2)   // the sitter's head over the back made it taller
    }

    func testSeasonChairsComeFromTheBoard() {
        XCTAssertEqual(ChairCatalog.available(owned: []).map(\.id), ["chair-wood"])
        XCTAssertEqual(ChairCatalog.available(owned: ["chair-bean"]).map(\.id), ["chair-wood", "chair-bean"])
        XCTAssertTrue(SeasonCatalog.known.isSuperset(of: ["chair-sofa", "chair-bean"]))
        XCTAssertFalse(SeasonCatalog.known.contains("chair-wood"))
        XCTAssertEqual(SeasonCatalog.name("chair-sofa"), ChairCatalog.chair("chair-sofa")?.name)
        XCTAssertEqual(SeasonIcon.art("chair-bean").0, ChairCatalog.chair("chair-bean")?.rows)
        let json = #"{"serial":3,"season":{"id":"cozy","title":{"ko":"포근","en":"Cozy"},"starts":"2027-02-01","ends":"2027-02-28","cells":8,"items":["chair-sofa","chair-wood","chair-bean"],"coins":5,"refund":10,"freePerDay":2,"ticketPrice":40,"buyPerDay":3}}"#
        XCTAssertEqual(try SeasonCheck.parse(Data(json.utf8)).items, ["chair-sofa", "chair-bean"])
    }

    func testTheSeatTravelsAsAnIdOnly() throws {
        var look = FriendLook.fallback
        look.seat = "chair-sofa"
        let back = try XCTUnwrap(SocialWire.decode(FriendLook.self, XCTUnwrap(SocialWire.encode(look))))
        XCTAssertEqual(FriendLook.received(back).seat, "chair-sofa")
        look.seat = "chair-throne"   // a newer build's chair: standing here
        XCTAssertNil(FriendLook.received(look).seat)
        // An older build's look has no seat at all.
        let old = try XCTUnwrap(SocialWire.decode(FriendLook.self, Data(#"{"character":"dog"}"#.utf8)))
        XCTAssertNil(old.seat)
    }
}
