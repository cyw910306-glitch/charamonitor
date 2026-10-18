import XCTest
@testable import DogMonitor

@MainActor
final class PendingActionsTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let body = "비밀 계약서 본문입니다 SECRETBODY"
    private let subject = "계약 SECRETSUBJECT"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var mail: AgentAction {
        .mailSend(MailDraft(to: [Recipient(name: "김", address: "kim@Example.com", provenance: .ownerWords)],
                            subject: subject, body: body))
    }
    private var reminder: AgentAction { .reminderAdd(ReminderDraft(title: "우유 사기", due: t0.addingTimeInterval(3600))) }
    private func decision(_ t: Tier) -> Decision { Decision(tier: t, needsReview: false) }
    private func ok(_ a: AgentAction) -> [Concern] { [] }
    private func executor(_ s: PendingStore, at: Date? = nil) -> Executor {
        Executor(store: s, delay: { _ in }, now: { at ?? self.t0 })
    }

    func testHashMismatchRefused() throws {
        let s = PendingStore(root: root)
        let f = s.add(mail, origin: .chat, decision: decision(.confirm), now: t0)
        // Someone rewrites the frozen payload on disk: the hash no longer matches.
        let file = root.appendingPathComponent("pending.json")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "SECRETBODY", with: "송금해 주세요")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let reloaded = PendingStore(root: root)
        XCTAssertNotEqual(reloaded.get(f.id)?.action, f.action)
        XCTAssertNil(reloaded.approve(f.id, now: t0))
        if case .failed = reloaded.get(f.id)?.state {} else { XCTFail("tampered card must be voided") }
    }

    func testCanonicalHashSurvivesDisk() {
        let s = PendingStore(root: root)
        let f = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        XCTAssertNotNil(PendingStore(root: root).approve(f.id, now: t0))
    }

    func testEditMakesNewIdAndCancelsOld() {
        let s = PendingStore(root: root)
        let f = s.add(mail, origin: .background, decision: decision(.confirm), now: t0)
        let later = t0.addingTimeInterval(60)
        let g = s.edit(f.id, to: reminder, decision: decision(.confirm), now: later)!
        XCTAssertNotEqual(g.id, f.id)
        XCTAssertNotEqual(g.sha256, f.sha256)
        XCTAssertEqual(g.origin, .background)
        XCTAssertEqual(s.get(f.id)?.state, .cancelled)
        XCTAssertEqual(s.pending(now: later).map(\.id), [g.id])
        XCTAssertNil(s.approve(f.id, now: later))
        XCTAssertNil(s.edit(f.id, to: reminder, decision: decision(.confirm), now: later))
    }

    func testBackgroundWithoutTokenRefusedEvenWhenAuto() async {
        let s = PendingStore(root: root)
        let f = s.add(reminder, origin: .background, decision: decision(.auto), now: t0)
        var ran = 0
        let e = executor(s)
        let a = await e.runAuto(f.id, recheck: ok) { _, _ in ran += 1; return PerformResult(summary: "ok") }
        let b = await e.run(f.id, token: nil, recheck: ok) { _, _ in ran += 1; return PerformResult(summary: "ok") }
        XCTAssertEqual(ran, 0)
        if case .failed = a {} else { XCTFail("\(a)") }
        if case .failed = b {} else { XCTFail("\(b)") }
        XCTAssertEqual(s.get(f.id)?.state, .proposed, "a stray call must not void the owner's card")

        // The same action from chat may run without a tap; a confirm-tier one may not.
        let c = s.add(reminder, origin: .chat, decision: decision(.auto), now: t0)
        let d = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        _ = await e.runAuto(d.id, recheck: ok) { _, _ in ran += 1; return PerformResult(summary: "ok") }
        XCTAssertEqual(ran, 0)
        let r = await e.runAuto(c.id, recheck: ok) { _, _ in ran += 1; return PerformResult(summary: "ok") }
        XCTAssertEqual(r, .done(summary: "ok", undoID: nil))
        XCTAssertEqual(ran, 1)
    }

    func testTokenForAnotherCardRefused() async {
        let s = PendingStore(root: root)
        let a = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        let b = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        let tokenA = s.approve(a.id, now: t0)
        _ = s.approve(b.id, now: t0)
        var ran = 0
        _ = await executor(s).run(b.id, token: tokenA, recheck: ok) { _, _ in ran += 1; return PerformResult(summary: "") }
        XCTAssertEqual(ran, 0)
    }

    func testBlockedDecisionRefusedEvenWithToken() async {
        let s = PendingStore(root: root)
        let f = s.add(reminder, origin: .chat, decision: decision(.blocked), now: t0)
        let token = s.approve(f.id, now: t0)
        var ran = 0
        _ = await executor(s).run(f.id, token: token, recheck: ok) { _, _ in ran += 1; return PerformResult(summary: "") }
        XCTAssertEqual(ran, 0)
    }

    func testExpiredProposalCannotBeApproved() {
        let s = PendingStore(root: root)
        let chat = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        let bg = s.add(reminder, origin: .background, decision: decision(.confirm), now: t0)
        let after31 = t0.addingTimeInterval(31 * 60)
        XCTAssertNil(s.approve(chat.id, now: after31))
        XCTAssertEqual(s.get(chat.id)?.state, .expired)
        XCTAssertNotNil(s.approve(bg.id, now: after31), "goal cards wait 12 hours")

        let late = s.add(reminder, origin: .background, decision: decision(.confirm), now: t0)
        s.expireSweep(now: t0.addingTimeInterval(12 * 3600 + 1))
        XCTAssertEqual(s.get(late.id)?.state, .expired)
        XCTAssertNil(s.approve(late.id, now: t0))
    }

    func testBlockingRecheckAtApprovalRefuses() async {
        let s = PendingStore(root: root)
        let f = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        let token = s.approve(f.id, now: t0)
        var ran = 0
        let warn = Concern(kind: .provenance, message: "확인", blocking: false)
        let stop = Concern(kind: .expired, message: "시간이 지났어요", blocking: true)
        let r = await executor(s).run(f.id, token: token, recheck: { _ in [warn, stop] }) { _, _ in
            ran += 1; return PerformResult(summary: "")
        }
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(r, .failed(reason: "시간이 지났어요"))
        XCTAssertEqual(s.get(f.id)?.state, r)
    }

    func testCapFilledDuringCountdownStopsSend() async {
        let s = PendingStore(root: root)
        let f = s.add(mail, origin: .chat, decision: decision(.confirm), now: t0)
        let token = s.approve(f.id, now: t0)
        var checks = 0
        let cap = Concern(kind: .cap, message: "오늘 보낼 수 있는 메일을 다 썼어요", blocking: true)
        var ran = 0
        let r = await executor(s).run(f.id, token: token, recheck: { _ in checks += 1; return checks > 1 ? [cap] : [] }) { _, _ in
            ran += 1; return PerformResult(summary: "")
        }
        XCTAssertEqual(checks, 2, "before and after the countdown")
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(r, .failed(reason: cap.message))
    }

    func testCountdownCancelStopsPerform() async {
        let s = PendingStore(root: root)
        let f = s.add(mail, origin: .chat, decision: decision(.confirm), now: t0)
        let token = s.approve(f.id, now: t0)
        var e: Executor!
        var waited: [TimeInterval] = []
        // The owner taps [취소] while the countdown runs.
        e = Executor(store: s, delay: { sec in waited.append(sec); await MainActor.run { e.cancel(f.id) } }, now: { self.t0 })
        var ran = 0
        let r = await e.run(f.id, token: token, recheck: ok) { _, _ in ran += 1; return PerformResult(summary: "") }
        XCTAssertEqual(waited, [10])
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(r, .cancelled)
        XCTAssertEqual(s.get(f.id)?.state, .cancelled)
        XCTAssertTrue(e.countingDown.isEmpty)
    }

    func testUnknownAfterDataNotRetried() async {
        let s = PendingStore(root: root)
        let f = s.add(mail, origin: .chat, decision: decision(.confirm), now: t0)
        let token = s.approve(f.id, now: t0)
        let e = executor(s)
        var ran = 0
        var seenID: UUID?
        let perform: (AgentAction, UUID) async throws -> PerformResult = { _, id in
            ran += 1; seenID = id
            throw MailUnknown(reason: "보냈는지 확실하지 않아요")
        }
        let r = await e.run(f.id, token: token, recheck: ok, perform: perform)
        XCTAssertEqual(r, .unknown(reason: "보냈는지 확실하지 않아요"))
        XCTAssertEqual(seenID, f.id, "the id seeds the Message-ID")
        _ = await e.run(f.id, token: token, recheck: ok, perform: perform)
        XCTAssertNil(s.approve(f.id, now: t0))
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(PendingStore(root: root).get(f.id)?.state, r)
    }

    func testUndoWindow() async {
        let s = PendingStore(root: root)
        let f = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        let g = s.add(reminder, origin: .chat, decision: decision(.confirm), now: t0)
        let e = executor(s)
        _ = await e.run(f.id, token: s.approve(f.id, now: t0), recheck: ok) { _, _ in PerformResult(summary: "추가", undoID: "EK-1") }
        _ = await e.run(g.id, token: s.approve(g.id, now: t0), recheck: ok) { _, _ in PerformResult(summary: "추가") }
        XCTAssertEqual(s.undoable(now: t0.addingTimeInterval(9 * 60)).map(\.id), [f.id])
        XCTAssertTrue(s.undoable(now: t0.addingTimeInterval(10 * 60)).isEmpty)
    }

    func testAuditHasNoMailBodyOrSubject() async throws {
        let s = PendingStore(root: root)
        let f = s.add(mail, origin: .chat, decision: decision(.confirm), now: t0)
        _ = await executor(s).run(f.id, token: s.approve(f.id, now: t0), recheck: ok) { _, _ in
            PerformResult(summary: "보냄: \(self.subject) \(self.body)")
        }
        let log = try String(contentsOf: root.appendingPathComponent("actions.jsonl"), encoding: .utf8)
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.count, 4) // proposed, approved, running, done
        XCTAssertFalse(log.contains("SECRETBODY"))
        XCTAssertFalse(log.contains("SECRETSUBJECT"))
        XCTAssertFalse(log.contains("kim@"))
        let last = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: String]
        XCTAssertEqual(Set(last.keys), ["time", "id", "type", "origin", "tier", "state", "summary"])
        XCTAssertEqual(last["state"], "done")
        XCTAssertEqual(last["type"], "mail_send")
        XCTAssertEqual(last["summary"], "to: example.com")
    }

    func testAuditRotatesKeepingOneOldFile() throws {
        let url = root.appendingPathComponent("actions.jsonl")
        let log = AuditLog(url: url, maxBytes: 600)
        let f = FrozenAction(action: reminder, origin: .chat, decision: decision(.auto), createdAt: t0)
        for i in 0..<20 { log.append(f, state: "done", summary: "줄 \(i)", now: t0) }
        let fm = FileManager.default
        let size = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 600)
        XCTAssertTrue(fm.fileExists(atPath: url.path + ".1"))
        XCTAssertFalse(fm.fileExists(atPath: url.path + ".1.1"))
        XCTAssertFalse(fm.fileExists(atPath: url.path + ".2"))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("줄 19"))
    }
}
