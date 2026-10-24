import XCTest
@testable import DogMonitor
import CharaCore

/// 포스트잇: what the notes file decodes to, where notes go, and where the 커서 친구 stands to type along.
final class StickyNotesTests: XCTestCase {
    func testRoundTrip() {
        let notes = [StickyNote(text: "할 일", color: .mint, x: 10, y: 500, folded: true), StickyNote(x: -300, y: 900)]
        XCTAssertEqual(StickyFile.decode(StickyFile.encode(notes)), notes)
    }

    func testDecodeRejectsBrokenAndHugeFiles() {
        XCTAssertEqual(StickyFile.decode(Data("not json".utf8)), [])
        XCTAssertEqual(StickyFile.decode(Data(count: StickyFile.maxBytes + 1)), [])
        // An unknown colour is a broken file, not a guess.
        XCTAssertEqual(StickyFile.decode(Data(#"[{"id":"\#(UUID())","text":"","color":"neon","x":0,"y":0,"folded":false}]"#.utf8)), [])
    }

    func testDecodeCapsCountTextAndDuplicates() {
        var many = (0..<(StickyFile.maxNotes + 5)).map { _ in StickyNote(x: 0, y: 0) }
        many[1].id = many[0].id
        many[2].text = String(repeating: "가", count: StickyFile.maxText + 50)
        let got = StickyFile.decode(try! JSONEncoder().encode(many))
        XCTAssertEqual(got.count, StickyFile.maxNotes)
        XCTAssertEqual(Set(got.map(\.id)).count, got.count)
        XCTAssertEqual(got[1].text.count, StickyFile.maxText)
    }

    func testFoldKeepsTheTop() {
        var n = StickyNote(x: 100, y: 800)
        let open = StickyMath.frame(n)
        n.folded = true
        let shut = StickyMath.frame(n)
        XCTAssertEqual(open.maxY, shut.maxY)
        XCTAssertEqual(shut.height, StickyMath.foldedHeight)
        XCTAssertEqual(open.height, StickyMath.height)
    }

    func testOffScreenNoteComesBack() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertEqual(StickyMath.onScreen(CGPoint(x: 200, y: 600), screens: [screen]), CGPoint(x: 200, y: 600))
        let back = StickyMath.onScreen(CGPoint(x: 5000, y: 600), screens: [screen])
        XCTAssertTrue(screen.contains(back))
        XCTAssertTrue(screen.contains(StickyMath.frame(StickyNote(x: back.x, y: back.y))))
    }

    func testNewNotesCascade() {
        let area = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let a = StickyMath.newSpot(count: 0, in: area), b = StickyMath.newSpot(count: 1, in: area)
        XCTAssertLessThan(b.x, a.x)
        XCTAssertLessThan(b.y, a.y)
        XCTAssertEqual(StickyMath.newSpot(count: 8, in: area), a)
    }

    func testStoreAddsUpToTheCapAndCutsText() {
        let store = StickyStore(url: nil)
        let area = CGRect(x: 0, y: 0, width: 1440, height: 875)
        for _ in 0..<StickyFile.maxNotes { XCTAssertNotNil(store.add(in: area)) }
        XCTAssertNil(store.add(in: area))
        XCTAssertFalse(store.canAdd)
        let id = store.notes[0].id
        store.update(id) { $0.text = String(repeating: "a", count: StickyFile.maxText + 1) }
        XCTAssertEqual(store.notes[0].text.count, StickyFile.maxText)
        store.remove(id)
        XCTAssertEqual(store.notes.count, StickyFile.maxNotes - 1)
    }

    func testTypingSpotBesideTheNote() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 875), size = CGSize(width: 60, height: 40)
        let note = CGRect(x: 300, y: 400, width: StickyMath.width, height: StickyMath.height)
        XCTAssertEqual(StickyMath.typingSpot(note: note, size: size, in: bounds), CGPoint(x: note.maxX + StickyMath.typingGap, y: note.minY))
        // No room on the right: the left side.
        let edge = CGRect(x: bounds.maxX - note.width, y: 400, width: note.width, height: note.height)
        XCTAssertEqual(StickyMath.typingSpot(note: edge, size: size, in: bounds).x, edge.minX - StickyMath.typingGap - size.width)
        // A note hanging below the screen: the friend stays on it.
        let low = CGRect(x: 300, y: -100, width: note.width, height: note.height)
        XCTAssertEqual(StickyMath.typingSpot(note: low, size: size, in: bounds).y, bounds.minY)
    }

    func testFoldedTitle() {
        XCTAssertEqual(StickyNoteView.title("\n  장보기 \n우유"), "장보기")
        XCTAssertEqual(StickyNoteView.title("  \n"), L("빈 메모"))
    }

    /// The notes file sits beside the folders 내 설정 파일 takes, never in one.
    func testNotesStayOutOfTheSetupFile() {
        let parent = StickyFile.defaultURL.deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(parent, "DogMonitor")
        XCTAssertFalse(SetupFile.folders.contains(StickyFile.defaultURL.lastPathComponent))
    }
}
