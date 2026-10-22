import XCTest
@testable import DogMonitor

final class FriendCryTests: XCTestCase {
    /// Every made voice is a real mono 16-bit WAV, not silent, and under half a second.
    func testMadeCriesAreValidShortWAVs() {
        for voice in [FriendCry.Voice.bark, .meow, .chirp(FriendCry.pitch("pack-x"))] {
            for kind in FriendCry.Kind.allCases {
                let wav = FriendCry.make(voice, kind)
                XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
                XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
                let pcm = wav.dropFirst(44)
                let seconds = Double(pcm.count / 2) / Double(FriendCry.sampleRate)
                XCTAssertGreaterThan(seconds, 0.1, "\(voice) \(kind)")
                XCTAssertLessThan(seconds, 0.5, "\(voice) \(kind)")
                XCTAssertTrue(pcm.contains { $0 != 0 }, "\(voice) \(kind)")
            }
        }
        XCTAssertNotEqual(FriendCry.make(.meow, .normal, variant: 0), FriendCry.make(.meow, .normal, variant: 1))
    }

    func testPitchIsStablePerCharacterAndDiffers() {
        XCTAssertEqual(FriendCry.pitch("pack-mochi"), FriendCry.pitch("pack-mochi"))
        XCTAssertEqual(FriendCry.hash("a"), 0xE40C292C)   // FNV-1a 32: the same on every launch
        XCTAssertNotEqual(FriendCry.pitch("pack-mochi"), FriendCry.pitch("pack-dubu"))
        XCTAssertTrue((520...1100).contains(FriendCry.pitch("anything")))
    }

    func testReactionKinds() {
        XCTAssertEqual(FriendCry.kind(.dizzy), .dizzy)
        XCTAssertEqual(FriendCry.kind(.pout), .sulk)
        XCTAssertEqual(FriendCry.kind(.jump), .hop)
        XCTAssertEqual(FriendCry.kind(.hearts), .normal)
    }

    /// Only known types, plain files, at most 2 MB, that really open, by name, ten at most.
    func testSoundFileRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = FriendCry.make(.bark, .normal)
        for i in 0..<12 { try good.write(to: dir.appendingPathComponent(String(format: "c%02d.wav", i))) }
        try good.write(to: dir.appendingPathComponent("a-notes.txt"))
        try Data("not audio".utf8).write(to: dir.appendingPathComponent("a-bad.wav"))
        try (good + Data(count: FriendCry.maxBytes)).write(to: dir.appendingPathComponent("a-big.wav"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("a-link.wav"), withDestinationURL: dir.appendingPathComponent("c00.wav"))
        let files = FriendCry.files(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(files, (0..<10).map { String(format: "c%02d.wav", $0) })
        XCTAssertEqual(FriendCry.files(in: dir.appendingPathComponent("none")), [])

        let into = dir.appendingPathComponent("sounds")
        XCTAssertEqual(FriendCry.add([dir.appendingPathComponent("a-bad.wav"), dir.appendingPathComponent("c00.wav")], to: into), 1)
        FriendCry.clear(into)
        XCTAssertFalse(FileManager.default.fileExists(atPath: into.path))

        // A file with a name already there only replaces it: 9 in, add c00, c01 and a new one = 10.
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        for i in 0..<9 { try good.write(to: into.appendingPathComponent(String(format: "c%02d.wav", i))) }
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        for n in ["c00.wav", "c01.wav", "new.wav"] { try good.write(to: other.appendingPathComponent(n)) }
        XCTAssertEqual(FriendCry.add(["c00.wav", "c01.wav", "new.wav"].map { other.appendingPathComponent($0) }, to: into), 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: into.appendingPathComponent("new.wav").path))

        // A sounds folder that is a link is not followed.
        let link = dir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: into)
        XCTAssertEqual(FriendCry.files(in: link), [])
    }

    /// Only a pack that loaded has a sounds folder: no made-up ids, no way out of the packs folder.
    func testPackFolderOnlyForLoadedPacks() {
        XCTAssertNil(FriendCry.packFolder("pack-x/../../../../Music"))
        XCTAssertNil(FriendCry.packFolder("pack-not-installed"))
        XCTAssertNil(FriendCry.source(character: "pack-x/../../Music").folder)
    }

    func testLimiterOnePerFriendAndSixPerSecond() {
        var l = FriendCry.Limiter()
        XCTAssertTrue(l.allow("buddy", at: 0, length: 0.3))
        XCTAssertFalse(l.allow("buddy", at: 0.1, length: 0.3))   // still crying
        XCTAssertTrue(l.allow("buddy", at: 0.31, length: 0.3))
        for i in 0..<4 { XCTAssertTrue(l.allow("m\(i)", at: 0.5, length: 0.3)) }
        XCTAssertFalse(l.allow("m9", at: 0.6, length: 0.3))   // six in the last second
        XCTAssertTrue(l.allow("m9", at: 1.01, length: 0.3))
    }
}
