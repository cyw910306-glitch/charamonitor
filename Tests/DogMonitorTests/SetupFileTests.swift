import XCTest
@testable import DogMonitor

/// 내 설정 파일: export then import between two scratch "Macs" (folders and defaults suites of their own).
final class SetupFileTests: XCTestCase {
    private var temp: URL!
    private var suites: [String] = []
    private var staged: [SetupFile.Staged] = []
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("setupfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        staged.forEach { $0.discard() }
        try? FileManager.default.removeItem(at: temp)
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
    }

    private func suite() -> UserDefaults {
        let name = "test.setupfile.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A well-formed root dictionary, with `change` applied.
    private func root(files: [String: Data] = [:], settings: [String: Any] = [:],
                      _ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var r: [String: Any] = ["format": SetupFile.formatVersion, "app": "2.5", "created": Date(), "settings": settings, "files": files]
        change(&r)
        return r
    }

    /// `root` as a binary .charamonitor file.
    private func file(_ root: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> URL {
        let url = temp.appendingPathComponent("\(UUID().uuidString).charamonitor")
        try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0).write(to: url)
        return url
    }

    private func inspect(_ url: URL, limit: Int64 = SetupFile.maxBytes) throws -> SetupFile.Staged {
        let s = try SetupFile.inspect(url, limit: limit)
        staged.append(s)
        return s
    }

    private func stage(_ files: [String: Data]) throws -> SetupFile.Staged {
        let s = try SetupFile.stage(root(files: files))
        staged.append(s)
        return s
    }

    private func exported(_ url: URL) throws -> [String: Data] {
        let r = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        return try XCTUnwrap(r?["files"] as? [String: Data])
    }

    func testRoundTripCarriesSettingsAndCharactersAndLeavesSecretsBehind() throws {
        let a = SetupFile.Dirs(root: temp.appendingPathComponent("A")), b = SetupFile.Dirs(root: temp.appendingPathComponent("B"))
        let da = suite(), db = suite()
        try write(#"{"id":"mine"}"#, "Packs/pack-mine/pack.json", in: a.root)
        try write("png", "Packs/pack-mine/frames/idle-0.png", in: a.root)
        try write("{}", "Characters/1234/character.json", in: a.root)
        da.set("original", forKey: "character")
        da.set(true, forKey: "cursorBuddy")
        da.set(25, forKey: "focus.goal")
        da.set(Data([1, 2, 3]), forKey: "desktopRug")
        da.set(["a": "b"], forKey: "assistant.lines")
        da.set([15, 5], forKey: "assistant.calendarLeads")
        da.set("secret-token", forKey: "assistant.pushoverToken")
        da.set("topic", forKey: "assistant.ntfyTopic")
        da.set(true, forKey: "assistant.agent.consent")
        da.set("cal-id", forKey: "assistant.agentCalendarID")
        da.set("2.4", forKey: "lastSeenVersion")
        da.set(true, forKey: "aiAutoRefine")
        // B had its own pack and a setting the file does not have.
        try write("{}", "Packs/pack-old/pack.json", in: b.root)
        db.set(true, forKey: "settingsTextLarge")
        db.set("keep", forKey: "assistant.pushoverToken")

        let out = temp.appendingPathComponent("내 캐릭모니터.charamonitor")
        let m = try SetupFile.export(to: out, defaults: da, dirs: a)
        XCTAssertEqual(m.packs, 1)
        XCTAssertEqual(m.characters, 1)
        XCTAssertEqual(m.settings, 6)
        XCTAssertTrue(try Data(contentsOf: out).starts(with: Array("bplist00".utf8)))

        let s = try inspect(out)
        XCTAssertEqual(s.packs, 1)
        XCTAssertEqual(s.characters, 1)
        XCTAssertNil(s.settings["assistant.pushoverToken"])
        XCTAssertNil(s.settings["lastSeenVersion"])
        let fm = FileManager.default
        let written = s.temp.appendingPathComponent("Packs/pack-mine/frames/idle-0.png").path
        XCTAssertEqual((try fm.attributesOfItem(atPath: written)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual((try fm.attributesOfItem(atPath: s.temp.appendingPathComponent("Packs/pack-mine").path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let backup = try SetupFile.install(s, defaults: db, dirs: b, screens: [])

        XCTAssertTrue(fm.fileExists(atPath: b.packs.appendingPathComponent("pack-mine/frames/idle-0.png").path))
        XCTAssertFalse(fm.fileExists(atPath: b.packs.appendingPathComponent("pack-old").path))
        XCTAssertTrue(fm.fileExists(atPath: b.characters.appendingPathComponent("1234/character.json").path))
        XCTAssertEqual(db.string(forKey: "character"), "original")
        XCTAssertEqual(db.object(forKey: "cursorBuddy") as? Bool, true)
        XCTAssertEqual(db.integer(forKey: "focus.goal"), 25)
        XCTAssertEqual(db.data(forKey: "desktopRug"), Data([1, 2, 3]))
        XCTAssertEqual(db.dictionary(forKey: "assistant.lines") as? [String: String], ["a": "b"])
        XCTAssertEqual(db.array(forKey: "assistant.calendarLeads") as? [Int], [15, 5])
        XCTAssertNil(db.object(forKey: "settingsTextLarge"))                       // replaced: the file did not have it
        XCTAssertEqual(db.string(forKey: "assistant.pushoverToken"), "keep")     // never touched
        for key in ["assistant.agent.consent", "assistant.agentCalendarID", "lastSeenVersion", "aiAutoRefine", "assistant.ntfyTopic"] {
            XCTAssertNil(db.object(forKey: key), key)
        }
        XCTAssertTrue(db.bool(forKey: SetupFile.helloKey))
        XCTAssertFalse(fm.fileExists(atPath: s.temp.path))

        // The backup is a setup file of B as it was, and imports back.
        let old = try inspect(backup)
        XCTAssertEqual(old.packs, 1)
        XCTAssertEqual(old.settings["settingsTextLarge"] as? Bool, true)
    }

    func testUnknownAndMistypedKeysAreDropped() {
        let kept = SetupFile.filter(["palette": "mint", "cursorBuddy": true, "focus.goal": 25,
                                     "unknown": "x", "assistant.pushoverToken": "t", "assistant.byo.provider": "openai",
                                     "palette2": 1, "cursorBuddySize": 3, "focus.sound": 1, "focus.goal2": true,
                                     "hangingFriends": "not data"])
        XCTAssertEqual(Set(kept.keys), ["palette", "cursorBuddy", "focus.goal"])
        XCTAssertFalse(SetupFile.valid(NSNumber(value: true), .number))
        XCTAssertFalse(SetupFile.valid(NSNumber(value: 1), .bool))
        XCTAssertFalse(SetupFile.valid([true], .ints))
        for secret in ["assistant.pushoverToken", "assistant.pushoverUser", "assistant.ntfyTopic", "claudeUseCLILogin",
                       "assistant.agentCalendarID", "assistant.agentReminderListID", "lastSeenVersion", "photoPath",
                       "assistant.agent.consent", "assistant.byo.provider", "assistant.mail.accounts", "weatherAdviceDay",
                       "assistant.urlSay", "autoUpdate", "cleanerProtected", "claudeRefine", "weatherWindow"] {
            XCTAssertNil(SetupFile.keys[secret], secret)
        }
    }

    func testTraversalAndOddNamesAreRejected() throws {
        let long = String(repeating: "a", count: 256)
        let deep = "Packs/" + Array(repeating: "d", count: SetupFile.maxDepth).joined(separator: "/")
        for path in ["../evil", "Packs/../../evil", "/etc/passwd", "Other/x", "Packs\\..\\x", "Packs/a\\b", "Packs", "Packs/",
                     "Packs//x", "Packs/./x", "Packs/p/..", "Packs/a\u{0}b", "Packs/a\nb", "Packs/a\u{7f}", "Packs/cafe\u{301}",
                     "Packs/\(long)", deep, "manifest.json", "Backups/x"] {
            XCTAssertNil(SetupFile.components(path), path)
            XCTAssertThrowsError(try stage([path: Data("x".utf8)]), path)
        }
        XCTAssertEqual(SetupFile.components("Packs/p/frames/idle-0.png"), ["Packs", "p", "frames", "idle-0.png"])
        XCTAssertNotNil(SetupFile.components("Characters/caf\u{e9}/" + String(repeating: "a", count: 255)))
    }

    func testAppleDoubleNamesAreRejected() {
        for path in ["Packs/p/._pack.json", "Packs/._p/pack.json", "._Packs/p/x", "Pictures/._1.png"] {
            XCTAssertNil(SetupFile.components(path), path)
            XCTAssertThrowsError(try stage([path: Data("x".utf8)]), path)
        }
    }

    func testCaseDuplicatesAndFileWhereAFolderGoesAreRejected() throws {
        let x = Data("x".utf8)
        XCTAssertThrowsError(try stage(["Packs/p/A.png": x, "Packs/p/a.png": x]))
        XCTAssertThrowsError(try stage(["Packs/p/Ä.png": x, "Packs/p/ä.png": x]))
        XCTAssertThrowsError(try stage(["Packs/p": x, "Packs/p/pack.json": x]))
        XCTAssertThrowsError(try stage(["Packs/P": x, "Packs/p/pack.json": x]))
        // The same folder spelled two ways is one folder, not a refusal.
        let ok = try stage(["Packs/P/a.json": x, "Packs/p/b.json": x, "Characters/c/character.json": x])
        XCTAssertEqual(ok.characters, 1)
    }

    func testTooBigFilesEntriesAndCountsAreRejected() throws {
        let big = try file(root(files: ["Packs/p/a.bin": Data(count: 4096)]))
        XCTAssertThrowsError(try inspect(big, limit: 1024)) { XCTAssertTrue($0.localizedDescription.contains("너무 커요")) }
        XCTAssertThrowsError(try SetupFile.stage(root(files: ["Packs/p/a.bin": Data(count: 600), "Packs/p/b.bin": Data(count: 600)]), limit: 1000))
        XCTAssertThrowsError(try stage(["Packs/p/a.bin": Data(count: SetupFile.maxFileBytes + 1)]))
        var many: [String: Data] = [:]
        for i in 0...SetupFile.maxEntries { many["Packs/p/\(i)"] = Data() }
        XCTAssertThrowsError(try stage(many))
    }

    func testWrongTypesAndNonBinaryFilesAreRejected() throws {
        let bad: [Any] = [
            ["not", "a", "dictionary"],
            root { $0["format"] = true },
            root { $0["format"] = "2" },
            root { $0["format"] = 1 },
            root { $0["format"] = 2.5 },
            root { $0["app"] = 2 },
            root { $0["created"] = "today" },
            root { $0["created"] = nil },
            root { $0["settings"] = ["a"] },
            root { $0["files"] = ["Packs/p/a": "text, not data"] },
            root { $0["files"] = nil },
            root { $0["extra"] = "x" },
        ]
        for r in bad { XCTAssertThrowsError(try inspect(try file(r)), "\(r)") }
        XCTAssertThrowsError(try inspect(try file(root(), format: .xml)))
        let plain = temp.appendingPathComponent("plain.charamonitor")
        try Data("hello".utf8).write(to: plain)
        XCTAssertThrowsError(try inspect(plain))
        let empty = temp.appendingPathComponent("empty.charamonitor")
        try Data().write(to: empty)
        XCTAssertThrowsError(try inspect(empty))
        XCTAssertEqual(try inspect(try file(root())).packs, 0)
    }

    func testNewerFormatAsksForAnUpdate() throws {
        XCTAssertThrowsError(try inspect(try file(root { $0["format"] = SetupFile.formatVersion + 1; $0["more"] = 1 }))) {
            XCTAssertTrue($0.localizedDescription.contains("업데이트"), $0.localizedDescription)
        }
    }

    func testOutOfRangeNumbersAreDropped() {
        let kept = SetupFile.filter(["focus.goal": Int64.max, "weatherSize": 99, "weatherLat": 200.0, "weatherLon": -500.0,
                                     "weatherX": Double.nan, "weatherY": Double.infinity])
        XCTAssertTrue(kept.isEmpty, "\(kept)")
        let ok = SetupFile.filter(["focus.goal": 50, "weatherSize": 6, "weatherLat": 37.5, "weatherLon": 127.0, "weatherX": 10.0])
        XCTAssertEqual(ok.count, 5)
    }

    /// Links (to a file outside, to a folder) and an unreadable folder in Packs: skipped, never followed, never blocking.
    func testExportSkipsLinksAndUnreadableFolders() throws {
        let a = SetupFile.Dirs(root: temp.appendingPathComponent("A")), fm = FileManager.default
        try write("{}", "Packs/p/frames/idle-0.png", in: a.root)
        try fm.createSymbolicLink(atPath: a.packs.appendingPathComponent("p/pack.json").path, withDestinationPath: "/etc/hosts")
        try fm.createSymbolicLink(atPath: a.packs.appendingPathComponent("etc").path, withDestinationPath: "/etc")
        try write("{}", "Packs/locked/x.json", in: a.root)
        let locked = a.packs.appendingPathComponent("locked").path
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let out = temp.appendingPathComponent("links.charamonitor")
        try SetupFile.export(to: out, defaults: suite(), dirs: a)
        XCTAssertEqual(Set(try exported(out).keys), ["Packs/p/frames/idle-0.png"])
    }

    func testPicturesTravelInTheFileNotAsPaths() throws {
        let a = SetupFile.Dirs(root: temp.appendingPathComponent("A")), b = SetupFile.Dirs(root: temp.appendingPathComponent("B"))
        let da = suite(), db = suite()
        let photo = temp.appendingPathComponent("mine/cat photo.JPG"), notImage = temp.appendingPathComponent("mine/hosts.png")
        try FileManager.default.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: photo)
        try Data("127.0.0.1 localhost".utf8).write(to: notImage)
        var hang = HangPrefs()
        hang.slots[0].imagePath = photo.path
        hang.slots[1].imagePath = "/nowhere/gone.png"
        hang.slots[2].imagePath = notImage.path
        da.set(try JSONEncoder().encode(hang), forKey: "hangingFriends")
        let out = temp.appendingPathComponent("p.charamonitor")
        try SetupFile.export(to: out, defaults: da, dirs: a)
        XCTAssertEqual(Set(try exported(out).keys), ["Pictures/1.png"])
        let s = try inspect(out)
        let carried = try JSONDecoder().decode(HangPrefs.self, from: XCTUnwrap(s.settings["hangingFriends"] as? Data))
        XCTAssertEqual(carried.slots[0].imagePath, "Pictures/1.png")
        XCTAssertNil(carried.slots[1].imagePath)
        XCTAssertNil(carried.slots[2].imagePath)
        try SetupFile.install(s, defaults: db, dirs: b, screens: [])
        let got = try JSONDecoder().decode(HangPrefs.self, from: XCTUnwrap(db.data(forKey: "hangingFriends")))
        XCTAssertEqual(got.slots[0].imagePath, b.pictures.appendingPathComponent("1.png").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(got.slots[0].imagePath))), png)
        XCTAssertNil(got.slots[1].imagePath)
    }

    func testAPathFromAFileIsNeverInstalled() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite()
        var hang = HangPrefs()
        hang.slots[0].imagePath = "/Users/someone/secret.png"
        hang.slots[1].imagePath = "Pictures/.."
        let s = try inspect(try file(root(settings: ["hangingFriends": try JSONEncoder().encode(hang)])))
        try SetupFile.install(s, defaults: db, dirs: b, screens: [])
        let got = try JSONDecoder().decode(HangPrefs.self, from: XCTUnwrap(db.data(forKey: "hangingFriends")))
        XCTAssertNil(got.slots[0].imagePath)
        XCTAssertNil(got.slots[1].imagePath)
    }

    func testOnlyTheNewestBackupsAreKept() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite()
        let f = try file(root())
        for i in 0..<5 {
            try SetupFile.install(try inspect(f), defaults: db, dirs: b, screens: [], now: Date(timeIntervalSince1970: Double(i) * 60))
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: b.backups.path)
        XCTAssertEqual(left.count, SetupFile.keptBackups)
    }

    /// A failure on the second folder puts the first back: no mix of the file's packs and this Mac's characters.
    func testAFailureHalfwayPutsEverythingBack() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite()
        let empty = try file(root())
        for i in 0..<SetupFile.keptBackups {
            try SetupFile.install(try inspect(empty), defaults: db, dirs: b, screens: [], now: Date(timeIntervalSince1970: Double(i) * 60))
        }
        try write("old", "Packs/pack-old/pack.json", in: b.root)
        try write("old", "Characters/c/character.json", in: b.root)
        db.set("mint", forKey: "palette")
        let s = try stage(["Packs/pack-new/pack.json": Data("new".utf8), "Characters/n/character.json": Data("new".utf8)])
        let chars = s.temp.appendingPathComponent("Characters")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: chars.path)   // a directory that cannot move
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chars.path) }
        XCTAssertThrowsError(try SetupFile.install(s, defaults: db, dirs: b, screens: []))
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: b.packs.appendingPathComponent("pack-old/pack.json").path))
        XCTAssertFalse(fm.fileExists(atPath: b.packs.appendingPathComponent("pack-new").path))
        XCTAssertTrue(fm.fileExists(atPath: b.characters.appendingPathComponent("c/character.json").path))
        XCTAssertEqual(db.string(forKey: "palette"), "mint")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: b.root.path).filter { $0.hasPrefix(".replaced") }, [])
        // Nothing old goes before the swap worked: the backups so far and the one just made are all there.
        XCTAssertEqual(SetupFile.backups(in: b.backups).count, SetupFile.keptBackups + 1)
    }

    func testWindowSpotOffEveryScreenComesBackOnTheMain() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900), side = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(SetupFile.clamp(CGPoint(x: 2000, y: 500), into: [main, side]), CGPoint(x: 2000, y: 500))
        XCTAssertEqual(SetupFile.clamp(CGPoint(x: 5000, y: -300), into: [main, side]), CGPoint(x: 1280, y: 0))
        XCTAssertEqual(SetupFile.clamp(CGPoint(x: 5000, y: 5000), into: []), CGPoint(x: 5000, y: 5000))
    }

    // MARK: Attack reports on 47a2f3d

    /// A 200MB petState or a 1MB string would be written into the defaults read at every launch.
    func testSettingValuesAreKeptSmall() {
        let big = SetupFile.maxSettingBytes + 1
        let kept = SetupFile.filter(["petState": Data(count: big), "motionLevel": String(repeating: "a", count: big),
                                     "assistant.lines": ["a": String(repeating: "b", count: big)],
                                     "desktopRug": Data([1, 2, 3]), "palette": "mint", "assistant.persona": "x"])
        XCTAssertEqual(Set(kept.keys), ["desktopRug", "palette", "assistant.persona"])
    }

    /// x 1e308 in a slot: frame.width * x is inf, and the layers get NaN. Numbers inside the JSON blobs are checked, and
    /// the stores clamp what they load anyway.
    func testNumbersInsideSettingsBlobsStayFinite() throws {
        let wild = Data(#"{"slots":[{"charm":"star","rope":"thread","x":1e308,"length":-1e308}],"on":true}"#.utf8)
        let clones = Data(#"{"on":true,"clones":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","x":1e300,"y":2}]}"#.utf8)
        let deep = Data(String(repeating: "[", count: 200_000).utf8)   // not JSON: parsed without a crash, then left as data
        let kept = SetupFile.filter(["hangingFriends": wild, "meadowFriends": wild, "desktopClones": clones, "desktopRug": deep])
        XCTAssertEqual(Set(kept.keys), ["desktopRug"])
        XCTAssertNotNil(SetupFile.filter(["petState": try JSONEncoder().encode(["updated": Date()])])["petState"])

        var hang = HangPrefs()
        hang.slots[0].x = 40; hang.slots[0].length = 1e9; hang.slots[1].x = -3; hang.volume = 1e9
        let got = try JSONDecoder().decode(HangPrefs.self, from: JSONEncoder().encode(hang))
        XCTAssertEqual(got.slots[0].x, 1)
        XCTAssertEqual(got.slots[0].length, HangSlot.lengths.upperBound)
        XCTAssertEqual(got.slots[1].x, 0)
        XCTAssertEqual(got.volume, 1)
        var meadow = MeadowPrefs()
        meadow.slots[0].x = 1e12
        XCTAssertEqual(try JSONDecoder().decode(MeadowPrefs.self, from: JSONEncoder().encode(meadow)).slots[0].x, 1)
        var many = ClonePrefs()
        many.clones = (0..<50).map { _ in CloneSpot(character: nil, x: 0.5, y: 0) }
        XCTAssertEqual(try JSONDecoder().decode(ClonePrefs.self, from: JSONEncoder().encode(many)).clones.count, ClonePrefs.maxCount)
    }

    /// One non-dictionary slot used to skip the mapping and keep an outside path in the blob.
    func testSlotsThatAreNotAllDictionariesNeverPassAPath() throws {
        let mixed = Data(#"{"slots":[{"imagePath":"/etc/hosts","x":0.5,"length":90},1]}"#.utf8)
        XCTAssertNil(SetupFile.mapPictures(mixed) { $0 })
        XCTAssertNil(SetupFile.mapPictures(Data(#"{"slots":"/etc/hosts"}"#.utf8)) { $0 })
        XCTAssertNotNil(SetupFile.mapPictures(Data(#"{"on":true}"#.utf8)) { $0 })
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite()
        db.set(Data("{}".utf8), forKey: "meadowFriends")
        let s = try inspect(try file(root(settings: ["meadowFriends": mixed])))
        try SetupFile.install(s, defaults: db, dirs: b, screens: [])
        XCTAssertNil(db.object(forKey: "meadowFriends"))
    }

    /// Pictures in a file are what export makes: images, side by side, within the picture sizes.
    func testPicturesInAFileMustBeImages() throws {
        XCTAssertThrowsError(try stage(["Pictures/evil.html": Data("<script>".utf8)]))
        XCTAssertThrowsError(try stage(["Pictures/big.png": Data(count: SetupFile.maxPictureBytes + 1)]))
        XCTAssertThrowsError(try stage(["Pictures/big.png": png + Data(count: SetupFile.maxPictureBytes)]))
        XCTAssertThrowsError(try stage(["Pictures/dir/1.png": png]))
        let each = png + Data(count: SetupFile.maxPictureBytes - png.count)
        var over: [String: Data] = [:]
        for i in 0...(SetupFile.maxPicturesBytes / each.count) { over["Pictures/\(i).png"] = each }
        XCTAssertThrowsError(try stage(over))
        XCTAssertNoThrow(try stage(["Pictures/1.png": png, "Pictures/2.png": each]))
    }

    /// The install side maps only Pictures/<a plain name> that is a regular file: no NUL, no folder, no empty name.
    func testInstalledPicturePathsAreCheckedLikeFileNames() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite()
        var hang = HangPrefs()
        hang.slots[0].imagePath = "Pictures/\u{0}"
        hang.slots[1].imagePath = "Pictures/1.png"
        hang.slots[2].imagePath = "Pictures/"
        hang.slots[3].imagePath = "Pictures/\u{1b}1.png"
        let s = try inspect(try file(root(files: ["Pictures/1.png": png], settings: ["hangingFriends": try JSONEncoder().encode(hang)])))
        try SetupFile.install(s, defaults: db, dirs: b, screens: [])
        let got = try JSONDecoder().decode(HangPrefs.self, from: XCTUnwrap(db.data(forKey: "hangingFriends")))
        XCTAssertEqual(got.slots.prefix(4).map(\.imagePath), [nil, b.pictures.appendingPathComponent("1.png").path, nil, nil])
    }

    func testHalfAWeatherSpotIsDropped() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite()
        db.set(10.0, forKey: "weatherY")
        let s = try inspect(try file(root(settings: ["weatherX": 1e300])))
        try SetupFile.install(s, defaults: db, dirs: b, screens: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        XCTAssertNil(db.object(forKey: "weatherX"))
        XCTAssertNil(db.object(forKey: "weatherY"))
    }

    func testCalendarLeadsAreOneOfThePickers() {
        for odd: [Any] in [[1.5], [Int64.max, -5, 0], [10, 30], [], Array(repeating: 5, count: 1000)] {
            XCTAssertTrue(SetupFile.filter(["assistant.calendarLeads": odd]).isEmpty, "\(odd)")
        }
        XCTAssertEqual(SetupFile.filter(["assistant.calendarLeads": [15, 5]]).count, 1)
    }

    /// "ß" and "ss" are one folder on APFS: one pack on the confirm sheet.
    func testFoldersAPFSMergesCountOnce() throws {
        let x = Data("x".utf8)
        XCTAssertEqual(try stage(["Packs/ß/a.json": x, "Packs/ss/b.json": x, "Packs/Q/c.json": x]).packs, 2)
        XCTAssertEqual(SetupFile.count(["Packs/ß/a", "Packs/SS/b", "Packs/x"], in: "Packs"), 1)
    }

    func testNonsenseFormatIsABrokenFileNotANewerOne() throws {
        for f in [Double.nan, Double.infinity, 1e300, 2.5] {
            XCTAssertThrowsError(try inspect(try file(root { $0["format"] = f })), "\(f)") {
                XCTAssertFalse($0.localizedDescription.contains("업데이트"), "\(f)")
            }
        }
    }

    /// The owner's own files in Backups are never pruned, and the newest backup always stays.
    func testBackupRotationTouchesOnlyItsOwnNewestFirst() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite(), fm = FileManager.default
        try fm.createDirectory(at: b.backups, withIntermediateDirectories: true)
        let mine = ["내 캐릭모니터.charamonitor", "work mac.charamonitor", "0 first export.charamonitor"]
        for name in mine { try Data("mine".utf8).write(to: b.backups.appendingPathComponent(name)) }
        let f = try file(root())
        var last: URL?
        for i in 0..<5 {
            last = try SetupFile.install(try inspect(f), defaults: db, dirs: b, screens: [], now: Date(timeIntervalSince1970: Double(i) * 60))
        }
        let left = Set(try fm.contentsOfDirectory(atPath: b.backups.path))
        XCTAssertTrue(left.isSuperset(of: mine))
        XCTAssertEqual(SetupFile.backups(in: b.backups).count, SetupFile.keptBackups)
        XCTAssertEqual(SetupFile.backups(in: b.backups).last, last)
    }

    /// Three backups in Seoul, then one in Los Angeles an hour later: the LA one is the newest and stays.
    func testBackupOrderHoldsAcrossTimeZones() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite(), f = try file(root())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        NSTimeZone.default = TimeZone(identifier: "Asia/Seoul")!
        for i in 0..<3 { try SetupFile.install(try inspect(f), defaults: db, dirs: b, screens: [], now: t0 + Double(i)) }
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let la = try SetupFile.install(try inspect(f), defaults: db, dirs: b, screens: [], now: t0 + 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: la.path))
        XCTAssertEqual(SetupFile.backups(in: b.backups).last, la)
        XCTAssertEqual(SetupFile.backups(in: b.backups).count, SetupFile.keptBackups)
    }

    /// Two imports in the same second: the first backup (the state before both) is not overwritten.
    func testTwoImportsInOneSecondKeepBothBackups() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite(), now = Date(timeIntervalSince1970: 1000)
        db.set("before", forKey: "palette")
        let first = try SetupFile.install(try inspect(try file(root(settings: ["palette": "imported1"]))), defaults: db, dirs: b, screens: [], now: now)
        let second = try SetupFile.install(try inspect(try file(root(settings: ["palette": "imported2"]))), defaults: db, dirs: b, screens: [], now: now)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try inspect(first).settings["palette"] as? String, "before")
        XCTAssertEqual(try inspect(second).settings["palette"] as? String, "imported1")
    }

    /// What the backup could not carry (an AppleDouble name, a link) is kept beside it, never deleted.
    func testFilesTheBackupCouldNotCarryAreKept() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite(), fm = FileManager.default
        try write("{}", "Packs/p/pack.json", in: b.root)
        try write("meta", "Packs/p/._meta", in: b.root)
        try fm.createSymbolicLink(atPath: b.packs.appendingPathComponent("p/link").path, withDestinationPath: "/etc/hosts")
        let backup = try SetupFile.install(try stage(["Packs/new/pack.json": Data("{}".utf8)]), defaults: db, dirs: b, screens: [])
        XCTAssertEqual(Set(try exported(backup).keys), ["Packs/p/pack.json"])
        let kept = SetupFile.leftovers(of: backup)
        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("Packs/p/._meta"), encoding: .utf8), "meta")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: kept.appendingPathComponent("Packs/p/link").path), "/etc/hosts")
        XCTAssertTrue(fm.fileExists(atPath: b.packs.appendingPathComponent("new/pack.json").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: b.root.path).filter { $0.hasPrefix(".replaced") }, [])
        // Nothing skipped: nothing kept.
        let next = try SetupFile.install(try stage([:]), defaults: db, dirs: b, screens: [], now: Date() + 5)
        XCTAssertFalse(fm.fileExists(atPath: SetupFile.leftovers(of: next).path))
    }

    /// A backup that cannot be made stops the import before anything changes.
    func testNoBackupNoImport() throws {
        let b = SetupFile.Dirs(root: temp.appendingPathComponent("B")), db = suite(), fm = FileManager.default
        try write("old", "Packs/pack-old/pack.json", in: b.root)
        try fm.createDirectory(at: b.backups, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: b.backups.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.backups.path) }
        let s = try stage(["Packs/new/pack.json": Data("{}".utf8)])
        XCTAssertThrowsError(try SetupFile.install(s, defaults: db, dirs: b, screens: [])) {
            XCTAssertTrue($0.localizedDescription.contains("백업하지 못해서"), $0.localizedDescription)
        }
        XCTAssertTrue(fm.fileExists(atPath: b.packs.appendingPathComponent("pack-old/pack.json").path))
        XCTAssertFalse(fm.fileExists(atPath: b.packs.appendingPathComponent("new").path))
    }

    /// Export counts the whole file, settings and plist too, so it never makes one import refuses.
    func testExportNeverMakesAFileImportRefuses() throws {
        let a = SetupFile.Dirs(root: temp.appendingPathComponent("A")), da = suite()
        try write(String(repeating: "x", count: 900), "Packs/p/a.json", in: a.root)
        da.set(String(repeating: "y", count: 400), forKey: "assistant.persona")
        let out = temp.appendingPathComponent("o.charamonitor")
        XCTAssertThrowsError(try SetupFile.export(to: out, defaults: da, dirs: a, limit: 1000))
        XCTAssertThrowsError(try SetupFile.export(to: out, defaults: suite(), dirs: a, limit: 800))   // files alone over
        try SetupFile.export(to: out, defaults: da, dirs: a, limit: 4000)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber).int64Value
        XCTAssertNoThrow(try inspect(out, limit: size))
    }

    /// A hard link in Packs to a file outside, and a picture path that is a link: neither is read.
    func testExportReadsNoHardLinkAndNoLinkedPicture() throws {
        let a = SetupFile.Dirs(root: temp.appendingPathComponent("A")), da = suite(), fm = FileManager.default
        let secret = temp.appendingPathComponent("outside/id_rsa"), real = temp.appendingPathComponent("outside/real.png")
        try fm.createDirectory(at: secret.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PRIVATE KEY".utf8).write(to: secret)
        try png.write(to: real)
        try write("{}", "Packs/p/pack.json", in: a.root)
        XCTAssertEqual(link(secret.path, a.packs.appendingPathComponent("p/hard.json").path), 0)
        let linked = temp.appendingPathComponent("outside/linked.png")
        try fm.createSymbolicLink(atPath: linked.path, withDestinationPath: real.path)
        var hang = HangPrefs()
        hang.slots[0].imagePath = linked.path
        hang.slots[1].imagePath = real.path
        da.set(try JSONEncoder().encode(hang), forKey: "hangingFriends")
        let out = temp.appendingPathComponent("h.charamonitor")
        let m = try SetupFile.export(to: out, defaults: da, dirs: a)
        XCTAssertEqual(Set(try exported(out).keys), ["Packs/p/pack.json", "Pictures/1.png"])
        XCTAssertEqual(m.skipped, 1)
    }

    /// After an import this copy writes nothing more to the owner's preferences (it quits; the new copy has the file's).
    func testAReplacedCopyWritesNoPreferences() {
        let key = "test.setupfile.guard.\(UUID().uuidString)", d = AppDefaults.owner
        SetupFile.replaced = true
        defer { SetupFile.replaced = false }
        d.set("x", forKey: key)
        d.set(true, forKey: key)
        d.set(3, forKey: key)
        d.set(2.5, forKey: key)
        d.set(Float(1), forKey: key)
        d.set(URL(fileURLWithPath: "/"), forKey: key)
        XCTAssertNil(d.object(forKey: key))
    }
}
