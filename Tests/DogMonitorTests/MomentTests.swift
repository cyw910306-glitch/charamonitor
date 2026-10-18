import XCTest
@testable import DogMonitor

/// The shared foundation for lively moments: burst motions, line variants, persona flavor, held bubbles.
final class MomentTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let all = Set(ExtraMotion.allCases)

    override func tearDown() { SituationEngine.burst = nil }

    func testBurstBeatsBusyThenExpires() {
        var e = SituationEngine()
        XCTAssertEqual(e.update(battery: nil, pose: .sprint, available: all, now: t0), .special)
        SituationEngine.play([.eat, .special], seconds: 8, now: t0)
        XCTAssertEqual(e.update(battery: nil, pose: .sprint, available: all, now: t0 + 7), .eat)
        XCTAssertNotEqual(e.update(battery: nil, pose: .sprint, available: all, now: t0 + 8), .eat)
        XCTAssertNil(SituationEngine.burst)
        // Capped at 15 s; the first motion the character has wins; none drawn leaves the pose alone.
        SituationEngine.play([.eat], seconds: 60, now: t0)
        XCTAssertEqual(SituationEngine.burst?.until, t0 + SituationEngine.burstCap)
        SituationEngine.play([.hungry, .special], now: t0)
        XCTAssertEqual(e.update(battery: nil, pose: .walk, available: [.special], now: t0 + 1), .special)
        SituationEngine.play([.eat], now: t0)
        XCTAssertNil(e.update(battery: nil, pose: .walk, available: [.special], now: t0 + 1))
    }

    func testLinePickNeverRepeatsAndStaysInRange() {
        XCTAssertEqual(LinePick.next(1, last: 0), 0)
        XCTAssertEqual(LinePick.next(0, last: nil), 0)
        for n in 2...5 {
            for last in 0..<n {
                for r in 0..<(n - 1) {
                    let i = LinePick.next(n, last: last, random: { _ in r })
                    XCTAssertTrue((0..<n).contains(i)); XCTAssertNotEqual(i, last)
                }
            }
        }
        var prev = ""
        for _ in 0..<30 {
            let s = LinePick.pick("test.moment", ["a", "b", "c"])
            XCTAssertNotEqual(s, prev); prev = s
        }
    }

    func testEveryVariantIsCleanAndPolite() {
        let nudges: [Nudge] = [.batteryLow(9), .hot, .taskDone(minutes: 12), .runaway("node"), .calendar(title: "회의", minutes: 10),
                               .reminder("약 먹기"), .mail(count: 2, senders: ["지은"])]
        for n in nudges {
            XCTAssertEqual(n.templates(polite: true).count, n.templates(polite: false).count)
            for t in n.templates(polite: true) { XCTAssertTrue(t.contains("요"), t); XCTAssertFalse(t.contains("\u{2014}")) }
            for t in n.templates(polite: false) { XCTAssertFalse(t.contains("\u{2014}")) }
        }
        for e: PetEvent in [.hungry, .cameHome, .focusDone(coins: 5), .restDone, .eyeRest] {
            XCTAssertGreaterThanOrEqual(PetModel.lines(e).count, 2)
        }
    }

    func testFlavorIsStableAndSkipsPolite() {
        let polite = Persona(name: "멍멍", style: .polite), calm = Persona(name: "멍멍", style: .calm)
        let bright = Persona(name: "멍멍", style: .bright)
        let lines = (1...200).map { "작업 \($0)개가 끝났어." }
        for l in lines {
            XCTAssertEqual(polite.flavor(l, day: t0), l)
            XCTAssertEqual(bright.flavor(l, day: t0), bright.flavor(l, day: t0))
        }
        let changed = lines.filter { bright.flavor($0, day: t0) != $0 }
        XCTAssertTrue((25...75).contains(changed.count), "\(changed.count) of 200")   // about one in four
        for l in changed {
            let f = bright.flavor(l, day: t0)
            XCTAssertTrue(bright.style.leads.contains { f == $0 + l } || bright.style.tails.contains { f == l + $0 }, f)
        }
        XCTAssertTrue(lines.allSatisfy { calm.flavor($0, day: t0).hasSuffix($0) })   // 담백: never a tail
    }

    func testHeldLineKeepsUnheldLinesOff() {
        let held = SpeechLine(text: "10분 뒤에 '회의' 있어.", source: .system, date: t0, hold: true)
        // Unheld lines of any source, including an AI-written nudge (.assistant), wait until it would have hidden.
        XCTAssertFalse(held.yields(hold: false, now: t0 + 1))
        XCTAssertTrue(held.yields(hold: true, now: t0 + 1))
        XCTAssertTrue(held.yields(hold: false, now: t0 + SpeechBubbleWindow.duration(held.text)))
        XCTAssertTrue(SpeechLine(text: "배고파요", source: .pet, date: t0).yields(hold: false, now: t0))
    }

    func testFlavorSkipsHeldAndMailLines() {
        XCTAssertFalse(Nudge.calendar(title: "회의", minutes: 10).flavored)
        XCTAssertFalse(Nudge.batteryLow(10).flavored)
        XCTAssertFalse(Nudge.mail(count: 2, senders: ["엄마"]).flavored)   // a tail would follow a sender's name
        XCTAssertTrue(Nudge.taskDone(minutes: 12).flavored)
        // Pet lines are 존댓말 for every persona, so no tail may carry a banmal ending.
        for style in PersonaStyle.allCases { for t in style.tails { XCTAssertFalse(t.hasSuffix("해") || t.hasSuffix("야"), t) } }
    }
}
