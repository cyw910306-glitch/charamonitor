#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import AppKit
import Foundation
import Security

// The live side of 보안 점검: read-only commands, plists and code signatures. Commands go through an injectable
// runner and signatures through an injectable checker so tests use fixtures. Nothing here changes the Mac.

enum CodeSigning {
    private static func requirement(_ text: String) -> SecRequirement? {
        var req: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess ? req : nil
    }
    private static let apple = requirement("anchor apple")
    private static let appStore = requirement("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
    private static let notarized = requirement("notarized")

    /// Signature of a binary, script or .app. Resources are not re-hashed (that takes minutes for Xcode-size apps).
    // ponytail: kSecCSDoNotValidateResources misses a tampered resource file; drop the flag if a full check is worth the time.
    static func check(_ path: String) -> CodeSignature {
        guard FileManager.default.fileExists(atPath: path) else { return CodeSignature(state: .missing) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return CodeSignature(state: .unsigned)
        }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status == errSecCSUnsigned { return CodeSignature(state: .unsigned) }
        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if status != errSecSuccess { return CodeSignature(state: .invalid) }
        if codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return CodeSignature(state: .adhoc) }
        func meets(_ r: SecRequirement?) -> Bool { r.map { SecStaticCodeCheckValidity(code, flags, $0) == errSecSuccess } ?? false }
        var sig = CodeSignature(state: .signed, apple: meets(apple), team: info[kSecCodeInfoTeamIdentifier as String] as? String)
        if !sig.apple {
            sig.appStore = meets(appStore)
            sig.notarized = meets(notarized)
            if let cert = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
               let subject = SecCertificateCopySubjectSummary(cert) as String? {
                sig.org = CodeSignature.org(fromSubject: subject)
            }
        }
        return sig
    }
}

enum SecurityScanner {
    static let logTimeout: TimeInterval = 30

    /// Every read-only probe of 기본 보호. `readPlist` reads a root-owned preferences file (they are world-readable).
    static func facts(run: CommandRunner, readPlist: (String) -> [String: Any]? = { NSDictionary(contentsOfFile: $0) as? [String: Any] })
        -> ProtectionFacts {
        var f = ProtectionFacts()
        if let v = SecurityParse.xprotectVersion(run(["/usr/bin/xprotect", "version"]).out) {
            f.xprotectVersion = v.version
            f.xprotectInstalled = v.installed
        }
        (f.launchScans, f.backgroundScans) = SecurityParse.xprotectScans(run(["/usr/bin/xprotect", "status"]).out)
        f.gatekeeper = SecurityParse.onOff(run(["/usr/sbin/spctl", "--status"]).out, on: "assessments enabled", off: "assessments disabled")
        f.sip = SecurityParse.onOff(run(["/usr/bin/csrutil", "status"]).out, on: "status: enabled", off: "status: disabled")
        f.fileVault = SecurityParse.onOff(run(["/usr/bin/fdesetup", "status"]).out, on: "FileVault is On", off: "FileVault is Off")
        f.firewall = SecurityParse.firewall(run(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"]).out)
        let su = readPlist("/Library/Preferences/com.apple.SoftwareUpdate.plist") ?? [:]
        f.autoMacOS = su["AutomaticallyInstallMacOSUpdates"] as? Bool
        f.configData = su["ConfigDataInstall"] as? Bool
        f.critical = su["CriticalUpdateInstall"] as? Bool
        f.autoLoginUser = (readPlist("/Library/Preferences/com.apple.loginwindow.plist")?["autoLoginUser"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // sysadminctl answers on stderr, which the runner drops.
        f.screenLockDelay = SecurityParse.screenLock(run(["/bin/sh", "-c", "/usr/sbin/sysadminctl -screenLock status 2>&1"]).out)
        f.listeningPorts = SecurityParse.listeningPorts(run(["/usr/sbin/netstat", "-an", "-p", "tcp"]).out)
        f.proxies = SecurityParse.proxies(run(["/usr/sbin/scutil", "--proxy"]).out)
        return f
    }

    static var userParked: String { LaunchAgents.userDir + "/" + LaunchAgents.parkedName }

    /// The launchd folders to look in, with the folders our 끄기 parks plists in.
    static func launchDirs(home: String = NSHomeDirectory()) -> [(dir: String, place: LaunchItem.Place, parked: Bool)] {
        let user = home + "/Library/LaunchAgents"
        return [(user, .userAgent, false), (user + "/" + LaunchAgents.parkedName, .userAgent, true),
                ("/Library/LaunchAgents", .agent, false), ("/Library/LaunchDaemons", .daemon, false),
                (AdminCommand.quarantine + "/LaunchAgents", .agent, true), (AdminCommand.quarantine + "/LaunchDaemons", .daemon, true)]
    }

    static func launchItems(dirs: [(dir: String, place: LaunchItem.Place, parked: Bool)], sign: SignatureChecker,
                            home: String = NSHomeDirectory(), own: String = LaunchAgents.own, now: Date = Date()) -> [LaunchItem] {
        let fm = FileManager.default
        var out: [LaunchItem] = []
        for (dir, place, parked) in dirs {
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".plist") {
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, let data = fm.contents(atPath: path),
                      let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = d["Label"] as? String, !label.hasPrefix(own) else { continue }
                var argv = d["ProgramArguments"] as? [String] ?? []
                if let program = d["Program"] as? String { argv = argv.isEmpty ? [program] : [program] + argv.dropFirst() }
                guard !argv.isEmpty else { continue }   // launchd would not run it either
                argv[0] = LaunchRules.resolve(argv[0])
                let (target, interp) = LaunchRules.target(argv)
                let signature = sign(target)
                let fakeApple = label.hasPrefix("com.apple.")
                if fakeApple, signature.apple { continue }   // Apple's own job; a com.apple name on anything else is listed
                let keep = d["KeepAlive"].map { ($0 as? Bool) ?? true } ?? false
                var item = LaunchItem(label: label, plist: path, place: place, argv: argv, target: target, interpreter: interp,
                                      runAtLoad: d["RunAtLoad"] as? Bool == true, keepAlive: keep, modified: SafePath.mtime(st),
                                      mine: LaunchAgents.isMine(target, home: home), parked: parked, signature: signature)
                item.mine = LaunchRules.ownScript(item, home: home)   // the '내가 만든 항목' tag only for the owner's scripts
                (item.level, item.reason) = LaunchRules.judge(item, now: now, home: home)
                if fakeApple {
                    item.level = max(item.level, .warn)
                    item.reason = L("Apple 이름을 쓰지만 Apple 서명이 아니에요 · ") + item.reason
                }
                out.append(item)
            }
        }
        return out.sorted { ($0.parked ? 0 : 1, $0.level, $1.label) > ($1.parked ? 0 : 1, $1.level, $0.label) }
    }

    /// .app bundles at the top of each root and one folder deep, ours left out.
    static func appPaths(roots: [String]) -> [String] {
        let fm = FileManager.default
        return roots.flatMap { root -> [String] in
            ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted().flatMap { name -> [String] in
                let path = root + "/" + name
                if name.hasSuffix(".app") { return [path] }
                var isDir: ObjCBool = false
                guard !name.hasPrefix("."), fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return [] }
                return ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted().filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
            }
        }
    }

    static func apps(roots: [String], sign: SignatureChecker, own: String = LaunchAgents.own) -> [AppFinding] {
        appPaths(roots: roots).compactMap { path in
            let id = (NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String) ?? ""
            guard id != own else { return nil }
            let sig = sign(path)
            guard let (level, reason) = AppRules.judge(sig) else { return nil }
            return AppFinding(name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, path: path, bundleID: id,
                              signature: sig, level: level, reason: reason)
        }
        .sorted { ($0.level, $1.name) > ($1.level, $0.name) }
    }

    /// Last 7 days of XProtect detections, nil when the log did not answer in time.
    static func detections(run: CommandRunner) -> [String]? {
        let r = run(["/usr/bin/log", "show", "--last", "7d", "--style", "compact", "--predicate",
                     #"subsystem BEGINSWITH "com.apple.xprotect" OR subsystem == "com.apple.XProtectFramework""#])
        return r.status == 0 ? SecurityParse.detections(r.out) : nil
    }

    static func scan(run: CommandRunner = Shell.run, logRun: @escaping CommandRunner = { Shell.run($0, timeout: logTimeout) },
                     sign: SignatureChecker = CodeSigning.check, home: String = NSHomeDirectory(), now: Date = Date()) -> SecurityReport {
        let start = Date()
        final class Box { var lines: [String]? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { box.lines = detections(run: logRun); done.signal() }   // the slow one, alongside
        let rows = ProtectionRules.rows(facts(run: run), now: now)
        let items = launchItems(dirs: launchDirs(home: home), sign: sign, home: home, now: now)
        let apps = apps(roots: ["/Applications", home + "/Applications"], sign: sign)
        done.wait()
        return SecurityReport(protections: rows, launchItems: items, apps: apps, detections: box.lines,
                              scannedAt: now, seconds: Date().timeIntervalSince(start))
    }

    /// --security-scan: prints what the page would show. Changes nothing.
    static func dryRun() {
        let r = scan()
        print("보안 점검 미리보기: 아무것도 끄거나 옮기거나 지우지 않아요")
        print("실시간 백신이 아니라, macOS 기본 보호가 켜져 있는지와 악성코드가 숨기 쉬운 곳을 점검해요.")
        print("검사 시간 \(String(format: "%.1f", r.seconds))초 · 가장 높은 단계 \(r.worst.label) · 대시보드 알림 \(r.needsAttention ? "보안 점검이 필요해요" : "없음")")
        print("\n[기본 보호]")
        for p in r.protections {
            print("  [\(p.level.label)] \(p.title): \(p.line)\(p.button.map { b in " · 버튼 \(b)" + (p.pane.map { " (\($0))" } ?? "") } ?? "")")
        }
        print("\n[수상한 자동 실행 항목] ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons (Apple 서명 항목 제외)")
        if r.launchItems.isEmpty { print("  없음") }
        for i in r.launchItems {
            let tags = [i.mine ? "내가 만든 항목" : nil, i.parked ? "꺼 둠" : nil].compactMap { $0 }
            print("  [\(i.level.label)] \(i.label)\(tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]") · \(i.place.rawValue)")
            print("      \(i.reason) · \(i.signer) · \(RunawayRules.pathHint(i.target))")
        }
        print("\n[서명이 없는 앱] /Applications, ~/Applications")
        if r.apps.isEmpty { print("  서명이 없는 앱이 없어요") }
        for a in r.apps { print("  [\(a.level.label)] \(a.name) (\(a.bundleID)) · \(a.reason) · \(a.signature.summary)") }
        print("\n[최근 차단 기록] XProtect, 최근 7일")
        if let d = r.detections {
            if d.isEmpty { print("  최근 7일 차단 기록 없음") }
            for line in d { print("  \(line)") }
        } else {
            print("  로그를 제때 읽지 못해 이 칸은 숨겨요")
        }
    }
}

/// The page's fixes. Each one runs only after a tap and a confirmation; all of them can be undone.
@MainActor
enum SecurityActions {
    /// `do shell script … with administrator privileges` through /usr/bin/osascript: macOS asks for the password itself.
    /// Runs off the main actor (the menu bar keeps animating) and gives up after `timeout`, password dialog included.
    /// Returns an error to show, nil on success.
    nonisolated static func runAsAdmin(_ shell: String, timeout: TimeInterval = 180) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", AdminCommand.appleScript(shell)]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return L("실패했어요: 관리자 명령을 시작하지 못했어요") }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()   // our own osascript child only
            return L("너무 오래 걸려서 멈췄어요. 잠시 뒤 다시 해 주세요")
        }
        guard p.terminationStatus != 0 else { return nil }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if msg.contains("(-128)") { return L("취소했어요") }
        let line = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        return L("실패했어요: \(line.isEmpty ? L("알 수 없는 오류") : line)")
    }

    /// Our cleaner's reversible 끄기 / 다시 켜기 for a plist in ~/Library/LaunchAgents (or parked from there).
    nonisolated static func toggleUser(_ i: LaunchItem, dir: String = LaunchAgents.userDir, run: CommandRunner = Shell.run) -> String? {
        guard i.place == .userAgent, !i.label.hasPrefix("com.apple."), !i.label.hasPrefix(LaunchAgents.own) else { return L("건드리지 않는 항목이에요") }
        guard let agent = LaunchAgents.list(dir: dir, jobs: LaunchAgents.jobs(run: run) ?? [:]).first(where: { $0.plist == i.plist }) else {
            return L("항목을 다시 찾지 못했어요. 다시 검사해 주세요")
        }
        return agent.disabled ? LaunchAgents.enable(agent, dir: dir, run: run) : LaunchAgents.disable(agent, dir: dir, run: run)
    }

    static func confirm(_ title: String, _ text: String, ok: String, alt: String? = nil) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: ok)
        if let alt { alert.addButton(withTitle: alt) }
        alert.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        return PopoverLayer.runModal { alert.runModal() }
    }

    static func open(_ url: String) {
        if let u = URL(string: url) { External.open(u) }
    }

    /// Asks macOS for the newest XProtect definitions (admin password), or opens Software Update instead.
    static func updateXProtect() async -> String? {
        switch confirm(L("XProtect 업데이트를 확인할까요?"),
                       L("Apple 서버에서 새 악성코드 정의가 있는지 보고 있으면 설치해요(xprotect update). 관리자 암호를 물어요. 설정은 바꾸지 않아요."),
                       ok: L("업데이트 확인"), alt: L("소프트웨어 업데이트 열기")) {
        case .alertFirstButtonReturn: return await Task.detached { runAsAdmin("/usr/bin/xprotect update") }.value
        case .alertSecondButtonReturn: open(SettingsPane.softwareUpdate); return nil
        default: return nil
        }
    }

    static func reveal(_ path: String) {
        NotificationCenter.default.post(name: .jellyClosePopover, object: nil)   // Finder comes up in front, not under the popover
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 관리자 권한으로 끄기 / 다시 켜기 of a /Library item, moved to and from AdminCommand.quarantine.
    static func toggleAdmin(_ i: LaunchItem) async -> String? {
        let cmd = i.parked ? AdminCommand.enable(i, uid: getuid()) : AdminCommand.disable(i, uid: getuid(), own: LaunchAgents.own)
        guard let cmd else { return L("건드리지 않는 항목이에요") }
        let text = i.parked
            ? L("\(i.label) 을(를) 원래 자리(/Library/\(i.place == .daemon ? "LaunchDaemons" : "LaunchAgents"))로 되돌리고 다시 켜요. 관리자 암호를 물어요.")
            : L("\(i.label) 을(를) 멈추고 plist 파일을 /Library/Application Support 안의 보관 폴더로 옮겨요. 지우지 않아서 다시 켜기로 되돌릴 수 있어요. 관리자 암호를 물어요.")
        guard confirm(i.parked ? L("\(i.label) 을(를) 다시 켤까요?") : L("\(i.label) 을(를) 관리자 권한으로 끌까요?"), text,
                      ok: i.parked ? L("다시 켜기") : L("끄기")) == .alertFirstButtonReturn else { return nil }
        return await Task.detached { runAsAdmin(cmd) }.value
    }

    static func confirmUser(_ i: LaunchItem) -> Bool {
        if i.parked {
            return confirm(L("\(i.label) 을(를) 다시 켤까요?"), L("다시 켜면 바로 실행될 수 있어요 · \(i.reason)"), ok: L("다시 켜기")) == .alertFirstButtonReturn
        }
        return confirm(L("\(i.label) 을(를) 끌까요?"),
                            L("\(RunawayRules.pathHint(i.target)) 을(를) 실행하는 항목이에요. 끄면 보관 폴더에 옮겨 두어서 다시 켜기로 되돌릴 수 있어요. 지금 실행 중이면 끝난 뒤에 꺼요."),
                            ok: L("끄기")) == .alertFirstButtonReturn
    }

    /// Quits the app normally (it may ask to save), then moves it to the Trash. Never forced, never deleted.
    static func trashApp(_ a: AppFinding) async -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        guard a.bundleID != LaunchAgents.own, !a.bundleID.hasPrefix("com.apple."), a.path.hasSuffix(".app"),
              a.path.hasPrefix("/Applications/") || a.path.hasPrefix(home + "/Applications/") else { return L("건드리지 않는 앱이에요") }
        guard confirm(L("\(a.name) 을(를) 휴지통으로 옮길까요?"),
                      L("\(a.reason). 켜져 있으면 먼저 종료를 요청해요(저장할지 물을 수 있어요). 휴지통에서 되살릴 수 있어요."),
                      ok: L("휴지통으로")) == .alertFirstButtonReturn else { return nil }
        let running = a.bundleID.isEmpty ? [] : NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID)
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
        if running.contains(where: { !$0.isTerminated }) { return L("\(a.name) 이(가) 아직 켜져 있어요. 저장 창을 닫은 뒤 다시 눌러 주세요") }
        do { _ = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: a.path)]) } catch { return L("휴지통으로 옮기지 못했어요") }
        return nil
    }
}
#endif
