import Carbon.HIToolbox
import XCTest
@testable import DogMonitor

final class HotkeyTests: XCTestCase {
    private let ours = HotkeyRules.ours
    private func combo(_ key: Int, _ mods: UInt32) -> HotkeyCombo { HotkeyCombo(key: UInt32(key), mods: mods) }

    func testDefaultsAreAllowedDistinctAndNotSideysCombo() {
        let d = HotkeyRules.defaults
        XCTAssertEqual(Set(d.keys), Set(HotkeyAction.allCases))
        XCTAssertEqual(Set(d.values).count, d.count)
        let sidey = HotkeyRules.control | HotkeyRules.option | HotkeyRules.command
        for (a, c) in d {
            XCTAssertEqual(HotkeyRules.check(c, for: a, in: d), .ok, a.rawValue)
            XCTAssertNotEqual(c.mods, sidey)
            XCTAssertEqual(c.mods & HotkeyRules.command, 0)   // no ⌘: the system's and every app's own
        }
        XCTAssertEqual(HotkeyRules.label(d[.friends]!), "⌃⌥⇧D")
        XCTAssertEqual(HotkeyRules.label(d[.left]!), "⌃⌥⇧←")
    }

    func testAModifierIsRequiredAndShiftAloneIsTyping() {
        let d = HotkeyRules.defaults
        XCTAssertEqual(HotkeyRules.check(combo(kVK_ANSI_K, 0), for: .quiet, in: d), .needsModifier)
        XCTAssertEqual(HotkeyRules.check(combo(kVK_ANSI_K, HotkeyRules.shift), for: .quiet, in: d), .needsModifier)
        XCTAssertEqual(HotkeyRules.check(combo(kVK_ANSI_K, HotkeyRules.option), for: .quiet, in: d), .ok)
        XCTAssertEqual(HotkeyRules.check(combo(kVK_ANSI_K, HotkeyRules.command | UInt32(alphaLock)), for: .quiet, in: d), .needsModifier)
    }

    func testOnlyLettersDigitsAndArrows() {
        let d = HotkeyRules.defaults
        XCTAssertEqual(HotkeyRules.check(combo(kVK_ANSI_7, ours), for: .quiet, in: d), .ok)
        XCTAssertEqual(HotkeyRules.check(combo(kVK_Space, ours), for: .quiet, in: d), .unsupportedKey)
        XCTAssertEqual(HotkeyRules.check(combo(kVK_F5, ours), for: .quiet, in: d), .unsupportedKey)
        XCTAssertEqual(HotkeyRules.check(combo(kVK_Return, ours), for: .quiet, in: d), .unsupportedKey)
        XCTAssertEqual(HotkeyRules.keyNames.count, 26 + 10 + 4)
    }

    func testAnotherActionsComboIsTakenButItsOwnIsFine() {
        let d = HotkeyRules.defaults
        XCTAssertEqual(HotkeyRules.check(d[.friends]!, for: .quiet, in: d), .taken(.friends))
        XCTAssertEqual(HotkeyRules.check(d[.quiet]!, for: .quiet, in: d), .ok)
    }

    func testModifierFlagsMapToCarbon() {
        XCTAssertEqual(HotkeyRules.mods([.control, .option, .shift]), ours)
        XCTAssertEqual(HotkeyRules.mods([.command, .capsLock]), HotkeyRules.command)
        XCTAssertEqual(HotkeyRules.label(combo(kVK_ANSI_1, HotkeyRules.command | HotkeyRules.control)), "⌃⌘1")
    }

    func testSavedMapRoundTripsAndBadEntriesFallBack() {
        var m = HotkeyRules.defaults
        m[.quiet] = combo(kVK_ANSI_K, HotkeyRules.option | HotkeyRules.command)
        XCTAssertEqual(HotkeyRules.decode(HotkeyRules.encode(m)), m)
        XCTAssertEqual(HotkeyRules.decode(nil), HotkeyRules.defaults)
        XCTAssertEqual(HotkeyRules.decode(Data("garbage".utf8)), HotkeyRules.defaults)
        // Unknown action, a key we do not take, no modifier: all dropped, the defaults stay.
        let bad = #"{"nope":{"key":2,"mods":6400},"quiet":{"key":49,"mods":6400},"talk":{"key":17,"mods":0}}"#
        XCTAssertEqual(HotkeyRules.decode(Data(bad.utf8)), HotkeyRules.defaults)
    }

    func testASavedComboTakesADefaultsKeyAndThatDefaultIsUnset() {
        // 대화 모아보기 moved onto 쉿 모드's default: 쉿 모드 has no key rather than two actions on one.
        let json = #"{"recent":{"key":\#(kVK_ANSI_Q),"mods":\#(ours)}}"#
        let m = HotkeyRules.decode(Data(json.utf8))
        XCTAssertEqual(m[.recent], HotkeyRules.defaults[.quiet])
        XCTAssertNil(m[.quiet])
        XCTAssertEqual(Set(m.values).count, m.count)
        // Two saved actions on one combo: the first (by name) keeps it.
        let twice = #"{"talk":{"key":\#(kVK_ANSI_K),"mods":\#(ours)},"friends":{"key":\#(kVK_ANSI_K),"mods":\#(ours)}}"#
        let t = HotkeyRules.decode(Data(twice.utf8))
        XCTAssertEqual(t[.friends], combo(kVK_ANSI_K, ours))
        XCTAssertEqual(t[.talk], HotkeyRules.defaults[.talk])
    }

    func testRefusedSetKeepsTheOldComboAndOffRegistersNothing() {
        let suite = "test.hotkeys"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let keys = Hotkeys()
        keys.defaults = d
        keys.start()
        XCTAssertFalse(keys.on)
        XCTAssertTrue(keys.failed.isEmpty)
        XCTAssertNotNil(keys.set(HotkeyRules.defaults[.friends]!, for: .quiet))
        XCTAssertNotNil(keys.set(combo(kVK_ANSI_K, 0), for: .quiet))
        XCTAssertEqual(keys.map[.quiet], HotkeyRules.defaults[.quiet])
        XCTAssertNil(keys.set(combo(kVK_ANSI_K, HotkeyRules.option | HotkeyRules.command), for: .quiet))
        let again = Hotkeys()
        again.defaults = d
        again.start()
        XCTAssertEqual(again.map[.quiet], combo(kVK_ANSI_K, HotkeyRules.option | HotkeyRules.command))
        again.resetToDefaults()
        XCTAssertEqual(again.map, HotkeyRules.defaults)
        XCTAssertNil(d.data(forKey: Hotkeys.mapKey))
    }

    func testHidingRemembersWhoWasOutAndShowingBringsThemBack() {
        let hide = DesktopHide.next(on: ["커서 친구", "room"], hidden: nil)
        XCTAssertEqual(hide.off, ["커서 친구", "room"])
        XCTAssertEqual(hide.hidden, ["커서 친구", "room"])
        let show = DesktopHide.next(on: [], hidden: hide.hidden)
        XCTAssertEqual(show.on, ["커서 친구", "room"])
        XCTAssertNil(show.hidden)
        // Nobody out: nothing to hide, nothing remembered.
        let none = DesktopHide.next(on: [], hidden: nil)
        XCTAssertTrue(none.off.isEmpty && none.on.isEmpty)
        XCTAssertNil(none.hidden)
    }

    func testRoomSeatsOnEachEdge() {
        let vf = CGRect(x: 0, y: 50, width: 1000, height: 700), size = CGSize(width: 100, height: 110)
        XCTAssertEqual(RoomRules.origin(0, edge: .bottom, size: size, in: vf), CGPoint(x: 40, y: 50))
        XCTAssertEqual(RoomRules.origin(0, edge: .bottom, size: size, in: vf, x: 2000), CGPoint(x: 900, y: 50))
        XCTAssertEqual(RoomRules.origin(1, edge: .top, size: size, in: vf), CGPoint(x: 148, y: 640))
        XCTAssertEqual(RoomRules.origin(0, edge: .left, size: size, in: vf), CGPoint(x: 0, y: 600))
        XCTAssertEqual(RoomRules.origin(1, edge: .right, size: size, in: vf), CGPoint(x: 900, y: 482))
        // A long column stops at the bottom.
        XCTAssertEqual(RoomRules.origin(9, edge: .left, size: size, in: vf).y, 50)
    }
}
