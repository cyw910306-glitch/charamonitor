// A test-only app for 딴짓 지킴이's paw (qa/drift-e2e.sh) and the real-screen QA (qa/real-*.sh): one window, bundle id
// qa.charamonitor.drifthelper. It prints "quit" when asked to quit the normal way (NSRunningApplication.terminate), so
// the script can tell a polite quit from anything else, and "click X Y" (global points, top left origin) for every
// click its window gets, so a script can tell a click that went through a friend's clear pixels.
// Options: --frame X Y W H (top left origin), --level N (window level), --backdrop X Y W H (a plain second window
// behind it, so clicks around the first one still land on the helper), --cmd FILE (polled: "move X Y" moves the window's top left there,
// "front" brings it in front again, "keep" does that every 0.3 s from then on (a test that needs it uncovered),
// "close" closes the window and keeps the app running).
import AppKit

let args = CommandLine.arguments
func opt(_ flag: String, _ n: Int) -> [Double]? {
    guard let i = args.firstIndex(of: flag), i + n < args.count else { return nil }
    return args[(i + 1)...(i + n)].compactMap(Double.init)
}
func say(_ s: String) { print(s); fflush(stdout) }
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

final class ClickView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        let p = w.convertPoint(toScreen: e.locationInWindow)
        say("click \(Int(p.x)) \(Int(primaryHeight - p.y))")
    }
    override func draw(_ r: NSRect) { NSColor(white: 0.93, alpha: 1).setFill(); r.fill() }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var backdrop: NSWindow?
    var timer: Timer?
    var keep: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 420, height: 260), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Drift QA helper"
        w.contentView = ClickView()
        if let f = opt("--frame", 4), f.count == 4 { place(w, x: f[0], y: f[1], width: f[2], height: f[3]) }
        if let l = opt("--level", 1)?.first { w.level = NSWindow.Level(Int(l)) }   // 2: over the owner's windows, under friends
        if let b = opt("--backdrop", 4), b.count == 4 {
            let d = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            d.contentView = ClickView()
            place(d, x: b[0], y: b[1], width: b[2], height: b[3])
            d.orderFront(nil)
            backdrop = d
        }
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        if let i = args.firstIndex(of: "--cmd"), i + 1 < args.count { poll(args[i + 1]) }
    }

    private func place(_ w: NSWindow, x: Double, y: Double, width: Double? = nil, height: Double? = nil) {
        let size = CGSize(width: width ?? w.frame.width, height: height ?? w.frame.height)
        w.setFrame(NSRect(x: x, y: primaryHeight - y - size.height, width: size.width, height: size.height), display: true)
        say("frame \(Int(x)) \(Int(y)) \(Int(size.width)) \(Int(size.height))")
    }

    private func poll(_ file: String) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let text = try? String(contentsOfFile: file, encoding: .utf8), !text.isEmpty else { return }
            try? "".write(toFile: file, atomically: true, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let p = line.split(separator: " ")
                if p.first == "move", p.count == 3, let x = Double(p[1]), let y = Double(p[2]), let w = self.window {
                    self.place(w, x: x, y: y)
                } else if p.first == "front" {
                    self.backdrop?.orderFrontRegardless()
                    self.window?.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                } else if p.first == "keep", self.keep == nil {
                    self.keep = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                        self?.backdrop?.orderFrontRegardless()
                        if self?.window?.isVisible == true { self?.window?.orderFrontRegardless() }
                    }
                } else if p.first == "close" {
                    self.window?.close()
                    say("closed")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        say("quit")
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
