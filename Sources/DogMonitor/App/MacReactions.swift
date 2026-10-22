import AppKit
import Combine

/// 다운로드 배달: which new files in the Downloads folder finished. Fed one look at the folder at a time (name to size
/// in bytes, -1 for folders and packages); a new file counts once its size held still (and over 0) between two looks
/// `settle` seconds apart. One that starts empty (curl, wget) is watched too: the folder says nothing as a file grows.
struct DownloadSettle {
    static let settle: TimeInterval = 1
    /// A new file still empty after this long is not a download (a `touch`): it stops the 1 s looks.
    static let emptyWait: TimeInterval = 30
    /// Browsers' unfinished downloads (Chrome, Safari, Firefox and others).
    static let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    private(set) var known: Set<String>
    private var pending: [String: (size: Int64, since: TimeInterval)] = [:]
    /// A new file is still settling: look again in a second.
    var waiting: Bool { !pending.isEmpty }

    /// What is there already is old news.
    init(_ listing: [String: Int64]) { known = Set(listing.keys) }

    /// Not done yet: hidden, a browser's partial file, or the final name next to one (Firefox makes both at the start).
    static func unfinished(_ name: String, in listing: [String: Int64]) -> Bool {
        name.hasPrefix(".") || partial.contains((name as NSString).pathExtension.lowercased())
            || partial.contains { listing["\(name).\($0)"] != nil }
    }

    /// The new files that finished since the last look, by name.
    mutating func feed(_ listing: [String: Int64], at t: TimeInterval) -> [String] {
        known.formIntersection(listing.keys)   // removed ones may come again
        pending = pending.filter { listing[$0.key] != nil }
        var done: [String] = []
        for (name, size) in listing where !known.contains(name) {
            if Self.unfinished(name, in: listing) { pending[name] = nil; continue }
            guard size >= 0 else { continue }   // a folder or a package
            if let p = pending[name], p.size == size {
                if size > 0, t - p.since >= Self.settle { done.append(name); known.insert(name); pending[name] = nil }
                if size == 0, t - p.since >= Self.emptyWait { known.insert(name); pending[name] = nil }
            } else {
                pending[name] = (size, t)
            }
        }
        return done.sorted()
    }
}

/// 바쁜 맥: the CPU stayed at `high` or over for `hold` seconds; it is over once it falls under `low`.
struct BusySpell {
    static let high = 0.7, low = 0.45, hold: TimeInterval = 20
    /// Readings farther apart than this (the Mac slept, sampling paused) start the count again.
    static let gap: TimeInterval = 5

    private(set) var busy = false
    private var since: TimeInterval?, last: TimeInterval?

    /// One CPU reading (0...1) at `t`; the new state when it changed.
    mutating func feed(_ cpu: Double, at t: TimeInterval) -> Bool? {
        if let l = last, t - l > Self.gap { since = nil }
        last = t
        if cpu >= Self.high { since = since ?? t } else if !busy || cpu < Self.low { since = nil }
        let now = since.map { t - $0 >= Self.hold } ?? false
        defer { busy = now }
        return now != busy ? now : nil
    }
}

/// 휴지통: how full the Trash is, from the folder's own link count (APFS: 2 plus one per item), which needs no Full
/// Disk Access, unlike listing or watching it.
enum TrashCount {
    static func items(links: Int) -> Int { max(0, links - 2) }

    /// Emptied: fewer than before and at most one left (Finder's hidden .DS_Store may stay).
    // ponytail: putting back all but one item looks the same; the Finder's own empty signal needs Automation permission
    static func emptied(from old: Int, to new: Int) -> Bool { new < old && new <= 1 }
}

/// 휴지통: the kick. A wind-up, then the bundle flies off in an arc, spinning.
enum TrashKick {
    static let windup: TimeInterval = 0.35, flight: TimeInterval = 1.2
    static var duration: TimeInterval { windup + flight }

    /// The bundle's offset from where it lay (points, y up) `t` seconds into the kick going `dir` (+1 right), and its turn.
    static func bundle(_ t: TimeInterval, dir: CGFloat) -> (offset: CGPoint, angle: CGFloat) {
        let s = CGFloat(min(flight, max(0, t - windup)))
        return (CGPoint(x: dir * 1500 * s, y: 700 * s - 900 * s * s), -dir * 9 * s)
    }
}

/// 바쁜 맥: where it stands to push a window (screen points, y up).
enum MacPush {
    /// Against the left side of `w`, or the right when there is no room on the left, feet on the window's bottom,
    /// all within `bounds` (the screen it is on); `dir` is the way it pushes. Nil when neither side has room there.
    static func spot(window w: CGRect, size: CGSize, in bounds: CGRect) -> (origin: CGPoint, dir: CGFloat)? {
        let y = min(max(w.minY, bounds.minY), bounds.maxY - size.height)
        if w.minX - size.width >= bounds.minX, w.minX <= bounds.maxX { return (CGPoint(x: w.minX - size.width + 2, y: y), 1) }
        if w.maxX >= bounds.minX, w.maxX + size.width <= bounds.maxX { return (CGPoint(x: w.maxX - 2, y: y), -1) }
        return nil
    }
}

/// "맥과 같이 놀기" (데스크톱 친구): the cursor buddy and the 복제 친구 answer what the Mac does, each part on its own
/// switch, all off at first. 다운로드 배달 watches the Downloads folder (an event per change, a 1 s look only while a new
/// file settles); 휴지통 and 바쁜 맥 ride the SystemMonitor's existing 1 s reading. Nothing runs while all are off.
final class MacReactions {
    static let shared = MacReactions()
    /// 바쁜 맥 now: the buddy pushes the front window while this holds.
    private(set) var busy = false

    private weak var monitor: SystemMonitor?
    private var bag: Set<AnyCancellable> = []
    private var reading: AnyCancellable?
    private var spell = BusySpell()
    private var beat = 0
    private var busySaid: TimeInterval = -.infinity
    #if !MAS
    private var source: DispatchSourceFileSystemObject?
    private var settle = DownloadSettle([:])
    private var settleTimer: Timer?
    /// The folder is read here, off the main thread: a big folder, or the system's privacy question the first time.
    private let disk = DispatchQueue(label: "dogmonitor.downloads", qos: .utility)
    private var opening = false, looking = false, lookAgain = false
    /// The Downloads folder said no (개인정보 보호): quiet until 다운로드 배달 is switched on again.
    private var denied = false
    private var trash: Int?
    #endif

    /// Call once at launch with the app's monitor. Follows the switches on its own.
    func start(monitor: SystemMonitor) {
        guard self.monitor == nil else { return }
        self.monitor = monitor
        MotionStore.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        refresh()
    }

    private func refresh() {
        let s = MotionStore.shared
        #if MAS
        let trashOn = false
        #else
        let trashOn = s.macTrash
        if s.macDownloads { watchDownloads() } else { stopDownloads(); denied = false }
        if !trashOn { trash = nil }
        #endif
        if !s.macBusy { spell = BusySpell(); setBusy(false) }
        if !s.macBusy && !trashOn { reading = nil }
        else if reading == nil { reading = monitor?.$cpuUsage.dropFirst().sink { [weak self] in self?.sample($0) } }
    }

    /// The monitor's reading, about once a second.
    private func sample(_ cpu: Double) {
        if MotionStore.shared.macBusy, let now = spell.feed(cpu, at: ProcessInfo.processInfo.systemUptime) { setBusy(now) }
        if busy { beat += 1; if beat % 4 == 0 { DesktopClones.shared.macMark("💦", hop: false) } }
        #if !MAS
        if MotionStore.shared.macTrash { lookAtTrash() }
        #endif
    }

    private func setBusy(_ on: Bool) {
        guard on != busy else { return }
        busy = on
        beat = 0
        guard on else { return }
        DesktopClones.shared.macMark("💦", hop: false)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - busySaid >= 600, CursorBuddy.shared.head() != nil else { return }   // a long build that comes and goes says so once
        busySaid = now
        say(L("맥이 많이 바빠요. 저도 같이 밀어 볼게요!"))
    }

    private func say(_ line: String) {
        let head = CursorBuddy.shared.head()
        SpeechBubbleCenter.shared.say(text: AssistantModel.persona().dress(line), source: .system,
                                      anchor: head == nil ? nil : { CursorBuddy.shared.head() })
    }

    #if !MAS
    // MARK: 다운로드 배달

    private var downloads: URL? { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }

    private func watchDownloads() {
        guard source == nil, !opening, !denied, let dir = downloads else { return }
        opening = true
        disk.async { [weak self] in
            let first = Self.listing(dir)
            DispatchQueue.main.async { self?.opened(dir, first) }
        }
    }

    private func opened(_ dir: URL, _ first: [String: Int64]?) {
        opening = false
        guard MotionStore.shared.macDownloads, source == nil, !denied else { return }   // switched off meanwhile
        // A refusal here (or the first time, the system's question) is the only ask: no retry until switched on again.
        guard let first else { denied = true; return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { denied = true; return }
        settle = DownloadSettle(first)
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in self?.look() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func stopDownloads() {
        source?.cancel()
        source = nil
        lookAgain = false
        settleTimer?.invalidate()
        settleTimer = nil
    }

    /// The folder changed, or a new file is settling.
    private func look() {
        settleTimer?.invalidate()
        settleTimer = nil
        guard source != nil, let dir = downloads else { return }
        guard !looking else { lookAgain = true; return }   // a burst of changes: one more look after this one
        looking = true
        disk.async { [weak self] in
            let list = Self.listing(dir)
            DispatchQueue.main.async { self?.looked(dir, list) }
        }
    }

    private func looked(_ dir: URL, _ list: [String: Int64]?) {
        looking = false
        guard source != nil else { lookAgain = false; return }
        guard let list else { stopDownloads(); denied = true; return }
        let done = settle.feed(list, at: ProcessInfo.processInfo.systemUptime)
        if let first = done.first { delivered(dir.appendingPathComponent(first), more: done.count - 1) }
        if lookAgain { lookAgain = false; look() }
        else if settle.waiting {
            settleTimer = Timer.scheduledTimer(withTimeInterval: DownloadSettle.settle, repeats: false) { [weak self] _ in self?.look() }
        }
    }

    /// Name to size (-1 for folders and packages) of everything in `dir`; nil when it cannot be read.
    private static func listing(_ dir: URL) -> [String: Int64]? {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return nil }
        var out: [String: Int64] = [:]
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            out[u.lastPathComponent] = v?.isRegularFile == true ? Int64(v?.fileSize ?? 0) : -1
        }
        return out
    }

    private func delivered(_ file: URL, more: Int) {
        let name = file.lastPathComponent
        _ = CursorBuddy.shared.deliver(NSWorkspace.shared.icon(forFile: file.path))
        DesktopClones.shared.macMark("📄", hop: true)
        say(more > 0 ? L("다운로드 왔어요: \(name) 외 \(more)개") : L("다운로드 왔어요: \(name)"))
    }

    // MARK: 휴지통

    private func lookAtTrash() {
        var st = stat()
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        guard stat(path, &st) == 0 else { trash = nil; return }
        let n = TrashCount.items(links: Int(st.st_nlink))
        if let old = trash, TrashCount.emptied(from: old, to: n) {
            _ = CursorBuddy.shared.kickTrash()
            DesktopClones.shared.macMark("✦", hop: true)
            say(L("휴지통을 비웠어요. 뻥!"))
        }
        trash = n
    }
    #endif
}
