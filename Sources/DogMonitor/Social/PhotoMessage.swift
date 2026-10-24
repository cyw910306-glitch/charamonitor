import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// 사진 메시지, 근처 친구 only: the photo goes over the friend's own TLS link in 32 KiB parts, never through the 원격
// 모임 relay (its events are 2 KiB). Before anything is decoded the file's size and its header's pixel size are
// checked; ImageIO then makes a 2048 px photo and a 320 px thumbnail, each redrawn on white in sRGB (so no EXIF, GPS
// or colour profile goes along) and saved as JPEG inside its budget. Kept in memory with the chat, never on disk.

enum PhotoRules {
    /// The protocol version (hello) that reads `.photo`; older friends never get one.
    static let version = 3
    /// What may go in: 20 MiB, 20,000 px a side, 80 megapixels.
    static let maxInput = 20 * 1024 * 1024
    static let maxSide = 20_000
    static let maxPixels = 80_000_000
    /// What goes out: the photo and its thumbnail, longest side and JPEG bytes.
    static let fullSide = 2048, thumbSide = 320
    static let fullBudget = 2 * 1024 * 1024, thumbBudget = 128 * 1024
    /// JPEG qualities tried in order; under the last one the picture shrinks by `shrink` and tries again.
    static let qualities: [CGFloat] = [0.85, 0.72, 0.6, 0.48]
    static let shrink: CGFloat = 0.75
    /// One part's bytes: base64 in JSON makes it about 44 KiB, under SocialWire.maxFrame.
    static let chunk = 32 * 1024
    static let maxTotal = fullBudget + thumbBudget
    static let maxParts = (maxTotal + chunk - 1) / chunk
    /// Photos one friend may start a minute (the receive side drops more).
    static let perMinute = 6
    /// Seconds between two of my photos (so one photo's parts never meet the next one's in a rate window).
    static let sendGap: TimeInterval = 3
    /// Per friend, the newest photos that keep their full size in memory; older ones keep only the thumbnail.
    static let keepFull = 8

    static func canSend(version: Int?) -> Bool { (version ?? 0) >= Self.version }

    static func inputOK(width: Int, height: Int, bytes: Int) -> Bool {
        width > 0 && height > 0 && width <= maxSide && height <= maxSide && width * height <= maxPixels && bytes <= maxInput
    }
}

/// A photo ready to send or just received: two JPEGs.
struct PreparedPhoto: Equatable {
    var full: Data
    var thumb: Data
}

enum PhotoFailure: Error, Equatable {
    case tooBig, notImage, wontFit
}

enum PhotoPrep {
    /// The two JPEGs, or why not. The header is read before any pixel is.
    static func prepare(_ data: Data) -> Result<PreparedPhoto, PhotoFailure> {
        guard data.count <= PhotoRules.maxInput else { return .failure(.tooBig) }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return .failure(.notImage) }
        guard PhotoRules.inputOK(width: w, height: h, bytes: data.count) else { return .failure(.tooBig) }
        guard let full = jpeg(src, side: PhotoRules.fullSide, budget: PhotoRules.fullBudget),
              let thumb = jpeg(src, side: PhotoRules.thumbSide, budget: PhotoRules.thumbBudget)
        else { return .failure(.wontFit) }
        return .success(PreparedPhoto(full: full, thumb: thumb))
    }

    /// The image at `side` px at most (turned upright), flattened, saved as JPEG under `budget` bytes.
    static func jpeg(_ src: CGImageSource, side: Int, budget: Int) -> Data? {
        var s = CGFloat(side)
        while s >= 32 {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: Int(s), kCGImageSourceShouldCacheImmediately: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), let flat = flatten(cg) else { return nil }
            for q in PhotoRules.qualities {
                if let d = encode(flat, quality: q), d.count <= budget { return d }
            }
            s = (s * PhotoRules.shrink).rounded(.down)
        }
        return nil
    }

    /// Redrawn on white in an sRGB bitmap: alpha, profile and every tag of the original stay behind.
    static func flatten(_ cg: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(cg, in: r)
        return ctx.makeImage()
    }

    static func encode(_ cg: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A friend's JPEG as this Mac shows it: a JPEG header no bigger than `side` (a little slack), else nil.
    static func checked(_ data: Data, side: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, max(w, h) <= side + 2 else { return nil }
        return NSImage(data: data)
    }

    /// A received photo, both halves checked.
    static func received(_ p: PreparedPhoto) -> Bool {
        checked(p.thumb, side: PhotoRules.thumbSide) != nil && checked(p.full, side: PhotoRules.fullSide) != nil
    }
}

/// One part of a photo on the wire: the thumbnail's bytes, then the photo's, cut in `PhotoRules.chunk`s.
struct PhotoPart: Codable, Equatable {
    var id: UInt32
    var index: Int
    var count: Int
    /// All bytes (thumbnail + photo) and the thumbnail's.
    var total: Int
    var thumb: Int
    var data: Data

    static func split(_ p: PreparedPhoto, id: UInt32) -> [PhotoPart] {
        let all = p.thumb + p.full
        let n = (all.count + PhotoRules.chunk - 1) / PhotoRules.chunk
        return (0..<n).map { i in
            let lo = i * PhotoRules.chunk
            return PhotoPart(id: id, index: i, count: n, total: all.count, thumb: p.thumb.count,
                             data: all.subdata(in: lo..<min(all.count, lo + PhotoRules.chunk)))
        }
    }

    /// Sizes that could be a photo of ours, before a byte is kept.
    var isSane: Bool {
        (1...PhotoRules.maxTotal).contains(total) && (1...PhotoRules.thumbBudget).contains(thumb) && thumb < total
            && total - thumb <= PhotoRules.fullBudget
            && count == (total + PhotoRules.chunk - 1) / PhotoRules.chunk && (0..<count).contains(index)
            && (1...PhotoRules.chunk).contains(data.count)
    }
}

/// The receive side: one photo in flight per friend, parts in order (TLS keeps them so), `PhotoRules.perMinute` starts.
/// A part that does not fit drops the photo it belongs to.
struct PhotoAssembly {
    private var open: [String: (head: PhotoPart, bytes: Data)] = [:]
    private var starts: [String: [TimeInterval]] = [:]

    mutating func push(_ p: PhotoPart, from friend: String, now: TimeInterval) -> PreparedPhoto? {
        guard p.isSane else { open[friend] = nil; return nil }
        if p.index == 0 {
            let recent = (starts[friend] ?? []).filter { now - $0 < 60 }
            guard recent.count < PhotoRules.perMinute else { starts[friend] = recent; open[friend] = nil; return nil }
            starts[friend] = recent + [now]
            open[friend] = (p, Data())
        }
        guard var o = open[friend], o.head.id == p.id, o.head.count == p.count, o.head.total == p.total, o.head.thumb == p.thumb,
              o.bytes.count == p.index * PhotoRules.chunk, o.bytes.count + p.data.count <= p.total
        else { open[friend] = nil; return nil }
        o.bytes.append(p.data)
        guard p.index == p.count - 1 else { open[friend] = o; return nil }
        open[friend] = nil
        guard o.bytes.count == p.total else { return nil }
        return PreparedPhoto(full: o.bytes.subdata(in: p.thumb..<p.total), thumb: o.bytes.prefix(p.thumb))
    }

    mutating func drop(_ friend: String) { open[friend] = nil }

    var inFlight: Int { open.count }
}

/// Where a photo to send comes from: a file, a drop or the clipboard. The size is checked before the bytes are read.
enum PhotoInput {
    static func load(_ url: URL) -> Result<Data, PhotoFailure> {
        guard url.isFileURL else { return .failure(.notImage) }
        if let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, n > PhotoRules.maxInput { return .failure(.tooBig) }
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.notImage) }
        return .success(d)
    }

    /// A copied file, else copied picture bytes (PNG first: a screenshot's TIFF is often over 20 MiB).
    static func pasteboard(_ pb: NSPasteboard = .general) -> Result<Data, PhotoFailure> {
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first { return load(url) }
        for t in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .tiff] {
            if let d = pb.data(forType: t) { return .success(d) }
        }
        return .failure(.notImage)
    }

    /// A drop on the chat window: the first file or picture.
    static func drop(_ providers: [NSItemProvider], then: @escaping (Result<Data, PhotoFailure>) -> Void) -> Bool {
        guard let p = providers.first else { return false }
        let done = { (r: Result<Data, PhotoFailure>) in DispatchQueue.main.async { then(r) } }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in done(url.map(load) ?? .failure(.notImage)) }
            return true
        }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in done(d.map { .success($0) } ?? .failure(.notImage)) }
            return true
        }
        return false
    }

    static func why(_ f: PhotoFailure) -> String {
        switch f {
        case .tooBig: return L("사진이 너무 커요. 20MB, 한 변 2만 픽셀까지 보낼 수 있어요.")
        case .notImage: return L("사진 파일만 보낼 수 있어요.")
        case .wontFit: return L("사진을 줄이지 못했어요. 다른 사진으로 해 주세요.")
        }
    }
}

extension SocialBus {
    func canPhoto(_ id: String) -> Bool { online.contains(id) && PhotoRules.canSend(version: versions[id]) }

    /// Prepares off the main thread, then sends the parts and keeps the photo in the chat. `done` gets nil or why not.
    func sendPhoto(_ data: Data, to id: String, done: @escaping (String?) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard canPhoto(id) else { done(L("친구가 지금 사진을 받을 수 없어요.")); return }
        guard now - (photoSentAt[id] ?? -.infinity) >= PhotoRules.sendGap else { done(L("잠깐 뒤에 다시 보내 주세요.")); return }
        photoSentAt[id] = now
        DispatchQueue.global(qos: .userInitiated).async {
            let r = PhotoPrep.prepare(data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch r {
                case .failure(let f): done(PhotoInput.why(f))
                case .success(let p):
                    guard self.canPhoto(id) else { done(L("친구가 지금 사진을 받을 수 없어요.")); return }
                    PhotoPart.split(p, id: UInt32.random(in: 1...UInt32.max)).forEach { self.send(.photo($0), to: id) }
                    SocialChat.shared.append(id, L("사진"), mine: true, photo: p)
                    done(nil)
                }
            }
        }
    }

    /// A part from a friend; a whole, checked photo goes in the chat and pops up like a chat line.
    func receivedPhoto(_ part: PhotoPart, from id: String) {
        guard let p = photoParts.push(part, from: id, now: ProcessInfo.processInfo.systemUptime), PhotoPrep.received(p) else { return }
        SocialChat.shared.append(id, L("사진"), mine: false, photo: p)
        let thumb = NSImage(data: p.thumb)
        let name = friend(id)?.nickname ?? L("친구")
        if !FriendWindow.isOpen(id),
           !FriendVisit.shared.show(id, line: L("사진을 보냈어요"), photo: thumb, tap: { PhotoWindow.open(p.full, title: name) }) {
            unread.insert(id)
        }
    }
}

/// A photo big, in its own window (not in screen shares).
enum PhotoWindow {
    static func open(_ jpeg: Data, title: String) {
        guard let image = NSImage(data: jpeg) else { return }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fit = PhotoZoomView.fit(image.size, in: CGSize(width: vf.width * 0.8, height: vf.height * 0.8))
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: fit), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: PhotoZoomView(image: image))
        w.isReleasedWhenClosed = true
        w.hidesOnDeactivate = false
        w.sharingType = .none
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct PhotoZoomView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(minWidth: 160, minHeight: 120)
            .background(Color.black.opacity(0.85))
            .accessibilityLabel(L("받은 사진"))
    }

    /// `size` scaled down (never up) to fit in `box`.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let k = min(1, box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }
}

/// A photo in the chat: the thumbnail, a click opens it big.
struct ChatPhotoView: View {
    let photo: ChatPhoto
    let title: String

    var body: some View {
        if let img = NSImage(data: photo.thumb) {
            let s = PhotoZoomView.fit(img.size, in: CGSize(width: 180, height: 180))
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: s.width, height: s.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .onTapGesture { PhotoWindow.open(photo.full ?? photo.thumb, title: title) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(L("사진"))
                .help(L("눌러서 크게 보기"))
        }
    }
}

/// The photo row of the chat window: 사진 menu, the line that says why not, and what a drop or paste does.
struct ChatPhotoBar: View {
    let friendID: String
    @ObservedObject private var bus = SocialBus.shared
    @Binding var note: String?

    var body: some View {
        HStack(spacing: 6) {
            Menu(L("사진")) {
                Button(L("파일에서 고르기…"), action: pick)
                Button(L("복사한 사진 붙여넣기"), action: paste)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(!bus.canPhoto(friendID))
            Text(verbatim: note ?? hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var hint: String {
        if !bus.online.contains(friendID) { return L("친구가 온라인일 때 사진을 보낼 수 있어요.") }
        if !bus.canPhoto(friendID) { return L("친구 앱을 업데이트하면 사진을 주고받을 수 있어요.") }
        return L("끌어다 놓거나 붙여넣어도 돼요. 위치 정보는 지우고 보내요.")
    }

    func send(_ r: Result<Data, PhotoFailure>) {
        let note = $note
        switch r {
        case .failure(let f): note.wrappedValue = PhotoInput.why(f)
        case .success(let d):
            note.wrappedValue = L("사진을 보내는 중…")
            bus.sendPhoto(d, to: friendID) { note.wrappedValue = $0 }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send(PhotoInput.load(url))
    }

    private func paste() { send(PhotoInput.pasteboard()) }
}

#if !MAS
/// --render-photo: the chat window with photos both ways, an old friend's, the pop-up bubble and the big view.
enum PhotoQA {
    static func render(to dir: URL) throws {
        let bus = SocialBus.shared
        let id = "qa-photo", old = "qa-photo-old"
        bus.setFriends([SocialFriend(id: id, nickname: "보리", look: .fallback, status: .working, pairedAt: Date()),
                        SocialFriend(id: old, nickname: "콩이", look: .fallback, status: .meal, pairedAt: Date())])
        bus.setOnline([id, old])
        bus.versions = [id: PhotoRules.version, old: 2]
        guard case .success(let a) = PhotoPrep.prepare(sample(1600, 1100, warm: true)),
              case .success(let b) = PhotoPrep.prepare(sample(900, 1300, warm: false)) else { throw PhotoFailure.wontFit }
        let chat = SocialChat.shared
        chat.append(id, "어제 간 카페", mine: false)
        chat.append(id, L("사진"), mine: false, photo: b)
        chat.append(id, "오 좋다", mine: true)
        chat.append(id, L("사진"), mine: true, photo: a)
        for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try DashboardSnapshot.snapshot(FriendChatView(friendID: id).frame(width: 320, height: 520), appearance: look,
                                           to: dir.appendingPathComponent("photo-chat-\(name).png"))
            try DashboardSnapshot.snapshot(FriendChatView(friendID: old).frame(width: 320, height: 300), appearance: look,
                                           to: dir.appendingPathComponent("photo-chat-old-friend-\(name).png"))
            try DashboardSnapshot.snapshot(SpeechBubbleView(text: "보리: " + L("사진을 보냈어요"), tailUp: false, tailDown: true, photo: NSImage(data: b.thumb)),
                                           appearance: look, to: dir.appendingPathComponent("photo-bubble-\(name).png"))
        }
        if let big = NSImage(data: a.full) {
            try DashboardSnapshot.snapshot(PhotoZoomView(image: big).frame(width: 400, height: 275), appearance: .darkAqua,
                                           to: dir.appendingPathComponent("photo-zoom.png"))
        }
        let sizes = "full \(a.full.count) B, thumb \(a.thumb.count) B, parts \(PhotoPart.split(a, id: 1).count)\n"
        try sizes.write(to: dir.appendingPathComponent("photo-sizes.txt"), atomically: true, encoding: .utf8)
        chat.clear(id)
    }

    /// A made-up picture: a sky, a sun and hills, PNG.
    static func sample(_ w: Int, _ h: Int, warm: Bool) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: w, height: h)
        NSGradient(starting: warm ? NSColor(red: 1, green: 0.7, blue: 0.45, alpha: 1) : NSColor(red: 0.5, green: 0.75, blue: 1, alpha: 1),
                   ending: warm ? NSColor(red: 0.55, green: 0.3, blue: 0.6, alpha: 1) : NSColor(red: 0.9, green: 0.95, blue: 1, alpha: 1))?.draw(in: r, angle: 90)
        NSColor(red: 1, green: 0.9, blue: 0.4, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: w * 6 / 10, y: h * 6 / 10, width: w / 6, height: w / 6)).fill()
        NSColor(red: 0.3, green: 0.6, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: -w / 4, y: -h / 3, width: w, height: h * 2 / 3)).fill()
        NSColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: w / 3, y: -h / 2, width: w, height: h * 3 / 4)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
#endif
