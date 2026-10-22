// QR code as SVG, made on this Mac by CoreImage (no service): swift tools/web-app/qr.swift <text> <out.svg>
// Reads the result back with CIDetector and fails if it does not decode to <text>.
import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: qr.swift <text> <out.svg>\n", stderr); exit(2) }
let text = args[1]
let f = CIFilter(name: "CIQRCodeGenerator")!
f.setValue(Data(text.utf8), forKey: "inputMessage")
f.setValue("M", forKey: "inputCorrectionLevel")
let image = f.outputImage!   // 1 px per module, with a 1-module margin
let ctx = CIContext()
let w = Int(image.extent.width), h = Int(image.extent.height)
var px = [UInt8](repeating: 0, count: w * h * 4)
ctx.render(image, toBitmap: &px, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

// One path, a run of dark modules per segment; 4-module quiet zone around (the image's 1 + 3).
let q = 3
var d = ""
for y in 0..<h {
    var x = 0
    while x < w {
        guard px[(y * w + x) * 4] < 128 else { x += 1; continue }
        var run = 0
        while x + run < w, px[(y * w + x + run) * 4] < 128 { run += 1 }
        d += "M\(x + q) \(y + q)h\(run)v1h-\(run)z"
        x += run
    }
}
let size = w + 2 * q
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(size) \(size)" shape-rendering="crispEdges" role="img" aria-label="\(text)"><rect width="\(size)" height="\(size)" fill="#fff"/><path fill="#000" d="\(d)"/></svg>

"""
try! svg.write(toFile: args[2], atomically: true, encoding: .utf8)

let big = image.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
let found = CIDetector(ofType: CIDetectorTypeQRCode, context: ctx, options: nil)!.features(in: big)
let decoded = (found.first as? CIQRCodeFeature)?.messageString
guard decoded == text else { fputs("QR check failed: \(decoded ?? "nothing")\n", stderr); exit(1) }
print("QR \(w - 2)x\(h - 2) modules, decodes to \(text)")
