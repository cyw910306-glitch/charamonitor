import CryptoKit
import Foundation

// 비서가 행동하기 v2, the agent browser contract (direct build only; implemented by AgentBrowser, a WKWebView window
// "젤리가 쓰는 중"). The model sees pages only as PageSnapshot text with element refs. Sensitive fields (passwords, card,
// OTP, 주민번호) are absent from snapshots, value and existence both. Design: docs/AGENT-DESIGN.md sections 3, 6, 9.

/// One element the agent may act on.
struct PageElement: Equatable {
    /// Stable within one page load ("e12"), written into the DOM as data-agent-ref.
    var ref: String
    /// link, button, input, textarea, select, checkbox, radio
    var role: String
    /// Visible text, aria-label, title, placeholder or alt, trimmed to 80 characters. "" for an icon-only button.
    var label: String
    var href: String? = nil
    /// The enclosing form's method ("get"/"post") and absolute action URL.
    var formMethod: String? = nil
    var formAction: String? = nil
    /// input type (text, search, email, tel, number, checkbox ...).
    var inputType: String? = nil
    /// Current value of a non-sensitive field, or the selected option's text.
    var value: String? = nil
    /// select: the options' texts (first 20).
    var options: [String] = []
}

struct PageSnapshot: Equatable {
    var url: String
    var title: String
    /// Visible text in reading order, whitespace collapsed (cut by forModel).
    var text: String
    var elements: [PageElement]
    /// Absolute src of every iframe (PG frames are a checkout signal).
    var frames: [String] = []

    /// What the model reads: title, address, text, then one line per element ("[e12] button '장바구니 담기'").
    func forModel(limit: Int = 6000) -> String {
        var lines = ["제목: \(title)", "주소: \(url)", ""]
        let budget = max(0, limit / 2)
        lines.append(String(text.prefix(budget)))
        lines.append("")
        lines.append("요소:")
        for e in elements {
            var l = "[\(e.ref)] \(e.role) '\(e.label)'"
            if let t = e.inputType, e.role == "input" { l += " type=\(t)" }
            if let v = e.value, !v.isEmpty { l += " 값='\(v.prefix(40))'" }
            if !e.options.isEmpty { l += " 보기=" + e.options.prefix(8).joined(separator: "|") }
            if let h = e.href, let u = URL(string: h), let host = u.host { l += " → \(host)\(u.path.prefix(40))" }
            lines.append(l)
        }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    func element(_ ref: String) -> PageElement? { elements.first { $0.ref == ref } }
}

enum BrowserError: Error, Equatable {
    case noPage
    case noElement(String)        // the ref is not on the page (any more)
    case sensitive                // a password/card/OTP field: never touched
    case blocked(String)          // a host outside http(s), a download, a file URL
    case ownerHasIt               // the owner pressed [내가 할게]
    case timeout
    case load(String)

    var message: String {
        switch self {
        case .noPage: return L("열린 페이지가 없어요")
        case .noElement(let r): return L("페이지에서 \(r) 요소를 찾지 못했어요. web_snapshot으로 다시 보세요")
        case .sensitive: return L("비밀번호·카드·인증번호 칸은 비서가 건드리지 않아요")
        case .blocked(let why): return why
        case .ownerHasIt: return L("사용자가 브라우저를 넘겨받았어요")
        case .timeout: return L("페이지가 너무 오래 걸려요")
        case .load(let why): return L("페이지를 열지 못했어요: \(why)")
        }
    }
}

/// The browser the tool host drives. Every method waits for the page to settle (load finished, then up to 1.5 s of DOM
/// quiet) and returns a fresh snapshot.
@MainActor
protocol AgentBrowsing: AnyObject {
    func open(_ url: URL) async throws -> PageSnapshot
    func snapshot() async throws -> PageSnapshot
    func click(ref: String) async throws -> PageSnapshot
    /// IME-safe for Korean. `text` is the real value (the host already replaced placeholders).
    func type(ref: String, text: String, submit: Bool) async throws -> PageSnapshot
    func select(ref: String, value: String) async throws -> PageSnapshot
    func scroll(down: Bool) async throws -> PageSnapshot
    func back() async throws -> PageSnapshot
    /// web_find: lines around the text and the nearest element refs.
    func find(_ text: String) async throws -> String
    /// The element's signature right now (nil when it is gone), for the approval-time TOCTOU check.
    func signature(ref: String) async throws -> String?
    /// Status line in the window ("젤리가 쿠팡에서 찾는 중…").
    func show(status: String)
    /// Brings the window forward, outlines `ref` (the pay button, the login field) and stops all agent input until the
    /// next run. The owner continues by hand.
    func handOff(reason: String, highlight ref: String?)
    /// The owner pressed [내가 할게] (or handOff ran): every agent call throws .ownerHasIt.
    var ownerHasIt: Bool { get }
    /// The last owner mouse or key event in the window (the agent pauses 5 seconds after it).
    var lastOwnerInput: Date? { get }
    /// Opens the window (if closed) so the owner can watch.
    func reveal()
    /// Starts a new run: clears ownerHasIt, keeps the cookies (the owner's logins).
    func beginRun()
    func close()
}

/// Approval-time check that the element is the one the owner saw on the card (design section 6).
enum ElementSignature {
    static func make(_ e: PageElement, pageURL: String) -> String {
        let parts = [pageURL, e.role, e.label, e.href ?? "", e.formMethod ?? "", e.formAction ?? "", e.inputType ?? ""]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Pages and buttons where the agent stops and hands the browser to the owner (design section 3). Pure, so the corpus
/// in CheckoutDetectorTests pins it.
enum CheckoutDetector {
    /// Why this page is a checkout (nil = not one): its address, title or a PG frame.
    static func page(url: String, title: String, frames: [String]) -> String? {
        if let host = pgHost(url) { return L("결제창(\(host))이에요") }
        if let t = checkoutToken(url: url) { return L("주소가 결제·주문 화면이에요 (\(t))") }
        if let t = titleToken(title) { return L("제목이 결제·주문 화면이에요 (\(t))") }
        if let host = frames.lazy.compactMap(pgHost).first { return L("결제창(\(host))이 들어 있어요") }
        return nil
    }

    /// Why pressing this element would pay, order, book, issue or transfer (nil = not one).
    static func element(_ e: PageElement) -> String? {
        if let w = payWord(e.label) { return L("'\(e.label)' 버튼은 결제·주문이에요 (\(w))") }
        // A submit into a checkout address pays whatever its label (icon-only buttons, "다음").
        let submits = e.role == "button" || ["submit", "image"].contains(e.inputType ?? "")
        if submits, let action = e.formAction, pgHost(action) != nil || checkoutToken(url: action) != nil {
            return L("결제·주문 주소로 보내는 버튼이에요")
        }
        return nil
    }

    // 예약하기 alone is not here: on booking sites it usually opens a form, and the confirm step that follows is caught
    // by 예약확정 or the page itself.
    private static let koreanLabels = ["결제", "구매하기", "바로구매", "지금구매", "즉시구매", "주문하기", "예약확정", "발권", "송금", "이체"]
    /// Labels about paying rather than pay buttons ("결제 내역", "네이버페이 적립 이벤트").
    private static let infoWords = ["내역", "안내", "조회", "이벤트", "적립", "혜택", "방법", "수단"]
    /// Pay brands are buttons only as short labels ("카카오페이", "네이버페이 구매"), not inside banner text.
    private static let payBrands = ["쿠페이", "네이버페이", "카카오페이", "토스페이", "페이코"]
    private static let englishWords: Set<String> = ["pay", "payment", "checkout", "purchase"]
    private static let englishPhrases = ["buy now", "buy it now", "place order", "place your order", "book now", "check out",
                                         "complete order", "confirm order", "submit order", "confirm booking"]
    /// Hosts of Korean PGs and pay services, by label (stdpay.inicis.com) or suffix.
    private static let pgLabels: Set<String> = ["inicis", "kcp", "tosspayments", "nicepay", "kakaopay", "payco", "coupay"]
    private static let pgSuffixes = ["pay.naver.com", "pay.kakao.com", "online-pay.kakao.com", "pay.toss.im", "pay.coupang.com"]
    private static let urlTokens: Set<String> = ["order", "orders", "ordersheet", "orderform", "checkout", "payment", "payments"]

    private static func payWord(_ label: String) -> String? {
        let squashed = label.filter { !$0.isWhitespace }
        // A keyword inside one word ("간편결제") or starting two joined words ("바로 구매"), never across a word
        // boundary ("운송 금지" is not 송금).
        let parts = label.split(whereSeparator: \.isWhitespace).map(String.init)
        let pairs = zip(parts, parts.dropFirst()).map { $0 + $1 }
        // Every keyword, not just the first: an excused "결제 혜택" must not hide a later "바로구매" (review 2026-10-06).
        let hits = koreanLabels.filter { k in parts.contains { $0.contains(k) } || pairs.contains { $0.hasPrefix(k) } }
        if let k = hits.first(where: { k in !infoWords.contains(where: squashed.contains) || squashed.hasSuffix(k) || squashed.hasSuffix(k + "하기") }) {
            return k
        }
        if hits.count > 1 { return hits[1] }
        if let b = payBrands.first(where: squashed.contains), squashed.count <= b.count + 3 { return b }
        let lower = label.lowercased()
        let w = words(lower)
        if let hit = w.first(where: englishWords.contains) { return hit }
        if w.first == "buy" { return "buy" }
        let spaced = " " + w.joined(separator: " ") + " "
        return englishPhrases.first { spaced.contains(" \($0) ") }
    }

    private static func pgHost(_ url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        if labels.contains(where: pgLabels.contains) || pgSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return host
        }
        return nil
    }

    /// order, checkout, payment as whole path or host words (camelCase and -_. split), 주문서 or 결제 inside a segment.
    private static func checkoutToken(url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        let path = u.path.removingPercentEncoding ?? u.path
        // Hash-routed SPAs (#/checkout) and step queries (?step=payment) too, and a bare "pay" segment.
        let fragment = (u.fragment ?? "").removingPercentEncoding ?? ""
        // Step-like keys only: a search for "checkout" (?q=checkout) is not a checkout page.
        let steps: Set<String> = ["step", "stage", "page", "view", "mode", "flow", "type", "path", "tab"]
        let query = (URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { steps.contains($0.name.lowercased()) }.compactMap(\.value)
        let parts = (u.host ?? "").split(separator: ".").map(String.init) + path.split(separator: "/").map(String.init)
            + fragment.split(whereSeparator: { "/?&=".contains($0) }).map(String.init) + query
        for part in parts {
            if let k = ["주문서", "결제"].first(where: part.contains) { return k }
            if let t = words(splitCamel(part)).first(where: urlTokens.contains) { return t }
        }
        if path.split(separator: "/").contains(where: { $0.lowercased() == "pay" }) { return "pay" }
        return nil
    }

    private static func titleToken(_ title: String) -> String? {
        if let k = ["주문서", "결제"].first(where: title.contains) { return k }
        return words(title.lowercased()).first { ["checkout", "payment", "order"].contains($0) }
    }

    /// Lowercased ASCII words; Hangul and punctuation split them, so "border" stays one word.
    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    private static func splitCamel(_ s: String) -> String {
        var out = ""
        var prev: Character?
        for c in s {
            if c.isUppercase, let p = prev, p.isLowercase { out.append(" ") }
            out.append(c)
            prev = c
        }
        return out
    }
}
