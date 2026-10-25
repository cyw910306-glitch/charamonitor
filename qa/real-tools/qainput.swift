// Real-screen QA input (qa/real-*.sh): mouse and key events through CGEvent, and the window list of one process.
// Points are global display points, top left origin (CGEvent's and CGWindowList's own). Needs 손쉬운 사용 for the
// terminal that runs it; `qainput trusted` says whether it has it.
//   qainput trusted
//   qainput click X Y                      press and release
//   qainput drag X1 Y1 X2 Y2 [steps] [ms] [hold ms]  press, move in steps (ms each), hold still (700 ms), release
//   qainput throw X1 Y1 X2 Y2 [steps] [ms] the same with no stop before the release (a throw)
//   qainput move X Y
//   qainput key KEYCODE ctrl,alt,shift,cmd
//   qainput windows PID                    one line per on-screen window: id layer x y w h sharing name
import AppKit

let a = CommandLine.arguments
func num(_ i: Int, _ d: Double = 0) -> Double { i < a.count ? Double(a[i]) ?? d : d }
let src = CGEventSource(stateID: .hidSystemState)

func mouse(_ t: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

/// Where a press may land: QA_ALLOW_PIDS ("<app> <helper>"). Walking the windows at each point front to back (past the
/// see-through full-screen layers of the Dock, the ring light and any copy of this app), the app's own windows may pass the click
/// on, so the first window that is not the app's must be the helper's (the last pid): nothing of the owner's, however
/// it got in front, is ever under a press. Refused: exit 3 before the button goes down.
let allowList = (ProcessInfo.processInfo.environment["QA_ALLOW_PIDS"] ?? "").split(separator: " ").compactMap { Int32($0) }

func landing(at p: CGPoint) -> (pid: Int32, name: String)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    func rect(_ w: [String: Any]) -> CGRect {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }
    func pid(_ w: [String: Any]) -> Int32 { w[kCGWindowOwnerPID as String] as? Int32 ?? -1 }
    func app(_ w: [String: Any]) -> Bool { ["DogMonitor", "캐릭모니터"].contains(w[kCGWindowOwnerName as String] as? String ?? "") }
    for w in list {
        let r = rect(w)
        guard r.contains(p), (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        let name = w[kCGWindowOwnerName as String] as? String ?? "?"
        let big = r.width >= 700 && r.height >= 700
        if big, app(w) || ["Dock", "Ring Light Helper"].contains(name), pid(w) != allowList.first { continue }   // click-through layers
        if pid(w) == allowList.first, allowList.count > 1 { continue }   // the app's own: may pass it on
        // Another copy's friend drawing (shared, so not its hotspot) around its own hotspot (never shared): click-through.
        if app(w), (w[kCGWindowSharingState as String] as? Int ?? 1) != 0,
           list.contains(where: { pid($0) == pid(w) && ($0[kCGWindowSharingState as String] as? Int ?? 1) == 0 && r.contains(rect($0)) }) { continue }
        return (pid(w), name)
    }
    return nil
}

func guardPath(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
    for i in 0...20 {
        let k = Double(i) / 20, p = CGPoint(x: x1 + (x2 - x1) * k, y: y1 + (y2 - y1) * k)
        let o = landing(at: p)
        guard let o, o.pid == allowList.last else {
            FileHandle.standardError.write("거부: \(p) 아래 첫 창이 \(o?.name ?? "없음")(\(o?.pid ?? 0)), 도우미 창이 아님\n".data(using: .utf8)!)
            exit(3)
        }
    }
}

/// Keys go to the app in front unless a combo is registered: only with the helper in front, or QA_HOTKEY_TAKEN=1 when
/// the app logged that the system took its combos (a taken combo never reaches the app in front).
func guardKeys() {
    if ProcessInfo.processInfo.environment["QA_HOTKEY_TAKEN"] == "1" { return }
    guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front == allowList.last else {
        FileHandle.standardError.write("거부: 맨 앞 앱이 도우미가 아님\n".data(using: .utf8)!)
        exit(3)
    }
}

/// The owner's own 커서 친구 follows the pointer and rests beside it, where the next target may be: the pointer waits
/// down and right of the target first (where that friend rests), so it never crosses the target on its way.
func approach(_ p: CGPoint) {
    mouse(.mouseMoved, CGPoint(x: p.x + 160, y: p.y + 120)); usleep(500_000)
}

func press(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, steps: Int, ms: Double, hold: Double) {
    guardPath(x1, y1, x2, y2)
    let from = CGPoint(x: x1, y: y1)
    approach(from)
    mouse(.mouseMoved, from); usleep(120_000)
    guardPath(x1, y1, x1, y1)   // again with the pointer there: a cursor-following friend may have come under it
    mouse(.leftMouseDown, from); usleep(60_000)
    for i in 1...max(1, steps) {
        let k = Double(i) / Double(max(1, steps))
        mouse(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * k, y: y1 + (y2 - y1) * k))
        usleep(useconds_t(ms * 1000))
    }
    if hold > 0 { usleep(useconds_t(hold * 1000)) }
    mouse(.leftMouseUp, CGPoint(x: x2, y: y2))
}

switch a.count > 1 ? a[1] : "" {
case "trusted":
    print(AXIsProcessTrusted() ? "yes" : "no")
case "click":
    guardPath(num(2), num(3), num(2), num(3))
    let p = CGPoint(x: num(2), y: num(3))
    approach(p)
    mouse(.mouseMoved, p); usleep(120_000)
    guardPath(p.x, p.y, p.x, p.y)   // again with the pointer there: a cursor-following friend may have come under it
    mouse(.leftMouseDown, p); usleep(70_000)
    mouse(.leftMouseUp, p)
case "drag":
    press(num(2), num(3), num(4), num(5), steps: Int(num(6, 20)), ms: num(7, 16), hold: num(8, 700))
case "throw":
    press(num(2), num(3), num(4), num(5), steps: Int(num(6, 6)), ms: num(7, 10), hold: 0)
case "move":
    mouse(.mouseMoved, CGPoint(x: num(2), y: num(3)))
case "key":
    guardKeys()
    var flags = CGEventFlags()
    for m in (a.count > 3 ? a[3] : "").split(separator: ",") {
        switch m {
        case "ctrl": flags.insert(.maskControl)
        case "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "cmd": flags.insert(.maskCommand)
        default: break
        }
    }
    let code = CGKeyCode(num(2))
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
case "windows":
    let pid = Int(num(2))
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print(w[kCGWindowNumber as String] ?? 0, w[kCGWindowLayer as String] ?? 0,
              Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(b["Width"] ?? 0), Int(b["Height"] ?? 0),
              w[kCGWindowSharingState as String] ?? 1, w[kCGWindowName as String] as? String ?? "-")
    }
default:
    FileHandle.standardError.write("사용법: qainput trusted|click|drag|throw|move|key|windows\n".data(using: .utf8)!)
    exit(2)
}
