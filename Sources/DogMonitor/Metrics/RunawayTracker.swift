import AppKit
import Darwin
import Foundation
import Security

// Runaway background processes (a stuck node or build, a spinning helper) and the restart hint.
// RunawayTracker samples CPU time every 30 s; RunawayRules decides, with no system calls, what to offer.

/// One process as the tracker saw it in the last sample.
struct ProcRow: Equatable {
    var pid: pid_t
    var ppid: pid_t
    var uid: uid_t
    var start: UInt64   // microseconds since 1970, with the pid it tells one process from a later reuse
    var name: String
}

struct ProcKey: Hashable {
    var pid: pid_t
    var start: UInt64
}

/// What a pid runs right now, compared before a signal is sent.
struct ProcIdentity: Equatable {
    var start: UInt64
    var path: String
}

/// Cumulative CPU seconds of one process at the last few samples.
struct CPUHistory: Equatable {
    struct Point: Equatable { var t: Double; var cpu: Double }
    static let keep = 10
    private(set) var points: [Point] = []
    /// Start of the unbroken run of intervals at or above RunawayRules.minCPU, which can outlast the 10 kept points.
    private(set) var hotSince: Double?

    mutating func add(t: Double, cpu: Double) {
        if let last = points.last {
            guard t > last.t, cpu >= last.cpu else { points = []; hotSince = nil; points.append(Point(t: t, cpu: cpu)); return }
            let rate = (cpu - last.cpu) / (t - last.t)
            hotSince = rate >= RunawayRules.minCPU ? (hotSince ?? last.t) : nil
        }
        points.append(Point(t: t, cpu: cpu))
        if points.count > Self.keep { points.removeFirst(points.count - Self.keep) }
    }

    var span: Double { (points.last?.t ?? 0) - (points.first?.t ?? 0) }

    /// Average share of one core over the kept window.
    var average: Double? {
        guard let a = points.first, let b = points.last, b.t > a.t else { return nil }
        return (b.cpu - a.cpu) / (b.t - a.t)
    }

    func hotFor(now: Double) -> Double { hotSince.map { now - $0 } ?? 0 }
}

struct RunawayCandidate: Identifiable, Equatable {
    var pid: pid_t
    var start: UInt64
    var name: String
    var path: String
    var cpu: Double            // average share of one core
    var duration: TimeInterval // how long it has been hot (at least the window)
    var orphan: Bool           // parent is launchd: a leftover, or a service that detached on purpose
    var id: ProcKey { ProcKey(pid: pid, start: start) }
}

enum RunawayRules {
    static let minCPU = 0.5
    static let minSamples = 6
    static let minSpan: TimeInterval = 180

    static let applePrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/Library/Developer/CommandLineTools/",
                                "/Applications/Xcode.app/", "/Applications/Xcode-beta.app/", "/private/var/db/"]
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "login", "nu", "tmux", "screen"]
    static let terminalBundles = ["/Terminal.app/", "/iTerm.app/", "/cmux.app/", "/Ghostty.app/", "/Warp.app/", "/Alacritty.app/",
                                  "/kitty.app/", "/WezTerm.app/", "/Hyper.app/", "/Tabby.app/"]

    static func isApplePath(_ path: String) -> Bool { applePrefixes.contains { path.hasPrefix($0) } }

    static func isShellOrTerminal(_ path: String) -> Bool {
        shells.contains((path as NSString).lastPathComponent) || terminalBundles.contains { path.contains($0) }
    }

    /// Claude Code, wherever it was installed; headless runs of it work for the owner.
    static func isClaudeCode(_ path: String) -> Bool {
        ["claude", "claude.exe"].contains((path as NSString).lastPathComponent)
            || path.contains("/@anthropic-ai/claude-code/") || path.contains("/.local/share/claude/")
    }

    /// What the rules need about the Mac right now, gathered on the main thread.
    struct Context {
        var own: pid_t
        var uid: uid_t
        var rows: [pid_t: ProcRow]
        var paths: [pid_t: String]
        var apps: Set<pid_t> = []           // main process of every running app, Dock, menu bar or background
        var appBundles: [String] = []       // their bundle paths, for helpers launchd adopted
        var services: Set<pid_t> = []       // jobs launchd runs for the owner right now (`launchctl list` PIDs)
        var args: (pid_t) -> [String] = { _ in [] }
        var isApple: (String) -> Bool = RunawayRules.isApplePath
    }

    /// Why `pid` is never offered, nil when it may be.
    static func exclusion(_ pid: pid_t, _ c: Context) -> String? {
        guard let row = c.rows[pid], let path = c.paths[pid] else { return "정보를 읽을 수 없음" }
        if pid == c.own || pid <= 1 { return "우리 앱" }
        if row.uid != c.uid { return "다른 사용자" }
        if c.isApple(path) { return "애플 프로그램" }
        if c.apps.contains(pid) { return "앱 본체(앱 목록에서 다룸)" }
        if isShellOrTerminal(path) { return "셸·터미널" }
        if isClaudeCode(path) { return "Claude Code" }
        if c.appBundles.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return "앱의 일부(앱 목록에서 다룸)" }
        if c.services.contains(pid) { return "로그인·백그라운드 항목" }
        var seen = Set<pid_t>(), up = row.ppid
        while up > 1, seen.insert(up).inserted {
            if up == c.own { return "우리 앱이 띄움" }
            if c.apps.contains(up) { return "앱이 띄움(앱 목록에서 다룸)" }
            if c.services.contains(up) { return "로그인·백그라운드 항목이 띄움" }
            if let p = c.paths[up], isShellOrTerminal(p) { return "터미널에서 실행함" }
            if let p = c.paths[up], isClaudeCode(p) { return "Claude Code가 띄움" }
            guard let parent = c.rows[up] else { return "부모 프로세스를 읽을 수 없음" }   // unknown chain: stay out
            up = parent.ppid
        }
        if c.args(pid).contains("--daemon") { return "상주 서비스(--daemon)" }
        return nil
    }

    /// Hot processes that may be offered, hottest first. Never pre-picked: a leftover and a service that
    /// detached on purpose (nohup, a daemon) look the same from here, so each needs the owner's own tick.
    static func candidates(_ histories: [ProcKey: CPUHistory], now: Double, _ c: Context) -> [RunawayCandidate] {
        histories.compactMap { key, h -> RunawayCandidate? in
            guard h.points.count >= minSamples, h.span >= minSpan, let avg = h.average, avg >= minCPU,
                  let row = c.rows[key.pid], row.start == key.start, let path = c.paths[key.pid],
                  exclusion(key.pid, c) == nil else { return nil }
            let orphan = row.ppid == 1
            let hot = max(h.span, h.hotFor(now: now))
            return RunawayCandidate(pid: key.pid, start: key.start, name: row.name, path: path, cpu: avg, duration: hot, orphan: orphan)
        }
        .sorted { $0.cpu > $1.cpu }
    }

    /// "~/…/bin/node": enough to recognise it, short enough for one line.
    static func pathHint(_ path: String, home: String = NSHomeDirectory()) -> String {
        let p = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count <= 4 ? p : ([parts[0], "…"] + parts.suffix(2)).joined(separator: "/")
    }

    static func why(_ r: RunawayCandidate) -> String {
        let span = L("\(Fmt.duration(minutes: Int(r.duration / 60)))째 CPU \(String(format: "%.0f%%", r.cpu * 100))")
        return span + (r.orphan ? L(" · 혼자 도는 중, 켜 둔 서비스일 수도") : L(" · 백그라운드에서 계속 돌아요"))
    }
}

#if !MAS
/// SIGTERM only, and only to the exact process that was shown: pid, start time and executable must still match.
enum RunawayStop {
    static func send(_ targets: [RunawayCandidate], identify: (pid_t) -> ProcIdentity?,
                     signal: (pid_t, Int32) -> Int32) -> (sent: [RunawayCandidate], skipped: [RunawayCandidate]) {
        var sent: [RunawayCandidate] = [], skipped: [RunawayCandidate] = []
        for t in targets {
            guard t.pid > 1, t.pid != getpid(), identify(t.pid) == ProcIdentity(start: t.start, path: t.path),
                  signal(t.pid, SIGTERM) == 0 else { skipped.append(t); continue }
            sent.append(t)
        }
        return (sent, skipped)
    }

    static func stillAlive(_ sent: [RunawayCandidate], identify: (pid_t) -> ProcIdentity?) -> [RunawayCandidate] {
        sent.filter { identify($0.pid) == ProcIdentity(start: $0.start, path: $0.path) }
    }
}

/// Samples CPU time of the owner's processes every 30 s. Started at launch, paused with the rest of sampling.
final class RunawayTracker {
    static let shared = RunawayTracker()
    static let interval: TimeInterval = 30

    private(set) var histories: [ProcKey: CPUHistory] = [:]
    private(set) var rows: [pid_t: ProcRow] = [:]
    private(set) var lastCost: TimeInterval = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = Self.interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Histories are dropped: after a pause the three minutes start over instead of averaging across the gap.
    func stop() {
        timer?.invalidate()
        timer = nil
        histories = [:]
    }

    func sample(now: Double = ProcessInfo.processInfo.systemUptime) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (rows, cpu) = Self.read()
        update(rows: rows, cpu: cpu, now: now)
        lastCost = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    }

    /// Keeps a history per (pid, start time); processes that are gone, or whose pid was reused, lose theirs.
    func update(rows: [pid_t: ProcRow], cpu: [ProcKey: Double], now: Double) {
        var next: [ProcKey: CPUHistory] = [:]
        for (key, seconds) in cpu {
            var h = histories[key] ?? CPUHistory()
            h.add(t: now, cpu: seconds)
            next[key] = h
        }
        histories = next
        self.rows = rows
    }

    /// Every process's parent and owner, and CPU seconds of the owner's own processes.
    static func read() -> ([pid_t: ProcRow], [ProcKey: Double]) {
        let uid = getuid()
        var rows: [pid_t: ProcRow] = [:], cpu: [ProcKey: Double] = [:]
        for pid in Cleaner.allPids() {
            guard let row = row(pid) else { continue }
            rows[pid] = row
            guard row.uid == uid, let u = Cleaner.usage(of: pid) else { continue }
            cpu[ProcKey(pid: pid, start: row.start)] = Cleaner.nanoseconds(u.ri_user_time &+ u.ri_system_time) / 1e9
        }
        return (rows, cpu)
    }

    static func row(_ pid: pid_t) -> ProcRow? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let comm = withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return ProcRow(pid: pid, ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid,
                       start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, name: name.isEmpty ? comm : name)
    }

    static func identify(_ pid: pid_t) -> ProcIdentity? {
        guard let r = row(pid), let path = Cleaner.path(of: pid) else { return nil }
        return ProcIdentity(start: r.start, path: path)
    }

    /// Signed by Apple itself (not a third party with an Apple certificate), wherever it is installed.
    static func isAppleSigned(_ path: String) -> Bool {
        var code: SecStaticCode?, req: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), req) == errSecSuccess
    }

    /// Context from NSWorkspace and the last sample. Paths are read here, not every 30 s. Cheap; the
    /// launchctl call and signature checks happen in `offer`, off the main thread.
    @MainActor
    func context() -> RunawayRules.Context {
        let apps = NSWorkspace.shared.runningApplications
        var paths: [pid_t: String] = [:]
        for pid in rows.keys { paths[pid] = Cleaner.path(of: pid) }
        return RunawayRules.Context(
            own: getpid(), uid: getuid(), rows: rows, paths: paths,
            apps: Set(apps.map(\.processIdentifier)),
            appBundles: apps.compactMap { $0.bundleURL.map { SafePath.real($0.path) ?? $0.path } },
            args: Cleaner.arguments(of:),
            isApple: { RunawayRules.isApplePath($0) || Self.isAppleSigned($0) })
    }

    /// The rules with launchd's running jobs filled in. Slow (launchctl, code signatures): not on the main thread.
    static func offer(_ histories: [ProcKey: CPUHistory], _ context: RunawayRules.Context) -> [RunawayCandidate] {
        var c = context
        c.services = LaunchAgents.runningPids(run: Shell.run)
        return RunawayRules.candidates(histories, now: ProcessInfo.processInfo.systemUptime, c)
    }

    /// Blocking, for the CLI and QA renders.
    @MainActor
    func candidates() -> [RunawayCandidate] { Self.offer(histories, context()) }

    /// --cleaner-dry-run: the app needs three minutes of samples, so this takes a 2 s look instead and prints
    /// every busy process of the owner with the rule that keeps it (or would let it be offered). Signals nothing.
    @MainActor
    static func dryRun() {
        let probe = RunawayTracker()
        probe.sample()
        let first = probe.lastCost
        Thread.sleep(forTimeInterval: 2)
        probe.sample()
        var c = probe.context()
        c.services = LaunchAgents.runningPids(run: Shell.run)
        let busy = probe.histories.compactMap { k, h in h.average.map { (k, $0) } }.filter { $0.1 >= 0.25 }.sorted { $0.1 > $1.1 }
        print("\n[폭주 프로세스] 앱은 3분 넘게 지켜본 뒤 골라요. 지금 2초 동안 CPU 25% 넘게 쓴 내 프로세스:")
        print(String(format: "  샘플 1회 비용 %.2f ms, %.2f ms (읽은 내 프로세스 %d개)", first * 1000, probe.lastCost * 1000, probe.histories.count))
        if busy.isEmpty { print("  없음") }
        for (k, cpu) in busy.prefix(12) {
            let name = probe.rows[k.pid]?.name ?? "?"
            let verdict = RunawayRules.exclusion(k.pid, c).map { "제외: \($0)" } ?? "후보가 될 수 있음"
            print("  \(name) (\(k.pid)) \(RunawayRules.pathHint(c.paths[k.pid] ?? "?")) · CPU \(String(format: "%.0f%%", cpu * 100)) · \(verdict)")
        }
        for r in RunawayTracker.shared.candidates() { print("  [ 둠 ] \(r.name) · \(RunawayRules.why(r)) (골라야만 멈춰요)") }

        let m = MemorySampler.sample(), up = Sysctl.uptime()
        let advise = RestartAdvice.recommend(uptime: up, swapUsed: m.swapUsed, pressure: m.pressureLevel)
        print("\n[재시동 권장] \(advise ? "권장" : "아직 괜찮아요") · 켜진 지 \(Fmt.uptime(up)) · 스왑 \(Fmt.mem(m.swapUsed)) · 압력 \(m.pressureLevel.rawValue)")
    }
}

#else
/// Mac App Store build: the sandbox cannot read other processes (proc_listpids answers 0, rusage EPERM), so there is
/// no per-process CPU and nothing to stop. The calls the status item makes stay, and the lists stay empty.
final class RunawayTracker {
    static let shared = RunawayTracker()
    private(set) var histories: [ProcKey: CPUHistory] = [:]
    private(set) var rows: [pid_t: ProcRow] = [:]
    func start() {}
    func stop() {}
}
#endif

/// Restart hint: a Mac left on for a week with swap grown, or for two weeks, runs cleaner after a restart.
enum RestartAdvice {
    static func recommend(uptime: TimeInterval, swapUsed: UInt64, pressure: MemoryPressureLevel) -> Bool {
        let days = uptime / 86_400
        return days >= 14 || (days >= 7 && (swapUsed >= 2 << 30 || pressure != .normal))
    }

    static func text(uptime: TimeInterval, swapUsed: UInt64) -> String {
        L("켜진 지 \(Int(uptime / 86_400))일 · 스왑 \(String(format: "%.1f GB", Double(swapUsed) / 1_073_741_824)) · 재시동하면 메모리가 깔끔해져요")
    }

    #if !MAS   // the App Store build has no Apple Events: it only shows the hint
    /// Asks first, then has System Events restart, which lets every app ask to save.
    @MainActor
    static func confirmAndRestart() {
        let alert = NSAlert()
        alert.messageText = L("맥을 재시동할까요?")
        alert.informativeText = L("켜진 앱에 저장 안 한 문서가 있으면 앱이 저장할지 물어봐요. 답하지 않으면 재시동이 멈춰요. 진행 중인 작업을 먼저 확인해 주세요.")
        alert.addButton(withTitle: L("재시동"))
        alert.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(&error)
    }
    #endif
}
