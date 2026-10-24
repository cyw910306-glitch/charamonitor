// A test-only app for 딴짓 지킴이's paw (qa/drift-e2e.sh): one window, bundle id qa.charamonitor.drifthelper.
// It prints "quit" when asked to quit the normal way (NSRunningApplication.terminate), so the script can tell a polite
// quit from anything else.
import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 420, height: 260), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Drift QA helper"
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("quit")
        fflush(stdout)
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
