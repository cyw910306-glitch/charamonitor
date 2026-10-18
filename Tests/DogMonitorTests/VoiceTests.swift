import XCTest
@testable import DogMonitor

/// Per-character voice: 울음소리 말투, a character's own 말투 and sounds, 대사 고치기.
final class VoiceTests: XCTestCase {
    func testCryKeepsTheLineIntactInBrackets() {
        let dog = Persona(name: "젤리", style: .cry, cries: ["멍!"])
        let line = "배터리가 10%밖에 안 남았어. 충전기 꽂아 줘!"
        XCTAssertEqual(dog.dress(line), "멍! (\(line))")
        XCTAssertEqual(dog.dress(line, flair: false), "멍! (\(line))")
        // No sounds of its own: the neutral ones; the other styles are untouched without flair.
        let bare = Persona(name: "젤리", style: .cry).dress(line)
        XCTAssertTrue(Persona.neutralCries.contains { bare == "\($0) (\(line))" }, bare)
        XCTAssertEqual(Persona(name: "젤리", style: .bright).dress(line, flair: false), line)
        XCTAssertTrue(PersonaStyle.cry.banmal)
        XCTAssertTrue(PersonaStyle.cry.leads.isEmpty && PersonaStyle.cry.tails.isEmpty)
        // A long answer: the sound on its own line, the answer outside brackets.
        let long = String(repeating: "저장 공간이 넉넉해요. ", count: 6)
        XCTAssertEqual(dog.dress(long), "멍!\n\(long)")
    }

    func testCrySoundStaysTheSameAllDaySoTheRepeatGateHolds() {
        let dog = Persona(name: "젤리", style: .cry, cries: ["멍!", "왕왕", "끄응…"])
        let day = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
        let first = dog.dress("또 왔어", day: day)
        XCTAssertEqual(dog.dress("또 왔어", day: day), first)
        XCTAssertEqual(dog.dress("또 왔어", day: day.addingTimeInterval(3600)), first)
    }

    func testOwnVoiceComesBeforeTheKindPreset() {
        let own = Persona.resolve(name: "삐약", character: .custom, id: nil, chosen: .auto, own: .cry, cries: ["삐!"])
        XCTAssertEqual(own.style, .cry)
        XCTAssertEqual(own.cries, ["삐!"])
        XCTAssertEqual(Persona.resolve(name: "삐약", character: .custom, id: nil, chosen: .polite, own: .cry).style, .polite)
        XCTAssertEqual(Persona.resolve(name: "삐약", character: .custom, id: nil, chosen: .auto, own: .auto).style, .friendly)
        XCTAssertEqual(Persona.resolve(name: "젤리", character: .dog, id: nil, chosen: .cry).cries, Persona.cries(character: .dog, id: nil))
        XCTAssertEqual(Persona.cries(character: .original, id: "original-tan-cat"), Persona.catCries)
    }

    func testCriesFromFilesAreCleaned() {
        let raw = [" 멍\n", "", "아주아주아주긴울음소리", "삐\u{7}익", "1", "2", "3", "4", "5"]
        XCTAssertEqual(Persona.cleanCries(raw), ["멍", "삐 익", "1", "2", "3", "4"])
        XCTAssertEqual(Persona.cleanCries(nil), [])
        XCTAssertEqual(Persona.oneLine("a\n\tb   c", max: 4), "a b")
    }

    func testLineOverridesFillOnlyKnownNames() {
        XCTAssertEqual(LineOverrides.unknown("{분} 뒤 {제목} {x}", allowed: ["분", "제목"]), ["x"])
        XCTAssertEqual(LineOverrides.fill("{제목}까지 {분}분", ["제목": "{분}회의", "분": "10"]), "{분}회의까지 10분")
        let saved = ["nudge.calendar": "{제목} 곧 시작! {분}분 남음"]
        XCTAssertEqual(LineOverrides.line("nudge.calendar", ["제목": "회의", "분": "5"], saved: saved), "회의 곧 시작! 5분 남음")
        XCTAssertNil(LineOverrides.line("nudge.hot", saved: saved))
        // Every slot's names are the ones its moment fills.
        for slot in LineOverrides.slots where slot.id.hasPrefix("nudge.") {
            XCTAssertFalse(slot.sample.isEmpty, slot.id)
        }
        XCTAssertEqual(LineOverrides.slots.first { $0.id == "nudge.calendar" }?.vars, ["분", "제목"])
        XCTAssertEqual(Nudge.calendar(title: "회의", minutes: 3).lineKey, "nudge.calendar")
        // 출근·점심·퇴근 are editable too; 퇴근 fills {분}.
        XCTAssertEqual(LineOverrides.slots.first { $0.id == "nudge.leave" }?.vars, ["분"])
        XCTAssertNotNil(LineOverrides.slots.first { $0.id == "nudge.morning" })
        XCTAssertEqual(LineOverrides.line("nudge.leave", Nudge.leave(minutes: 7).lineValues, saved: ["nudge.leave": "{분}분 뒤 끝!"]), "7분 뒤 끝!")
        XCTAssertEqual(PetModel.lineKey(.focusDone(coins: 2)), "pet.focusDone")
    }
}
