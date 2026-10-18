import XCTest
@testable import DogMonitor

/// Developer caches, old node_modules and launch agents. Files live in a temp folder; commands go to a fake runner.
final class DevCleanerTests: XCTestCase {
    private var tmp: URL!
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["CLEANER_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        tmp = base.appendingPathComponent("dev-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    private func file(_ rel: String, bytes: Int = 5000) throws -> String {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url.path
    }

    /// Sets the mtime of everything under `rel` (the folder too), deepest first so folders keep the date.
    private func age(_ rel: String, days: Double) throws {
        let root = tmp.appendingPathComponent(rel).path
        var all: [String] = []
        SafePath.walk(root) { p, _ in all.append(p) }
        for p in all.sorted(by: { $0.count > $1.count }) {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * day)], ofItemAtPath: p)
        }
    }

    private func proc(_ name: String, path: String = "/opt/homebrew/bin/node", args: [String] = [], age: TimeInterval = 10) -> ToolProc {
        ToolProc(name: name, path: path, args: args, age: age)
    }

    // MARK: Blocking rules

    func testToolsBlockTheirOwnCacheOnly() {
        func blocked(_ kind: CleanTarget.Kind, _ p: ToolProc, running: [String] = []) -> Bool {
            DevCacheRules.blocker(kind, tools: [p], runningIDs: running) != nil
        }
        // What the kernel reports for npm: name "node", the npm title in argv[0].
        XCTAssertTrue(blocked(.npmCache, proc("node", args: ["npm install", "", ""])))
        XCTAssertTrue(blocked(.npmCache, proc("node", args: ["npm ci"])))
        XCTAssertEqual(DevCacheRules.blocker(.npmCache, tools: [proc("node", args: ["npm install"])], runningIDs: []),
                       "npm 실행 중이라 이번엔 건너뛰어요")
        XCTAssertTrue(blocked(.npmCache, proc("node", args: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "ci"])))
        XCTAssertTrue(blocked(.npmCache, proc("pnpm")))
        XCTAssertTrue(blocked(.npmCache, proc("node", args: ["npm exec @playwright/mcp@latest", "", ""], age: 30)))   // may still be fetching
        XCTAssertFalse(blocked(.npmCache, proc("node", args: ["npm exec @playwright/mcp@latest", "", ""], age: 3600)))  // an MCP server up for an hour
        XCTAssertFalse(blocked(.npmCache, proc("node", args: ["node", "/x/npx-cli.js", "-y", "server"], age: 3600)))
        XCTAssertFalse(blocked(.npmCache, proc("node", args: ["node", "server.js"])))   // a plain node program
        XCTAssertFalse(blocked(.brewCache, proc("node", args: ["npm install"])))

        XCTAssertTrue(blocked(.brewCache, proc("brew", path: "/bin/bash")))
        XCTAssertTrue(blocked(.brewCache, proc("ruby", path: "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby")))
        XCTAssertTrue(blocked(.pipCache, proc("pip3", path: "/usr/bin/python3")))
        XCTAssertTrue(blocked(.pipCache, proc("Python", path: "/usr/bin/python3", args: ["python3", "-m", "pip", "install", "x"])))
        XCTAssertFalse(blocked(.pipCache, proc("Python", path: "/usr/bin/python3", args: ["python3", "pipeline.py"])))
        XCTAssertTrue(blocked(.yarnCache, proc("node", args: ["node", "/usr/local/bin/yarn.js"])))

        XCTAssertTrue(blocked(.simulators, proc("simctl", path: "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl")))
        XCTAssertNotNil(DevCacheRules.blocker(.simulators, tools: [], runningIDs: ["com.apple.dt.Xcode"]))
        XCTAssertNil(DevCacheRules.blocker(.simulators, tools: [], runningIDs: ["com.google.Chrome"]))
    }

    func testUnavailableSimulatorsAreParsedAndOnlyUdidShapedOnesKept() {
        let json = """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
          {"udid": "0A1B2C3D-0000-1111-2222-333344445555", "isAvailable": false},
          {"udid": "../../escape", "isAvailable": false},
          {"udid": "FFFFFFFF-0000-1111-2222-333344445555", "isAvailable": true}]}}
        """
        XCTAssertEqual(DevCacheRules.unavailableDevices(json: json), ["0A1B2C3D-0000-1111-2222-333344445555"])
        XCTAssertEqual(DevCacheRules.unavailableDevices(json: "not json"), [])
    }

    // MARK: Developer caches in a fake home

    func testDevCachesAreOfferedBlockedAndRecheckedRightBeforeDeleting() throws {
        let npm = try file(".npm/_cacache/content-v2/sha512/ab/blob")
        let npx = try file(".npm/_npx/1a2b/node_modules/pkg/index.js")   // running MCP servers live here: kept
        let brew = try file("Library/Caches/Homebrew/downloads/x.tar.gz")
        let pip = try file("Library/Caches/pip/http-v2/a")
        let yarn = try file("Library/Caches/Yarn/v6/pkg")
        let home = tmp!

        let calm = Cleaner.devTargets(home: home, runningIDs: [], tools: [], run: { _ in (1, "") })
        XCTAssertEqual(calm.map(\.kind), [.npmCache, .brewCache, .pipCache, .yarnCache])
        XCTAssertTrue(calm.allSatisfy { $0.recommended && $0.blocked == nil && ($0.bytes ?? 0) > 0 })

        let installing = Cleaner.devTargets(home: home, runningIDs: [], tools: [proc("node", args: ["npm install"])], run: { _ in (1, "") })
        let npmTarget = try XCTUnwrap(installing.first { $0.kind == .npmCache })
        XCTAssertNotNil(npmTarget.blocked)
        XCTAssertFalse(npmTarget.recommended)
        XCTAssertEqual(Cleaner.delete([npmTarget]), 0)                 // a blocked group is never deleted
        XCTAssertTrue(FileManager.default.fileExists(atPath: npm))

        // brew started between the scan and the tap: dropped by the recheck.
        let later = CleanerRules.recheck(calm, runningIDs: [], processPaths: [], tools: [proc("brew", path: "/bin/bash")])
        XCTAssertEqual(later.map(\.kind), [.npmCache, .pipCache, .yarnCache])
        XCTAssertGreaterThan(Cleaner.delete(later), 0)
        for gone in [npm, pip, yarn] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone), gone) }
        for kept in [npx, brew] { XCTAssertTrue(FileManager.default.fileExists(atPath: kept), kept) }
        for root in [".npm", "Library/Caches/pip", "Library/Caches/Yarn"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(root).path), root)
        }
    }

    func testSimulatorsGoThroughTheInjectedRunner() throws {
        let udid = "0A1B2C3D-0000-1111-2222-333344445555"
        let device = try file("Library/Developer/CoreSimulator/Devices/\(udid)/data/big.img", bytes: 20_000)
        let cache = try file("Library/Developer/CoreSimulator/Caches/dyld/cache.bin")
        var calls: [[String]] = []
        let fake: CommandRunner = { argv in
            calls.append(argv)
            if argv.contains("list") { return (0, #"{"devices":{"r":[{"udid":"\#(udid)","isAvailable":false}]}}"#) }
            return (0, "")
        }
        let t = try XCTUnwrap(Cleaner.devTargets(home: tmp, runningIDs: [], tools: [], run: fake).first { $0.kind == .simulators })
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.command, ["/usr/bin/xcrun", "simctl", "delete", "unavailable"])
        XCTAssertGreaterThan(t.commandBytes, 0)
        XCTAssertEqual(calls.first, ["/usr/bin/xcode-select", "-p"])

        calls = []
        XCTAssertGreaterThan(Cleaner.delete([t], run: fake), t.commandBytes)
        XCTAssertEqual(calls, [["/usr/bin/xcrun", "simctl", "delete", "unavailable"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: device))   // devices are simctl's to delete, never ours

        // No Xcode: xcrun is never called (it would pop the install dialog).
        calls = []
        _ = Cleaner.devTargets(home: tmp, runningIDs: [], tools: [], run: { calls.append($0); return (2, "") })
        XCTAssertEqual(calls, [["/usr/bin/xcode-select", "-p"]])
    }

    // MARK: Old node_modules

    func testOnlyLongUntouchedProjectsAreOfferedAndDeleted() throws {
        let oldLib = try file("code/old/node_modules/pkg/index.js")
        let oldSrc = try file("code/old/src/app.ts")
        try file("code/old/package-lock.json")
        try age("code/old", days: 40)
        try file("code/fresh/node_modules/pkg/index.js")
        try age("code/fresh", days: 40)
        try file("code/fresh/src/edited.ts")                              // touched now
        try age("code/fresh/src/edited.ts", days: 1)                      // yesterday
        try file("code/committed/node_modules/pkg/index.js")
        try file("code/committed/.git/logs/HEAD")
        try age("code/committed", days: 40)
        try age("code/committed/.git/logs/HEAD", days: 2)                 // committed two days ago
        let precious = try file("outside/node_modules/keep.js")
        try file("outside/yarn.lock")
        try age("outside", days: 40)
        try file("code/linked/package.json")
        try FileManager.default.createSymbolicLink(atPath: tmp.appendingPathComponent("code/linked/node_modules").path,
                                                   withDestinationPath: tmp.appendingPathComponent("outside/node_modules").path)
        try age("code/linked", days: 40)
        try file(".hidden/p/node_modules/x.js"); try age(".hidden", days: 40)
        try file("Library/p/node_modules/x.js"); try age("Library", days: 40)
        try file("a/b/c/d/e/node_modules/x.js"); try age("a", days: 40)   // six levels down: past the search depth
        try file("code/nolock/node_modules/x.js"); try age("code/nolock", days: 40)   // npm install would not bring it back as it was
        for rel in ["code/fresh", "code/committed", "code/linked", ".hidden/p", "Library/p", "a/b/c/d/e"] {
            try file(rel + "/package-lock.json"); try age(rel + "/package-lock.json", days: 40)
        }

        let targets = Cleaner.scanFiles(home: tmp, runningIDs: [], xcodeRunning: false, processPaths: [], tools: [], run: { _ in (1, "") })
        let node = try XCTUnwrap(targets.first { $0.kind == .nodeModules })
        let offered = node.projects.map { $0.project.replacingOccurrences(of: SafePath.real(tmp.path)!, with: "")
            .replacingOccurrences(of: tmp.path, with: "") }
        XCTAssertEqual(Set(offered), ["/code/old", "/outside"])
        XCTAssertFalse(node.recommended)

        // A running binary inside node_modules keeps it; so does a dev server run by a node outside the project,
        // seen by its working folder or by the script it runs.
        let busy = NodeModules.scan(home: tmp.path, now: Date(), processPaths: [SafePath.real(oldLib)!])
        XCTAssertEqual(busy.projects.count, 1)
        let oldDir = SafePath.real(tmp.appendingPathComponent("code/old").path)!
        let server = proc("node", path: "/Users/me/.local/node/bin/node", args: ["node", oldDir + "/node_modules/vite/bin/vite.js"])
        let inside = proc("node", path: "/Users/me/.local/node/bin/node", args: ["npm run dev"])
        var inCwd = inside; inCwd.cwd = oldDir + "/src"
        XCTAssertEqual(NodeModules.scan(home: tmp.path, now: Date(), processPaths: [], tools: [server]).projects.count, 1)
        XCTAssertEqual(NodeModules.scan(home: tmp.path, now: Date(), processPaths: [], tools: [inCwd]).projects.count, 1)
        XCTAssertEqual(NodeModules.scan(home: tmp.path, now: Date(), processPaths: [], tools: [inside]).projects.count, 2)
        XCTAssertEqual(CleanerRules.recheck([node], runningIDs: [], processPaths: [], tools: [server]).first?.projects.map(\.name), ["outside"])

        // Path guard: only real folders named node_modules inside home.
        XCTAssertFalse(NodeModules.deletable(tmp.appendingPathComponent("code/old/src").path, home: tmp.path))
        XCTAssertFalse(NodeModules.deletable(tmp.appendingPathComponent("code/linked/node_modules").path, home: tmp.path))
        XCTAssertFalse(NodeModules.deletable(tmp.appendingPathComponent("outside/node_modules").path,
                                             home: tmp.appendingPathComponent("code").path))
        let forged = CleanTarget(kind: .nodeModules, root: tmp.path, paths: [tmp.appendingPathComponent("code/old/src").path],
                                 bytes: 1, recommended: false)
        XCTAssertEqual(Cleaner.delete([forged]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSrc))

        // The owner opens "outside" again before tapping: the recheck keeps it.
        try file("outside/README.md")
        let now = CleanerRules.recheck([node], runningIDs: [], processPaths: [])
        XCTAssertEqual(now.first?.projects.count, 1)
        XCTAssertGreaterThan(Cleaner.delete(now), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("code/old/node_modules").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSrc))
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: tmp.appendingPathComponent("code/linked/node_modules").path))
    }

    // MARK: Launch agents

    private func plist(_ dir: String, _ label: String, args: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": args], format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir + "/\(label).plist"))
    }

    func testLaunchAgentDisableAndRestoreRoundTrip() throws {
        let dir = tmp.appendingPathComponent("LaunchAgents").path
        try plist(dir, "com.apple.something", args: ["/usr/bin/true"])
        try plist(dir, "com.jelly.dogmonitor.helper", args: ["/usr/bin/true"])
        try plist(dir, "com.example.sync", args: ["/bin/bash", "/Users/x/tools/sync.sh", "--quiet"])
        var calls: [[String]] = []
        let fake: CommandRunner = { argv in
            calls.append(argv)
            return argv == ["/bin/launchctl", "list"] ? (0, "PID\tStatus\tLabel\n-\t0\tcom.example.sync\n42\t0\tcom.apple.x\n") : (0, "")
        }
        let jobs = try XCTUnwrap(LaunchAgents.jobs(run: fake))
        XCTAssertEqual(jobs, ["com.example.sync": 0, "com.apple.x": 42])
        let agents = LaunchAgents.list(dir: dir, jobs: jobs, own: "com.jelly.dogmonitor", home: "/Users/x")
        XCTAssertEqual(agents.map(\.label), ["com.example.sync"])
        let a = agents[0]
        XCTAssertTrue(a.loaded)
        XCTAssertEqual(a.pid, 0)
        XCTAssertTrue(a.mine, "a script in the owner's folders")
        XCTAssertEqual(a.program, "/Users/x/tools/sync.sh")

        // Running right now: never booted out (that would kill the run), the plist stays put.
        calls = []
        let busy: CommandRunner = { argv in
            calls.append(argv)
            return argv == ["/bin/launchctl", "list"] ? (0, "PID\tStatus\tLabel\n777\t0\tcom.example.sync\n") : (0, "")
        }
        XCTAssertEqual(LaunchAgents.list(dir: dir, jobs: LaunchAgents.jobs(run: busy) ?? [:], own: "com.jelly.dogmonitor")[0].state, "실행 중")
        calls = []
        XCTAssertNotNil(LaunchAgents.disable(a, dir: dir, uid: 501, run: busy))   // the scan said idle; the fresh look says running
        XCTAssertEqual(calls, [["/bin/launchctl", "list"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.plist))

        calls = []
        XCTAssertNil(LaunchAgents.disable(a, dir: dir, uid: 501, run: fake))
        XCTAssertEqual(calls, [["/bin/launchctl", "list"], ["/bin/launchctl", "bootout", "gui/501/com.example.sync"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.plist))
        let parked = LaunchAgents.list(dir: dir, jobs: [:], own: "com.jelly.dogmonitor")
        XCTAssertEqual(parked.map(\.disabled), [true])
        XCTAssertTrue(parked[0].plist.contains("/\(LaunchAgents.parkedName)/"))

        calls = []
        XCTAssertNil(LaunchAgents.enable(parked[0], dir: dir, uid: 501, run: fake))
        XCTAssertEqual(calls, [["/bin/launchctl", "bootstrap", "gui/501", dir + "/com.example.sync.plist"]])
        XCTAssertEqual(LaunchAgents.list(dir: dir, jobs: [:], own: "com.jelly.dogmonitor").map(\.disabled), [false])

        // launchctl unreadable, or bootout refused: the plist stays where it is.
        XCTAssertNotNil(LaunchAgents.disable(a, dir: dir, uid: 501, run: { _ in (5, "") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.plist))
        XCTAssertNotNil(LaunchAgents.disable(a, dir: dir, uid: 501, run: { argv in argv.count == 2 ? fake(argv) : (5, "") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.plist))
    }

    func testScheduleSaysWhenAnAgentRuns() {
        let now = DateComponents(calendar: .current, year: 2026, month: 9, day: 30).date!
        func when(_ d: [String: Any]) -> String { LaunchAgents.schedule(d, now: now) }
        XCTAssertEqual(when(["RunAtLoad": true]), "로그인 때")
        XCTAssertEqual(when(["StartInterval": 1800]), "30분마다")
        XCTAssertEqual(when(["StartInterval": 3600]), "1시간마다")
        XCTAssertEqual(when(["StartCalendarInterval": ["Hour": 9, "Minute": 0]]), "매일 09:00")
        XCTAssertEqual(when(["StartCalendarInterval": ["Weekday": 0, "Hour": 12, "Minute": 0]]), "매주 일 12:00")
        XCTAssertEqual(when(["StartCalendarInterval": ["Year": 2026, "Month": 9, "Day": 13, "Hour": 9, "Minute": 0]]),
                       "2026-09-13 09:00 한 번(지남)")
        XCTAssertEqual(when(["StartCalendarInterval": [["Hour": 8, "Minute": 40], ["Hour": 20, "Minute": 0]]]), "매일 08:40 외 1개")
        XCTAssertEqual(when(["KeepAlive": true, "RunAtLoad": true]), "로그인 때 · 항상")
        XCTAssertEqual(when(["KeepAlive": ["SuccessfulExit": false]]), "항상")
        XCTAssertEqual(when(["KeepAlive": false]), "불릴 때만")
    }

    /// The kernel's view of a real npm: our own node child sets process.title the way npm does.
    func testRealNpmTitleBlocksTheNpmCache() throws {
        let home = NSHomeDirectory()
        let local = ((try? FileManager.default.contentsOfDirectory(atPath: home + "/.local/node")) ?? []).map { home + "/.local/node/\($0)/bin/node" }
        guard let node = (["/opt/homebrew/bin/node", "/usr/local/bin/node"] + local).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("node is not installed") }
        let cwd = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = ["-e", "process.title='npm install'; setTimeout(() => {}, 15000)"]
        p.currentDirectoryURL = cwd
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }   // our own child, nothing else
        var me: ToolProc?
        for _ in 0..<30 {
            me = Cleaner.toolProcs().first { $0.args.first == "npm install" && $0.cwd == SafePath.real(cwd.path) }
            if me != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let t = try XCTUnwrap(me, "own node child not seen with its npm title")
        XCTAssertEqual(t.name, "node")
        XCTAssertNotNil(DevCacheRules.blocker(.npmCache, tools: [t], runningIDs: []), "a real npm install blocks the npm cache")
        let cache = CleanTarget(kind: .npmCache, root: tmp.path, paths: [tmp.path + "/_cacache"], bytes: 1, recommended: true)
        XCTAssertTrue(CleanerRules.recheck([cache], runningIDs: [], processPaths: [], tools: [t]).isEmpty)
        XCTAssertTrue(NodeModules.inUse(cwd.path + "/node_modules", processPaths: [], tools: [t]), "its working folder counts as use")
    }
}
