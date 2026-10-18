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
    @State private var fullURL = false   // 전체 주소 보기

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
            // Page text and addresses with their invisible characters shown, so the card reads like what runs.
            row(L("사이트"), ActionCopy.host(w.pageURL))
            if w.kind == .open {
                urlRow(L("주소"), w.pageURL)
            } else {
                row(Self.webVerb(w.kind), w.label.isEmpty ? L("(이름 없는 버튼)") : ActionCopy.visible(w.label))
            }
            if let v = w.value {
                if w.kind == .click { urlRow(L("이동할 곳"), v, host: true) } else { row(L("값"), ActionCopy.visible(ActionCopy.resolved(v))) }
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

    /// An address: its host first when asked (where a click really goes), then the readable address, cut at
    /// ActionCopy.urlShown with its full length shown and 전체 주소 보기. Selectable either way.
    private func urlRow(_ label: String, _ url: String, host: Bool = false) -> some View {
        let text = ActionCopy.readableURL(url)
        let long = text.count > ActionCopy.urlShown
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if host { Text(ActionCopy.host(url)).font(.system(size: 11, weight: .semibold)).textSelection(.enabled) }
                Text(long && !fullURL ? ActionCopy.shortened(text) : text).font(.system(size: 11)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(fullURL ? L("주소 접기") : L("전체 주소 보기")) { fullURL.toggle() }
                        .buttonStyle(.link).font(.system(size: 10))
                }
            }
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
    /// Addresses on a card show this many characters, then "…(총 N자)" and 전체 주소 보기.
    static let urlShown = 300
    /// A web step whose address is longer than this, or hides a character, is not done (AgentGuard, `urlProblem`).
    static let urlLimit = 2_000

    /// The whole address as the owner reads it. %XX is decoded only where it spells an unreserved ASCII character
    /// (letters, digits, - . _ ~) or a non-ASCII letter, spacing mark or digit (한글 paths); combining marks and every
    /// separator the server reads
    /// (/ ? # & = % + and the rest) stays encoded exactly as it is sent. The part before the path (scheme://name@host:port)
    /// is never decoded. Invisible characters show as ⟦U+202E⟧ (`visible`). Never shortened (`shortened` is for the card).
    static func readableURL(_ s: String) -> String { scanURL(s).text }

    /// Why a web step with this address cannot be approved, or nil: a hidden character, raw or %-encoded, could make the
    /// card read unlike what opens, a %-encoded host ("%D0%B0pple.com" reads as apple.com but opens xn--pple-43d.com) is
    /// never a real site's address, and nobody checks an address past `urlLimit`. A backslash or "name@" before the host,
    /// or anything but "//" after "scheme:", is read one way by Foundation and another by WebKit, so it is refused too.
    static func urlProblem(_ s: String) -> String? {
        let scan = scanURL(s)
        if scan.hidden { return L("주소에 보이지 않는 제어 문자(글자 방향 바꾸기 등)가 있어서 하지 않아요") }
        if scan.encodedHost { return L("사이트 이름이 %로 감춰져 있어 실제로 가는 곳이 다를 수 있어서 하지 않아요") }
        if let odd = scan.oddAuthority { return odd }
        if s.unicodeScalars.count > urlLimit { return L("주소가 2,000자를 넘어서 확인할 수 없어 하지 않아요") }
        return nil
    }

    /// The addresses a web step card shows and the owner approves: the page to open, or where a click goes.
    static func urls(_ w: WebStep) -> [String] {
        switch w.kind {
        case .open: return [w.pageURL]
        case .click: return w.value.map { [$0] } ?? []
        case .type, .select: return []
        }
    }

    /// `text` as is when it fits, else its first `limit` characters and a visible "…(총 N자)". Never cut silently.
    static func shortened(_ text: String, limit: Int = urlShown) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + L("…(총 \(text.count)자)")
    }

    /// The host the browser goes to (after any "name@" part), invisible characters shown; no host: the readable address.
    /// A %-encoded host is shown as the punycode name WebKit opens (xn--pple-43d.com), never decoded to a lookalike.
    static func host(_ s: String) -> String {
        // URLComponents: URL.host decodes %XX, and URL.host(percentEncoded:) turns punycode back into %XX.
        guard let h = URLComponents(string: s)?.encodedHost, !h.isEmpty else { return readableURL(s) }
        guard h.contains("%") else { return visible(h) }
        if let d = h.removingPercentEncoding, d.unicodeScalars.allSatisfy({ readable($0) || $0 == "." }),
           let ascii = URLComponents(string: "https://" + d)?.encodedHost, !ascii.contains("%") { return ascii }
        return h
    }

    /// Characters that act instead of showing: C0 and C1 controls, bidi marks, embeddings and isolates (U+200E/F,
    /// U+202A-202E, U+2066-2069), zero-width and other format characters, line breaks, any space but " ", every
    /// Default_Ignorable_Code_Point, and the blank-looking letters: Hangul fillers (U+115F U+1160 U+3164 U+FFA0) and U+2800.
    static func isHidden(_ u: Unicode.Scalar) -> Bool {
        if u.properties.isDefaultIgnorableCodePoint || [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800].contains(u.value) { return true }
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        case .spaceSeparator: return u != " "
        default: return false
        }
    }

    /// `text` with every hidden character written as ⟦U+XXXX⟧.
    static func visible(_ text: String) -> String {
        var out = ""
        for u in text.unicodeScalars {
            if isHidden(u) { out += mark(u) } else { out.unicodeScalars.append(u) }
        }
        return out
    }

    private static func mark(_ u: Unicode.Scalar) -> String { String(format: "⟦U+%04X⟧", u.value) }

    /// Decoded from %XX for reading: unreserved ASCII, or a non-ASCII letter, spacing mark or digit that shows.
    /// Never a separator, a hidden character, or a combining mark (Mn/Me, which would fold onto the character before it).
    private static func readable(_ u: Unicode.Scalar) -> Bool {
        if isHidden(u) { return false }
        if u.isASCII { return ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u) || "-._~".unicodeScalars.contains(u) }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .spacingMark, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// readableURL's text, whether a hidden character is in the address (raw or %-encoded), whether its host has %XX,
    /// and why the part before the path parses differently in Foundation and WebKit (backslash, "name@", not "//"), if so.
    private static func scanURL(_ s: String) -> (text: String, hidden: Bool, encodedHost: Bool, oddAuthority: String?) {
        let u = Array(s.unicodeScalars)
        func isHex(_ c: Unicode.Scalar) -> Bool { c.isASCII && c.properties.isASCIIHexDigit }
        var out = "", hidden = false, i = 0
        // The authority (name@host:port, after "scheme:" and its slashes, a backslash read as one) is checked for hidden
        // characters but never decoded: URL.host turns %D0%B0pple.com into a Cyrillic "аpple.com" while WebKit opens
        // xn--pple-43d.com.
        var start = 0, authorityEnd = 0, oddAuthority: String?
        func schemeChar(_ c: Unicode.Scalar) -> Bool { c.isASCII && (c.properties.isAlphabetic || "0123456789+-.".unicodeScalars.contains(c)) }
        if let colon = u.firstIndex(of: ":"), colon > 0, u[..<colon].allSatisfy(schemeChar) {
            start = u[(colon + 1)...].firstIndex { $0 != "/" && $0 != "\\" } ?? u.count
            authorityEnd = u[start...].firstIndex { "/\\?#".unicodeScalars.contains($0) } ?? u.count
            // WebKit reads a backslash as "/"; Foundation does not. Up to the first / ? # either may call it the host.
            let wide = u[start...].firstIndex { "/?#".unicodeScalars.contains($0) } ?? u.count
            if !u[(colon + 1)..<start].elementsEqual("//".unicodeScalars) {
                oddAuthority = L("주소의 :// 모양이 달라서 실제로 가는 곳이 다를 수 있어서 하지 않아요")
            } else if u[start..<wide].contains("\\") {
                oddAuthority = L("주소에 역슬래시가 있어 실제로 가는 곳이 다를 수 있어서 하지 않아요")
            } else if u[start..<wide].contains("@") {
                oddAuthority = L("사이트 이름 앞에 @가 있어 실제로 가는 곳이 다를 수 있어서 하지 않아요")
            }
        }
        let encodedHost = u[start..<authorityEnd].split(separator: "@", omittingEmptySubsequences: false).last?.contains("%") == true
        while i < u.count {
            let decode = i >= authorityEnd
            // A run of %XX is decoded as UTF-8; a sequence that is not one character we may show keeps its %XX text.
            var run: [(byte: UInt8, text: String)] = []
            while i + 2 < u.count, u[i] == "%", isHex(u[i + 1]), isHex(u[i + 2]) {
                let text = "%" + String(u[i + 1]) + String(u[i + 2])
                run.append((UInt8(text.dropFirst(), radix: 16)!, text))
                i += 3
            }
            var j = 0
            while j < run.count {
                let lead = run[j].byte
                let n = lead < 0x80 ? 1 : lead >> 5 == 0b110 ? 2 : lead >> 4 == 0b1110 ? 3 : lead >> 3 == 0b11110 ? 4 : 0
                let bytes = n > 0 && j + n <= run.count ? run[j..<j + n].map(\.byte) : []
                let char = String(decoding: bytes, as: UTF8.self)
                guard !bytes.isEmpty, Array(char.utf8) == bytes, let c = char.unicodeScalars.first else {
                    out += run[j].text
                    j += 1
                    continue
                }
                if isHidden(c) { hidden = true }
                out += decode && readable(c) ? char : run[j..<j + n].map(\.text).joined()
                j += n
            }
            guard i < u.count, run.isEmpty else { continue }
            if isHidden(u[i]) { hidden = true; out += mark(u[i]) } else { out.unicodeScalars.append(u[i]) }
            i += 1
        }
        return (out, hidden, encodedHost, oddAuthority)
    }

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
