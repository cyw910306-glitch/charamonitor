import AppKit
import SwiftUI

// Small reusable dashboard pieces and formatters.

/// Number formats of the reference dashboard: one decimal everywhere, decimal units for disk and network.
enum Fmt {
    static func percent1(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

    /// "14,900원" (English: "₩14,900"), for the shopping prices the agent shows.
    static func won(_ amount: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ko_KR")
        return L("\(f.string(from: NSNumber(value: amount)) ?? String(amount))원")
    }

    /// Memory in binary units like Activity Monitor: "1.8 GB", "512 MB".
    static func mem(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    /// Disk in decimal units like Finder: "289.7 GB", "1.81 TB".
    static func disk(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1e9
        return gb >= 1000 ? String(format: "%.2f TB", gb / 1000) : String(format: "%.1f GB", gb)
    }

    /// File sizes in decimal units like Finder: "340 MB", "1.2 GB".
    static func size(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1e6
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }

    /// "25.8 kB/s", "3.4 MB/s".
    static func rate(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        if v >= 1e9 { return String(format: "%.1f GB/s", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB/s", v / 1e6) }
        return String(format: "%.1f kB/s", v / 1e3)
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? L("\(minutes / 60)시간 \(minutes % 60)분") : L("\(minutes)분")
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let d = m / 1440, h = (m % 1440) / 60, min = m % 60
        if d > 0 { return h > 0 ? L("\(d)일 \(h)시간") : L("\(d)일") }   // "11일", not "11일 0시간"
        if h > 0 { return L("\(h)시간 \(min)분") }
        return L("\(min)분")
    }
}

/// One row of the stats panel: big monochrome symbol on the left, bold title and indented details on the right.
struct StatSection<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) { content }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)   // VoiceOver reads a section as one stop
    }
}

/// Rounded square button of the right column: big symbol above a short label.
struct TileButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular))
                Text(title).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle())
        .accessibilityLabel(title)
    }
}

private struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// QA renders of pages taller than the popover set this to draw the whole scroll content at once.
enum QARender { static var fullHeight = false }

/// Sub page frame: back button and title, then the page content.
struct PageScaffold<Content: View>: View {
    let title: String
    let onBack: () -> Void
    /// Stays below the scrolling content, always in view.
    var footer: AnyView? = nil
    /// Child id scrolled to the top once on appear (비서 설정 back on 연동 after a permission prompt).
    var scrollTo: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(action: onBack) { Label("뒤로", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            ScrollViewReader { proxy in
                CappedScroll(maxHeight: QARender.fullHeight ? 5000 : footer == nil ? 560 : 480) {
                    content.padding(.horizontal, 12)
                }
                .onAppear {
                    guard let scrollTo else { return }
                    // After CappedScroll has measured its height, or there is nothing to scroll yet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(scrollTo, anchor: .top) }
                }
            }
            if let footer { footer }
        }
        .padding(.vertical, 12)
    }
}

/// Plain rounded group used on the sub pages. With a `tint` it is a pastel sticker card (데스크톱 친구).
struct Panel<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tint == nil ? 12 : 16, style: .continuous)
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(tint == nil ? 10 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tint.map { $0.opacity(scheme == .dark ? 0.16 : 0.10) } ?? Color.primary.opacity(0.06)))
            .overlay(tint.map { shape.strokeBorder($0.opacity(0.35), lineWidth: 1.5) })
    }
}

/// Horizontal fill bar with a thin outline, like the storage bar of the reference.
struct FillBar: View {
    var fraction: Double
    var color: Color = .blue
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            color.frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(0.45), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("사용량")
        .accessibilityValue(Fmt.percent1(min(1, max(0, fraction))))
    }
}

/// Filled area of a series on a thin baseline, scaled to `maxValue` (or its own max).
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double? = nil
    var color: Color = .blue

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 0), 0.000_001)
            let line = Self.path(values, top: top, size: geo.size)
            ZStack(alignment: .bottom) {
                Rectangle().fill(color.opacity(0.35)).frame(height: 0.5)
                Self.area(line, size: geo.size).fill(color.opacity(0.85))
                line.stroke(color, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("최근 1분 기록")
    }

    private static func path(_ v: [Double], top: Double, size: CGSize) -> Path {
        var p = Path()
        guard v.count > 1 else { return p }
        let step = size.width / CGFloat(v.count - 1)
        for (i, x) in v.enumerated() {
            let pt = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(1, max(0, x / top)))))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private static func area(_ line: Path, size: CGSize) -> Path {
        guard !line.isEmpty else { return line }
        var p = line
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }
}

/// Measures content and caps it at `maxHeight`, scrolling only when it overflows.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content.background(GeometryReader { g in
                Color.clear.preference(key: HeightKey.self, value: g.size.height)
            })
        }
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Owner photo, decoded and downscaled once per path.
enum PhotoLoader {
    private static var cache: [String: NSImage] = [:]

    static func image(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let hit = cache[path] { return hit }
        guard let src = NSImage(contentsOfFile: path), src.size.width > 0, src.size.height > 0 else { return nil }
        let px = 168   // 56 pt at 3x
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Center square crop.
        let side = min(src.size.width, src.size.height)
        let crop = NSRect(x: (src.size.width - side) / 2, y: (src.size.height - side) / 2, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: 56, height: 56))
        img.addRepresentation(rep)
        cache[path] = img
        return img
    }
}

extension Color {
    init(_ rgb: RGBColor) { self.init(nsColor: rgb.nsColor) }
}

extension RGBColor {
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent))
    }
}

extension Color {
    /// Warning text and icons. Plain .orange is too light to read on the light popover (about 2:1 on white),
    /// so light mode uses a deep amber and dark mode a soft orange (both above 4.5:1).
    static let warn = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.29, blue: 0.0, alpha: 1)
    })
}
