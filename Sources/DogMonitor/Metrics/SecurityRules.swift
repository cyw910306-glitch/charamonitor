#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import Foundation

// 보안 점검: not an antivirus. macOS already scans for malware (XProtect); this checks that its protections are on
// and looks where Mac malware and adware like to hide. Everything here is pure so tests can feed it fixtures;
// commands and code signatures come in through SecurityScanner.

enum SecurityLevel: Int, Comparable {
    case ok, info, warn, danger
    var label: String { [L("정상"), L("정보"), L("주의"), L("위험")][rawValue] }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// System Settings panes the fix buttons open.
enum SettingsPane {
    static let softwareUpdate = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    static let security = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security"
    static let fileVault = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault"
    static let firewall = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
    static let network = "x-apple.systempreferences:com.apple.Network-Settings.extension"
    static let sharing = "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    static let lockScreen = "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
    static let users = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
}

/// One row of 기본 보호.
struct ProtectionRow: Identifiable, Equatable {
    var id: String
    var title: String
    var line: String
    var level: SecurityLevel
    var button: String? = nil
    var pane: String? = nil       // opened by the button; nil with a button means the XProtect update action
    var key = false               // one of the protections whose loss shows "보안 점검이 필요해요"
}

/// What the read-only commands said. nil = could not tell.
struct ProtectionFacts: Equatable {
    var xprotectVersion: String?
    var xprotectInstalled: Date?
    var launchScans: Bool?
    var backgroundScans: Bool?
    var gatekeeper: Bool?
    var sip: Bool?
    var fileVault: Bool?
    var firewall: Bool?
    var autoMacOS: Bool?          // AutomaticallyInstallMacOSUpdates
    var configData: Bool?         // ConfigDataInstall (XProtect and other security data)
    var critical: Bool?           // CriticalUpdateInstall (security responses)
    var autoLoginUser: String?
    var screenLockDelay: Int?     // seconds, 0 = immediate, -1 = off
    var listeningPorts: Set<Int> = []
    var proxies: [String] = []
}

enum SecurityParse {
    private static func first(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    /// `xprotect version`: "Version: 5362 Installed: 2026-09-26 13:26:51 +0000".
    static func xprotectVersion(_ out: String) -> (version: String, installed: Date?)? {
        guard let g = first(#"Version:\s*(\S+)(?:\s+Installed:\s*(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}))?"#, in: out) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return (g[0], g[1].isEmpty ? nil : f.date(from: g[1]))
    }

    /// `xprotect status`: "XProtect launch scans: enabled" / "XProtect background scans: enabled".
    static func xprotectScans(_ out: String) -> (launch: Bool?, background: Bool?) {
        func flag(_ word: String) -> Bool? { first(word + #" scans:\s*(\w+)"#, in: out).map { $0[0] == "enabled" } }
        return (flag("launch"), flag("background"))
    }

    /// "enabled"/"disabled" style answers: spctl, csrutil, fdesetup.
    static func onOff(_ out: String, on: String, off: String) -> Bool? {
        let s = out.lowercased()
        if s.contains(off.lowercased()) { return false }
        if s.contains(on.lowercased()) { return true }
        return nil
    }

    /// socketfilterfw --getglobalstate: "Firewall is disabled. (State = 0)", 1 = on, 2 = block all.
    static func firewall(_ out: String) -> Bool? {
        if let g = first(#"State = (\d)"#, in: out), let n = Int(g[0]) { return n > 0 }
        return onOff(out, on: "enabled", off: "disabled")
    }

    /// `sysadminctl -screenLock status` (stderr): "screenLock delay is immediate" / "… is 300 seconds" / "screenLock is off".
    static func screenLock(_ out: String) -> Int? {
        if out.contains("screenLock is off") { return -1 }
        if out.contains("delay is immediate") { return 0 }
        return first(#"delay is (\d+) seconds"#, in: out).flatMap { Int($0[0]) }
    }

    /// Ports listening on a non-loopback address, from `netstat -an -p tcp`.
    static func listeningPorts(_ out: String) -> Set<Int> {
        var ports = Set<Int>()
        for line in out.split(separator: "\n") where line.hasSuffix("LISTEN") || line.contains(" LISTEN ") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4, let dot = cols[3].lastIndex(of: ".") else { continue }
            let host = cols[3][..<dot], port = cols[3][cols[3].index(after: dot)...]
            guard !host.hasPrefix("127."), host != "::1", host != "localhost", let n = Int(port) else { continue }
            ports.insert(n)
        }
        return ports
    }

    /// Proxies from `scutil --proxy`, as short Korean phrases. Empty when none is on.
    static func proxies(_ out: String) -> [String] {
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        var out: [String] = []
        for (name, key) in [("HTTP", "HTTP"), ("HTTPS", "HTTPS"), ("SOCKS", "SOCKS")] where kv[key + "Enable"] == "1" {
            out.append(L("\(name) 프록시 \(kv[key + "Proxy"] ?? "?")\(kv[key + "Port"].map { ":" + $0 } ?? "")"))
        }
        if kv["ProxyAutoConfigEnable"] == "1" { out.append(L("자동 프록시(PAC) \(kv["ProxyAutoConfigURLString"] ?? "")")) }
        if kv["ProxyAutoDiscoveryEnable"] == "1" { out.append(L("자동 프록시 찾기(WPAD)")) }
        return out
    }

    /// Detection lines from `log show --style compact` of the XProtect subsystems, newest last, as "MM-dd HH:mm 내용".
    static func detections(_ out: String, limit: Int = 20) -> [String] {
        let hit = ["detected", "remediat", "malware", "blocked"]
        let quiet = ["nothreatdetected", "no threat", "not detected", "notdetected", "0 detected", "rules location"]
        var seen = Set<String>(), lines: [String] = []
        for raw in out.split(separator: "\n") {
            let low = raw.lowercased()
            guard hit.contains(where: low.contains), !quiet.contains(where: low.contains) else { continue }
            // "2026-09-30 11:35:31.815 Df proc[1:2] [sub:cat] message"
            let cols = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4, cols[0].count == 10 else { continue }
            let when = cols[0].dropFirst(5) + " " + cols[1].prefix(5)
            let msg = cols[3].replacingOccurrences(of: #"^\S+\[[\d:a-f]+\] (\[[^\]]*\] )?"#, with: "", options: .regularExpression)
            let proc = cols[3].split(separator: "[").first.map(String.init) ?? ""
            let text = "\(when) \(proc): \(msg)".prefix(160)
            if seen.insert(String(text.dropFirst(12))).inserted { lines.append(String(text)) }
        }
        return Array(lines.suffix(limit))
    }
}

enum ProtectionRules {
    static let staleDefinitions: TimeInterval = 30 * 86_400
    static let sharedPorts: [(Int, String)] = [(22, L("원격 로그인(SSH)")), (5900, L("화면 공유")), (445, L("파일 공유"))]

    static func rows(_ f: ProtectionFacts, now: Date = Date()) -> [ProtectionRow] {
        var rows: [ProtectionRow] = []

        // XProtect: Apple's own malware scanner, always there. What matters is fresh definitions and scans on.
        var x = ProtectionRow(id: "xprotect", title: L("XProtect(악성코드 검사)"), line: "", level: .ok, button: L("업데이트 확인"), key: true)
        if let v = f.xprotectVersion {
            var parts = [L("정의 \(v)")]
            if let d = f.xprotectInstalled { parts.append(L("\(d.formatted(.dateTime.month().day())) 설치")) }
            let scansOff = f.launchScans == false || f.backgroundScans == false
            parts.append(scansOff ? L("검사 꺼짐") : f.launchScans == true ? L("실행·백그라운드 검사 켜짐") : L("검사 상태 모름"))
            x.line = parts.joined(separator: " · ")
            if scansOff {
                x.level = .danger
                x.line += L(". 실시간 검사가 꺼져 있어요")
            } else if let d = f.xprotectInstalled, now.timeIntervalSince(d) > staleDefinitions {
                x.level = .warn
                x.line += L(". 정의가 \(Int(now.timeIntervalSince(d) / 86_400))일 됐어요")
            }
        } else {
            x.level = .warn
            x.line = L("버전을 읽지 못했어요. 소프트웨어 업데이트에서 확인해 주세요")
        }
        rows.append(x)

        rows.append(f.gatekeeper == false
            ? ProtectionRow(id: "gatekeeper", title: "Gatekeeper", line: L("꺼져 있어 확인 안 된 앱도 그냥 열려요"), level: .danger,
                            button: L("설정 열기"), pane: SettingsPane.security, key: true)
            : ProtectionRow(id: "gatekeeper", title: "Gatekeeper", line: f.gatekeeper == true ? L("확인된 개발자의 앱만 열려요") : L("상태를 읽지 못했어요"),
                            level: f.gatekeeper == true ? .ok : .info, key: true))

        rows.append(ProtectionRow(id: "sip", title: L("시스템 무결성 보호(SIP)"),
                                  line: f.sip == false ? L("꺼져 있어요. 복구 모드에서 csrutil enable 로 켤 수 있어요")
                                      : f.sip == true ? L("시스템 파일이 잠겨 있어요") : L("상태를 읽지 못했어요"),
                                  level: f.sip == false ? .danger : f.sip == true ? .ok : .info, key: true))

        rows.append(f.fileVault == false
            ? ProtectionRow(id: "filevault", title: L("FileVault(디스크 암호화)"), line: L("꺼져 있어 맥을 잃어버리면 파일을 읽힐 수 있어요"),
                            level: .warn, button: L("설정 열기"), pane: SettingsPane.fileVault, key: true)
            : ProtectionRow(id: "filevault", title: L("FileVault(디스크 암호화)"),
                            line: f.fileVault == true ? L("디스크가 암호화돼 있어요") : L("상태를 읽지 못했어요"),
                            level: f.fileVault == true ? .ok : .info, key: true))

        rows.append(f.firewall == false
            ? ProtectionRow(id: "firewall", title: L("방화벽"), line: L("꺼져 있어요. 카페·공용 Wi-Fi를 쓴다면 켜 두세요"), level: .warn,
                            button: L("설정 열기"), pane: SettingsPane.firewall)
            : ProtectionRow(id: "firewall", title: L("방화벽"), line: f.firewall == true ? L("켜져 있어요") : L("상태를 읽지 못했어요"),
                            level: f.firewall == true ? .ok : .info))

        // Missing keys mean Apple's defaults: security data on, macOS installs off.
        var u = ProtectionRow(id: "updates", title: L("자동 보안 업데이트"), line: L("macOS·보안 응답·XProtect 자동 설치 켜짐"), level: .ok)
        if f.configData == false || f.critical == false {
            u.level = .warn
            u.line = L("보안 응답·XProtect 자동 설치가 꺼져 있어요")
        } else if f.autoMacOS != true {
            u.level = .info
            u.line = L("보안 데이터는 자동, macOS 업데이트는 직접 설치해요")
        }
        if u.level != .ok { u.button = L("설정 열기"); u.pane = SettingsPane.softwareUpdate }
        rows.append(u)

        rows.append(f.autoLoginUser.map { user in
            ProtectionRow(id: "autologin", title: L("자동 로그인"), line: L("\(user) 계정이 암호 없이 로그인돼요. 누구나 맥을 켜면 들어와요"),
                          level: .danger, button: L("설정 열기"), pane: SettingsPane.users, key: true)
        } ?? ProtectionRow(id: "autologin", title: L("자동 로그인"), line: L("꺼져 있어요"), level: .ok))

        if let d = f.screenLockDelay {
            let line = d < 0 ? L("잠자기·화면 보호기 뒤에 암호를 묻지 않아요") : d == 0 ? L("잠자기·화면 보호기 뒤 바로 암호를 물어요")
                : L("잠자기 \(d >= 60 ? L("\(d / 60)분") : L("\(d)초")) 뒤부터 암호를 물어요")
            let level: SecurityLevel = d < 0 || d > 300 ? .warn : .ok
            rows.append(ProtectionRow(id: "screenlock", title: L("화면 잠금 암호"), line: line, level: level,
                                      button: level == .ok ? nil : L("설정 열기"), pane: SettingsPane.lockScreen))
        }

        let shared = sharedPorts.filter { f.listeningPorts.contains($0.0) }.map(\.1)
        rows.append(shared.isEmpty
            ? ProtectionRow(id: "sharing", title: L("공유 기능"), line: L("원격 로그인·화면 공유·파일 공유가 꺼져 있어요"), level: .ok)
            : ProtectionRow(id: "sharing", title: L("공유 기능"), line: shared.joined(separator: " · ") + L(" 켜짐. 직접 켠 게 아니면 꺼 주세요"),
                            level: .info, button: L("설정 열기"), pane: SettingsPane.sharing))

        rows.append(f.proxies.isEmpty
            ? ProtectionRow(id: "proxy", title: L("프록시"), line: L("쓰지 않아요"), level: .ok)
            : ProtectionRow(id: "proxy", title: L("프록시"), line: f.proxies.joined(separator: " · ") + L(". 회사 정책이면 괜찮아요, 모르는 설정이면 확인해 주세요"),
                            level: .info, button: L("설정 열기"), pane: SettingsPane.network))
        return rows
    }
}

/// What Security.framework said about a file.
struct CodeSignature: Equatable {
    enum State: Equatable { case missing, unsigned, invalid, adhoc, signed }
    var state: State
    var apple = false        // signed by Apple itself
    var appStore = false
    var team: String? = nil
    var org: String? = nil   // "Logitech Inc." from "Developer ID Application: Logitech Inc. (QED4VVPZWA)"
    var notarized = false

    var summary: String {
        switch state {
        case .missing: return L("파일 없음")
        case .unsigned: return L("서명 없음")
        case .invalid: return L("서명 손상")
        case .adhoc: return L("임시 서명(ad-hoc)")
        case .signed:
            if apple { return "Apple" }
            let who = org ?? team ?? L("개발자")
            return who + (appStore ? " · App Store" : notarized ? L(" · 공증됨") : L(" · 공증 안 됨"))
        }
    }

    /// Organisation name out of a leaf certificate's subject summary.
    static func org(fromSubject s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        var name = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let paren = name.range(of: " (", options: .backwards) { name = String(name[..<paren.lowerBound]) }
        return name.isEmpty ? nil : name
    }
}

typealias SignatureChecker = (_ path: String) -> CodeSignature

/// A launchd plist outside com.apple, with what it runs and our verdict.
struct LaunchItem: Identifiable, Equatable {
    enum Place: String { case userAgent = "내 LaunchAgents", agent = "/Library/LaunchAgents", daemon = "/Library/LaunchDaemons" }
    var label: String
    var plist: String
    var place: Place
    var argv: [String]           // argv[0] resolved to a full path when it could be
    var target: String           // what really runs: the script, the app opened, or argv[0]
    var interpreter: Bool        // argv[0] is a shell, python, osascript …
    var runAtLoad = false
    var keepAlive = false
    var modified = Date.distantPast
    var mine = false
    var parked = false           // turned off by us (moved out of the launchd folder)
    var signature = CodeSignature(state: .signed, apple: true)
    var level = SecurityLevel.ok
    var reason = ""
    var id: String { plist }
    var isScript: Bool { interpreter && target != argv.first }
    var scriptFile: Bool { ["sh", "zsh", "bash", "py", "rb", "pl", "js", "command"].contains((target as NSString).pathExtension) }
    /// Who signed what runs, for the second line.
    var signer: String { (isScript || scriptFile) && signature.state == .unsigned ? L("스크립트") : signature.summary }
}

enum LaunchRules {
    static let interpreters: Set<String> = ["bash", "sh", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "python", "python2", "python3",
                                            "perl", "ruby", "osascript", "node", "bun", "deno", "php", "env"]
    static let tempRoots = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]
    static let recent: TimeInterval = 7 * 86_400

    static func isInterpreter(_ path: String) -> Bool {
        let base = (path as NSString).lastPathComponent
        return interpreters.contains(base) || base.range(of: #"^python[0-9.]+$"#, options: .regularExpression) != nil
    }

    /// argv[0] (or Program) as a full path: bare names like "open" are looked up in the system folders.
    static func resolve(_ exe: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        guard !exe.hasPrefix("/") else { return exe }
        return ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { $0 + "/" + exe }.first(where: exists) ?? exe
    }

    /// The file that actually runs. For an interpreter or `open`, the first path argument (the script or app);
    /// an inline script (`bash -c …`) has none, so it is the interpreter itself.
    static func target(_ argv: [String]) -> (target: String, interpreter: Bool) {
        guard let exe = argv.first else { return ("", false) }
        let interp = isInterpreter(exe)
        guard interp || (exe as NSString).lastPathComponent == "open" else { return (exe, false) }
        let rest = argv.dropFirst()
        if interp, rest.contains("-c") || rest.contains("-e") { return (exe, true) }   // inline code, no file
        return (rest.first(where: { $0.hasPrefix("/") }) ?? exe, interp)
    }

    /// Script arguments that fetch or unpack code and run it. Only looked at for interpreters.
    static func argumentRisk(_ argv: [String]) -> (level: SecurityLevel, reason: String)? {
        guard let exe = argv.first, isInterpreter(exe) else { return nil }
        let s = argv.dropFirst().joined(separator: " ").lowercased()
        let fetch = s.contains("curl ") || s.contains("wget ") || s.range(of: #"\bcurl\b|\bwget\b"#, options: .regularExpression) != nil
        if fetch, s.range(of: #"\|\s*(sudo\s+)?(ba|z|k)?sh\b|\|\s*python|\|\s*perl|\|\s*osascript"#, options: .regularExpression) != nil {
            return (.danger, L("인터넷에서 받은 스크립트를 바로 실행해요"))
        }
        if s.contains("base64") { return (.danger, L("base64로 숨긴 명령을 풀어서 실행해요")) }
        if s.range(of: #"\beval\b"#, options: .regularExpression) != nil { return (.danger, L("eval로 만든 명령을 실행해요")) }
        if fetch || s.contains("http://") || s.contains("https://") { return (.warn, L("실행할 때마다 인터넷에서 무언가를 받아요")) }
        return nil
    }

    /// A folder name like "a8Xk29fQ0z": at least 10 letters and digits only, with 3+ of each.
    // ponytail: naive shape test; adware also uses plausible names (com.SearchDaemon), which only the signature rules catch.
    static func looksRandom(_ name: String) -> Bool {
        guard name.count >= 10, name.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil else { return false }
        return name.filter(\.isNumber).count >= 3 && name.filter(\.isLetter).count >= 3
    }

    /// Where the file sits, if that alone is odd: temp folders, hidden folders, random names in Application Support.
    static func oddPlace(_ path: String, home: String) -> String? {
        if tempRoots.contains(where: path.hasPrefix) { return L("임시·공용 폴더에서 실행돼요") }
        let parts = path.split(separator: "/").dropLast()
        if parts.contains(where: { $0.hasPrefix(".") }) { return L("숨김 폴더에서 실행돼요") }
        let support = home + "/Library/Application Support/"
        if path.hasPrefix(support), let name = path.dropFirst(support.count).split(separator: "/").first,
           looksRandom(String(name)) { return L("Application Support 안 무작위 이름 폴더에서 실행돼요") }
        return nil
    }

    /// Severity and one short reason.
    /// The owner's own script: in their folders (not Downloads or Desktop, where downloads land) and a script, not a
    /// compiled program. Only these skip the signature rules, and never when the arguments are 위험.
    static func ownScript(_ i: LaunchItem, home: String) -> Bool {
        i.mine && (i.isScript || i.scriptFile) && !["/Downloads/", "/Desktop/"].contains { i.target.hasPrefix(home + $0) }
    }

    static func judge(_ i: LaunchItem, now: Date, home: String) -> (SecurityLevel, String) {
        let risk = argumentRisk(i.argv)
        if let risk, risk.level == .danger { return risk }
        if ownScript(i, home: home) { return (.ok, L("내 폴더의 스크립트예요")) }
        let sig = i.signature
        if sig.state == .missing { return (.warn, L("실행 파일이 없어요. 지운 앱이 남긴 항목일 수 있어요")) }
        let unsigned = sig.state != .signed
        let what = i.isScript ? L("서명 없는 스크립트") : sig.state == .adhoc ? L("임시 서명(ad-hoc)뿐인 프로그램") : L("서명 없는 프로그램")
        if let odd = oddPlace(i.target, home: home) { return unsigned ? (.danger, "\(odd) · \(what)") : (.warn, odd) }
        if sig.state == .invalid { return (.danger, L("서명이 손상됐어요. 설치된 뒤 파일이 바뀌었어요")) }
        if unsigned, i.runAtLoad, i.keepAlive { return (.danger, L("로그인 때부터 항상 켜져 있어요 · \(what)")) }
        if unsigned, now.timeIntervalSince(i.modified) < recent { return (.danger, L("최근 7일 안에 생겼어요 · \(what)")) }
        if let risk { return risk }
        if unsigned { return (.warn, L("\(what). 설치한 기억이 없으면 확인해 주세요")) }
        return (.ok, sig.apple ? L("Apple 서명이에요") : L("확인된 개발자 서명이에요"))
    }
}

/// An app in /Applications whose signature is missing, broken or only ad-hoc (or, as 정보, not notarized).
struct AppFinding: Identifiable, Equatable {
    var name: String
    var path: String
    var bundleID: String
    var signature: CodeSignature
    var level: SecurityLevel
    var reason: String
    var id: String { path }
}

enum AppRules {
    static func judge(_ s: CodeSignature) -> (SecurityLevel, String)? {
        switch s.state {
        case .missing: return nil
        case .unsigned: return (.warn, L("서명이 없는 앱이에요. 받은 곳을 모르면 지워 주세요"))
        case .adhoc: return (.warn, L("임시 서명(ad-hoc)뿐이에요. 직접 빌드한 앱이 아니면 확인해 주세요"))
        case .invalid: return (.warn, L("서명이 깨졌어요. 설치된 뒤 앱 파일이 바뀌었어요"))
        case .signed: return s.apple || s.appStore || s.notarized ? nil : (.info, L("개발자 서명은 있지만 Apple 공증은 안 받았어요"))
        }
    }
}

/// Everything the 보안 page shows.
struct SecurityReport: Equatable {
    var protections: [ProtectionRow]
    var launchItems: [LaunchItem]
    var apps: [AppFinding]
    var detections: [String]?    // nil = the log could not be read in time
    var scannedAt: Date
    var seconds: Double

    /// A key protection is off or anything is 위험: the dashboard shows "보안 점검이 필요해요".
    var needsAttention: Bool {
        protections.contains { $0.key && $0.level >= .warn } || protections.contains { $0.level == .danger }
            || launchItems.contains { $0.level == .danger && !$0.parked } || apps.contains { $0.level == .danger }
            || !(detections ?? []).isEmpty
    }

    var worst: SecurityLevel {
        (protections.map(\.level) + launchItems.filter { !$0.parked }.map(\.level) + apps.map(\.level)).max() ?? .ok
    }
}

/// Shell text for the admin 끄기 / 다시 켜기 of a /Library item, run through `do shell script … with administrator privileges`.
enum AdminCommand {
    static let quarantine = "/Library/Application Support/JellyMonitor/격리된 항목"

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// AppleScript string literal of a shell command.
    static func appleScript(_ shell: String) -> String {
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(esc)\" with administrator privileges"
    }

    /// nil when the item may not be touched: Apple's, ours, or not directly in a /Library launchd folder.
    static func disable(_ i: LaunchItem, uid: uid_t, own: String) -> String? {
        guard i.place != .userAgent, !i.parked, !i.label.hasPrefix("com.apple."), !i.label.hasPrefix(own) else { return nil }
        let folder = i.place == .daemon ? "LaunchDaemons" : "LaunchAgents"
        guard (i.plist as NSString).deletingLastPathComponent == "/Library/" + folder else { return nil }
        let dest = quarantine + "/" + folder
        let to = dest + "/" + (i.plist as NSString).lastPathComponent
        let domain = i.place == .daemon ? "system/\(i.label)" : "gui/\(uid)/\(i.label)"
        return "/bin/mkdir -p \(quote(dest)) && /bin/test ! -e \(quote(to)) && { /bin/launchctl bootout \(quote(domain)) || true; } && /bin/mv \(quote(i.plist)) \(quote(to))"
    }

    /// Moves a quarantined plist back and loads it again.
    static func enable(_ i: LaunchItem, uid: uid_t) -> String? {
        guard i.place != .userAgent, i.parked, !i.label.hasPrefix("com.apple."), i.plist.hasPrefix(quarantine + "/") else { return nil }
        let folder = i.place == .daemon ? "LaunchDaemons" : "LaunchAgents"
        let back = "/Library/\(folder)/" + (i.plist as NSString).lastPathComponent
        let domain = i.place == .daemon ? "system" : "gui/\(uid)"
        return "/bin/test ! -e \(quote(back)) && /bin/mv \(quote(i.plist)) \(quote(back)) && { /bin/launchctl bootstrap \(domain) \(quote(back)) || true; }"
    }
}
#endif
