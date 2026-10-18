import AppKit

extension Notification.Name {
    /// Pages post this when a choice is done or something outside opens; the status item closes its popover.
    static let jellyClosePopover = Notification.Name("DogMonitor.closePopover")
}

/// Opening a browser, System Settings or another app from the popover: close the popover first,
/// so it never stays on top of the page the user just opened (a web page, a settings pane).
enum External {
    static func open(_ url: URL) {
        NotificationCenter.default.post(name: .jellyClosePopover, object: nil)
        NSWorkspace.shared.open(url)
    }

    static func openApp(at url: URL) {
        NotificationCenter.default.post(name: .jellyClosePopover, object: nil)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The popover floats above normal windows. While another window should be on top (our own open panel
/// or alert, or any other app the user clicks), it drops to the normal level and comes back afterwards.
enum PopoverLayer {
    static var lower: (() -> Void)?
    static var restore: (() -> Void)?

    /// Runs an app-modal panel (NSOpenPanel, NSAlert) above the popover instead of underneath it.
    static func runModal<T>(_ body: () -> T) -> T {
        lower?()
        defer { restore?() }
        return body()
    }
}

/// Never shown (the app is an accessory), but its key equivalents are what route Cmd+C/V/X/A/Z to text fields
/// and selectable text. Without it, copying or pasting an API key into a text field does nothing.
enum EditMenu {
    static func make() -> NSMenu {
        let edit = NSMenu(title: L("편집"))
        edit.addItem(withTitle: L("실행 취소"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("실행 복귀"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("오려두기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("복사하기"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: L("편집"), action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: L("캐릭모니터"), action: nil, keyEquivalent: ""))
        main.addItem(item)
        return main
    }
}
