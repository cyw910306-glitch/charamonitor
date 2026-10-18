import AppKit
import SwiftUI

/// A proposal inside the chat (design section 9). It renders only from the frozen payload, so what the owner reads is
/// exactly what runs. Untrusted recipients are red and must be retyped; a reviewer "block" turns the button into a
/// double confirm; mail counts down 10 seconds with a [취소].
struct AgentCardView: View {
    let card: FrozenAction
    var countingDown = false
    var undoable = false
    var onApprove: () -> Void = {}
    var onCancel: () -> Void = {}
    var onUndo: () -> Void = {}
    /// The owner retyped an untrusted address (index into the action's recipients).
    var onRetype: (Int, String) -> Void = { _, _ in }
    var onOpen: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @State private var retyped: [Int: String] = [:]
    @State private var armed = false   // the first tap of a double confirm

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(card.action.type)).foregroundStyle(Color.accentColor)
                Text(Self.title(card.action.type)).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(card.decision.tier.label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().strokeBorder(Color.primary.opacity(0.2)))
            }
            details
            ForEach(card.concerns, id: \.self) { c in
                Label(c, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let r = card.reviewer {
                Label(L("2차 검토: \(r)"), systemImage: "checkmark.shield").font(.system(size: 10))
                    .foregroundStyle(doubleConfirm ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }

    /// The reviewer said block: the button asks twice.
    private var doubleConfirm: Bool { card.decision.reasons.contains(ActionCopy.reviewerBlockMark) }

    // MARK: Details

    @ViewBuilder private var details: some View {
        switch card.action {
        case .mailSend(let m), .mailReply(let m, _):
            recipients(m.to + m.cc)
            row(L("보내는 계정"), Self.account(m.accountID))
            row(L("제목"), m.subject.isEmpty ? L("(제목 없음)") : m.subject)
            Text(m.body).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        case .eventAdd(let e):
            row(L("제목"), e.title)
            row(L("언제"), ActionCopy.range(e.start, e.end))
            if let l = e.location { row(L("어디"), l) }
            Text("초대는 캘린더 앱에서 보낼 수 있어요").font(.system(size: 10)).foregroundStyle(.secondary)
        case .reminderAdd(let r):
            row(L("할 일"), r.title)
            if let d = r.due { row(L("언제"), ActionCopy.when(d)) }
        case .reminderDone(_, let title):
            row(L("할 일"), title)
        case .messagePrepare(let to, let body):
            recipients(to)
            row(L("내용"), body)
        case .messageSend(let to, let body):
            recipients(to)
            row(L("내용"), body)
            #if !MAS
            Text("메시지 앱으로 바로 보내요").font(.system(size: 10)).foregroundStyle(.secondary)
            #endif
        case .webStep(let w):
            row(L("사이트"), URL(string: w.pageURL)?.host ?? w.pageURL)
            if w.kind == .open {
                row(L("주소"), ActionCopy.readableURL(w.pageURL))
            } else {
                row(Self.webVerb(w.kind), w.label.isEmpty ? L("(이름 없는 버튼)") : w.label)
            }
            if let v = w.value {
                if w.kind == .click { row(L("이동할 곳"), ActionCopy.readableURL(v)) } else { row(L("값"), ActionCopy.resolved(v)) }
            }
            if w.submit == true { row(L("그다음"), L("Enter로 제출해요")) }
            Text(w.why).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .kakaoPrepare(let body):
            row(L("내용"), body)
            Text("카카오톡은 직접 보낼 수 없어서, 복사해 두고 카카오톡을 열어 줄게요").font(.system(size: 10)).foregroundStyle(.secondary)
        case .shopSearch(let q, _):
            row(L("찾을 것"), q)
            HStack(spacing: 6) {
                linkButton(L("네이버쇼핑"), KoreanLinks.naverShopping(q))
                linkButton(L("쿠팡"), KoreanLinks.coupang(q))
            }
            Text("주문과 결제는 직접 해 주세요").font(.system(size: 10)).foregroundStyle(.secondary)
        case .flightSearch(let f):
            row(L("구간"), "\(Airports.name(for: f.from) ?? f.from) → \(Airports.name(for: f.to) ?? f.to)")
            row(L("날짜"), ActionCopy.day(f.depart) + (f.returnDate.map { " ~ " + ActionCopy.day($0) } ?? L(" (편도)")))
            row(L("인원"), L("어른 \(f.adults)명"))
            HStack(spacing: 6) {
                if let u = KoreanLinks.naverFlights(f) { linkButton(L("네이버 항공권"), u) }
                if let u = KoreanLinks.skyscanner(f) { linkButton(L("스카이스캐너"), u) }
                if let u = KoreanLinks.googleFlights(f) { linkButton(L("구글"), u) }
                if let a = f.airline, let u = KoreanLinks.airline(a) { linkButton(a, u) }
            }
            Text("탑승객 정보와 결제는 직접 해 주세요").font(.system(size: 10)).foregroundStyle(.secondary)
        case .goalCreate(let g):
            row(L("맡길 일"), g.title)
            switch g.kind {
            case .priceWatch(let query, let target, let drop):
                row(L("상품"), query)
                row(L("알림"), target.map { L("\(Fmt.won($0)) 이하가 되면") } ?? drop.map { L("\($0)% 넘게 내리면") } ?? L("가격이 내리면"))
                Text("AI를 쓰지 않고 네이버쇼핑 가격만 봐요. 맥이 켜져 있을 때 확인해요").font(.system(size: 10)).foregroundStyle(.secondary)
            case .agent(let prompt):
                row(L("할 일"), prompt)
                row(L("확인 주기"), L("\(g.everyMinutes / 60)시간마다 (하루 약 \(max(1, 24 * 60 / g.everyMinutes))번 내 AI 사용)"))
                Text("자리를 비운 동안엔 찾아보기만 하고, 할 일은 카드로 남겨요").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .memoryAdd(let k, let v):
            row(L("기억할 것"), "\(k): \(v)")
        case .undo:
            Text("방금 한 일을 되돌릴게요").font(.system(size: 11))
        }
    }

    private func recipients(_ rs: [Recipient]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rs.enumerated()), id: \.offset) { i, r in
                HStack(spacing: 5) {
                    Text(i == 0 ? L("받는 사람") : "").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    if r.provenance == .untrusted {
                        TextField(L("주소를 직접 입력"), text: Binding(get: { retyped[i] ?? "" }, set: { retyped[i] = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                            .onSubmit { if let a = retyped[i], !a.isEmpty { onRetype(i, a) } }
                        Text("받은 메일에서 나온 주소예요: \(r.address)").font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
                    } else {
                        Text(r.name.map { "\($0) <\(r.address)>" } ?? r.address).font(.system(size: 11)).textSelection(.enabled)
                        Text(ActionCopy.badge(r.provenance)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func linkButton(_ title: String, _ url: URL) -> some View {
        Button(title) { onOpen(url) }.buttonStyle(.bordered).controlSize(.small)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch card.state {
        case .approved:
            // Tapped: counting down (mail) or about to run. Never a second 보내기 button.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(countingDown ? L("10초 뒤에 보내요") : L("하는 중이에요")).font(.system(size: 11))
                if countingDown { Button("보내지 않기", action: onCancel).buttonStyle(.bordered).controlSize(.small) }
            }
        case .proposed:
            if card.decision.tier == .blocked {
                Text("이 일은 안전을 위해 하지 않아요").font(.system(size: 11)).foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    Button(primaryTitle) {
                        if doubleConfirm && !armed { armed = true } else { onApprove() }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(card.action.recipients.contains { $0.provenance == .untrusted })
                    Button("취소", action: onCancel).buttonStyle(.bordered).controlSize(.small)
                    Spacer(minLength: 0)
                    Text(ActionCopy.expiry(card.expiresAt)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(countingDown ? L("10초 뒤에 보내요") : L("하는 중이에요")).font(.system(size: 11))
                if countingDown { Button("보내지 않기", action: onCancel).buttonStyle(.bordered).controlSize(.small) }
            }
        case .done(let summary, _):
            HStack(spacing: 6) {
                Label(summary, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                if undoable { Button("되돌리기", action: onUndo).buttonStyle(.bordered).controlSize(.small) }
            }
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon").font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .unknown(let reason):
            Label(reason, systemImage: "questionmark.circle").font(.system(size: 11)).foregroundStyle(Color.warn).fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text("취소했어요").font(.system(size: 11)).foregroundStyle(.secondary)
        case .expired:
            Text("시간이 지나서 취소됐어요. 다시 부탁해 주세요").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var primaryTitle: String {
        if doubleConfirm && armed { return L("그래도 진행") }
        switch card.action.type {
        case .mailSend, .mailReply:
            if case .mailSend(let m) = card.action, m.accountID == nil { return L("쓰기 창 열기") }
            if case .mailReply(let m, _) = card.action, m.accountID == nil { return L("쓰기 창 열기") }
            return L("보내기")
        case .eventAdd, .reminderAdd, .goalCreate: return L("만들기")
        case .reminderDone: return L("완료로 표시")
        case .messagePrepare, .kakaoPrepare: return L("준비하기")
        case .shopSearch, .flightSearch: return L("찾아보기")
        case .memoryAdd: return L("기억하기")
        case .undo: return L("되돌리기")
        case .messageSend: return L("보내기")
        case .webStep:
            if case .webStep(let w) = card.action { return Self.webVerb(w.kind) }
            return L("하기")
        }
    }

    static func webVerb(_ k: WebStep.Kind) -> String {
        switch k {
        case .open: return L("열기")
        case .click: return L("누르기")
        case .type: return L("입력하기")
        case .select: return L("고르기")
        }
    }

    /// "me@gmail.com" for the frozen account, or what happens without one.
    static func account(_ id: String?) -> String {
        guard let id else { return L("메일 앱 쓰기 창 (보내기는 직접)") }
        return MailAccounts.shared.accounts.first { $0.id == id }.map { MailSender.address(of: $0) } ?? L("(찾을 수 없는 계정)")
    }

    static func title(_ t: AgentActionType) -> String {
        switch t {
        case .eventAdd: return L("일정 추가")
        case .reminderAdd: return L("미리알림 추가")
        case .reminderDone: return L("미리알림 완료")
        case .mailSend: return L("메일 보내기")
        case .mailReply: return L("메일 답장")
        case .messagePrepare: return L("문자 준비")
        case .kakaoPrepare: return L("카카오톡 준비")
        case .shopSearch: return L("상품 찾기")
        case .flightSearch: return L("항공권 찾기")
        case .goalCreate: return L("맡긴 일")
        case .memoryAdd: return L("기억하기")
        case .undo: return L("되돌리기")
        case .messageSend: return L("문자 보내기")
        case .webStep: return L("웹에서 하기")
        }
    }

    static func symbol(_ t: AgentActionType) -> String {
        switch t {
        case .eventAdd: return "calendar.badge.plus"
        case .reminderAdd, .reminderDone: return "checklist"
        case .mailSend, .mailReply: return "envelope"
        case .messagePrepare, .kakaoPrepare: return "message"
        case .shopSearch: return "cart"
        case .flightSearch: return "airplane"
        case .goalCreate: return "binoculars"
        case .memoryAdd: return "brain"
        case .undo: return "arrow.uturn.backward"
        case .messageSend: return "message.fill"
        case .webStep: return "safari"
        }
    }
}

/// Words and dates on the cards: absolute, with the weekday (design: "10월 16일 (금) 오후 3:00~4:00").
enum ActionCopy {
    /// The whole address, percent-decoded, so the owner sees the path and the query too.
    static func readableURL(_ s: String) -> String { String((s.removingPercentEncoding ?? s).prefix(300)) }

    /// "{{memory.이름}}" shown with the owner's value (the model only ever saw the placeholder).
    @MainActor static func resolved(_ text: String) -> String {
        var out = text
        for e in AgentCenter.shared.memory.entries { out = out.replacingOccurrences(of: "{{memory.\(e.key)}}", with: e.value) }
        return out
    }

    /// Put in Decision.reasons when the reviewer said block, so the card asks twice.
    static let reviewerBlockMark = "reviewer-block"

    static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = appLocale
        d.setLocalizedDateFormatFromTemplate(f)
        return d
    }

    static func when(_ d: Date) -> String { formatter("MMMMdEEEahmm").string(from: d) }
    static func day(_ d: Date) -> String { formatter("MMMMdEEE").string(from: d) }

    static func range(_ a: Date, _ b: Date) -> String {
        Calendar.current.isDate(a, inSameDayAs: b) ? "\(when(a))~\(formatter("ahmm").string(from: b))" : "\(when(a)) ~ \(when(b))"
    }

    static func badge(_ p: Provenance) -> String {
        switch p {
        case .ownerWords: return L("직접 쓴 주소")
        case .contact: return L("연락처")
        case .pointedMail: return L("가리킨 메일의 보낸 사람")
        case .ownerProfile: return L("기억한 정보")
        case .untrusted: return L("확인 필요")
        }
    }

    static func expiry(_ d: Date, now: Date = Date()) -> String {
        let m = max(0, Int(d.timeIntervalSince(now) / 60))
        return m >= 60 ? L("\(m / 60)시간 안에 확인") : L("\(m)분 안에 확인")
    }
}
