#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt

/// Remembers when each app was last frontmost, from our launch on. Started by AppDelegate.
final class ActivityTracker {
    static let shared = ActivityTracker()
    let launch = Date()
    private(set) var lastActive: [String: Date] = [:]
    /// The frontmost app other than us. Opening the popover makes us frontmost, so this is what the owner was using.
    private(set) var lastOtherFrontmost: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    private var tokens: [NSObjectProtocol] = []

    func start() {
        guard tokens.isEmpty else { return }
        let own = Bundle.main.bundleIdentifier
        let center = NSWorkspace.shared.notificationCenter
        // Activation and deactivation both count: an app used for an hour was active until it lost focus.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier else { return }
                self?.lastActive[id] = Date()
                if name == NSWorkspace.didActivateApplicationNotification, id != own { self?.lastOtherFrontmost = id }
            })
        }
    }
}

/// One cleanable group of files. Paths are deleted one by one, each checked against `root`.
struct CleanTarget: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case logs, caches, npmCache, brewCache, pipCache, yarnCache, simulators, derivedData, nodeModules, trash
    }
    var kind: Kind
    var root: String
    var paths: [String]
    var bytes: UInt64?       // nil when it could not be read (the trash without Full Disk Access)
    var recommended: Bool
    var blocked: String? = nil       // a tool using it is running: shown disabled with this reason
    var command: [String]? = nil     // run before the paths go (xcrun simctl delete unavailable)
    var commandBytes: UInt64 = 0     // what the command frees when it succeeds
    var count = 0                    // unavailable simulators
    var projects: [NodeProject] = [] // nodeModules: one per project, paths mirror it
    var partial = false              // nodeModules: the search ran out of time, more may exist
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .logs: return L("오래된 로그")
        case .caches: return L("앱 캐시")
        case .npmCache: return L("npm 캐시")
        case .brewCache: return L("Homebrew 캐시")
        case .pipCache: return L("pip 캐시")
        case .yarnCache: return L("Yarn 캐시")
        case .simulators: return L("iOS 시뮬레이터")
        case .nodeModules: return L("오래된 node_modules")
        case .derivedData: return L("Xcode 빌드 캐시")
        case .trash: return L("휴지통 비우기")
        }
    }

    var detail: String {
        switch kind {
        case .logs: return L("7일 지난 로그 \(paths.count)개")
        case .caches: return L("지금 안 쓰는 앱 캐시 \(paths.count)개")
        case .npmCache: return L("~/.npm/_cacache, 다음 설치 때 다시 받아요")
        case .brewCache: return L("받아 둔 설치 파일, 다음 설치 때 다시 받아요")
        case .pipCache, .yarnCache: return L("내려받기 캐시, 다음 설치 때 다시 받아요")
        case .simulators: return (count > 0 ? L("못 쓰는 시뮬레이터 \(count)대 · ") : "") + L("시뮬레이터 캐시")
        case .nodeModules: return L("30일 넘게 안 쓴 프로젝트 \(projects.count)개\(partial ? "+" : "") · 다시 쓰려면 npm install")
        case .derivedData: return L("DerivedData, 다음 빌드가 조금 느려져요")
        case .trash: return L("되돌릴 수 없어요")
        }
    }

    var symbol: String {
        switch kind {
        case .logs: return "doc.text"
        case .caches: return "shippingbox"
        case .npmCache, .yarnCache: return "cube.box"
        case .brewCache: return "mug"
        case .pipCache: return "puzzlepiece.extension"
        case .simulators: return "iphone"
        case .nodeModules: return "folder.badge.minus"
        case .derivedData: return "hammer"
        case .trash: return "trash"
        }
    }
}

struct CleanerScan {
    var apps: [CleanerCandidate]
    var files: [CleanTarget]
    var runaways: [RunawayCandidate] = []
    var agents: [LaunchAgent] = []
}

enum Cleaner {
    /// What the scan needs from NSWorkspace, read on the main thread.
    struct AppRef {
        var pid: pid_t
        var bundleID: String
        var name: String
        var path: String
        var launch: Date?
        var lastActive: Date?
    }

    // MARK: Apps

    @MainActor
    static func runningApps() -> [AppRef] {
        let tracker = ActivityTracker.shared
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier,
                  let path = app.bundleURL?.path, app.processIdentifier != getpid() else { return nil }
            return AppRef(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id, path: path,
                          launch: app.launchDate, lastActive: tracker.lastActive[id])
        }
    }

    /// Bundle ids of every running app, menu bar apps and agents included, plus ourselves.
    /// Cache folders of these are never offered.
    @MainActor
    static func runningIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) + [Bundle.main.bundleIdentifier].compactMap { $0 }
    }

    /// Two usage samples `window` seconds apart; memory and CPU summed over each app and its helpers.
    /// Apps NSWorkspace still lists after they quit are dropped.
    static func measure(_ refs: [AppRef], window: TimeInterval = 1, ourLaunch: Date) -> [CleanerApp] {
        let paths = processPaths()
        let refs = refs.map { r -> AppRef in var r = r; r.path = SafePath.real(r.path) ?? r.path; return r }
            .filter { CleanerRules.isAlive(pid: $0.pid, bundlePath: $0.path, processPaths: paths) }
        let responsible = paths.filter { $0.value.contains(".xpc/") }.keys.reduce(into: [pid_t: pid_t]()) { out, pid in
            if let r = responsibleFor(pid) { out[pid] = r }
        }
        let groups = CleanerRules.group(processPaths: paths, bundles: refs.map { ($0.pid, $0.path) }, responsible: responsible)
        let awake = awakePids()
        let pids = Set(groups.values.joined())
        let first = pids.reduce(into: [pid_t: rusage_info_v2]()) { $0[$1] = usage(of: $1) }
        let t0 = Date()
        Thread.sleep(forTimeInterval: window)
        let second = pids.reduce(into: [pid_t: rusage_info_v2]()) { $0[$1] = usage(of: $1) }
        let elapsed = max(0.1, Date().timeIntervalSince(t0))
        let now = Date()

        return refs.map { ref in
            var memory: UInt64 = 0, cpuNs: Double = 0
            for pid in groups[ref.pid] ?? [ref.pid] {
                guard let b = second[pid] else { continue }
                memory += b.ri_phys_footprint
                if let a = first[pid] {
                    let ticks = (b.ri_user_time &+ b.ri_system_time) &- (a.ri_user_time &+ a.ri_system_time)
                    if ticks < UInt64(1) << 62 { cpuNs += nanoseconds(ticks) }   // a wrapped delta means pid reuse
                }
            }
            let idle = CleanerRules.idle(now: now, lastActive: ref.lastActive, appLaunch: ref.launch, ourLaunch: ourLaunch)
            let group = groups[ref.pid] ?? [ref.pid]
            return CleanerApp(pid: ref.pid, bundleID: ref.bundleID, name: ref.name, path: ref.path, memory: memory,
                              cpu: cpuNs / 1e9 / elapsed, idle: idle.seconds, idleAtLeast: idle.atLeast,
                              inUse: group.contains(where: awake.contains))
        }
    }

    /// Executable path of every process we can see.
    static func processPaths() -> [pid_t: String] {
        Dictionary(allPids().compactMap { pid in path(of: pid).map { (pid, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Pids holding an assertion that keeps the Mac or its display awake (video, calls, recordings, renders).
    static func awakePids() -> Set<pid_t> {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
              let byPid = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let kinds: Set<String> = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep",
                                  "NoDisplaySleepAssertion", "NoIdleSleepAssertion"]
        var out = Set<pid_t>()
        for (pid, list) in byPid {
            for a in list where kinds.contains(a[kIOPMAssertionTypeKey] as? String ?? "") {
                out.insert(pid.int32Value)
                if let onBehalf = a["AssertionOnBehalfOfPID"] as? NSNumber { out.insert(onBehalf.int32Value) }
            }
        }
        return out
    }

    /// The app macOS holds responsible for `pid` (what Activity Monitor groups by). Private libsystem call,
    /// looked up at run time so a missing symbol only loses the WebKit attribution.
    private static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsibleFor(_ pid: pid_t) -> pid_t? {
        guard let r = responsibleFn?(pid), r > 0, r != pid else { return nil }
        return r
    }

    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(max(0, Int(got)))).filter { $0 > 0 }
    }

    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func usage(of pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? info : nil
    }

    /// rusage times are mach ticks on Apple Silicon (and nanoseconds on Intel, where the timebase is 1/1).
    private static let timebase: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (Double(tb.numer), Double(max(1, tb.denom)))
    }()

    static func nanoseconds(_ ticks: UInt64) -> Double { Double(ticks) * timebase.numer / timebase.denom }

    // MARK: Files

    /// Everything under `home` that the cleaner offers, with sizes. Slow on big caches: call off the main thread.
    static func scanFiles(home: URL, runningIDs: [String], xcodeRunning: Bool, now: Date = Date(),
                          processPaths: [String] = Array(Cleaner.processPaths().values),
                          tools: [ToolProc] = Cleaner.toolProcs(), run: CommandRunner = Shell.run,
                          nodeBudget: TimeInterval = NodeModules.searchBudget) -> [CleanTarget] {
        let lib = home.appendingPathComponent("Library").path
        var out: [CleanTarget] = []

        let logs = lib + "/Logs"
        var old: [String] = [], logBytes: UInt64 = 0
        SafePath.walk(logs) { path, st in
            guard path != logs, st.st_mode & S_IFMT != S_IFDIR,
                  now.timeIntervalSince(SafePath.mtime(st)) >= CleanerRules.logAge else { return }
            old.append(path)
            logBytes += UInt64(max(0, st.st_blocks)) * 512
        }
        if !old.isEmpty { out.append(CleanTarget(kind: .logs, root: logs, paths: old, bytes: logBytes, recommended: true)) }

        let caches = lib + "/Caches"
        var dropped: [String] = [], cacheBytes: UInt64 = 0
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: caches)) ?? []).sorted() {
            let dir = caches + "/" + name
            var st = stat()
            guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  CleanerRules.isAppCacheName(name, runningIDs: runningIDs),
                  !CleanerRules.holdsProcess(SafePath.real(dir) ?? dir, processPaths: processPaths) else { continue }
            var newest = SafePath.mtime(st), bytes: UInt64 = 0
            SafePath.walk(dir) { _, s in
                newest = max(newest, SafePath.mtime(s))
                bytes += UInt64(max(0, s.st_blocks)) * 512
            }
            guard CleanerRules.isAppCache(name: name, newestChange: newest, now: now, runningIDs: runningIDs) else { continue }
            dropped.append(dir)
            cacheBytes += bytes
        }
        if !dropped.isEmpty { out.append(CleanTarget(kind: .caches, root: caches, paths: dropped, bytes: cacheBytes, recommended: true)) }
        out += devTargets(home: home, runningIDs: runningIDs, tools: tools, run: run)

        let derived = lib + "/Developer/Xcode/DerivedData"
        if !xcodeRunning, let kids = try? FileManager.default.contentsOfDirectory(atPath: derived), !kids.isEmpty {
            var bytes: UInt64 = 0
            SafePath.walk(derived) { _, s in bytes += UInt64(max(0, s.st_blocks)) * 512 }
            out.append(CleanTarget(kind: .derivedData, root: derived, paths: kids.map { derived + "/" + $0 },
                                   bytes: bytes, recommended: false))
        }

        let node = NodeModules.scan(home: home.path, now: now, processPaths: processPaths, tools: tools, budget: nodeBudget)
        if !node.projects.isEmpty {
            out.append(CleanTarget(kind: .nodeModules, root: home.path, paths: node.projects.map(\.modules),
                                   bytes: node.projects.map(\.bytes).reduce(0, +), recommended: false,
                                   projects: node.projects, partial: !node.complete))
        }

        // The trash is emptied by Finder; reading its size needs Full Disk Access, so it may stay unknown.
        let trash = home.appendingPathComponent(".Trash").path
        let trashKids = try? FileManager.default.contentsOfDirectory(atPath: trash)
        var trashStat = stat()
        if lstat(trash, &trashStat) == 0, trashKids?.isEmpty != true {   // exists, and full or unreadable
            var bytes: UInt64 = 0
            if trashKids != nil { SafePath.walk(trash) { _, s in bytes += UInt64(max(0, s.st_blocks)) * 512 } }
            out.append(CleanTarget(kind: .trash, root: trash, paths: [], bytes: trashKids == nil ? nil : bytes, recommended: false))
        }
        return out
    }

    /// Deletes the chosen file groups (not the trash, see emptyTrash). Returns bytes freed.
    /// Blocked groups are skipped; node_modules go only when the path passes NodeModules.deletable.
    static func delete(_ targets: [CleanTarget], run: CommandRunner = Shell.run) -> UInt64 {
        var freed: UInt64 = 0
        for t in targets where t.kind != .trash && t.blocked == nil {
            if let cmd = t.command, run(cmd).status == 0 { freed += t.commandBytes }
            for p in t.paths {
                if t.kind == .nodeModules, !NodeModules.deletable(p, home: t.root) { continue }
                freed += SafePath.delete(p, inside: t.root) ?? 0
            }
        }
        return freed
    }

    /// Asks Finder to empty the trash. The first time macOS asks the owner to allow automation.
    @MainActor
    static func emptyTrash() -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: Whole scan

    /// Blocking scan for the CLI and QA renders (about one second).
    @MainActor
    static func scanNow(protected: Set<String> = CleanerProtection.load()) -> CleanerScan {
        let refs = runningApps()
        let apps = measure(refs, ourLaunch: ActivityTracker.shared.launch)
        let candidates = CleanerRules.candidates(apps, protected: protected, frontmost: ActivityTracker.shared.lastOtherFrontmost,
                                                 own: Bundle.main.bundleIdentifier)
        let running = runningIDs(), paths = Array(processPaths().values)
        let files = scanFiles(home: FileManager.default.homeDirectoryForCurrentUser, runningIDs: running,
                              xcodeRunning: CleanerRules.xcodeBusy(runningIDs: running, processPaths: paths), processPaths: paths)
        return CleanerScan(apps: candidates, files: files,
                           runaways: RunawayTracker.shared.candidates(),
                           agents: LaunchAgents.scan())
    }

    /// --cleaner-dry-run: prints what 정리하기 would do with the recommended picks. Quits and deletes nothing.
    @MainActor
    static func dryRun() {
        let scan = scanNow()
        let m = MemorySampler.sample()
        print("클리너 미리보기: 아무것도 종료하거나 지우지 않아요")
        print("메모리 사용 \(Fmt.mem(m.used)) / \(Fmt.mem(m.total)) · 압력 \(Fmt.percent1(m.pressure)) (\(m.pressureLevel.rawValue))")
        print("\n[안 쓰는 앱 종료] 추천 \(scan.apps.filter(\.recommended).count) / 후보 \(scan.apps.count)")
        for c in scan.apps {
            let mark = c.isProtected ? "[보호]" : c.recommended ? "[종료]" : "[ 둠 ]"
            print("  \(mark) \(c.app.name) (\(c.app.bundleID)) · \(CleanerText.appLine(c.app))")
        }
        RunawayTracker.dryRun()
        print("\n[정리할 파일]")
        if scan.files.isEmpty { print("  정리할 파일이 없어요") }
        for t in scan.files {
            let mark = t.blocked != nil ? "[막힘]" : t.recommended ? "[삭제]" : "[ 둠 ]"
            print("  \(mark) \(t.title) · \(t.blocked ?? t.detail) · \(t.bytes.map(Fmt.size) ?? "크기 모름")")
            if let cmd = t.command { print("      실행할 명령: \(cmd.joined(separator: " ")) (\(Fmt.size(t.commandBytes)))") }
            if t.kind == .nodeModules {
                for p in t.projects { print("      \(RunawayRules.pathHint(p.project)) · \(Fmt.size(p.bytes)) · \(CleanerText.lastUsed(p.lastUsed))") }
                continue
            }
            for p in t.paths.prefix(8) { print("      \(p)") }
            if t.paths.count > 8 { print("      외 \(t.paths.count - 8)개") }
        }
        print("\n[로그인·백그라운드 항목] ~/Library/LaunchAgents (끄기는 항목마다 따로, 정리하기에 안 들어가요)")
        if scan.agents.isEmpty { print("  없음") }
        for a in scan.agents {
            let state = a.disabled ? "꺼 둠(캐릭모니터)" : a.pid > 0 ? "실행 중(PID \(a.pid))" : a.state
            print("  \(a.label)\(a.mine ? " [내가 만든 항목]" : "") · \(state) · \(a.when) · \(RunawayRules.pathHint(a.program))")
        }
        print("  앱이 등록한 로그인 항목은 목록을 읽을 방법이 없어요: 시스템 설정 > 일반 > 로그인 항목")
        let quit = scan.apps.filter(\.recommended)
        let bytes = scan.files.filter { $0.recommended && $0.blocked == nil }.compactMap(\.bytes).reduce(0, +)
        print("\n추천대로 정리하면: 앱 \(quit.count)개 종료 요청(\(Fmt.mem(quit.map(\.app.memory).reduce(0, +)))), 파일 \(Fmt.size(bytes)) 확보")
    }
}

/// Apps the owner locked against quitting. Stored as the full set once the owner changes anything.
enum CleanerProtection {
    private static let key = "cleanerProtected"

    static func load() -> Set<String> {
        (AppDefaults.store.array(forKey: key) as? [String]).map(Set.init) ?? CleanerRules.defaultProtected
    }

    static func save(_ ids: Set<String>) { AppDefaults.store.set(ids.sorted(), forKey: key) }
}

enum CleanerText {
    static func idle(_ app: CleanerApp) -> String {
        let minutes = Int(app.idle / 60)
        if minutes < 1 { return app.idleAtLeast ? L("아직 지켜보는 중") : L("방금 씀") }
        return app.idleAtLeast ? L("\(Fmt.duration(minutes: minutes)) 넘게 안 씀") : L("\(Fmt.duration(minutes: minutes))째 안 씀")
    }

    static func lastUsed(_ date: Date, now: Date = Date()) -> String {
        L("\(Int(now.timeIntervalSince(date) / 86_400))일 전에 마지막으로 씀")
    }

    static func appLine(_ app: CleanerApp) -> String {
        "\(Fmt.mem(app.memory)) · CPU \(String(format: "%.0f%%", app.cpu * 100)) · \(idle(app))" + (app.inUse ? L(" · 재생·작업 중") : "")
    }
}
#endif
