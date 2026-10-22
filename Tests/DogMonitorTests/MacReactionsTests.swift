import XCTest
@testable import DogMonitor

final class MacReactionsTests: XCTestCase {
    func testOldFilesAndTempNamesNeverCount() {
        var d = DownloadSettle(["old.pdf": 10])
        let busy: [String: Int64] = ["old.pdf": 10, "a.zip.crdownload": 5, "b.dmg.download": 0, ".DS_Store": 6, "c.iso": 0, "c.iso.part": 9]
        XCTAssertEqual(d.feed(busy, at: 0), [])
        XCTAssertEqual(d.feed(busy, at: 5), [])
        XCTAssertFalse(d.waiting)
    }

    func testANewFileCountsOnceItsSizeHoldsStill() {
        var d = DownloadSettle([:])
        XCTAssertEqual(d.feed(["a.zip": 100], at: 0), [])
        XCTAssertTrue(d.waiting)
        XCTAssertEqual(d.feed(["a.zip": 200], at: 1), [], "still growing")
        XCTAssertEqual(d.feed(["a.zip": 200], at: 1.5), [], "held still for less than a second")
        XCTAssertEqual(d.feed(["a.zip": 200], at: 2.1), ["a.zip"])
        XCTAssertFalse(d.waiting)
        XCTAssertEqual(d.feed(["a.zip": 200], at: 5), [], "only once")
    }

    func testARenamedPartialFileCountsUnderItsFinalName() {
        var d = DownloadSettle([:])
        XCTAssertEqual(d.feed(["x.dmg": 0, "x.dmg.part": 50], at: 0), [])
        XCTAssertEqual(d.feed(["x.dmg": 80], at: 1), [])
        XCTAssertEqual(d.feed(["x.dmg": 80], at: 2), ["x.dmg"])
    }

    func testAFileThatLeavesStopsWaiting() {
        var d = DownloadSettle([:])
        _ = d.feed(["a": 1], at: 0)
        XCTAssertEqual(d.feed([:], at: 1), [])
        XCTAssertFalse(d.waiting)
    }

    func testAFileThatStartsEmptyIsWatchedUntilItFills() {
        var d = DownloadSettle([:])
        XCTAssertEqual(d.feed(["x.zip": 0, "Folder": -1], at: 0), [])
        XCTAssertTrue(d.waiting, "curl starts with an empty file: keep looking")
        XCTAssertEqual(d.feed(["x.zip": 0, "Folder": -1], at: 5), [], "an empty file never counts")
        XCTAssertEqual(d.feed(["x.zip": 900, "Folder": -1], at: 6), [])
        XCTAssertEqual(d.feed(["x.zip": 900, "Folder": -1], at: 7), ["x.zip"])
        XCTAssertFalse(d.waiting)
    }

    func testAFileThatStaysEmptyOrAFolderStopsTheLooks() {
        var d = DownloadSettle([:])
        _ = d.feed(["note.txt": 0, "Folder": -1], at: 0)
        XCTAssertEqual(d.feed(["note.txt": 0, "Folder": -1], at: DownloadSettle.emptyWait), [])
        XCTAssertFalse(d.waiting)
        XCTAssertEqual(d.feed(["note.txt": 5, "Folder": -1], at: 40), [], "known now: filling it later is not a download")
    }

    func testBusyAfterTwentySecondsHighAndOverWhenItDrops() {
        var b = BusySpell()
        var changes: [Bool] = []
        for t in 0...19 { if let c = b.feed(0.9, at: Double(t)) { changes.append(c) } }
        XCTAssertEqual(changes, [], "19 s is not enough")
        XCTAssertEqual(b.feed(0.9, at: 20), true)
        XCTAssertNil(b.feed(0.55, at: 21), "between the marks it stays busy")
        XCTAssertEqual(b.feed(0.3, at: 22), false)
    }

    func testADipOrAGapStartsTheCountAgain() {
        var b = BusySpell()
        for t in 0...15 { _ = b.feed(0.9, at: Double(t)) }
        _ = b.feed(0.5, at: 16)   // under `high` while not busy yet
        for t in 17...36 { XCTAssertNil(b.feed(0.9, at: Double(t))) }
        XCTAssertEqual(b.feed(0.9, at: 37), true)

        var g = BusySpell()
        for t in 0...15 { _ = g.feed(0.9, at: Double(t)) }
        XCTAssertNil(g.feed(0.9, at: 30), "the Mac slept in between")
    }

    func testTrashEmptiedFromItsLinkCount() {
        XCTAssertEqual(TrashCount.items(links: 21), 19)
        XCTAssertEqual(TrashCount.items(links: 1), 0)
        XCTAssertTrue(TrashCount.emptied(from: 19, to: 0))
        XCTAssertTrue(TrashCount.emptied(from: 19, to: 1), "the .DS_Store may stay")
        XCTAssertFalse(TrashCount.emptied(from: 0, to: 0))
        XCTAssertFalse(TrashCount.emptied(from: 3, to: 2), "one thing put back")
        XCTAssertFalse(TrashCount.emptied(from: 0, to: 1))
    }

    func testPushSpotPrefersTheLeftSide() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800), size = CGSize(width: 60, height: 40)
        XCTAssertEqual(MacPush.spot(window: CGRect(x: 300, y: 100, width: 400, height: 300), size: size, in: screen)?.dir, 1)
        XCTAssertEqual(MacPush.spot(window: CGRect(x: 20, y: 100, width: 400, height: 300), size: size, in: screen)?.dir, -1)
        XCTAssertNil(MacPush.spot(window: CGRect(x: 0, y: 0, width: 1000, height: 800), size: size, in: screen))
        XCTAssertNil(MacPush.spot(window: CGRect(x: 1200, y: 100, width: 400, height: 300), size: size, in: screen), "on another screen")
    }

    func testTheKickWaitsThenFliesAway() {
        XCTAssertEqual(TrashKick.bundle(0.2, dir: 1).offset, .zero)
        let mid = TrashKick.bundle(TrashKick.windup + 0.3, dir: -1).offset
        XCTAssertLessThan(mid.x, 0)
        XCTAssertGreaterThan(mid.y, 0)
        XCTAssertGreaterThan(TrashKick.bundle(TrashKick.duration, dir: 1).offset.x, 1500)
    }
}
