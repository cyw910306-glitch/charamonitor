#if !MAS
import AppKit
import WebKit

/// The agent browser (design sections 3, 9, 14): a WKWebView window "젤리가 쓰는 중" with a [내가 할게] button. All DOM
/// work runs in the isolated "agent" content world, so the page's scripts cannot see or patch our helpers. Cookies live
/// in the default persistent store, so the owner's logins carry over between runs.
@MainActor
final class AgentBrowser: NSObject, AgentBrowsing, WKNavigationDelegate, WKUIDelegate {
    private(set) var ownerHasIt = false
    private(set) var lastOwnerInput: Date?
    let webView: WKWebView
    private var window: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "")
    private let world = WKContentWorld.world(name: "agent")
    private var synthesizing = false
    private var loadError: String?
    /// HTTP status of the last top page (403/429 with an empty page = a bot wall).
    private(set) var lastStatus: Int?
    /// Every subframe this page loaded, src or not: PG layers are often an empty iframe filled by a form POST
    /// (review 2026-10-06), so the frame's own navigation is what shows the payment host.
    private var subframes: [String] = []

    /// `offscreen` never shows a window and keeps no cookies (tests and the --agent-browse probe).
    init(name: String? = nil, offscreen: Bool = false) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = offscreen ? .nonPersistent() : .default()
        // Without the Safari token the WebKit agent string reads as an embedded bot to some shops.
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "18.0"
        config.applicationNameForUserAgent = "Version/\(safari) Safari/605.1.15"
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if !offscreen { makeWindow(name) }
    }

    // MARK: AgentBrowsing

    func open(_ url: URL) async throws -> PageSnapshot {
        try await gate()
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw BrowserError.blocked(L("http·https 주소만 열 수 있어요")) }
        let t0 = Date()
        webView.load(URLRequest(url: url))
        try await settle()
        var s = try await read()
        // Bot challenges (쿠팡, ~9 s) and heavy apps (대한항공, ~19 s) stay blank long after load: wait within the 20 s.
        while s.text.count < 50, Date().timeIntervalSince(t0) < 20 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if ownerHasIt { throw BrowserError.ownerHasIt }
            s = try await read()
        }
        return s
    }

    /// Tests: a fixture page under a pretend https address.
    func load(html: String, baseURL: URL) async throws -> PageSnapshot {
        loadError = nil
        webView.loadHTMLString(html, baseURL: baseURL)
        try await settle()
        return try await read()
    }

    func snapshot() async throws -> PageSnapshot {
        try await gate()
        return try await read()
    }

    func click(ref: String) async throws -> PageSnapshot {
        try await gate()
        let r = try await call("prepare", ["ref": ref])
        try check(r, ref)
        let p = (try? JSONSerialization.jsonObject(with: Data(r.utf8))) as? [String: Any]
        if let window, window.isVisible, let p, p["hit"] as? Bool == true, let x = p["x"] as? Double, let y = p["y"] as? Double {
            nativeClick(at: CGPoint(x: x, y: y), in: window)
        } else {
            try check(try await call("click", ["ref": ref]), ref)   // hidden window or covered element: a DOM click
        }
        try await settle(grace: true)
        return try await read()
    }

    func type(ref: String, text: String, submit: Bool) async throws -> PageSnapshot {
        try await gate()
        try check(try await call("type", ["ref": ref, "text": text, "submit": submit]), ref)
        try await settle(grace: submit)
        return try await read()
    }

    func select(ref: String, value: String) async throws -> PageSnapshot {
        try await gate()
        let r = try await call("select", ["ref": ref, "value": value])
        if r == "nooption" { throw BrowserError.blocked(L("'\(value)' 보기가 없어요")) }
        if r == "ambiguous" { throw BrowserError.blocked(L("'\(value)'에 맞는 보기가 여러 개예요. 보기 글자 그대로 골라 주세요")) }
        try check(r, ref)
        try await settle(grace: true)
        return try await read()
    }

    func scroll(down: Bool) async throws -> PageSnapshot {
        try await gate()
        _ = try await call("scroll", ["down": down])
        try await settle()
        return try await read()
    }

    func back() async throws -> PageSnapshot {
        try await gate()
        guard webView.canGoBack else { throw BrowserError.blocked(L("뒤로 갈 페이지가 없어요")) }
        webView.goBack()
        try await settle(grace: true)
        return try await read()
    }

    func find(_ text: String) async throws -> String {
        _ = try await snapshot()   // refs first, so the snippets can name them
        let r = try await call("find", ["q": text])
        return r.isEmpty ? L("'\(text)' 글자를 찾지 못했어요") : r
    }

    func signature(ref: String) async throws -> String? {
        let s = try await snapshot()
        return s.element(ref).map { ElementSignature.make($0, pageURL: s.url) }
    }

    func show(status: String) { statusLabel.stringValue = status }

    func handOff(reason: String, highlight ref: String?) {
        ownerHasIt = true
        show(status: reason)
        reveal()
        if let ref { Task { _ = try? await call("outline", ["ref": ref]) } }
    }

    func reveal() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func beginRun() {
        ownerHasIt = false
        show(status: "")
    }

    func close() {
        window?.orderOut(nil)
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    @objc private func takeOver() {
        ownerHasIt = true
        show(status: L("이제 직접 하세요"))
    }

    // MARK: Waiting

    /// Holds every agent call while the owner has the browser or touched it in the last 5 seconds.
    private func gate() async throws {
        loadError = nil
        while true {
            if ownerHasIt { throw BrowserError.ownerHasIt }
            guard let t = lastOwnerInput, Date().timeIntervalSince(t) < 5 else { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Load finished (20 s cap), then DOM quiet: no mutation for 600 ms, at most 1.5 s.
    private func settle(grace: Bool = false) async throws {
        if grace { try await Task.sleep(nanoseconds: 300_000_000) }   // a click or Enter starts its navigation a beat later
        let end = Date().addingTimeInterval(20)
        while webView.isLoading {
            if ownerHasIt { throw BrowserError.ownerHasIt }
            if Date() > end {
                // Pages that never stop loading (ads, long polls) are still usable once the DOM is parsed.
                let state = try? await call("state")
                if state == "interactive" || state == "complete" { break }
                throw BrowserError.timeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let e = loadError { loadError = nil; throw BrowserError.load(e) }
        var last = -1
        var quietSince = Date()
        let cap = Date().addingTimeInterval(1.5)
        while Date() < cap {
            let n = Int((try? await call("mutations")) ?? "") ?? -2
            if n != last { last = n; quietSince = Date() } else if Date().timeIntervalSince(quietSince) >= 0.6 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: JavaScript

    private func read() async throws -> PageSnapshot {
        guard let url = webView.url, ["http", "https"].contains(url.scheme ?? "") else { throw BrowserError.noPage }
        let raw = try await call("snapshot")
        guard let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { throw BrowserError.load("snapshot") }
        let elements = (o["elements"] as? [[String: Any]] ?? []).map { d in
            PageElement(ref: d["ref"] as? String ?? "", role: d["role"] as? String ?? "button", label: d["label"] as? String ?? "",
                        href: d["href"] as? String, formMethod: d["formMethod"] as? String, formAction: d["formAction"] as? String,
                        inputType: d["inputType"] as? String, value: d["value"] as? String, options: d["options"] as? [String] ?? [])
        }
        return PageSnapshot(url: url.absoluteString, title: webView.title ?? "", text: o["text"] as? String ?? "",
                            elements: elements, frames: Array(Set((o["frames"] as? [String] ?? []) + subframes)).sorted())
    }

    /// Runs one helper of `agentJS` in the agent world. Helpers always return a string.
    private func call(_ fn: String, _ args: [String: Any] = [:]) async throws -> String {
        let body = "if (!window.__agent) {\n\(Self.agentJS)\n}\nreturn String(window.__agent.\(fn)(args));"
        return try await withCheckedThrowingContinuation { c in
            webView.callAsyncJavaScript(body, arguments: ["args": args], in: nil, in: world) { r in
                switch r {
                case .success(let v): c.resume(returning: v as? String ?? "")
                case .failure(let e): c.resume(throwing: BrowserError.load(e.localizedDescription))
                }
            }
        }
    }

    private func check(_ result: String, _ ref: String) throws {
        switch result {
        case "missing": throw BrowserError.noElement(ref)
        case "sensitive": throw BrowserError.sensitive
        case "notfield": throw BrowserError.blocked(L("\(ref) 요소는 입력할 수 없는 칸이에요"))
        case "nofocus": throw BrowserError.blocked(L("\(ref) 칸에 커서를 둘 수 없어서 입력하지 않았어요"))
        default: return
        }
    }

    /// A real mouse click, so the page sees isTrusted events. Page points are top-left based like the flipped web view.
    private func nativeClick(at p: CGPoint, in window: NSWindow) {
        let local = webView.isFlipped ? p : CGPoint(x: p.x, y: webView.bounds.height - p.y)
        let at = webView.convert(local, to: nil)
        synthesizing = true
        defer { synthesizing = false }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(e)
        }
    }

    // MARK: Delegates

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if action.shouldPerformDownload { return decisionHandler(.cancel) }
        if action.targetFrame?.isMainFrame ?? true {
            // The top page is only ever a web page: no file:, data: or app links.
            guard ["http", "https", "about"].contains(scheme) else {
                loadError = L("열 수 없는 주소예요 (\(scheme):)")
                return decisionHandler(.cancel)
            }
            if scheme != "about" { subframes = [] }
        } else if scheme == "file" {
            return decisionHandler(.cancel)
        } else if ["http", "https"].contains(scheme), let u = action.request.url?.absoluteString, subframes.count < 50 {
            subframes.append(u)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame { lastStatus = (response.response as? HTTPURLResponse)?.statusCode }
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)   // no downloads
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    private func noteFailure(_ error: Error) {
        let e = error as NSError
        // Cancelled loads (a new navigation, our own policy cancel) are not page failures.
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        loadError = e.localizedDescription
    }

    /// window.open and target=_blank load in this same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { webView.load(action.request) }
        return nil
    }

    // MARK: Window

    private func makeWindow(_ name: String?) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: true)
        w.title = name.map { L("\(Banmal.josa($0, "이", "가")) 쓰는 중") } ?? L("캐릭터가 쓰는 중")
        w.isReleasedWhenClosed = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView()
        bar.setViews([statusLabel], in: .leading)
        bar.setViews([NSButton(title: L("내가 할게"), target: self, action: #selector(takeOver))], in: .trailing)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let content = NSView()
        for v in [webView, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
        ])
        w.contentView = content
        w.center()
        window = w
        // The owner's own clicks and keys in this window pause the agent for 5 seconds (synthesized clicks excluded).
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window === self.window, !self.synthesizing { self.lastOwnerInput = Date() }
            }
            return e
        }
    }

    // MARK: Probe

    /// --agent-browse <url> [--out <file>]: opens the page offscreen with no cookies, prints what the model would read
    /// and the checkout verdict, then exits. Read only: no clicks, no typing.
    static func probe(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--agent-browse"), i + 1 < args.count, let url = URL(string: args[i + 1]) else {
            fputs("사용법: DogMonitor --agent-browse <url> [--out <파일>]\n", stderr)
            exit(2)
        }
        let out = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        _ = NSApplication.shared
        let browser = AgentBrowser(offscreen: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { fputs("시간 초과\n", stderr); exit(3) }
        Task {
            let t0 = Date()
            do {
                let s = try await browser.open(url)
                let html = (try? await browser.webView.evaluateJavaScript("document.documentElement.outerHTML.length")) as? Int ?? 0
                let hits = s.elements.compactMap { e in CheckoutDetector.element(e).map { "[\(e.ref)] \($0)" } }
                let report = String(format: "== %.1f초 · HTTP %d · 요소 %d개 · 글자 %d · 프레임 %d · HTML %d\n",
                                    Date().timeIntervalSince(t0), browser.lastStatus ?? 0, s.elements.count, s.text.count, s.frames.count, html)
                    + s.forModel(limit: 12000)
                    + "\n== 결제 화면: " + (CheckoutDetector.page(url: s.url, title: s.title, frames: s.frames) ?? "아님")
                    + "\n== 결제 버튼: " + (hits.isEmpty ? "없음" : hits.joined(separator: " / "))
                    + "\n== 프레임: " + s.frames.map { $0.prefix(100) }.joined(separator: " ") + "\n"
                print(report)
                if let out { try? report.write(toFile: out, atomically: true, encoding: .utf8) }
                exit(0)
            } catch {
                print("== 오류: \((error as? BrowserError)?.message ?? "\(error)")")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    // MARK: Page helpers (agent world)

    private static let agentJS = #"""
    let n = 0, muts = 0;
    for (const e of document.querySelectorAll('[data-agent-ref]')) n = Math.max(n, parseInt(e.getAttribute('data-agent-ref').slice(1)) || 0);
    new MutationObserver(rs => { if (rs.some(r => r.attributeName !== 'data-agent-ref')) muts++; })
      .observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
    const SEL = 'a[href],button,input,textarea,select,[role=button],[role=link],[onclick],summary';
    const KO = /주민|비밀번호|카드번호|보안코드|인증번호|유효기간|외국인등록|계좌비번|결제비번|생년월일앞/;
    const EN = new Set(['card', 'cvc', 'cvv', 'cvn', 'csc', 'pin', 'otp', 'password', 'passwd', 'passcode', 'pw', 'pwd', 'creditcard',
      'cardnumber', 'cardno', 'cardnum', 'ccnum', 'cc', 'securitycode', 'expiry', 'exp', 'jumin', 'rrn', 'ssn']);
    const clean = s => (s || '').replace(/\s+/g, ' ').trim();
    const isField = el => ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName);
    const typeOf = el => (el.getAttribute('type') || el.type || '').toLowerCase();
    const find = ref => document.querySelector('[data-agent-ref="' + CSS.escape(ref) + '"]');

    // Password, card, OTP and 주민번호 fields: never listed, never touched.
    function sensitive(el) {
      if (el.tagName === 'LABEL') return !!(el.control && sensitive(el.control));
      if (!isField(el)) return false;
      if (typeOf(el) === 'password') return true;
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
      if (ac.some(t => t.startsWith('cc-') || ['current-password', 'new-password', 'one-time-code'].includes(t))) return true;
      const by = (el.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => id && document.getElementById(id)).filter(Boolean);
      const cell = el.closest('td') && el.closest('tr') && el.closest('tr').querySelector('th');
      const words = [el.getAttribute('name'), el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'), el.getAttribute('title'),
        ...Array.from(el.labels || []).map(l => l.innerText), ...by.map(b => b.innerText), cell && cell.innerText].filter(Boolean).join(' ');
      // "카드 번호" and "인증 번호" too: Korean is tested with the spaces removed.
      if (KO.test(words.replace(/\s+/g, ''))) return true;
      return words.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/).map(t => t.replace(/\d+/g, '')).some(t => EN.has(t));
    }

    function visible(el) {
      if (el.closest('[aria-hidden="true"],[hidden],[inert]')) return false;
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return false;
      if (el.checkVisibility) return el.checkVisibility({opacityProperty: true, visibilityProperty: true});
      const s = getComputedStyle(el);
      return s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity) > 0;
    }

    function role(el) {
      const t = el.tagName, ty = typeOf(el), ar = el.getAttribute('role');
      if (t === 'A' || ar === 'link') return 'link';
      if (t === 'SELECT') return 'select';
      if (t === 'TEXTAREA') return 'textarea';
      if (t === 'INPUT') {
        if (ty === 'checkbox' || ty === 'radio') return ty;
        return ['submit', 'button', 'reset', 'image'].includes(ty) ? 'button' : 'input';
      }
      return 'button';
    }

    function labelOf(el) {
      let s = '';
      if (isField(el)) {
        if (['submit', 'button', 'reset'].includes(typeOf(el))) s = el.value;
        s = clean(s) || clean(Array.from(el.labels || []).map(l => l.innerText).join(' ')) || el.getAttribute('aria-label')
          || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name');
      } else {
        const img = el.querySelector('img[alt]');
        s = clean(el.innerText) || el.getAttribute('aria-label') || el.getAttribute('title') || (img && img.alt) || '';
      }
      return clean(s).slice(0, 80);
    }

    function snapshot() {
      const elements = [], seen = new Set();
      for (const el of document.querySelectorAll(SEL)) {
        if (elements.length >= 400) break;
        if (sensitive(el)) continue;
        let target = el;
        if (!visible(el)) {
          // Styled checkboxes hide the input and show its label: the label is what gets clicked.
          const ty = typeOf(el);
          if (el.tagName !== 'INPUT' || (ty !== 'checkbox' && ty !== 'radio')) continue;
          target = Array.from(el.labels || []).find(visible);
          if (!target) continue;
        }
        let ref = target.getAttribute('data-agent-ref');
        if (!ref) { ref = 'e' + (++n); target.setAttribute('data-agent-ref', ref); }
        if (seen.has(ref)) continue;
        seen.add(ref);
        const r = role(el), ty = typeOf(el);
        const f = el.form || el.closest('form');
        const e = {ref, role: r, label: labelOf(el), options: []};
        if (el.tagName === 'A') e.href = el.href;
        if (f) {
          // Only a method the page wrote: a method-less form is usually JS-handled (a fetch POST), not a search.
          const m = el.getAttribute('formmethod') || f.getAttribute('method');
          if (m) e.formMethod = m.toLowerCase();
          e.formAction = new URL(el.getAttribute('formaction') || f.getAttribute('action') || '', document.baseURI).href;
        }
        if (el.tagName === 'INPUT') e.inputType = ty || 'text';
        if (r === 'checkbox' || r === 'radio') e.value = el.checked ? 'checked' : '';
        else if (el.tagName === 'SELECT') {
          e.value = clean(el.selectedOptions[0] && el.selectedOptions[0].text);
          e.options = Array.from(el.options).slice(0, 20).map(o => clean(o.text));
        } else if (r === 'input' || r === 'textarea') e.value = (el.value || '').slice(0, 60);
        elements.push(e);
      }
      const lines = [];
      for (const l of (document.body ? document.body.innerText : '').split('\n')) {
        const c = clean(l);
        if (c && c !== lines[lines.length - 1]) lines.push(c);
      }
      const frames = Array.from(document.querySelectorAll('iframe,frame')).map(f => f.src).filter(s => /^https?:/.test(s));
      return JSON.stringify({text: lines.join('\n').slice(0, 20000), elements, frames});
    }

    // Scrolls the element to the middle and says where it is and whether a click there lands on it.
    function prepare(a) {
      const el = find(a.ref);
      if (!el) return 'missing';
      if (sensitive(el)) return 'sensitive';
      // Instant, so the measured point is where the element is now (Bootstrap's scroll-behavior: smooth animates).
      el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      const r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      const at = document.elementFromPoint(x, y);
      // The click lands on `el` itself, not on another control nested in it or laid over it.
      const ok = !!at && (at === el || (at.closest(SEL) === el) || (el.tagName === 'LABEL' && (at === el.control || at.closest('label') === el)));
      return JSON.stringify({x, y, hit: ok});
    }

    function click(a) {
      const el = find(a.ref);
      if (!el) return 'missing';
      if (sensitive(el)) return 'sensitive';
      if (el.tagName === 'A' && el.target && el.target !== '_self') el.target = '_self';   // an untrusted click would be popup-blocked
      el.click();
      return 'ok';
    }

    function type(a) {
      const el = find(a.ref);
      if (!el) return 'missing';
      if (sensitive(el)) return 'sensitive';
      if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return 'notfield';
      if (el.disabled || el.readOnly) return 'notfield';
      el.scrollIntoView({block: 'center', behavior: 'instant'});
      el.focus();
      // insertText writes into whatever has focus: never anything but this field.
      if (document.activeElement !== el) return 'nofocus';
      if (el.select) el.select();
      let ok = false;
      try { ok = a.text !== '' && document.execCommand('insertText', false, a.text); } catch (e) {}
      if (!ok || el.value !== a.text) {
        // React keeps its own copy of value; the prototype setter plus an input event updates both.
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, a.text);
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
      }
      if (a.submit) {
        const o = {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true};
        const go = el.dispatchEvent(new KeyboardEvent('keydown', o));
        el.dispatchEvent(new KeyboardEvent('keypress', o));
        el.dispatchEvent(new KeyboardEvent('keyup', o));
        // A page that handled Enter itself prevents the default; otherwise submit the form like a real Enter would.
        if (go && el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
      }
      return 'ok';
    }

    function select(a) {
      const el = find(a.ref);
      if (!el) return 'missing';
      if (sensitive(el)) return 'sensitive';
      if (el.tagName !== 'SELECT') return 'notfield';
      const v = clean(a.value), opts = Array.from(el.options);
      let o = opts.find(o => clean(o.text) === v || o.value === v);
      if (!o) {
        // A partial match only when it is the only one ("1" must not pick "10개 묶음").
        const near = opts.filter(o => clean(o.text).startsWith(v) || clean(o.text).split(' ').includes(v));
        if (near.length > 1) return 'ambiguous';
        o = near[0];
      }
      if (!o) return 'nooption';
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(el, o.value);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      return 'ok';
    }

    function scroll(a) { window.scrollBy(0, (a.down ? 1 : -1) * window.innerHeight * 0.9); return 'ok'; }

    function outline(a) {
      const el = find(a.ref);
      if (!el) return 'missing';
      el.style.outline = '3px solid #FF3B30';
      el.style.outlineOffset = '2px';
      el.scrollIntoView({block: 'center', behavior: 'instant'});
      return 'ok';
    }

    // Up to five places with the text, each with the refs inside or around it.
    function findText(a) {
      const q = a.q.toLowerCase(), out = [], seen = new Set();
      if (!q || !document.body) return '';
      const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      while (out.length < 5 && w.nextNode()) {
        const node = w.currentNode;
        if (!node.data.toLowerCase().includes(q) || !node.parentElement || !visible(node.parentElement)) continue;
        let block = node.parentElement;
        while (block.parentElement && block !== document.body && block.innerText.length < 60 && block.parentElement.innerText.length < 400) block = block.parentElement;
        if (seen.has(block)) continue;
        seen.add(block);
        const txt = clean(block.innerText), i = Math.max(0, txt.toLowerCase().indexOf(q));
        const refs = [];
        const own = node.parentElement.closest('[data-agent-ref]');
        if (own) refs.push(own.getAttribute('data-agent-ref'));
        // Nearest first: the match's own container, then outward up to the snippet's block.
        for (let up = node.parentElement; up && refs.length < 3; up = up.parentElement) {
          for (const e of up.querySelectorAll('[data-agent-ref]')) {
            const r = e.getAttribute('data-agent-ref');
            if (refs.length < 3 && !refs.includes(r)) refs.push(r);
          }
          if (up === block) break;
        }
        out.push('…' + txt.slice(Math.max(0, i - 80), i + q.length + 80) + '…' + (refs.length ? ' → ' + refs.join(', ') : ''));
      }
      return out.join('\n');
    }

    window.__agent = {snapshot, prepare, click, type, select, scroll, outline, find: findText,
      mutations: () => muts, state: () => document.readyState};
    """#
}
#endif
