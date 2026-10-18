#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import Darwin
import Foundation

// Developer caches (npm, Homebrew, pip, Yarn, iOS simulators), node_modules of long untouched projects,
// and the owner's launch agents. Rules are pure; commands go through an injectable runner so tests never
// touch the real npm, simctl or launchctl.

/// Runs a program (argv[0] is an absolute path) and returns its exit status and standard output.
typealias CommandRunner = (_ argv: [String]) -> (status: Int32, out: String)

enum Shell {
    private final class Box { var data = Data() }

    /// A child that overruns `timeout` gets SIGTERM. It is our own child, never anyone else's process.
    static func run(_ argv: [String]) -> (status: Int32, out: String) { run(argv, timeout: 60) }

    static func run(_ argv: [String], timeout: TimeInterval) -> (status: Int32, out: String) {
        guard let exe = argv.first else { return (-1, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return (-1, "")
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }
}

/// One of the owner's processes, as much as the blocking rules need.
struct ToolProc: Equatable {
    var name: String      // pbi_name: "node" for npm, whose title lives in args[0] ("npm install", "npm exec …")
    var path: String      // executable
    var args: [String]    // only read for interpreters (node, ruby, python, shells)
    var age: TimeInterval
    var cwd: String? = nil
}

enum DevCacheRules {
    /// An `npm exec` / npx process this old (an MCP server, say) fetched its package at start and only runs it now.
    static let serveGrace: TimeInterval = 300

    private static let npmWords: Set<String> = ["npm", "npx", "npm-cli.js", "npx-cli.js", "pnpm", "pnpm.cjs", "pnpm.js", "pnpx",
                                                "yarn", "yarn.js", "yarn.cjs", "yarnpkg"]
    private static let yarnWords: Set<String> = ["yarn", "yarn.js", "yarn.cjs", "yarnpkg"]
    private static let simWords: Set<String> = ["Simulator", "simctl", "xcodebuild", "Xcode"]

    /// npm sets process.title, which rewrites argv[0] to "npm install" / "npm exec @x/y"; the kernel name stays "node".
    static func title(_ p: ToolProc) -> String { p.args.first ?? p.name }

    static func words(_ p: ToolProc) -> Set<String> {
        let base = { (s: String) in (s as NSString).lastPathComponent }
        let first = { (s: String) in String(s.split(separator: " ").first ?? "") }
        return Set([first(p.name), first(title(p)), base(p.path)] + p.args.prefix(3).map(base))
    }

    static func uses(_ p: ToolProc, _ kind: CleanTarget.Kind) -> Bool {
        let w = words(p)
        switch kind {
        case .npmCache:
            guard !w.isDisjoint(with: npmWords) else { return false }
            let serving = p.name.hasPrefix("npm exec") || title(p).hasPrefix("npm exec") || w.contains("npx") || w.contains("npx-cli.js")
                || p.args.dropFirst().prefix(2).contains("exec")
            return !(serving && p.age >= serveGrace)
        case .brewCache:
            return !w.isDisjoint(with: ["brew", "brew.sh", "brew.rb"]) || p.path.contains("/Library/Homebrew/")
        case .pipCache:
            return w.contains { $0.range(of: #"^pip[0-9.]*$"#, options: .regularExpression) != nil }
                || zip(p.args, p.args.dropFirst()).contains { $0 == "-m" && $1 == "pip" }
        case .yarnCache: return !w.isDisjoint(with: yarnWords)
        case .simulators: return !w.isDisjoint(with: simWords)
        default: return false
        }
    }

    /// Why this cache is left alone right now, or nil when it may go.
    static func blocker(_ kind: CleanTarget.Kind, tools: [ToolProc], runningIDs: [String]) -> String? {
        if kind == .simulators, runningIDs.contains(where: { $0 == "com.apple.iphonesimulator" || $0 == "com.apple.dt.Xcode" }) {
            return L("Xcode나 시뮬레이터가 켜져 있어 이번엔 건너뛰어요")
        }
        guard let p = tools.first(where: { uses($0, kind) }) else { return nil }
        let t = title(p).hasPrefix("npm") ? title(p) : p.name
        let who = String(t.split(separator: " ").first ?? "")
        return L("\(who.isEmpty ? L("설치 도구") : who) 실행 중이라 이번엔 건너뛰어요")
    }

    /// Udids from `xcrun simctl list devices unavailable -j`, only ones shaped like a udid.
    static func unavailableDevices(json: String) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let byRuntime = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        return byRuntime.values.joined().compactMap { d in
            guard (d["isAvailable"] as? Bool) != true, let u = d["udid"] as? String,
                  u.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil else { return nil }
            return u
        }.sorted()
    }
}

/// node_modules of a project nobody touched for 30 days.
struct NodeProject: Identifiable, Equatable {
    var modules: String      // …/project/node_modules
    var bytes: UInt64
    var lastUsed: Date
    var id: String { modules }
    var project: String { (modules as NSString).deletingLastPathComponent }
    var name: String { (project as NSString).lastPathComponent }
}

enum NodeModules {
    static let staleAge: TimeInterval = 30 * 86_400
    static let maxDepth = 5
    static let searchBudget: TimeInterval = 15
    /// Home folders never searched: Library and apps, and the ones macOS guards with a permission prompt.
    static let skipAtHome: Set<String> = ["Library", "Applications", "Desktop", "Documents", "Downloads",
                                          "Pictures", "Movies", "Music", "Public"]
    static let walkCap = 20_000
    /// Without one, npm install may resolve other versions, so the project would not come back as it was.
    static let lockfiles = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]

    static func hasLockfile(_ modules: String) -> Bool {
        let project = (modules as NSString).deletingLastPathComponent
        return lockfiles.contains { FileManager.default.fileExists(atPath: project + "/" + $0) }
    }

    /// A program runs from the project, in it (its working folder), or on a file in it
    /// (`node …/node_modules/vite/bin/vite.js`): a dev server that is up for days still counts as use.
    static func inUse(_ modules: String, processPaths: [String], tools: [ToolProc]) -> Bool {
        let project = (modules as NSString).deletingLastPathComponent
        let projects = Set([project, SafePath.real(project) ?? project])
        func inside(_ p: String) -> Bool { projects.contains { p == $0 || p.hasPrefix($0 + "/") } }
        return processPaths.contains(where: inside) || tools.contains { t in (t.cwd.map(inside) ?? false) || t.args.contains(where: inside) }
    }

    /// node_modules folders (real ones, not links) up to five levels below home, never inside hidden folders
    /// or other node_modules. `complete` is false when the time budget ran out.
    static func find(home: String, deadline: Date) -> (paths: [String], complete: Bool) {
        var out: [String] = [], complete = true
        func visit(_ dir: String, depth: Int) {
            guard depth < maxDepth else { return }
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
                guard Date() < deadline else { complete = false; return }
                guard !name.hasPrefix("."), !(depth == 0 && skipAtHome.contains(name)) else { continue }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                if name == "node_modules" { out.append(path) } else if !name.hasSuffix(".app") { visit(path, depth: depth + 1) }
            }
        }
        visit(home, depth: 0)
        return (out, complete)
    }

    /// Newest change in the project, node_modules folders excluded, plus node_modules/.package-lock.json
    /// (rewritten by every npm install). Hidden entries count but are not entered; for .git the last commit
    /// or checkout (logs/HEAD) counts. nil when it cannot tell.
    // ponytail: files deeper than 4 levels are only seen through their folders' mtimes; raise the depth if that misses edits.
    static func lastUsed(modules: String) -> Date? {
        let project = (modules as NSString).deletingLastPathComponent
        var st = stat()
        guard lstat(project, &st) == 0 else { return nil }
        var newest = SafePath.mtime(st), seen = 0
        func visit(_ dir: String, depth: Int) -> Bool {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name != "node_modules" {
                seen += 1
                if seen > walkCap { return false }
                // .git itself changes whenever anything runs `git status`; a commit or checkout writes logs/HEAD.
                let path = dir + "/" + name + (name == ".git" ? "/logs/HEAD" : "")
                var s = stat()
                guard lstat(path, &s) == 0 else { continue }
                newest = max(newest, SafePath.mtime(s))
                if s.st_mode & S_IFMT == S_IFDIR, !name.hasPrefix("."), depth < 4, !visit(path, depth: depth + 1) { return false }
            }
            return true
        }
        guard visit(project, depth: 0) else { return nil }
        if lstat(modules + "/.package-lock.json", &st) == 0 { newest = max(newest, SafePath.mtime(st)) }
        return newest
    }

    static func isStale(_ modules: String, now: Date) -> Bool {
        lastUsed(modules: modules).map { now.timeIntervalSince($0) >= staleAge } ?? false
    }

    /// Only a real folder literally named node_modules, strictly inside home.
    static func deletable(_ path: String, home: String) -> Bool {
        var st = stat()
        return (path as NSString).lastPathComponent == "node_modules"
            && lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
            && SafePath.resolve(path, inside: home) != nil
    }

    static func scan(home: String, now: Date, processPaths: [String], tools: [ToolProc] = [], budget: TimeInterval = searchBudget)
        -> (projects: [NodeProject], complete: Bool) {
        let found = find(home: home, deadline: Date().addingTimeInterval(budget))
        let projects = found.paths.compactMap { m -> NodeProject? in
            guard deletable(m, home: home), hasLockfile(m), let used = lastUsed(modules: m), now.timeIntervalSince(used) >= staleAge,
                  !inUse(m, processPaths: processPaths, tools: tools) else { return nil }
            var bytes: UInt64 = 0
            SafePath.walk(m) { _, s in bytes += UInt64(max(0, s.st_blocks)) * 512 }
            return NodeProject(modules: m, bytes: bytes, lastUsed: used)
        }
        return (projects.sorted { $0.bytes > $1.bytes }, found.complete)
    }
}

extension Cleaner {
    /// The owner's processes with names, working folders and, for interpreters, arguments. For the blocking rules.
    static func toolProcs(now: Date = Date()) -> [ToolProc] {
        let uid = getuid()
        let interpreters = #"^(node|bun|deno|ruby|bash|sh|zsh|[Pp]ython.*)$"#
        return allPids().compactMap { pid in
            guard let row = RunawayTracker.row(pid), row.uid == uid, let path = path(of: pid) else { return nil }
            let base = (path as NSString).lastPathComponent
            let args = base.range(of: interpreters, options: .regularExpression) != nil ? arguments(of: pid) : []
            return ToolProc(name: row.name, path: path, args: args, age: now.timeIntervalSince1970 - Double(row.start) / 1e6,
                            cwd: cwd(of: pid))
        }
    }

    /// Working folder of one of the owner's processes, nil when unreadable.
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// argv of one of the owner's processes (KERN_PROCARGS2), empty when unreadable.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }   // exec path
        while i < size, buf[i] == 0 { i += 1 }   // padding
        var out: [String] = []
        while out.count < argc, i < size {
            let s = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// npm, Homebrew, pip, Yarn and simulator targets under `home`, blocked while their tool runs.
    static func devTargets(home: URL, runningIDs: [String], tools: [ToolProc], run: CommandRunner) -> [CleanTarget] {
        let fm = FileManager.default
        let lib = home.appendingPathComponent("Library").path
        func size(_ path: String) -> UInt64 {
            var b: UInt64 = 0
            SafePath.walk(path) { _, s in b += UInt64(max(0, s.st_blocks)) * 512 }
            return b
        }
        func target(_ kind: CleanTarget.Kind, root: String, paths: [String], extra: UInt64 = 0) -> CleanTarget {
            let blocked = DevCacheRules.blocker(kind, tools: tools, runningIDs: runningIDs)
            return CleanTarget(kind: kind, root: root, paths: paths, bytes: paths.map(size).reduce(extra, +),
                               recommended: blocked == nil, blocked: blocked)
        }
        func kids(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().map { dir + "/" + $0 }
        }
        var out: [CleanTarget] = []
        let npm = home.appendingPathComponent(".npm").path
        if fm.fileExists(atPath: npm + "/_cacache") { out.append(target(.npmCache, root: npm, paths: [npm + "/_cacache"])) }
        for (kind, name) in [(CleanTarget.Kind.brewCache, "Homebrew"), (.pipCache, "pip"), (.yarnCache, "Yarn")] {
            let root = lib + "/Caches/" + name
            let paths = kids(root)
            if !paths.isEmpty { out.append(target(kind, root: root, paths: paths)) }
        }

        let sim = lib + "/Developer/CoreSimulator"
        let caches = kids(sim + "/Caches")
        var devices: [String] = []
        // xcrun without Xcode or its tools would pop the install dialog, so ask xcode-select first.
        if fm.fileExists(atPath: sim + "/Devices"), run(["/usr/bin/xcode-select", "-p"]).status == 0 {
            let r = run(["/usr/bin/xcrun", "simctl", "list", "devices", "unavailable", "-j"])
            if r.status == 0 { devices = DevCacheRules.unavailableDevices(json: r.out) }
        }
        if !caches.isEmpty || !devices.isEmpty {
            let deviceBytes = devices.map { size(sim + "/Devices/" + $0) }.reduce(0, +)
            var t = target(.simulators, root: sim + "/Caches", paths: caches, extra: deviceBytes)
            t.count = devices.count
            if !devices.isEmpty { t.command = ["/usr/bin/xcrun", "simctl", "delete", "unavailable"]; t.commandBytes = deviceBytes }
            out.append(t)
        }
        return out
    }
}

/// A plist in ~/Library/LaunchAgents: what it starts and when, whether launchd has it loaded or running,
/// whether we parked it.
struct LaunchAgent: Identifiable, Equatable {
    var label: String
    var program: String
    var plist: String
    var loaded: Bool
    var disabled: Bool     // parked by us in the "젤리 모니터가 끈 항목" folder
    var pid: pid_t = 0     // running right now when > 0
    var when = ""          // "로그인 때", "매일 09:00", "30분마다", "항상" …
    var mine = false       // runs a program in the owner's own folders (a script of theirs), not an app's updater
    var id: String { plist }
    var state: String { disabled ? L("꺼 둠") : pid > 0 ? L("실행 중") : loaded ? L("켜짐") : L("등록만 됨") }
}

enum LaunchAgents {
    static let parkedName = "젤리 모니터가 끈 항목"
    static let loginItemsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    static var userDir: String { NSHomeDirectory() + "/Library/LaunchAgents" }
    static var own: String { Bundle.main.bundleIdentifier ?? "com.jelly.dogmonitor" }

    /// Label to PID from `launchctl list`; 0 when loaded but not running ("-"). nil when launchctl failed.
    static func jobs(run: CommandRunner) -> [String: pid_t]? {
        let r = run(["/bin/launchctl", "list"])
        guard r.status == 0 else { return nil }
        var out: [String: pid_t] = [:]
        for line in r.out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if cols.count >= 3 { out[String(cols[2])] = pid_t(cols[0]) ?? 0 }
        }
        return out
    }

    /// Pids of every job launchd runs for the owner right now.
    static func runningPids(run: CommandRunner) -> Set<pid_t> { Set((jobs(run: run) ?? [:]).values.filter { $0 > 0 }) }

    /// When launchd starts the job, in a few words.
    static func schedule(_ d: [String: Any], now: Date = Date()) -> String {
        var parts: [String] = []
        if d["RunAtLoad"] as? Bool == true { parts.append(L("로그인 때")) }
        if let s = d["StartInterval"] as? Int, s > 0 {
            parts.append(s % 86_400 == 0 ? L("\(s / 86_400)일마다") : s % 3600 == 0 ? L("\(s / 3600)시간마다")
                         : s % 60 == 0 ? L("\(s / 60)분마다") : L("\(s)초마다"))
        }
        let cal = (d["StartCalendarInterval"] as? [[String: Int]]) ?? (d["StartCalendarInterval"] as? [String: Int]).map { [$0] } ?? []
        if let c = cal.first { parts.append(calendar(c, now: now) + (cal.count > 1 ? L(" 외 \(cal.count - 1)개") : "")) }
        if let k = d["KeepAlive"], (k as? Bool) ?? true { parts.append(L("항상")) }
        if d["WatchPaths"] != nil || d["QueueDirectories"] != nil { parts.append(L("파일이 바뀔 때")) }
        return parts.isEmpty ? L("불릴 때만") : parts.joined(separator: " · ")
    }

    private static func calendar(_ c: [String: Int], now: Date) -> String {
        let time = String(format: "%02d:%02d", c["Hour"] ?? 0, c["Minute"] ?? 0)
        if let y = c["Year"], let m = c["Month"], let day = c["Day"] {
            let at = DateComponents(calendar: Calendar.current, year: y, month: m, day: day, hour: c["Hour"], minute: c["Minute"]).date
            return String(format: "%d-%02d-%02d ", y, m, day) + time + (at.map { $0 < now } == true ? L(" 한 번(지남)") : L(" 한 번"))
        }
        if let w = c["Weekday"] { return L("매주 \([L("일"), L("월"), L("화"), L("수"), L("목"), L("금"), L("토")][((w % 7) + 7) % 7]) ") + time }
        if let day = c["Day"] { return L("매달 \(day)일 ") + time }
        if c["Hour"] != nil { return L("매일 ") + time }
        return L("매시 \(String(format: "%02d", c["Minute"] ?? 0))분")
    }

    /// A program in the owner's own folders (a script of theirs), not in Library, Applications or a hidden folder.
    static func isMine(_ program: String, home: String = NSHomeDirectory()) -> Bool {
        program.hasPrefix(home + "/") && !["/Library/", "/Applications/", "/."].contains { program.hasPrefix(home + $0) }
    }

    /// Agents in `dir` and in its parked folder, Apple's and our own left out.
    static func list(dir: String, jobs: [String: pid_t], own: String = own, home: String = NSHomeDirectory(),
                     now: Date = Date()) -> [LaunchAgent] {
        let parked = dir + "/" + parkedName
        let fm = FileManager.default
        let all = [(dir, false), (parked, true)].flatMap { folder, disabled in
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".plist") }.map { (folder + "/" + $0, disabled) }
        }
        return all.compactMap { path, disabled in
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  let data = fm.contents(atPath: path),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = dict["Label"] as? String,
                  !label.hasPrefix("com.apple."), !label.hasPrefix(own) else { return nil }
            let args = dict["ProgramArguments"] as? [String] ?? []
            let program = dict["Program"] as? String ?? args.dropFirst().last(where: { $0.hasPrefix("/") }) ?? args.first ?? "?"
            return LaunchAgent(label: label, program: program, plist: path, loaded: jobs[label] != nil, disabled: disabled,
                               pid: disabled ? 0 : jobs[label] ?? 0, when: schedule(dict, now: now), mine: isMine(program, home: home))
        }
        .sorted { ($0.disabled ? 1 : 0, $0.label) < ($1.disabled ? 1 : 0, $1.label) }
    }

    static func scan(run: CommandRunner = Shell.run) -> [LaunchAgent] {
        list(dir: userDir, jobs: jobs(run: run) ?? [:])
    }

    /// Parks the plist so the agent stays off after login, and unloads it. A job that is running right now
    /// is left alone: bootout would SIGTERM (then SIGKILL) its run, a deploy or a compile partway through.
    /// Returns an error to show, nil on success.
    static func disable(_ a: LaunchAgent, dir: String, uid: uid_t = getuid(), run: CommandRunner) -> String? {
        guard !a.disabled, (a.plist as NSString).deletingLastPathComponent == dir else { return L("이미 꺼 둔 항목이에요") }
        guard let now = jobs(run: run) else { return L("launchctl 을 읽지 못해 끄지 않았어요") }   // fresh: it may have started since the scan
        if let pid = now[a.label], pid > 0 { return L("\(a.label) 은(는) 지금 실행 중(PID \(pid))이라 끄지 않았어요. 끝난 뒤 다시 눌러 주세요") }
        if now[a.label] != nil, run(["/bin/launchctl", "bootout", "gui/\(uid)/\(a.label)"]).status != 0 {
            return L("\(a.label) 을(를) 끄지 못했어요")
        }
        let parked = dir + "/" + parkedName
        do {
            try FileManager.default.createDirectory(atPath: parked, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: a.plist, toPath: parked + "/" + (a.plist as NSString).lastPathComponent)
        } catch {
            return L("껐지만 파일을 옮기지 못해 다음 로그인 때 다시 켜져요")
        }
        return nil
    }
    /// Moves a parked plist back and loads it again.
    static func enable(_ a: LaunchAgent, dir: String, uid: uid_t = getuid(), run: CommandRunner) -> String? {
        guard a.disabled else { return L("이미 켜진 항목이에요") }
        let back = dir + "/" + (a.plist as NSString).lastPathComponent
        do { try FileManager.default.moveItem(atPath: a.plist, toPath: back) } catch {
            return L("같은 이름의 파일이 있어 되돌리지 못했어요")
        }
        if run(["/bin/launchctl", "bootstrap", "gui/\(uid)", back]).status != 0 {
            return L("파일은 되돌렸어요. 다음 로그인 때 켜져요")
        }
        return nil
    }
}
#endif
