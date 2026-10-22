import AppKit
import Combine

/// 폴더 아이콘 입히기 (폴더 친구 card): the chosen character sits on top of a folder's icon, everywhere Finder shows it
/// (desktop, windows, Dock), on the desktop's folders while 폴더 친구 is on. It is the folder's own custom icon (NSWorkspace.setIcon), so nothing runs to keep it there.
/// Only folders this app dressed are remembered and ever touched again: a folder that already has its own custom icon is
/// left alone, 원래대로 takes ours off. A new character dresses the remembered folders again.
final class FolderIcons: ObservableObject {
    static let shared = FolderIcons()
    static let key = "folderIcons"

    private let defaults: UserDefaults
    /// Paths of the folders wearing our icon.
    @Published private(set) var dressed: [String]
    private var bag: Set<AnyCancellable> = []
    private var look: (SpriteLook, [String: [String: RGBColor]])?

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        dressed = defaults.stringArray(forKey: Self.key) ?? []
    }

    private var watch: DispatchSourceFileSystemObject?

    /// With 폴더 친구 on, the desktop's folders wear the character (new ones too, by watching the desktop); off, ours come
    /// off. The remembered folders are dressed again when the character or its colors change.
    func start() {
        FolderStore.shared.$prefs.map(\.on).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.desktop(on) }
            .store(in: &bag)
        look = (SpriteLook(AppSettings.shared), AppSettings.shared.characterColors)
        AppSettings.shared.objectWillChange
            .merge(with: CustomCharacterStore.shared.objectWillChange)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, !dressed.isEmpty else { return }
                let now = (SpriteLook(AppSettings.shared), AppSettings.shared.characterColors)
                if look.map({ $0 != now }) ?? true { look = now; dress(dressed.map(URL.init(fileURLWithPath:))) }
            }
            .store(in: &bag)
        FolderStore.shared.$prefs.map(\.iconStyle).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] style in
                guard let self else { return }
                dress(dressed.map(URL.init(fileURLWithPath:)), style: style)
            }
            .store(in: &bag)
    }

    private func desktop(_ on: Bool) {
        watch?.cancel(); watch = nil
        guard on else { if !dressed.isEmpty { undress() }; return }
        dress(Self.desktopFolders())
        let fd = open(Self.desk.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        // A folder dropped or made on the desktop: dressed a moment later (a new folder is still being named).
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self, FolderStore.shared.prefs.on else { return }
                let new = Self.desktopFolders().filter { !self.dressed.contains($0.path) }
                if !new.isEmpty { self.dress(new) }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watch = src
    }

    static var desk: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop") }

    /// The folders right on the desktop (not packages, not hidden).
    static func desktopFolders() -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: desk, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return items.filter {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isPackage != true && v?.isSymbolicLink != true
        }
    }

    /// A folder with a custom icon we did not put there.
    func ownIcon(_ url: URL) -> Bool {
        !dressed.contains(url.path) && FileManager.default.fileExists(atPath: url.appendingPathComponent("Icon\r").path)
    }

    /// Puts the character on `urls`; returns how many now wear it.
    @discardableResult
    func dress(_ urls: [URL], style: FolderIconStyle = FolderStore.shared.prefs.iconStyle) -> Int {
        guard let art = Self.art(style: style) else { return 0 }
        var done = Set(dressed)
        for u in urls where !ownIcon(u) {
            // Finder keeps showing a replaced custom icon until the folder loses it: take ours off first, then tell
            // Finder the folder and the folder it is in changed.
            if done.contains(u.path) { NSWorkspace.shared.setIcon(nil, forFile: u.path, options: []) }
            if NSWorkspace.shared.setIcon(art, forFile: u.path, options: []) { done.insert(u.path) }
            NSWorkspace.shared.noteFileSystemChanged(u.path)
            NSWorkspace.shared.noteFileSystemChanged(u.deletingLastPathComponent().path)
        }
        save(done.filter { FileManager.default.fileExists(atPath: $0) }.sorted())
        return urls.filter { done.contains($0.path) }.count
    }

    /// 원래대로: every folder we dressed gets Finder's own icon back.
    func undress() {
        for p in dressed where FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.setIcon(nil, forFile: p, options: [])
        }
        save([])
    }

    private func save(_ paths: [String]) {
        dressed = paths
        defaults.set(paths, forKey: Self.key)
    }

    /// The folder icon with the menu bar character on it in `style`, 512 pt square.
    static func art(character: String? = nil, style: FolderIconStyle = FolderStore.shared.prefs.iconStyle) -> NSImage? {
        let c = MeadowFriends.cache(character: character, pixelSize: 8)
        let frames = BuddyGait.frames(c)
        guard let who = (style == .nap ? frames[.sleep]?.first : nil) ?? frames[.stand]?.first else { return nil }
        return art(folder: NSWorkspace.shared.icon(for: .folder), character: trimmed(who), smooth: c.smooth, style: style)
    }

    /// `image` cut to its drawn part: wide frames (HD packs) are mostly see-through and would leave a tiny figure.
    static func trimmed(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rep = Optional(NSBitmapImageRep(cgImage: cg)) else { return image }
        var lo = (x: rep.pixelsWide, y: rep.pixelsHigh), hi = (x: -1, y: -1)
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
            lo = (min(lo.x, x), min(lo.y, y)); hi = (max(hi.x, x), max(hi.y, y))
        } }
        guard hi.x >= lo.x, let cut = cg.cropping(to: CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x + 1, height: hi.y - lo.y + 1)) else { return image }
        return NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
    }

    static func art(folder: NSImage, character who: NSImage, smooth: Bool, style: FolderIconStyle = .stand) -> NSImage {
        let side: CGFloat = 512
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // The folder a little smaller, at the bottom. Its front panel's top is about 74% up its square.
            let box = CGRect(x: side * 0.11, y: 0, width: side * 0.78, height: side * 0.78)
            let front = box.minY + box.height * 0.737
            folder.draw(in: box)
            let aspect = who.size.width / max(1, who.size.height)
            /// The figure `h` tall (no wider than `maxW`), its bottom middle at (x, y).
            func place(h: CGFloat, maxW: CGFloat, x: CGFloat, y: CGFloat) -> CGRect {
                let fit = min(1, maxW / max(1, h * aspect))
                return CGRect(x: x - h * aspect * fit / 2, y: y, width: h * aspect * fit, height: h * fit)
            }
            NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
            switch style {
            case .stand, .nap:
                // Feet just on the folder's top edge, as big as the room above allows.
                who.draw(in: place(h: side - 4 - front, maxW: side * 0.8, x: side * 0.56, y: front))
            case .peek:
                // Most of it inside the folder: the front panel is drawn again over everything below its top edge.
                let r = place(h: (side - 8 - front) / 0.5, maxW: box.width * 0.9, x: side * 0.53, y: 0)
                who.draw(in: r.offsetBy(dx: 0, dy: front - r.minY - r.height * 0.5))
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(x: 0, y: 0, width: side, height: front)).addClip()
                folder.draw(in: box)
                NSGraphicsContext.restoreGraphicsState()
            case .sticker:
                // On the front panel, like a sticker.
                who.draw(in: place(h: box.height * 0.6, maxW: box.width * 0.62, x: box.midX, y: box.minY + box.height * 0.1))
            }
            return true
        }
    }
}

/// How the character is on a folder's icon.
enum FolderIconStyle: String, CaseIterable, Codable {
    case stand, peek, nap, sticker

    var label: String {
        switch self {
        case .stand: return L("서 있기")
        case .peek: return L("얼굴만 빼꼼")
        case .nap: return L("누워서 낮잠")
        case .sticker: return L("스티커")
        }
    }
}
