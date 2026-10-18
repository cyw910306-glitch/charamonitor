import XCTest
@testable import DogMonitor

/// 대롱대롱 친구: chime synthesis, wind, charms and where a slot hangs.
final class HangingTests: XCTestCase {

    func testChimeIsAMonoPCMWave() {
        let wav = ChimeSound.make(freq: 1000, seconds: 0.5, sampleRate: 8000)
        let bytes = [UInt8](wav)
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        XCTAssertEqual(u32(24), 8000)                 // sample rate
        XCTAssertEqual(u32(40), 4000 * 2)             // 0.5 s of 16-bit mono
        XCTAssertEqual(u32(4), wav.count - 8)         // RIFF size
        XCTAssertEqual(bytes[22], 1)                  // one channel
        XCTAssertEqual(bytes[34], 16)                 // bits per sample
        XCTAssertEqual(wav.count, 44 + 8000)
        XCTAssertEqual(ChimeSound.notes.count, HangPrefs.maxCount)   // one note per slot
    }

    func testNoWindNeverMoves() {
        var b = Breeze(push: WindLevel.calm.push)
        for i in 0..<300 { XCTAssertEqual(b.step(to: Double(i) / 30, dt: 1.0 / 30) { 0.5 }, 0) }
    }

    func testWindGustsStayBounded() {
        var seed: UInt64 = 7
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        let base = WindLevel.light.push
        var b = Breeze(push: base)
        var most: CGFloat = 0
        for i in 0..<(30 * 20) {
            let w = b.step(to: Double(i) / 30, dt: 1.0 / 30, random: random)
            XCTAssertGreaterThanOrEqual(w, 0)
            XCTAssertLessThanOrEqual(w, base * 2.6 + 0.001)
            most = max(most, w)
        }
        XCTAssertGreaterThan(most, base * 1.2)   // at least one gust in 20 s
        XCTAssertLessThanOrEqual(b.push(at: 3, phase: 1), b.now * 1.3 + 0.001)
    }

    func testRealWindMapsToAPush() {
        XCTAssertEqual(WindLevel.push(metersPerSecond: -2), 0)
        XCTAssertLessThan(WindLevel.push(metersPerSecond: 2), WindLevel.push(metersPerSecond: 8))
        XCTAssertEqual(WindLevel.push(metersPerSecond: 40), 320)
    }

    func testWindFollowsReduceMotionAndLocalWind() {
        XCTAssertEqual(WindLevel.strong.push(still: true, local: 9), 0)              // 동작 줄이기: nothing blows
        XCTAssertEqual(WindLevel.fresh.push(still: false, local: 9), WindLevel.fresh.push)
        XCTAssertEqual(WindLevel.local.push(still: false, local: 9), WindLevel.push(metersPerSecond: 9))
        XCTAssertEqual(WindLevel.local.push(still: false, local: nil), WindLevel.light.push)   // no weather: 산들
    }

    func testLongestStringStaysInsideThePanel() {
        let panel: CGFloat = 450, body: CGFloat = 90
        for rest in stride(from: HangSlot.lengths.lowerBound, through: HangSlot.lengths.upperBound, by: 10) {
            let k = HangingFriends.maxStretch(panel: panel, body: body, rest: CGFloat(rest))
            XCTAssertLessThanOrEqual(CGFloat(rest) * k + body, panel + 0.001, "rest \(rest)")
            XCTAssertGreaterThanOrEqual(k, 1.1)
        }
        XCTAssertEqual(HangingFriends.maxStretch(panel: 2000, body: 90, rest: 50), 2.5)
    }

    func testCharmsAreRectangularStamps() {
        for c in Charm.allCases where c != .none {
            let w = c.rows.first?.count ?? 0
            XCTAssertGreaterThan(w, 0, "\(c)")
            XCTAssertTrue(c.rows.allSatisfy { $0.count == w }, "\(c) rows differ in width")
            XCTAssertTrue(c.rows.joined().allSatisfy { "owl.".contains($0) }, "\(c) has an unknown letter")
            XCTAssertEqual(c.image(pixel: 2)?.size, CGSize(width: w * 2, height: c.rows.count * 2))
        }
        XCTAssertNil(Charm.none.image(pixel: 2))
    }

    func testDroppedSlotHangsWhereItWasPut() {
        var s = HangSlot.defaults[0]
        let screen = CGRect(x: 1000, y: 0, width: 2000, height: 1000)
        s.move(to: CGPoint(x: 1500, y: 800), top: 975, screen: screen, display: 42, sag: 15)
        XCTAssertEqual(s.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.length, 160, accuracy: 1e-9)   // 975 - 800 - 15
        XCTAssertEqual(s.display, 42)
        s.move(to: CGPoint(x: 900, y: 0), top: 975, screen: screen, display: 42, sag: 15)
        XCTAssertEqual(s.x, 0.02)                                  // kept on screen
        XCTAssertEqual(s.length, HangSlot.lengths.upperBound)      // never longer than the longest string
        s.move(to: CGPoint(x: 1500, y: 990), top: 975, screen: screen, display: nil, sag: 15)
        XCTAssertEqual(s.length, HangSlot.lengths.lowerBound)
    }

    func testPrefsRoundTripAndPadSlots() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "HangingTests"))
        d.removePersistentDomain(forName: "HangingTests")
        defer { d.removePersistentDomain(forName: "HangingTests") }
        var short = HangPrefs()
        short.slots = Array(short.slots.prefix(2))
        short.slots[0].imagePath = "/tmp/x.png"
        short.wind = .strong
        d.set(try JSONEncoder().encode(short), forKey: HangingStore.key)
        let store = HangingStore(defaults: d)
        XCTAssertEqual(store.prefs.slots.count, HangPrefs.maxCount)
        XCTAssertEqual(store.prefs.slots[0].imagePath, "/tmp/x.png")
        XCTAssertEqual(store.prefs.wind, .strong)
        store.prefs.count = 5
        XCTAssertEqual(HangingStore(defaults: d).prefs.count, 5)
    }
}
