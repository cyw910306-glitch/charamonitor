import XCTest
@testable import DogMonitor

/// 폴더 친구: which Finder windows, where it sits, hiding, polling and its saved settings.
final class FolderFriendsTests: XCTestCase {
    private let finder: pid_t = 100, other: pid_t = 200, me: pid_t = 300
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)   // a visible frame under a 25 pt menu bar
    private let size = CGSize(width: 64, height: 60)

    private func win(_ id: Int, _ pid: pid_t, _ frame: CGRect, layer: Int = 0, alpha: Double = 1) -> ListedWindow {
        ListedWindow(id: id, pid: pid, layer: layer, frame: frame, alpha: alpha)
    }

    // MARK: Window list

    func testListEntryFlipsToYUpAndNeedsNoName() throws {
        let bounds = CGRect(x: 100, y: 50, width: 400, height: 300).dictionaryRepresentation
        let info: [String: Any] = [kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 7,
                                   kCGWindowLayer as String: 0, kCGWindowBounds as String: bounds, kCGWindowAlpha as String: 1.0]
        let w = try XCTUnwrap(ListedWindow(info, primaryHeight: 900))
        XCTAssertEqual(w.id, 42)
        XCTAssertEqual(w.pid, 7)
        XCTAssertEqual(w.frame, CGRect(x: 100, y: 550, width: 400, height: 300))   // 900 - (50 + 300)
        XCTAssertNil(ListedWindow([kCGWindowNumber as String: 1], primaryHeight: 900))
    }

    func testOnlyFindersNormalVisibleFolderWindowsCount() {
        let list = [
            win(1, other, CGRect(x: 0, y: 0, width: 800, height: 600)),
            win(2, finder, CGRect(x: 0, y: 0, width: 500, height: 400), layer: 3),   // floating: not a folder window
            win(3, finder, CGRect(x: 0, y: 0, width: 500, height: 400), alpha: 0),
            win(4, finder, CGRect(x: 0, y: 0, width: 150, height: 80)),               // a progress window
            win(7, finder, CGRect(x: 0, y: 0, width: 265, height: 500)),              // 정보 가져오기
            win(5, finder, CGRect(x: 10, y: 10, width: 500, height: 400)),
            win(6, finder, CGRect(x: 20, y: 20, width: 600, height: 400)),
        ]
        XCTAssertEqual(FolderPerch.finderWindows(list, finder: [finder]).map(\.id), [5, 6])
        XCTAssertEqual(FolderPerch.finderWindows(list, finder: []).map(\.id), [])
    }

    func testChoosesTheFrontmostOrEachUpToTheCap() {
        let ws = (1...5).map { win($0, finder, CGRect(x: 0, y: 0, width: 500, height: 400)) }
        XCTAssertEqual(FolderPerch.chosen(ws, every: false).map(\.id), [1])
        XCTAssertEqual(FolderPerch.chosen(ws, every: true).map(\.id), [1, 2, 3])
        XCTAssertEqual(FolderPerch.chosen(Array(ws.prefix(2)), every: true).map(\.id), [1, 2])
        XCTAssertEqual(FolderPerch.chosen([], every: true).count, 0)
    }

    // MARK: Where it sits

    func testPanelSitsOnTheTopEdge() throws {
        let w = CGRect(x: 200, y: 300, width: 600, height: 400)
        let p = try XCTUnwrap(FolderPerch.panelFrame(on: w, size: size, screens: [screen]))
        XCTAssertEqual(p.minX, 200)
        XCTAssertEqual(p.width, 600)
        XCTAssertEqual(p.minY, 700 - FolderPerch.edge(size.height))
        XCTAssertGreaterThan(p.maxY, 700 + size.height * 2)   // room for a hop and a mark
    }

    func testPanelIsWholePointsSoItNeverKeepsResetting() throws {
        // AppKit keeps window frames in whole points: a fractional target never equals the panel's frame again.
        for h in [41.5, 60, 63.3, 80, 121.7] as [CGFloat] {
            let p = try XCTUnwrap(FolderPerch.panelFrame(on: CGRect(x: 200, y: 300, width: 600, height: 400),
                                                         size: CGSize(width: h * 1.1, height: h), screens: [screen]))
            XCTAssertEqual(p, p.integral)
            XCTAssertEqual(FolderPerch.edge(h), FolderPerch.edge(h).rounded())
        }
    }

    func testFeetOnTheEdgeStandingDrapedNapping() {
        XCTAssertEqual(FolderPerch.sink(60, napping: false), 2)
        XCTAssertEqual(FolderPerch.sink(60, napping: true), 5)    // 8 % of 60, whole points
        XCTAssertEqual(FolderPerch.sink(12, napping: false), 1)   // never deeper than the panel's bottom
    }

    func testNoRoomUnderTheMenuBarOrOffScreenOrTooNarrow() {
        // Top against the menu bar (a zoomed window): no room for the friend.
        XCTAssertNil(FolderPerch.panelFrame(on: CGRect(x: 0, y: 400, width: 600, height: 475), size: size, screens: [screen]))
        XCTAssertNotNil(FolderPerch.panelFrame(on: CGRect(x: 0, y: 400, width: 600, height: 415), size: size, screens: [screen]))
        XCTAssertNil(FolderPerch.panelFrame(on: CGRect(x: 0, y: 100, width: 90, height: 300), size: size, screens: [screen]))
        XCTAssertNil(FolderPerch.panelFrame(on: CGRect(x: 3000, y: 100, width: 600, height: 300), size: size, screens: [screen]))
        // A second screen to the right takes it.
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        XCTAssertNotNil(FolderPerch.panelFrame(on: CGRect(x: 1600, y: 100, width: 600, height: 300), size: size, screens: [screen, right]))
    }

    func testXStaysOverTheEdge() {
        XCTAssertEqual(FolderPerch.clampX(-50, width: 600, size: size), 84)    // clear of the traffic lights
        XCTAssertEqual(FolderPerch.clampX(900, width: 600, size: size), 550)   // in from the rounded corner
        XCTAssertEqual(FolderPerch.clampX(300, width: 600, size: size), 300)
        XCTAssertEqual(FolderPerch.clampX(10, width: 60, size: size), 30)   // narrower than the friend: the middle
    }

    // MARK: Hiding

    func testHidesWhenAWindowInFrontCoversIt() {
        let folder = win(10, finder, CGRect(x: 100, y: 100, width: 600, height: 400))
        let rect = CGRect(x: 300, y: 489, width: 64, height: 72)
        let mine = win(1, me, rect.insetBy(dx: -50, dy: -50))
        let farAway = win(2, other, CGRect(x: 900, y: 0, width: 300, height: 300))
        let over = win(3, other, CGRect(x: 250, y: 450, width: 300, height: 300))
        let behind = win(4, other, CGRect(x: 250, y: 450, width: 300, height: 300))
        let floating = win(5, other, CGRect(x: 250, y: 450, width: 300, height: 300), layer: 3)
        XCTAssertFalse(FolderPerch.covered(rect, behind: folder, in: [mine, farAway, folder, behind], me: me))
        XCTAssertTrue(FolderPerch.covered(rect, behind: folder, in: [over, folder], me: me))
        XCTAssertFalse(FolderPerch.covered(rect, behind: folder, in: [floating, folder], me: me))
        XCTAssertTrue(FolderPerch.covered(rect, behind: folder, in: [mine, farAway], me: me))   // gone from the list
    }

    // MARK: Polling

    func testPollsOnlyWhileFinderWindowsAreOutFastOnlyWhileMoving() {
        XCTAssertNil(FolderPerch.pollEvery(windows: false, finderFront: false, dragging: true, sinceMove: 0))
        XCTAssertEqual(FolderPerch.pollEvery(windows: false, finderFront: true, dragging: false, sinceMove: 99), 1)
        XCTAssertEqual(FolderPerch.pollEvery(windows: true, finderFront: false, dragging: false, sinceMove: 99), 1)
        XCTAssertEqual(FolderPerch.pollEvery(windows: true, finderFront: true, dragging: true, sinceMove: 99), 1.0 / 60)
        XCTAssertEqual(FolderPerch.pollEvery(windows: true, finderFront: true, dragging: false, sinceMove: 0.2), 1.0 / 60)
        XCTAssertEqual(FolderPerch.pollEvery(windows: true, finderFront: false, dragging: false, sinceMove: 0.55), 1.0 / 60)   // a zoom animating
        XCTAssertEqual(FolderPerch.pollEvery(windows: true, finderFront: false, dragging: false, sinceMove: 0.7), 1)
    }

    // MARK: Settings

    func testPrefsDecodeOldAndOddValues() throws {
        let d = JSONDecoder()
        XCTAssertEqual(try d.decode(FolderPrefs.self, from: Data("{}".utf8)), FolderPrefs())
        let odd = try d.decode(FolderPrefs.self, from: Data(#"{"on":true,"size":"gigantic","everyWindow":"yes"}"#.utf8))
        XCTAssertTrue(odd.on)
        XCTAssertEqual(odd.size, .medium)
        XCTAssertFalse(odd.everyWindow)
        var p = FolderPrefs(); p.on = true; p.size = .huge; p.everyWindow = true
        XCTAssertEqual(try d.decode(FolderPrefs.self, from: JSONEncoder().encode(p)), p)
    }

    func testStoreSavesAndSetupFileCarriesIt() throws {
        let suite = "test.folderFriends.\(UUID().uuidString)"
        let db = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { db.removePersistentDomain(forName: suite) }
        let a = FolderStore(defaults: db)
        a.prefs.on = true
        a.prefs.size = .large
        XCTAssertEqual(FolderStore(defaults: db).prefs.size, .large)
        XCTAssertEqual(SetupFile.keys[FolderStore.key], .data)
        XCTAssertNotNil(SetupFile.filter([FolderStore.key: try XCTUnwrap(db.data(forKey: FolderStore.key))])[FolderStore.key])
    }

    func testMenuBarSubmenuListsIt() {
        XCTAssertTrue(DesktopFriends.toggles.contains { $0.title == L("폴더 친구") })
    }
}
