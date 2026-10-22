#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import AppKit
import CryptoKit
import Foundation

/// The small file the site serves at /update.json. /update.json.sig is the base64 Ed25519 signature over its exact
/// bytes, made with the release signing key (scripts/package.sh + tools/update/sign_manifest.swift).
struct UpdateManifest: Codable, Equatable {
    var version: String
    var build: Int
    var url: String
    var sha256: String
    var minSystem: String
    var notes: String
}

enum UpdateError: Error, Equatable {
    case badHost, badSignature, badManifest, offline, checksum, unzip, badBundle, codesign, notBundled, notWritable, swap, swapLost

    var message: String {
        switch self {
        case .badHost: return L("업데이트 주소가 캐릭모니터 사이트가 아니에요.")
        case .badSignature: return L("업데이트 서명이 맞지 않아요.")
        case .badManifest: return L("업데이트 정보를 읽지 못했어요.")
        case .offline: return L("업데이트 서버에 연결하지 못했어요.")
        case .checksum: return L("받은 파일이 손상됐어요.")
        case .unzip: return L("받은 파일을 풀지 못했어요.")
        case .badBundle: return L("받은 앱이 예상한 버전이 아니에요.")
        case .codesign: return L("받은 앱의 코드 서명이 맞지 않아요.")
        case .notBundled: return L("앱 번들에서 실행 중일 때만 스스로 업데이트할 수 있어요.")
        case .notWritable: return L("앱이 있는 폴더에 쓸 수 없어요.")
        case .swap: return L("앱을 바꿔 끼우지 못했어요. 지금 앱은 그대로예요.")
        case .swapLost: return L("앱을 바꿔 끼우다 멈췄어요. 이전 앱은 휴지통이 아니라 앱 폴더에 숨겨져 있어요.")
        }
    }
}

/// Fetching and checking the manifest. Pure parts are separate so tests never touch the network.
enum UpdateCheck {
    /// Download hosts a signed manifest may point at: the old site and the 캐릭모니터 one.
    static let hosts: Set<String> = ["jelly-monitor.vercel.app", "charamonitor.vercel.app"]
    /// Where the app checks. Switch to "charamonitor.vercel.app" once that site serves update.json.
    static let checkHost = "jelly-monitor.vercel.app"
    static let site = URL(string: "https://\(checkHost)")!
    static let manifestURL = URL(string: "https://\(checkHost)/update.json")!
    static let signatureURL = URL(string: "https://\(checkHost)/update.json.sig")!
    static let bundleID = "com.jelly.dogmonitor"
    /// The release signing key's public half. Only the owner holds the private key, so a fork's update.json cannot
    /// pass here: a fork that ships its own updates swaps in its own key (sign_manifest.swift prints its first bytes to compare).
    static let publicKey: [UInt8] = [
        0x3D, 0x92, 0x09, 0x03, 0x5C, 0x61, 0x81, 0xD7, 0x6D, 0xFB, 0x77, 0xFA, 0xDA, 0xD3, 0x9B, 0x4D,
        0x26, 0x81, 0x25, 0x94, 0x11, 0x69, 0xA4, 0x0A, 0x7F, 0x98, 0x27, 0xE8, 0xC2, 0x5E, 0x25, 0x5E,
    ]

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host.map { hosts.contains($0.lowercased()) } == true && url.port == nil && url.user == nil && url.password == nil
    }

    /// The signature is checked before anything is parsed. Throws for unsigned, tampered or foreign-key files.
    static func verify(_ data: Data, signature: Data, publicKey: [UInt8] = publicKey) throws -> UpdateManifest {
        guard signed(data, signature: signature, publicKey: publicKey) else { throw UpdateError.badSignature }
        guard let m = try? JSONDecoder().decode(UpdateManifest.self, from: data), m.build > 0,
              m.sha256.count == 64, m.sha256.allSatisfy(\.isHexDigit) else { throw UpdateError.badManifest }
        guard isAllowed(URL(string: m.url)) else { throw UpdateError.badHost }
        return m
    }

    /// Whether `signature` (one base64 line, sign_manifest.swift) is the release key's over exactly these bytes.
    /// The 후원 친구 list (sponsors.json) is checked the same way.
    static func signed(_ data: Data, signature: Data, publicKey: [UInt8] = publicKey) -> Bool {
        guard let text = String(data: signature, encoding: .utf8),
              let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return pub.isValidSignature(sig, for: data)
    }

    /// Dotted numbers, missing parts count as 0: "1.10" > "1.9", "1.7" == "1.7.0".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Only a strictly higher build whose version is not lower: never a downgrade, never the same build again.
    static func isNewer(_ m: UpdateManifest, thanBuild build: Int, version: String) -> Bool {
        m.build > build && compare(m.version, version) != .orderedAscending
    }

    static func runsHere(_ m: UpdateManifest) -> Bool {
        let p = m.minSystem.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: p[0], minorVersion: p[1], patchVersion: p[2]))
    }

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // no cookies or cache on disk
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120          // the zip; the manifest request itself times out at 15 s
        return URLSession(configuration: config)
    }()

    static func request(_ url: URL) throws -> URLRequest {
        guard isAllowed(url) else { throw UpdateError.badHost }
        return URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    }

    static func checkResponse(_ response: URLResponse) throws {
        guard isAllowed(response.url), (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.offline }
    }

    /// The body of a small file, read only after the response checks out and never past `maxBytes` (a declared length
    /// over it is refused before any byte is read).
    static func fetch(_ url: URL, maxBytes: Int = 65_536) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request(url))
            try checkResponse(response)
            guard response.expectedContentLength <= Int64(maxBytes) else { throw UpdateError.badManifest }
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > maxBytes { throw UpdateError.badManifest }
            }
            return data
        } catch let e as UpdateError { throw e } catch { throw UpdateError.offline }
    }

    /// `folder`: read update.json and update.json.sig from disk instead (QA of freshly packaged files).
    static func fetchManifest(folder: URL? = nil) async throws -> UpdateManifest {
        if let folder {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent("update.json")),
                  let s = try? Data(contentsOf: folder.appendingPathComponent("update.json.sig")) else { throw UpdateError.badManifest }
            return try verify(d, signature: s)
        }
        async let d = fetch(manifestURL)
        async let s = fetch(signatureURL, maxBytes: 256)
        return try verify(try await d, signature: try await s)
    }

    /// `--check-update [폴더]`: read-only. Fetches, verifies and prints what the app would do.
    static func runCLI(folder: URL?) async -> Int32 {
        let running = Bundle.main.bundleURL
        print("지금 앱: \(AppInfo.version) (빌드 \(currentBuild)) · \(running.path)")
        do {
            let m = try await fetchManifest(folder: folder)
            print("서명 확인됨 · 서버: \(m.version) (빌드 \(m.build)) · macOS \(m.minSystem) 이상 · \(m.url)")
            print("sha256 \(m.sha256) · \(m.notes)")
            if !isNewer(m, thanBuild: currentBuild, version: AppInfo.version) {
                print("할 일: 없음 (지금 앱이 최신이거나 더 새로워요)")
            } else if !runsHere(m) {
                print("할 일: 없음 (새 버전은 macOS \(m.minSystem) 이상이 필요해요)")
            } else if let plan = try? UpdateInstall.plan(running: running) {
                print("할 일: \(m.version) 받기 → 확인 → \(plan.target.path) 바꿔 끼우고 다시 켜기")
            } else {
                print("할 일: 바꿔 끼울 수 없어서(번들 밖이거나 폴더에 쓸 수 없음) \(site.absoluteString) 열기")
            }
            return 0
        } catch {
            print("실패: \((error as? UpdateError ?? .offline).message)")
            return 1
        }
    }
}

/// Download, check and swap. Every step before the swap works on a temp folder; the swap rolls back on failure.
enum UpdateInstall {
    /// The running bundle is parked next to itself while the new one, staged in the same folder first, moves in:
    /// the same folder, so both moves are renames even when the app lives on another volume than the temp folder.
    struct Swap: Equatable {
        let target: URL
        let parked: URL
        let staged: URL
    }

    static func plan(running: URL, fm: FileManager = .default) throws -> Swap {
        guard running.pathExtension == "app" else { throw UpdateError.notBundled }
        let folder = running.deletingLastPathComponent()
        // A translocated copy (opened straight from Downloads) runs from a read-only mount.
        guard !folder.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable }
        let name = running.deletingPathExtension().lastPathComponent, tag = UUID().uuidString.prefix(8)
        return Swap(target: running, parked: folder.appendingPathComponent(".\(name)-old-\(tag).app"),
                    staged: folder.appendingPathComponent(".\(name)-new-\(tag).app"))
    }

    /// Moves the checked app next to the running one. This may copy across volumes; if it fails, only the staged
    /// copy is gone and the running app was never touched.
    static func stage(_ app: URL, _ plan: Swap, fm: FileManager = .default) throws {
        do { try fm.moveItem(at: app, to: plan.staged) } catch {
            try? fm.removeItem(at: plan.staged)
            throw UpdateError.swap
        }
    }

    /// Afterwards either the new bundle is at `target` and the old one at `parked`, or the old one is back at
    /// `target` (.swap). .swapLost only when even putting it back failed; then nothing is claimed to be unchanged.
    static func swap(_ plan: Swap, newBundle: URL, fm: FileManager = .default) throws {
        do { try fm.moveItem(at: plan.target, to: plan.parked) } catch { throw UpdateError.swap }
        do { try fm.moveItem(at: newBundle, to: plan.target) } catch {
            if (try? fm.moveItem(at: plan.parked, to: plan.target)) == nil, fm.fileExists(atPath: plan.parked.path) {
                try? fm.removeItem(at: plan.target)   // a half-moved new bundle in the way; the old one is safe at parked
                try? fm.moveItem(at: plan.parked, to: plan.target)
            }
            throw fm.fileExists(atPath: plan.target.path) && !fm.fileExists(atPath: plan.parked.path) ? UpdateError.swap : UpdateError.swapLost
        }
    }

    static func sha256Hex(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func checkSHA(_ file: URL, _ expected: String) throws {
        guard (try? sha256Hex(file)) == expected.lowercased() else { throw UpdateError.checksum }
    }

    /// Ours, and exactly the build the signed manifest promised.
    static func checkBundle(_ app: URL, build: Int) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == UpdateCheck.bundleID,
              info["CFBundleVersion"] as? String == String(build) else { throw UpdateError.badBundle }
    }

    /// Returns the checked new .app inside `work`. Never touches the running app.
    static func prepare(_ m: UpdateManifest, in work: URL, progress: @escaping (String) -> Void) async throws -> URL {
        guard let url = URL(string: m.url) else { throw UpdateError.badHost }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        progress(L("새 버전 \(m.version) 받는 중…"))
        let zip = work.appendingPathComponent("update.zip")
        do {
            let (file, response) = try await UpdateCheck.session.download(for: UpdateCheck.request(url))
            defer { try? FileManager.default.removeItem(at: file) }
            try UpdateCheck.checkResponse(response)
            try FileManager.default.moveItem(at: file, to: zip)
        } catch let e as UpdateError { throw e } catch { throw UpdateError.offline }
        progress(L("받은 파일을 확인하는 중…"))
        try checkSHA(zip, m.sha256)
        let out = work.appendingPathComponent("unzipped", isDirectory: true)
        guard Shell.run(["/usr/bin/ditto", "-x", "-k", zip.path, out.path], timeout: 60).status == 0,
              let app = try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
                  .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.unzip }
        try checkBundle(app, build: m.build)
        guard Shell.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path], timeout: 60).status == 0 else {
            throw UpdateError.codesign
        }
        return app
    }

    /// Opens the new bundle once this process has exited, so two copies never share the menu bar.
    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
    }
}

/// The app side: a check 30 s after launch and then daily, the 설정 card state, and the install.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let autoKey = "autoUpdate"

    /// A verified, newer build that runs on this Mac.
    @Published private(set) var available: UpdateManifest?
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: Self.autoKey) } }

    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        autoUpdate = defaults.object(forKey: Self.autoKey) as? Bool ?? true
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// `manual`: 업데이트 확인 was pressed, so the result always shows and a failed install opens the site.
    func check(manual: Bool = false) {
        guard !busy else { return }
        busy = true
        if manual { status = L("업데이트를 확인하는 중…") }
        Task { @MainActor in
            do {
                let m = try await UpdateCheck.fetchManifest()
                busy = false
                guard UpdateCheck.isNewer(m, thanBuild: UpdateCheck.currentBuild, version: AppInfo.version) else {
                    available = nil
                    if manual { status = L("최신 버전이에요 (\(AppInfo.version))") }
                    return
                }
                guard UpdateCheck.runsHere(m) else {
                    available = nil
                    if manual { status = L("새 버전 \(m.version) · macOS \(m.minSystem) 이상이 필요해요.") }
                    return
                }
                available = m
                status = nil
                if manual { install(manual: true) } else if autoUpdate { installWhenIdle() }
            } catch {
                busy = false
                if manual { status = (error as? UpdateError ?? .offline).message }
            }
        }
    }

    /// QA renders (DashboardSnapshot) show the update card without a real manifest.
    func qaShow(_ m: UpdateManifest?) { available = m }

    /// Set by the status item: false while the popover is open (the creator may hold unsaved pictures or an AI
    /// drawing that already used a quota slot). Automatic installs wait for that; the button never does.
    static var isIdle: () -> Bool = { true }

    /// Automatic install: now if nothing is open, else a look again every 10 minutes until it is.
    private func installWhenIdle() {
        guard autoUpdate, available != nil else { return }
        guard Self.isIdle() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.installWhenIdle() }
            return
        }
        install(manual: false)
    }

    func install(manual: Bool = true) {
        guard let m = available, !busy else { return }
        busy = true
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-update-\(UUID().uuidString)", isDirectory: true)
        Task { @MainActor in
            do {
                guard Bundle.main.bundleIdentifier == UpdateCheck.bundleID else { throw UpdateError.notBundled }
                let plan = try UpdateInstall.plan(running: Bundle.main.bundleURL)   // fail before downloading anything
                let app = try await Task.detached {
                    try await UpdateInstall.prepare(m, in: work) { [weak self] text in Task { @MainActor in self?.status = text } }
                }.value
                status = L("새 버전으로 바꾸는 중…")
                try UpdateInstall.stage(app, plan)
                do { try UpdateInstall.swap(plan, newBundle: plan.staged) } catch {
                    try? FileManager.default.removeItem(at: plan.staged)
                    throw error
                }
                try? FileManager.default.removeItem(at: work)
                status = L("새 버전으로 다시 켜는 중…")
                NSWorkspace.shared.recycle([plan.parked]) { _, _ in
                    DispatchQueue.main.async {
                        UpdateInstall.relaunch(plan.target)
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: work)
                busy = false
                status = L("\((error as? UpdateError ?? .offline).message) 사이트에서 새 버전을 받아 주세요.")
                if manual { External.open(UpdateCheck.site) }
            }
        }
    }
}
#endif
