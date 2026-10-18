import Foundation

/// Where the popover was, so opening it again soon after it closed comes back to the same page (2 min), and after
/// a trip to System Settings for a permission to the same section (10 min). Pure apart from `shared`.
struct PopoverMemory {
    static let keep: TimeInterval = 120
    static let settingsKeep: TimeInterval = 600
    /// The 비서 설정 panel id a permission flow scrolls back to.
    static let integrations = "integrations"
    /// 비서 설정 > AI 엔진 and 메일 계정: back here after making a key or an app password in the browser.
    static let byo = "byo", mail = "mail"

    /// 메일 계정 > 계정 추가 as it was left (never the password), so the trip to the app password page keeps it.
    struct MailDraft: Equatable {
        var adding = false
        var preset: MailPreset = .gmail
        var user = ""
        var host = ""
        var port = "993"
    }

    var page: DashboardPage = .main
    /// On `.assistant`: 비서 설정 was open, not the chat.
    var assistantSettings = false
    /// Section to scroll to when the page is rebuilt (a permission flow closed the popover). Cleared once shown.
    var anchor: String?
    var mailDraft = MailDraft()
    private var closedAt: Date?
    private var keepFor = Self.keep

    mutating func closed(at now: Date) { closedAt = now }

    /// A permission prompt or System Settings is about to take the focus: come back to `anchor`, for at least `keep`.
    mutating func leaving(anchor: String?, keep: TimeInterval) {
        self.anchor = anchor
        keepFor = max(keepFor, keep)
    }

    /// The flow ended with the popover still open: nothing to scroll back to.
    mutating func stayed() {
        anchor = nil
        keepFor = Self.keep
    }

    /// The page to open with. Past the window (or first open), the main page and nothing remembered.
    mutating func reopen(now: Date) -> DashboardPage {
        defer { closedAt = nil; keepFor = Self.keep }
        if let closedAt, now.timeIntervalSince(closedAt) < keepFor { return page }
        self = PopoverMemory()
        return .main
    }

    @MainActor static var shared = PopoverMemory()
}

/// Asking macOS for a permission (EventKit, contacts, automation) or sending the user to System Settings for one.
/// The prompt belongs to another process, so our app loses the focus and a transient popover would close and come
/// back on the main page. While a flow runs the popover stays open; when it ends the popover is raised again (or
/// reopened on the same page and section if it closed after all).
@MainActor
enum PermissionFlow {
    private(set) static var running = 0
    static var isActive: Bool { running > 0 }
    /// Set by StatusItemController: raise the popover, or show it again if it closed during the flow.
    static var reopen: (() -> Void)?
    /// Set by StatusItemController: the first flow starts (it notes whether the popover was open then).
    static var started: (() -> Void)?

    /// `asks` false (already allowed or refused, nothing will pop up): just runs `body`, so a long check neither
    /// holds the popover open nor takes the focus back from the app the user went on to.
    static func run<T>(anchor: String? = PopoverMemory.integrations, asks: Bool = true, _ body: () async -> T) async -> T {
        guard asks else { return await body() }
        begin(anchor)
        let result = await body()
        end()
        return result
    }

    /// For a call that blocks the main thread while macOS asks (NSAppleScript). The app's resign-active arrives
    /// only after it returns, so the hold lasts a moment longer.
    static func hold<T>(anchor: String? = nil, _ body: () -> T) -> T {
        begin(anchor)
        let result = body()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { end() }
        return result
    }

    /// The flow goes on in System Settings or a browser (a key, an app password) and its end can't be seen: the
    /// popover closes (External), and opening it within 10 minutes lands back on this page and section.
    static func openSettings(_ url: URL, anchor: String? = PopoverMemory.integrations) {
        PopoverMemory.shared.leaving(anchor: anchor, keep: PopoverMemory.settingsKeep)
        External.open(url)
    }

    private static func begin(_ anchor: String?) {
        running += 1
        if running == 1 { started?() }
        PopoverMemory.shared.leaving(anchor: anchor, keep: PopoverMemory.keep)
    }

    private static func end() {
        running -= 1
        guard running == 0 else { return }
        reopen?()
    }
}
