import XCTest
@testable import DogMonitor

final class CleanerTests: XCTestCase {
    private func app(_ id: String, mem: UInt64 = 100, cpu: Double = 0, idleMin: Double = 0, pid: pid_t = 0) -> CleanerApp {
        CleanerApp(pid: pid == 0 ? pid_t(abs(id.hashValue % 90_000) + 100) : pid, bundleID: id, name: id, path: "/Applications/\(id).app",
                   memory: mem, cpu: cpu, idle: idleMin * 60, idleAtLeast: false)
    }

    // MARK: Candidates

    func testCandidatesSkipOurselvesFrontmostAndFinderAndSortByMemory() {
        let apps = [app("a.small", mem: 10, idleMin: 40), app("a.big", mem: 900, idleMin: 40),
                    app("me.dog"), app("a.front", idleMin: 99), app("com.apple.finder", idleMin: 99)]
        let c = CleanerRules.candidates(apps, protected: [], frontmost: "a.front", own: "me.dog")
        XCTAssertEqual(c.map(\.app.bundleID), ["a.big", "a.small"])
        XCTAssertTrue(c.allSatisfy(\.recommended))
    }

    func testRecommendationThresholds() {
        let apps = [app("idle.29", idleMin: 29), app("idle.30", idleMin: 30),
                    app("busy.9", cpu: 0.5, idleMin: 9), app("busy.10", cpu: 0.30, idleMin: 10),
                    app("calm.20", cpu: 0.29, idleMin: 20)]
        let picked = CleanerRules.candidates(apps, protected: [], frontmost: nil, own: nil).filter(\.recommended).map(\.app.bundleID)
        XCTAssertEqual(Set(picked), ["idle.30", "busy.10"])
    }

    func testProtectedAppsAreListedButNeverPicked() {
        let c = CleanerRules.candidates([app("com.cmuxterm.app", mem: 5000, cpu: 0.9, idleMin: 600)],
                                        protected: CleanerRules.defaultProtected, frontmost: nil, own: nil)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].isProtected)
        XCTAssertFalse(c[0].recommended)
    }

    func testIdleIsALowerBoundWhenNeverSeenFrontmost() {
        let now = Date(timeIntervalSince1970: 10_000)
        let seen = CleanerRules.idle(now: now, lastActive: now.addingTimeInterval(-600), appLaunch: nil, ourLaunch: .distantPast)
        XCTAssertEqual(seen.seconds, 600)
        XCTAssertFalse(seen.atLeast)
        // Launched before us: counted from our launch. Launched after us: from its own launch.
        let early = CleanerRules.idle(now: now, lastActive: nil, appLaunch: now.addingTimeInterval(-9000), ourLaunch: now.addingTimeInterval(-3000))
        XCTAssertEqual(early.seconds, 3000)
        XCTAssertTrue(early.atLeast)
        let late = CleanerRules.idle(now: now, lastActive: nil, appLaunch: now.addingTimeInterval(-100), ourLaunch: now.addingTimeInterval(-3000))
        XCTAssertEqual(late.seconds, 100)
    }

    func testHelpersGoToTheInnermostBundle() {
        let groups = CleanerRules.group(
            processPaths: [1: "/A/Chrome.app/Contents/MacOS/Chrome",
                           2: "/A/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
                           3: "/A/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator",
                           4: "/A/Xcode.app/Contents/MacOS/Xcode", 5: "/A/Chrome.appx/evil", 6: "/usr/bin/other"],
            bundles: [(1, "/A/Chrome.app"), (4, "/A/Xcode.app"),
                      (3, "/A/Xcode.app/Contents/Developer/Applications/Simulator.app")])
        XCTAssertEqual(groups[1].map(Set.init), [1, 2])
        XCTAssertEqual(groups[4], [4])
        XCTAssertEqual(groups[3], [3])
    }

    func testAppKeepingTheMacAwakeIsNeverPicked() {
        var rec = app("com.obsproject.obs-studio", cpu: 0.8, idleMin: 120)
        rec.inUse = true
        let c = CleanerRules.candidates([rec, app("idle.app", idleMin: 120)], protected: [], frontmost: nil, own: nil)
        XCTAssertEqual(c.filter(\.recommended).map(\.app.bundleID), ["idle.app"])
    }

    func testWebKitServicesGoToTheirResponsibleAppButPlainChildrenDoNot() {
        let groups = CleanerRules.group(
            processPaths: [10: "/Applications/Safari.app/Contents/MacOS/Safari",
                           11: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                           20: "/Applications/Alacritty.app/Contents/MacOS/alacritty",
                           21: "/usr/bin/swift-build",
                           30: "/System/Library/Other.xpc/Contents/MacOS/Other"],
            bundles: [(10, "/Applications/Safari.app"), (20, "/Applications/Alacritty.app")],
            responsible: [11: 10, 21: 20, 30: 999])
        XCTAssertEqual(groups[10].map(Set.init), [10, 11])
        XCTAssertEqual(groups[20], [20])   // a terminal is not charged for the build it runs
    }

    func testQuitAppsStillListedByNSWorkspaceAreDropped() {
        let paths: [pid_t: String] = [5: "/Applications/Keynote.app/Contents/MacOS/Keynote", 6: "/usr/sbin/reused"]
        XCTAssertTrue(CleanerRules.isAlive(pid: 5, bundlePath: "/Applications/Keynote.app", processPaths: paths))
        XCTAssertFalse(CleanerRules.isAlive(pid: 7, bundlePath: "/Applications/Keynote.app", processPaths: paths))   // gone
        XCTAssertFalse(CleanerRules.isAlive(pid: 6, bundlePath: "/Applications/Keynote.app", processPaths: paths))   // pid reused
    }

    // MARK: Cache filter

    func testCacheFolderFilter() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-2 * 3600), fresh = now.addingTimeInterval(-30 * 60)
        let running = ["com.google.Chrome", "org.mozilla"]
        func ok(_ name: String, _ date: Date? = old) -> Bool {
            CleanerRules.isAppCache(name: name, newestChange: date, now: now, runningIDs: running)
        }
        XCTAssertTrue(ok("com.figma.agent"))
        XCTAssertFalse(ok("Homebrew"))                       // not bundle id shaped
        XCTAssertFalse(ok("com.apple.Safari"))                // Apple's
        XCTAssertFalse(ok("COM.APPLE.news"))
        XCTAssertFalse(ok("com.google.Chrome"))               // running
        XCTAssertFalse(ok("com.google.Chrome.helper"))        // running app is a prefix of it
        XCTAssertFalse(ok("org.mozilla.firefox"))
        XCTAssertFalse(ok("com.google"))                      // prefix of a running app
        XCTAssertFalse(ok("com.figma.agent", fresh))          // touched within the hour
        XCTAssertFalse(ok("com.figma.agent", nil))
        XCTAssertFalse(ok(".hidden.dir"))
    }

    // MARK: Safe deletion (temp dirs only)

    private var tmp: URL!

    override func setUpWithError() throws {
        // CLEANER_TEST_ROOT pins every file these tests make (and delete) to one folder.
        let base = ProcessInfo.processInfo.environment["CLEANER_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        tmp = base.appendingPathComponent("cleaner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func file(_ rel: String, bytes: Int = 5000, age: TimeInterval = 0) throws -> String {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
        return url.path
    }

    func testSafePathRefusesRootOutsideAndDotDot() throws {
        let root = tmp.appendingPathComponent("root").path
        _ = try file("root/keep.txt")
        let outside = try file("outside.txt")
        XCTAssertNil(SafePath.delete(root, inside: root))
        XCTAssertNil(SafePath.delete(root + "/", inside: root))
        XCTAssertNil(SafePath.delete(root + "/..", inside: root))
        XCTAssertNil(SafePath.delete(root + "/../outside.txt", inside: root))
        XCTAssertNil(SafePath.delete(outside, inside: root))
        XCTAssertNil(SafePath.delete(tmp.appendingPathComponent("rootx/a").path, inside: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/keep.txt"))
    }

    func testLinksAreRemovedNotFollowed() throws {
        let root = tmp.appendingPathComponent("root").path
        let precious = try file("precious/data.txt")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tmp.appendingPathComponent("precious").path)
        // Through the link the target resolves outside the root: refused.
        XCTAssertNil(SafePath.delete(link + "/data.txt", inside: root))
        // The link itself is inside: it goes, what it points to stays.
        XCTAssertNotNil(SafePath.delete(link, inside: root))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious))
        // A link nested in a deleted folder is unlinked too.
        let dir = root + "/cache.dir"
        _ = try file("root/cache.dir/a.bin")
        try FileManager.default.createSymbolicLink(atPath: dir + "/escape", withDestinationPath: tmp.appendingPathComponent("precious").path)
        let freed = SafePath.delete(dir, inside: root)
        XCTAssertGreaterThan(freed ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious))
    }

    func testRootReachedThroughALinkStillGuardsItsOwnInside() throws {
        let real = tmp.appendingPathComponent("realroot").path
        let target = try file("realroot/old.log")
        let alias = tmp.appendingPathComponent("aliasroot").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: real)
        XCTAssertNotNil(SafePath.delete(alias + "/old.log", inside: alias))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real))
    }

    func testScanAndDeleteFilesInAFakeHome() throws {
        let day: TimeInterval = 86_400
        let oldLog = try file("Library/Logs/App/old.log", age: 8 * day)
        let newLog = try file("Library/Logs/App/new.log", age: 1 * day)
        let staleCache = try file("Library/Caches/com.stale.app/blob", age: 2 * 3600)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                              ofItemAtPath: tmp.appendingPathComponent("Library/Caches/com.stale.app").path)
        let busyCache = try file("Library/Caches/com.running.app/blob", age: 2 * 3600)
        let appleCache = try file("Library/Caches/com.apple.Safari/blob", age: 2 * 3600)
        let freshCache = try file("Library/Caches/com.fresh.app/blob")
        let plainCache = try file("Library/Caches/Homebrew/blob", age: 2 * 3600)
        let derived = try file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/x.o")

        let targets = Cleaner.scanFiles(home: tmp, runningIDs: ["com.running.app"], xcodeRunning: false, tools: [], run: { _ in (1, "") })
        let byKind = Dictionary(uniqueKeysWithValues: targets.map { ($0.kind, $0) })
        XCTAssertEqual(byKind[.logs]?.paths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["old.log"])
        XCTAssertEqual(byKind[.caches]?.paths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["com.stale.app"])
        XCTAssertEqual(byKind[.logs]?.recommended, true)
        XCTAssertEqual(byKind[.derivedData]?.recommended, false)
        XCTAssertEqual(byKind[.brewCache]?.paths, [tmp.appendingPathComponent("Library/Caches/Homebrew/blob").path])
        XCTAssertNil(byKind[.trash])   // no .Trash folder in the fake home
        XCTAssertNil(Cleaner.scanFiles(home: tmp, runningIDs: [], xcodeRunning: true).first { $0.kind == .derivedData })

        let freed = Cleaner.delete(targets)
        XCTAssertGreaterThan(freed, 0)
        for gone in [oldLog, staleCache, derived, plainCache] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone), gone) }
        for kept in [newLog, busyCache, appleCache, freshCache] { XCTAssertTrue(FileManager.default.fileExists(atPath: kept), kept) }
        // Roots survive.
        for root in ["Library/Logs", "Library/Caches", "Library/Caches/Homebrew", "Library/Developer/Xcode/DerivedData"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(root).path), root)
        }
    }

    func testCachesOfAgentsAndRunningProcessesAreKept() throws {
        let caches = tmp.appendingPathComponent("Library/Caches")
        _ = try file("Library/Caches/com.logi.pluginservice/blob", age: 2 * 3600)
        let exe = try file("Library/Caches/org.webkit.Playwright/webkit-1/Playwright.app/Contents/MacOS/Playwright", age: 2 * 3600)
        _ = try file("Library/Caches/com.stale.app/blob", age: 2 * 3600)
        for name in ["com.logi.pluginservice", "org.webkit.Playwright", "com.stale.app"] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                                  ofItemAtPath: caches.appendingPathComponent(name).path)
        }
        for sub in ["webkit-1", "webkit-1/Playwright.app", "webkit-1/Playwright.app/Contents", "webkit-1/Playwright.app/Contents/MacOS"] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)],
                                                  ofItemAtPath: caches.appendingPathComponent("org.webkit.Playwright/" + sub).path)
        }
        let running = ["com.logi.pluginservice"]   // a menu bar agent, not a Dock app
        let procs = [SafePath.real(exe)!]           // proc_pidpath reports resolved paths
        let targets = Cleaner.scanFiles(home: tmp, runningIDs: running, xcodeRunning: false, processPaths: procs)
        XCTAssertEqual(targets.first { $0.kind == .caches }?.paths, [caches.appendingPathComponent("com.stale.app").path])
        // Without the process the Playwright cache would have been offered: the rule is what keeps it.
        let loose = Cleaner.scanFiles(home: tmp, runningIDs: running, xcodeRunning: false, processPaths: [])
        XCTAssertEqual(loose.first { $0.kind == .caches }?.paths.count, 2)
    }

    func testRecheckRightBeforeDeletingDropsWhatStartedSinceTheScan() throws {
        let caches = tmp.appendingPathComponent("Library/Caches").path
        _ = try file("Library/Caches/com.started.later/blob")
        _ = try file("Library/Caches/com.still.idle/blob")
        let exe = try file("Library/Caches/com.cli.tool/bin/tool")
        let derived = tmp.appendingPathComponent("Library/Developer/Xcode/DerivedData").path
        let targets = [
            CleanTarget(kind: .caches, root: caches, paths: ["com.started.later", "com.still.idle", "com.cli.tool"].map { caches + "/" + $0 },
                        bytes: 1, recommended: true),
            CleanTarget(kind: .derivedData, root: derived, paths: [derived + "/P"], bytes: 1, recommended: false),
            CleanTarget(kind: .logs, root: "/x", paths: ["/x/a"], bytes: 1, recommended: true),
        ]
        let now = CleanerRules.recheck(targets, runningIDs: ["com.started.later"], processPaths: [SafePath.real(exe)!])
        XCTAssertEqual(now.first { $0.kind == .caches }?.paths.map { ($0 as NSString).lastPathComponent }, ["com.still.idle"])
        XCTAssertNotNil(now.first { $0.kind == .derivedData })
        XCTAssertNotNil(now.first { $0.kind == .logs })
        let building = CleanerRules.recheck(targets, runningIDs: [], processPaths: ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"])
        XCTAssertNil(building.first { $0.kind == .derivedData })
        XCTAssertNil(CleanerRules.recheck(targets, runningIDs: ["com.apple.dt.Xcode"], processPaths: []).first { $0.kind == .derivedData })
    }

    func testTamperedTargetOutsideItsRootIsSkipped() throws {
        let outside = try file("elsewhere/important.txt")
        let logs = tmp.appendingPathComponent("Library/Logs").path
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let t = CleanTarget(kind: .logs, root: logs, paths: [outside], bytes: 0, recommended: true)
        XCTAssertEqual(Cleaner.delete([t]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }
}
