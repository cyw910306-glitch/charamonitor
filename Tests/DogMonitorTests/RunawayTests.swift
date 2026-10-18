import XCTest
@testable import DogMonitor

final class RunawayTests: XCTestCase {
    private let uid: uid_t = 501

    /// launchd(1) → cmux(10) → fish(11) → node(12); launchd → orphan(20); launchd → Chrome(30) → helper(31), tool(32);
    /// launchd → Apple(40); launchd → root(50); launchd → spotify helper(60, adopted);
    /// launchd → bun --daemon(70) → claude(71) → node MCP(72); launch agent job(80) → claude -p's node(81); us(99).
    private func context() -> RunawayRules.Context {
        let table: [(pid_t, pid_t, uid_t, String)] = [
            (1, 0, 0, "/sbin/launchd"), (10, 1, uid, "/Applications/cmux.app/Contents/MacOS/cmux"),
            (11, 10, uid, "/opt/homebrew/bin/fish"), (12, 11, uid, "/opt/homebrew/bin/node"),
            (20, 1, uid, "/Users/me/.npm/_npx/bin/node"),
            (30, 1, uid, "/Applications/Chrome.app/Contents/MacOS/Chrome"),
            (31, 30, uid, "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            (32, 30, uid, "/Users/me/bin/tool"),
            (70, 1, uid, "/Users/me/.bun/bin/bun"),
            (71, 70, uid, "/Users/me/.local/node/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"),
            (72, 71, uid, "/opt/homebrew/bin/node"), (80, 1, uid, "/Users/me/tools/sync-runner"), (81, 80, uid, "/opt/homebrew/bin/node"),
            (40, 1, uid, "/System/Library/CoreServices/mds"), (50, 1, 0, "/opt/root/daemon"),
            (60, 1, uid, "/Applications/Spotify.app/Contents/Frameworks/Helper"), (99, 1, uid, "/Applications/Dog.app/Contents/MacOS/Dog"),
        ]
        var rows: [pid_t: ProcRow] = [:], paths: [pid_t: String] = [:]
        for (pid, ppid, owner, path) in table {
            rows[pid] = ProcRow(pid: pid, ppid: ppid, uid: owner, start: UInt64(pid) * 1000, name: (path as NSString).lastPathComponent)
            paths[pid] = path
        }
        return RunawayRules.Context(own: 99, uid: uid, rows: rows, paths: paths, apps: [10, 30, 99],
                                    appBundles: ["/Applications/cmux.app", "/Applications/Chrome.app", "/Applications/Spotify.app"],
                                    services: [80], args: { $0 == 70 ? ["bun", "worker-service.cjs", "--daemon"] : [] })
    }

    /// `count` samples 30 s apart burning `cpu` of one core, the last one at `now`.
    private func history(cpu: Double, count: Int, now: Double = 1000) -> CPUHistory {
        var h = CPUHistory()
        for i in 0..<count {
            let t = now - Double(count - 1 - i) * 30
            h.add(t: t, cpu: t * cpu)
        }
        return h
    }

    private func key(_ pid: pid_t) -> ProcKey { ProcKey(pid: pid, start: UInt64(pid) * 1000) }

    func testHistoryKeepsTenSamplesAndAverages() {
        let h = history(cpu: 0.6, count: 14)
        XCTAssertEqual(h.points.count, 10)
        XCTAssertEqual(h.span, 270)
        XCTAssertEqual(h.average ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(h.hotFor(now: 1000), 13 * 30)   // the hot run outlasts the kept window
    }

    func testThresholds() {
        let c = context()
        let picks = RunawayRules.candidates([key(20): history(cpu: 0.49, count: 10)], now: 1000, c)
        XCTAssertTrue(picks.isEmpty, "below half a core")
        XCTAssertTrue(RunawayRules.candidates([key(20): history(cpu: 1, count: 6)], now: 1000, c).isEmpty, "only 2.5 minutes watched")
        let three = RunawayRules.candidates([key(20): history(cpu: 0.5, count: 7)], now: 1000, c)
        XCTAssertEqual(three.map(\.pid), [20])
    }

    func testLeftoverIsListedButNeverPreselected() {
        let c = context()
        let orphan = RunawayRules.candidates([key(20): history(cpu: 1, count: 20)], now: 1000, c)
        XCTAssertEqual(orphan.map(\.pid), [20])
        XCTAssertTrue(orphan[0].orphan)
        XCTAssertFalse(RunawayRules.why(orphan[0]).contains("없어진"), "a detached service is not called a leftover")
        let model = MainActor.assumeIsolated { () -> Bool in
            let m = CleanerModel()
            m.show(CleanerScan(apps: [], files: [], runaways: orphan, agents: []))
            return m.pickedRunaways.isEmpty
        }
        XCTAssertTrue(model, "each runaway needs the owner's own tick")
    }

    func testTerminalProtectedAppleAndOwnProcessesAreNeverOffered() {
        let c = context()
        let all = Dictionary(uniqueKeysWithValues: [10, 11, 12, 30, 31, 32, 40, 50, 60, 70, 71, 72, 80, 81, 99]
            .map { (key($0), history(cpu: 1, count: 11)) })
        XCTAssertTrue(RunawayRules.candidates(all, now: 1000, c).isEmpty)
        XCTAssertEqual(RunawayRules.exclusion(12, c), "터미널에서 실행함")
        XCTAssertEqual(RunawayRules.exclusion(11, c), "셸·터미널")
        XCTAssertEqual(RunawayRules.exclusion(40, c), "애플 프로그램")
        XCTAssertEqual(RunawayRules.exclusion(50, c), "다른 사용자")
        XCTAssertEqual(RunawayRules.exclusion(60, c), "앱의 일부(앱 목록에서 다룸)")
        XCTAssertEqual(RunawayRules.exclusion(30, c), "앱 본체(앱 목록에서 다룸)")
        XCTAssertEqual(RunawayRules.exclusion(99, c), "우리 앱")
        XCTAssertTrue(RunawayRules.isApplePath("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"))
        XCTAssertTrue(RunawayRules.isApplePath("/usr/libexec/something"))
        XCTAssertFalse(RunawayRules.isApplePath("/Users/me/usr/bin/x"))
    }

    func testDaemonsClaudeCodeAndLaunchAgentJobsAreKept() {
        let c = context()
        XCTAssertEqual(RunawayRules.exclusion(70, c), "상주 서비스(--daemon)")
        XCTAssertEqual(RunawayRules.exclusion(71, c), "Claude Code")
        XCTAssertEqual(RunawayRules.exclusion(72, c), "Claude Code가 띄움")
        XCTAssertEqual(RunawayRules.exclusion(80, c), "로그인·백그라운드 항목")
        XCTAssertEqual(RunawayRules.exclusion(81, c), "로그인·백그라운드 항목이 띄움")
        XCTAssertNil(RunawayRules.exclusion(20, c))
    }

    func testAnythingAnAppStartedIsLeftToTheAppSection() {
        let c0 = context()
        XCTAssertEqual(RunawayRules.exclusion(31, c0), "앱의 일부(앱 목록에서 다룸)")
        XCTAssertEqual(RunawayRules.exclusion(32, c0), "앱이 띄움(앱 목록에서 다룸)", "a Chrome child outside its bundle")
        // The cmux app shields the whole chain even without the shell in between.
        var c = c0
        c.rows[12]?.ppid = 10
        XCTAssertNotNil(RunawayRules.exclusion(12, c))
        // A chain we cannot read is not offered.
        c.rows[12]?.ppid = 777
        XCTAssertNotNil(RunawayRules.exclusion(12, c))
    }

    func testPidReuseNeverMixesHistories() {
        let tracker = RunawayTracker()
        let row = { (start: UInt64) in [pid_t(20): ProcRow(pid: 20, ppid: 1, uid: self.uid, start: start, name: "node")] }
        for i in 0..<8 { tracker.update(rows: row(20_000), cpu: [ProcKey(pid: 20, start: 20_000): Double(i) * 30], now: Double(i) * 30) }
        XCTAssertEqual(tracker.histories[ProcKey(pid: 20, start: 20_000)]?.points.count, 8)
        // Same pid, new process: the old history is gone and the new one starts from scratch.
        tracker.update(rows: row(55_000), cpu: [ProcKey(pid: 20, start: 55_000): 5], now: 240)
        XCTAssertEqual(tracker.histories.count, 1)
        XCTAssertEqual(tracker.histories[ProcKey(pid: 20, start: 55_000)]?.points.count, 1)
        // A stale history whose start does not match the current row is not offered.
        var c = context()
        c.rows[20]?.start = 1
        XCTAssertTrue(RunawayRules.candidates([key(20): history(cpu: 1, count: 11)], now: 1000, c).isEmpty)
    }

    func testCPUGoingBackwardsResetsTheHistory() {
        var h = history(cpu: 1, count: 8)
        h.add(t: 1030, cpu: 3)
        XCTAssertEqual(h.points.count, 1)
        XCTAssertNil(h.hotSince)
    }

    func testStopReverifiesIdentityAndSendsOnlySIGTERM() {
        let c = RunawayCandidate(pid: 20, start: 20_000, name: "node", path: "/x/node", cpu: 1, duration: 600, orphan: true)
        let moved = RunawayCandidate(pid: 21, start: 21_000, name: "a", path: "/x/a", cpu: 1, duration: 600, orphan: true)
        let reused = RunawayCandidate(pid: 22, start: 22_000, name: "b", path: "/x/b", cpu: 1, duration: 600, orphan: true)
        let gone = RunawayCandidate(pid: 23, start: 23_000, name: "c", path: "/x/c", cpu: 1, duration: 600, orphan: true)
        let now: [pid_t: ProcIdentity] = [20: ProcIdentity(start: 20_000, path: "/x/node"),
                                          21: ProcIdentity(start: 21_000, path: "/x/other"),   // exec'd something else
                                          22: ProcIdentity(start: 99_999, path: "/x/b")]       // pid reused
        var signals: [(pid_t, Int32)] = []
        let r = RunawayStop.send([c, moved, reused, gone], identify: { now[$0] }, signal: { signals.append(($0, $1)); return 0 })
        XCTAssertEqual(r.sent.map(\.pid), [20])
        XCTAssertEqual(r.skipped.map(\.pid), [21, 22, 23])
        XCTAssertEqual(signals.map(\.0), [20])
        XCTAssertEqual(signals.map(\.1), [SIGTERM])
        XCTAssertEqual(RunawayStop.stillAlive(r.sent, identify: { now[$0] }).map(\.pid), [20])
        XCTAssertTrue(RunawayStop.stillAlive(r.sent, identify: { _ in nil }).isEmpty)
        // A refused signal is reported as skipped.
        XCTAssertEqual(RunawayStop.send([c], identify: { now[$0] }, signal: { _, _ in -1 }).skipped.map(\.pid), [20])
    }

    func testRestartAdvice() {
        let day: TimeInterval = 86_400, gb: UInt64 = 1 << 30
        XCTAssertFalse(RestartAdvice.recommend(uptime: 6.9 * day, swapUsed: 8 * gb, pressure: .critical))
        XCTAssertFalse(RestartAdvice.recommend(uptime: 8 * day, swapUsed: 2 * gb - 1, pressure: .normal))
        XCTAssertTrue(RestartAdvice.recommend(uptime: 7 * day, swapUsed: 2 * gb, pressure: .normal))
        XCTAssertTrue(RestartAdvice.recommend(uptime: 7 * day, swapUsed: 0, pressure: .warning))
        XCTAssertFalse(RestartAdvice.recommend(uptime: 13.9 * day, swapUsed: 0, pressure: .normal))
        XCTAssertTrue(RestartAdvice.recommend(uptime: 14 * day, swapUsed: 0, pressure: .normal))
        XCTAssertEqual(RestartAdvice.text(uptime: 9.5 * day, swapUsed: 3 * gb), "켜진 지 9일 · 스왑 3.0 GB · 재시동하면 메모리가 깔끔해져요")
    }

    func testPathHint() {
        XCTAssertEqual(RunawayRules.pathHint("/Users/me/claude code/app/node_modules/.bin/vite", home: "/Users/me"), "~/…/.bin/vite")
        XCTAssertEqual(RunawayRules.pathHint("/opt/homebrew/bin/node", home: "/Users/me"), "/…/bin/node")
        XCTAssertEqual(RunawayRules.pathHint("/usr/bin/x", home: "/Users/me"), "/usr/bin/x")
    }
}
