#if !MAS   // Mac App Store build: no AI drawing at all (2.3.1, 5.1.2), see the #else below
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What the AI drawing clients share (ChatGPTCharacterClient, ClaudeCharacterClient): their error and the photo they send.
enum AICharacterClient {
    struct Failure: Error, Equatable, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static let photoPixels = 512

    /// At most `photoPixels` on the long side, flattened on white (a see-through PNG would turn black), JPEG.
    static func jpeg(_ image: CGImage, maxPixel: Int = photoPixels) -> Data? {
        let small = CustomSprite.downscale(image, maxPixel: maxPixel)
        guard let ctx = CGContext(data: nil, width: small.width, height: small.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: small.width, height: small.height))
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        guard let flat = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// Who can draw 자동 다듬기 on this Mac: its own ChatGPT (Codex) sign-in, else nobody. Checked in the background at
/// launch and when the creator opens; the creator and 설정 only mention the AI while there is a route, so nobody is
/// promised a drawing nothing can make.
final class AutoRefine: ObservableObject {
    enum Route { case chatgpt }
    static let shared = AutoRefine()

    @Published private(set) var route: Route?
    private var checking = false

    /// Blocking parts run off the main thread; `route` updates on it.
    func check() {
        guard !checking else { return }
        checking = true
        Task.detached(priority: .utility) {
            let found = await Self.resolve()
            await MainActor.run { self.route = found; self.checking = false }
        }
    }

    /// Up to a few seconds (`codex login status`); never on the main thread.
    static func resolve(chatGPT: ChatGPTCharacterClient = ChatGPTCharacterClient()) async -> Route? {
        chatGPT.codexPath() != nil && chatGPT.status().isReady ? .chatgpt : nil
    }

    /// Where the photo goes, for the privacy lines.
    var destination: String? { route == nil ? nil : L("이 맥에 로그인된 ChatGPT(OpenAI)") }
}
#else
import Foundation

/// Mac App Store build: no photo leaves the Mac and nothing draws with AI. `route` stays nil, which already hides
/// every AI line in the creator and 설정. Only the error type FrameArt shares is kept.
enum AICharacterClient {
    struct Failure: Error, Equatable, CustomStringConvertible {
        var message: String
        var description: String { message }
    }
}

final class AutoRefine: ObservableObject {
    enum Route { case chatgpt }
    static let shared = AutoRefine()
    @Published private(set) var route: Route?
    func check() {}
    var destination: String? { nil }
}
#endif
