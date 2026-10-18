import XCTest
@testable import DogMonitor

/// Reopening the popover: same page for 2 minutes, 10 after a trip to System Settings, 연동 anchor taken once.
@MainActor
final class PopoverMemoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testFirstOpenIsMain() {
        var m = PopoverMemory()
        m.page = .pet
        XCTAssertEqual(m.reopen(now: t0), .main)   // never closed: nothing to come back to
    }

    func testSamePageWithinTwoMinutes() {
        var m = PopoverMemory()
        m.page = .assistant
        m.assistantSettings = true
        m.closed(at: t0)
        XCTAssertEqual(m.reopen(now: t0.addingTimeInterval(119)), .assistant)
        XCTAssertTrue(m.assistantSettings)
        m.closed(at: t0)
        XCTAssertEqual(m.reopen(now: t0.addingTimeInterval(121)), .main)
        XCTAssertFalse(m.assistantSettings)
    }

    func testSettingsTripKeepsTenMinutesOnce() {
        var m = PopoverMemory()
        m.page = .assistant
        m.leaving(anchor: PopoverMemory.integrations, keep: PopoverMemory.settingsKeep)
        m.closed(at: t0)
        XCTAssertEqual(m.reopen(now: t0.addingTimeInterval(500)), .assistant)
        XCTAssertEqual(m.anchor, PopoverMemory.integrations)
        m.closed(at: t0)   // the longer window was for that one trip
        XCTAssertEqual(m.reopen(now: t0.addingTimeInterval(500)), .main)
    }

    func testPromptAnsweredWithPopoverOpenDropsAnchor() {
        var m = PopoverMemory()
        m.leaving(anchor: PopoverMemory.integrations, keep: PopoverMemory.keep)
        m.stayed()
        XCTAssertNil(m.anchor)
    }

    /// Nothing will pop up (already allowed or refused): no hold, no focus taken back afterwards.
    func testFlowThatCannotAskIsNotAFlow() async {
        let saved = PopoverMemory.shared
        defer { PopoverMemory.shared = saved; PermissionFlow.reopen = nil; PermissionFlow.started = nil }
        PopoverMemory.shared = PopoverMemory()
        var raised = 0, started = 0
        PermissionFlow.reopen = { raised += 1 }
        PermissionFlow.started = { started += 1 }
        let active = await PermissionFlow.run(asks: false) { PermissionFlow.isActive }
        XCTAssertFalse(active)
        XCTAssertEqual(raised, 0)
        XCTAssertEqual(started, 0)
        XCTAssertNil(PopoverMemory.shared.anchor)
        _ = await PermissionFlow.run { true }
        XCTAssertEqual(started, 1)
        XCTAssertEqual(raised, 1)
    }

    /// 계정 추가 survives the trip to the app password page (no password in it), and is gone past the window.
    func testMailDraftKeptForTheTripOnly() {
        var m = PopoverMemory()
        m.page = .assistant
        m.mailDraft = .init(adding: true, preset: .naver, user: "kim")
        m.leaving(anchor: PopoverMemory.mail, keep: PopoverMemory.settingsKeep)
        m.closed(at: t0)
        XCTAssertEqual(m.reopen(now: t0.addingTimeInterval(500)), .assistant)
        XCTAssertEqual(m.mailDraft.user, "kim")
        XCTAssertEqual(m.anchor, PopoverMemory.mail)
        m.closed(at: t0)
        _ = m.reopen(now: t0.addingTimeInterval(700))
        XCTAssertEqual(m.mailDraft, PopoverMemory.MailDraft())
    }

    func testFlowHoldsThenRaisesOnce() async {
        let saved = PopoverMemory.shared
        defer { PopoverMemory.shared = saved; PermissionFlow.reopen = nil }
        var raised = 0
        PermissionFlow.reopen = { raised += 1 }
        let inner: Bool = await PermissionFlow.run {
            let nested = await PermissionFlow.run { PermissionFlow.isActive }   // a prompt inside a prompt
            return nested && PermissionFlow.isActive
        }
        XCTAssertTrue(inner)
        XCTAssertFalse(PermissionFlow.isActive)
        XCTAssertEqual(raised, 1)   // only when the outer flow ends
        XCTAssertEqual(PopoverMemory.shared.anchor, PopoverMemory.integrations)
    }
}
