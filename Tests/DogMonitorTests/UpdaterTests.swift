import CryptoKit
import XCTest
@testable import DogMonitor

final class UpdaterTests: XCTestCase {
    private let seller = Curve25519.Signing.PrivateKey()
    private var pub: [UInt8] { Array(seller.publicKey.rawRepresentation) }
    private let manifest = Data(#"{"version":"1.7","build":8,"url":"https://jelly-monitor.vercel.app/JellyMonitor.zip","sha256":"\#(String(repeating: "ab", count: 32))","minSystem":"13.0","notes":"한 줄 요약"}"#.utf8)

    private func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        Data((try (key ?? seller).signature(for: data).base64EncodedString() + "\n").utf8)
    }

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-updater-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func fakeBundle(_ url: URL, id: String = UpdateCheck.bundleID, build: String, marker: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleVersion": build]
        XCTAssertTrue(plist.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true))
        try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/marker"))
    }

    private func marker(_ app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/marker"))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testSignedManifestVerifies() throws {
        let m = try UpdateCheck.verify(manifest, signature: try sign(manifest), publicKey: pub)
        XCTAssertEqual(m.version, "1.7")
        XCTAssertEqual(m.build, 8)
        XCTAssertEqual(m.notes, "한 줄 요약")
    }

    func testTamperedUnsignedOrForeignKeyIsRejected() throws {
        var tampered = manifest
        tampered[tampered.firstIndex(of: UInt8(ascii: "8"))!] = UInt8(ascii: "9")   // build 8 -> 9
        XCTAssertThrowsError(try UpdateCheck.verify(tampered, signature: try sign(manifest), publicKey: pub)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
        XCTAssertThrowsError(try UpdateCheck.verify(manifest, signature: try sign(manifest, with: .init()), publicKey: pub))
        XCTAssertThrowsError(try UpdateCheck.verify(manifest, signature: Data(), publicKey: pub))
        XCTAssertThrowsError(try UpdateCheck.verify(manifest, signature: Data("not base64".utf8), publicKey: pub))
        // The shipped app key never accepts a file signed by some other key.
        XCTAssertThrowsError(try UpdateCheck.verify(manifest, signature: try sign(manifest)))
    }

    func testSignedManifestPointingElsewhereIsRejected() throws {
        let evil = Data(String(decoding: manifest, as: UTF8.self)
            .replacingOccurrences(of: "https://jelly-monitor.vercel.app", with: "https://evil.example").utf8)
        XCTAssertThrowsError(try UpdateCheck.verify(evil, signature: try sign(evil), publicKey: pub)) {
            XCTAssertEqual($0 as? UpdateError, .badHost)
        }
    }

    func testHostCheck() {
        XCTAssertTrue(UpdateCheck.isAllowed(URL(string: "https://jelly-monitor.vercel.app/update.json")))
        XCTAssertTrue(UpdateCheck.isAllowed(URL(string: "https://JELLY-MONITOR.vercel.app/x.zip")))
        for bad in ["http://jelly-monitor.vercel.app/update.json", "https://jelly-monitor.vercel.app.evil.com/u",
                    "https://evil.vercel.app/u", "https://jelly-monitor.vercel.app:8443/u",
                    "https://a@jelly-monitor.vercel.app/u", "file:///tmp/update.json"] {
            XCTAssertFalse(UpdateCheck.isAllowed(URL(string: bad)), bad)
        }
        XCTAssertFalse(UpdateCheck.isAllowed(nil))
        XCTAssertThrowsError(try UpdateCheck.request(URL(string: "https://evil.example/update.json")!))
    }

    func testVersionCompareNeverDowngrades() throws {
        XCTAssertEqual(UpdateCheck.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(UpdateCheck.compare("1.7", "1.7.0"), .orderedSame)
        XCTAssertEqual(UpdateCheck.compare("1.6", "1.7"), .orderedAscending)
        let m = try UpdateCheck.verify(manifest, signature: try sign(manifest), publicKey: pub)
        XCTAssertTrue(UpdateCheck.isNewer(m, thanBuild: 7, version: "1.6"))
        XCTAssertFalse(UpdateCheck.isNewer(m, thanBuild: 8, version: "1.7"))   // same build
        XCTAssertFalse(UpdateCheck.isNewer(m, thanBuild: 9, version: "1.8"))   // older
        XCTAssertFalse(UpdateCheck.isNewer(m, thanBuild: 7, version: "1.8"))   // higher build but lower version
        XCTAssertTrue(UpdateCheck.runsHere(m))                                  // 13.0: every Mac this app runs on
        var future = m
        future.minSystem = "99.0"
        XCTAssertFalse(UpdateCheck.runsHere(future))
    }

    func testChecksumMismatchIsRejected() throws {
        let file = try temp().appendingPathComponent("update.zip")
        try Data("zip bytes".utf8).write(to: file)
        let good = try UpdateInstall.sha256Hex(file)
        XCTAssertEqual(good.count, 64)
        XCTAssertNoThrow(try UpdateInstall.checkSHA(file, good.uppercased()))
        XCTAssertThrowsError(try UpdateInstall.checkSHA(file, String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? UpdateError, .checksum)
        }
    }

    func testBundleCheck() throws {
        let dir = try temp()
        let ok = dir.appendingPathComponent("A.app"), other = dir.appendingPathComponent("B.app")
        try fakeBundle(ok, build: "8", marker: "new")
        try fakeBundle(other, id: "com.example.other", build: "8", marker: "x")
        XCTAssertNoThrow(try UpdateInstall.checkBundle(ok, build: 8))
        XCTAssertThrowsError(try UpdateInstall.checkBundle(ok, build: 9))
        XCTAssertThrowsError(try UpdateInstall.checkBundle(other, build: 8))
        XCTAssertThrowsError(try UpdateInstall.checkBundle(dir.appendingPathComponent("missing.app"), build: 8))
    }

    func testSwapReplacesBundleInPlaceAndKeepsOldAside() throws {
        let dir = try temp()
        let running = dir.appendingPathComponent("DogMonitor.app"), incoming = dir.appendingPathComponent("new/DogMonitor.app")
        try fakeBundle(running, build: "7", marker: "old")
        try fakeBundle(incoming, build: "8", marker: "new")
        let plan = try UpdateInstall.plan(running: running)
        XCTAssertEqual(plan.target, running)
        XCTAssertEqual(plan.parked.deletingLastPathComponent().path, dir.path)
        XCTAssertTrue(plan.parked.lastPathComponent.hasPrefix(".DogMonitor-old-"))
        try UpdateInstall.swap(plan, newBundle: incoming)
        XCTAssertEqual(marker(running), "new")
        XCTAssertEqual(marker(plan.parked), "old")
    }

    func testFailedSwapLeavesOldAppUntouched() throws {
        let dir = try temp()
        let running = dir.appendingPathComponent("DogMonitor.app")
        try fakeBundle(running, build: "7", marker: "old")
        let plan = try UpdateInstall.plan(running: running)
        XCTAssertThrowsError(try UpdateInstall.swap(plan, newBundle: dir.appendingPathComponent("missing.app"))) {
            XCTAssertEqual($0 as? UpdateError, .swap)
        }
        XCTAssertEqual(marker(running), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.parked.path))
    }

    /// The new app is staged next to the running one first, so the swap itself is two renames in one folder.
    func testStageMovesTheNewAppIntoTheTargetFolder() throws {
        let dir = try temp()
        let running = dir.appendingPathComponent("DogMonitor.app"), incoming = dir.appendingPathComponent("tmp/DogMonitor.app")
        try fakeBundle(running, build: "7", marker: "old")
        try fakeBundle(incoming, build: "8", marker: "new")
        let plan = try UpdateInstall.plan(running: running)
        XCTAssertEqual(plan.staged.deletingLastPathComponent().path, dir.path)
        XCTAssertTrue(plan.staged.lastPathComponent.hasPrefix(".DogMonitor-new-"))
        try UpdateInstall.stage(incoming, plan)
        XCTAssertEqual(marker(plan.staged), "new")
        XCTAssertEqual(marker(running), "old", "staging never touches the running app")
        XCTAssertThrowsError(try UpdateInstall.stage(dir.appendingPathComponent("missing.app"), plan)) {
            XCTAssertEqual($0 as? UpdateError, .swap)
        }
    }

    /// A move that leaves half a bundle at the target (a cross-volume copy that fails midway): the half copy is
    /// cleared and the old app put back, so .swap's "지금 앱은 그대로예요" stays true.
    func testSwapClearsAPartialBundleAndPutsTheOldAppBack() throws {
        final class HalfMove: FileManager {
            override func moveItem(at src: URL, to dst: URL) throws {
                if src.lastPathComponent == "Half.app" {
                    try createDirectory(at: dst.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try super.moveItem(at: src, to: dst)
            }
        }
        let dir = try temp()
        let running = dir.appendingPathComponent("DogMonitor.app"), incoming = dir.appendingPathComponent("Half.app")
        try fakeBundle(running, build: "7", marker: "old")
        try fakeBundle(incoming, build: "8", marker: "new")
        let plan = try UpdateInstall.plan(running: running)
        XCTAssertThrowsError(try UpdateInstall.swap(plan, newBundle: incoming, fm: HalfMove())) {
            XCTAssertEqual($0 as? UpdateError, .swap)
        }
        XCTAssertEqual(marker(running), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.parked.path))
    }

    /// The version a bare debug binary shows is the one build_app.sh stamps into the real app.
    func testUnbundledVersionMatchesTheBuildScript() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build_app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("<key>CFBundleShortVersionString</key><string>\(AppInfo.unbundledVersion)</string>"))
    }

    func testPlanRefusesNonBundlesAndReadOnlyFolders() throws {
        let dir = try temp()
        XCTAssertThrowsError(try UpdateInstall.plan(running: dir.appendingPathComponent("debug"))) {
            XCTAssertEqual($0 as? UpdateError, .notBundled)
        }
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try fakeBundle(locked.appendingPathComponent("DogMonitor.app"), build: "7", marker: "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try UpdateInstall.plan(running: locked.appendingPathComponent("DogMonitor.app"))) {
            XCTAssertEqual($0 as? UpdateError, .notWritable)
        }
    }

    @MainActor
    func testAutoUpdateDefaultsOnAndPersists() throws {
        let suite = "jelly-updater-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(Updater(defaults: defaults).autoUpdate)
        Updater(defaults: defaults).autoUpdate = false
        XCTAssertFalse(Updater(defaults: defaults).autoUpdate)
    }
}
