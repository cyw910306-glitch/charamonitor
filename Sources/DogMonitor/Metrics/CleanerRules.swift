#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import Darwin
import Foundation

// Pure decisions of the cleaner: which apps to suggest quitting, which cache folders are safe to drop,
// and whether a path may be deleted at all. No AppKit here, so the tests can drive every rule.

/// One running app as the cleaner sees it.
struct CleanerApp: Identifiable, Equatable {
    var pid: pid_t
    var bundleID: String
    var name: String
    var path: String          // bundle path, for the icon
    var memory: UInt64        // phys_footprint of the app plus its helper processes
    var cpu: Double           // fraction of one core over the scan window, helpers included
    var idle: TimeInterval    // since it was last frontmost
    var idleAtLeast: Bool     // not frontmost since we started, so `idle` is a lower bound
    var inUse = false         // it or a helper keeps the Mac awake: playback, a call, a recording, a render
    var id: pid_t { pid }
}

struct CleanerCandidate: Identifiable, Equatable {
    var app: CleanerApp
    var isProtected: Bool
    var recommended: Bool
    var id: pid_t { app.pid }
}

enum CleanerRules {
    static let idleQuit: TimeInterval = 30 * 60
    static let busyCPU = 0.30
    static let busyIdle: TimeInterval = 10 * 60
    static let logAge: TimeInterval = 7 * 86_400
    static let cacheQuiet: TimeInterval = 60 * 60
    static let finder = "com.apple.finder"

    /// Apps never suggested for quitting unless the owner removes the lock.
    static let defaultProtected: Set<String> = [
        finder, "com.cmuxterm.app", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.anthropic.claudefordesktop", "com.spotify.client", "com.apple.Music", "us.zoom.xos",
        "com.microsoft.teams2", "com.apple.FaceTime", "com.kakao.KakaoTalkMac", "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS", "com.apple.mail",
    ]

    /// Not frontmost does not mean unused: an app holding a sleep assertion is working for the owner.
    static func recommend(_ app: CleanerApp, isProtected: Bool) -> Bool {
        !isProtected && !app.inUse && (app.idle >= idleQuit || (app.cpu >= busyCPU && app.idle >= busyIdle))
    }

    /// Drops ourselves, the frontmost app and Finder, marks protection and the recommendation, biggest first.
    static func candidates(_ apps: [CleanerApp], protected: Set<String>, frontmost: String?, own: String?) -> [CleanerCandidate] {
        let skip = Set([own, frontmost, finder].compactMap { $0 })
        return apps.filter { !skip.contains($0.bundleID) }
            .map { app in
                let locked = protected.contains(app.bundleID)
                return CleanerCandidate(app: app, isProtected: locked, recommended: recommend(app, isProtected: locked))
            }
            .sorted { $0.app.memory > $1.app.memory }
    }

    /// Idle time since the app was last frontmost. Never seen frontmost: counted from whichever is later,
    /// our start or the app's own launch, and flagged as a lower bound.
    static func idle(now: Date, lastActive: Date?, appLaunch: Date?, ourLaunch: Date) -> (seconds: TimeInterval, atLeast: Bool) {
        if let lastActive { return (max(0, now.timeIntervalSince(lastActive)), false) }
        let from = max(ourLaunch, appLaunch ?? ourLaunch)
        return (max(0, now.timeIntervalSince(from)), true)
    }

    /// For each app pid, every pid whose executable sits inside that app's bundle (Chrome helpers and the like).
    /// A process inside nested bundles belongs to the innermost one, so Simulator is not counted under Xcode.
    /// An XPC service outside every bundle (WebKit's WebContent for Safari or Mail) goes to its responsible app;
    /// plain programs do not, so a terminal is not charged for the builds it runs.
    static func group(processPaths: [pid_t: String], bundles: [(pid: pid_t, path: String)],
                      responsible: [pid_t: pid_t] = [:]) -> [pid_t: [pid_t]] {
        let ordered = bundles.sorted { $0.path.count > $1.path.count }
        let appPids = Set(bundles.map(\.pid))
        var out = Dictionary(uniqueKeysWithValues: bundles.map { ($0.pid, [$0.pid]) })
        for (pid, exe) in processPaths {
            let owner = ordered.first(where: { exe.hasPrefix(dir($0.path)) })?.pid
                ?? (exe.contains(".xpc/") ? responsible[pid].flatMap { appPids.contains($0) ? $0 : nil } : nil)
            guard let owner, pid != owner else { continue }
            out[owner, default: [owner]].append(pid)
        }
        return out
    }

    /// NSWorkspace keeps listing some apps after they quit (lsappinfo says "terminated"). A pid that is gone,
    /// or now runs something outside the app's bundle (pid reuse), is not that app.
    static func isAlive(pid: pid_t, bundlePath: String, processPaths: [pid_t: String]) -> Bool {
        processPaths[pid]?.hasPrefix(dir(bundlePath)) ?? false
    }

    /// A cache folder holding a running executable (headless Playwright, a CLI's own binary) is in use.
    static func holdsProcess(_ folder: String, processPaths: [String]) -> Bool {
        let prefix = dir(folder)
        return processPaths.contains { $0.hasPrefix(prefix) }
    }

    /// Xcode, or a build it or a script started, is using DerivedData.
    static func xcodeBusy(runningIDs: [String], processPaths: [String]) -> Bool {
        runningIDs.contains("com.apple.dt.Xcode")
            || processPaths.contains { ["xcodebuild", "XCBBuildService", "SWBBuildService"].contains(($0 as NSString).lastPathComponent) }
    }

    /// Re-checked right before deleting, since apps can start between the scan and the tap:
    /// drops caches that now belong to a running app or process, and DerivedData while Xcode builds.
    /// Developer caches drop while their tool runs; each node_modules must still be 30 days quiet.
    static func recheck(_ targets: [CleanTarget], runningIDs: [String], processPaths: [String],
                        tools: [ToolProc] = [], now: Date = Date()) -> [CleanTarget] {
        targets.compactMap { t in
            switch t.kind {
            case .npmCache, .brewCache, .pipCache, .yarnCache, .simulators:
                return DevCacheRules.blocker(t.kind, tools: tools, runningIDs: runningIDs) == nil ? t : nil
            case .nodeModules:
                var t = t
                t.projects = t.projects.filter {
                    NodeModules.deletable($0.modules, home: t.root) && NodeModules.isStale($0.modules, now: now)
                        && !NodeModules.inUse($0.modules, processPaths: processPaths, tools: tools)
                }
                t.paths = t.projects.map(\.modules)
                return t.paths.isEmpty ? nil : t
            case .caches:
                var t = t
                t.paths = t.paths.filter {
                    isAppCacheName(($0 as NSString).lastPathComponent, runningIDs: runningIDs)
                        && !holdsProcess(SafePath.real($0) ?? $0, processPaths: processPaths)
                }
                return t.paths.isEmpty ? nil : t
            case .derivedData: return xcodeBusy(runningIDs: runningIDs, processPaths: processPaths) ? nil : t
            case .logs, .trash: return t
            }
        }
    }

    private static func dir(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    /// A ~/Library/Caches subfolder we may drop: named like a bundle id, not Apple's, not a running app's
    /// (prefix match either way), and untouched for an hour.
    static func isAppCache(name: String, newestChange: Date?, now: Date, runningIDs: [String]) -> Bool {
        guard let newestChange, isAppCacheName(name, runningIDs: runningIDs) else { return false }
        return now.timeIntervalSince(newestChange) >= cacheQuiet
    }

    /// The name half of isAppCache, checked before walking a folder for its size and newest change.
    static func isAppCacheName(_ name: String, runningIDs: [String]) -> Bool {
        let n = name.lowercased()
        guard n.contains("."), !n.hasPrefix("."), !n.hasPrefix("com.apple.") else { return false }
        return !runningIDs.map { $0.lowercased() }.contains { !$0.isEmpty && (n.hasPrefix($0) || $0.hasPrefix(n)) }
    }
}

/// Deletion that cannot leave its root: symlinks along the path are resolved before the check,
/// the last component is never followed, and the root itself is never a target.
enum SafePath {
    static func real(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// `target` with its parent's symlinks resolved, when it sits strictly inside `root`; nil otherwise.
    static func resolve(_ target: String, inside root: String) -> String? {
        let url = URL(fileURLWithPath: target)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/",
              let parent = real(url.deletingLastPathComponent().path), let base = real(root) else { return nil }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard parent == base || parent.hasPrefix(prefix) else { return nil }
        return (parent.hasSuffix("/") ? parent : parent + "/") + name
    }

    /// Deletes `target` if it is inside `root`. Returns the bytes freed, nil when refused.
    @discardableResult
    static func delete(_ target: String, inside root: String) -> UInt64? {
        guard let path = resolve(target, inside: root) else { return nil }
        return removeTree(path)
    }

    /// Removes a file, a link (not what it points to) or a real directory with its contents.
    /// The walk goes through directory descriptors opened with O_NOFOLLOW, so a folder swapped for a link
    /// mid walk is refused instead of followed. Errors skip that entry and the walk goes on.
    private static func removeTree(_ path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { return 0 }
        defer { close(parent) }
        return removeEntry(url.lastPathComponent, in: parent)
    }

    /// Returns allocated bytes of what was removed.
    private static func removeEntry(_ name: String, in dfd: Int32) -> UInt64 {
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return 0 }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            return unlinkat(dfd, name, 0) == 0 ? UInt64(max(0, st.st_blocks)) * 512 : 0
        }
        let fd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return 0 }
        guard let dir = fdopendir(fd) else { close(fd); return 0 }
        var names: [String] = []
        while let e = readdir(dir) {
            let child = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if child != ".", child != ".." { names.append(child) }
        }
        var freed: UInt64 = 0
        for child in names { freed += removeEntry(child, in: fd) }
        closedir(dir)   // also closes fd
        unlinkat(dfd, name, AT_REMOVEDIR)
        return freed
    }

    /// Visits every non-directory entry under `path` (and `path` itself), never following links.
    static func walk(_ path: String, _ visit: (String, stat) -> Void) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard st.st_mode & S_IFMT == S_IFDIR else { visit(path, st); return }
        visit(path, st)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            walk(path + "/" + child, visit)
        }
    }

    static func mtime(_ st: stat) -> Date {
        Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }
}
#endif
