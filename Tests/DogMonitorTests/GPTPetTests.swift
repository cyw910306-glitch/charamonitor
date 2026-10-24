import XCTest
@testable import DogMonitor
import UniformTypeIdentifiers

final class GPTPetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gptpet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A sheet of `rows` rows at `scale` (1 = 192 x 208 cells) with a box drawn in `filled` (row, column) cells.
    private func sheet(rows: Int = 11, scale: Double = 0.25, filled: Set<[Int]>) -> CGImage {
        let cw = Int(192 * scale), ch = Int(208 * scale)
        let ctx = DogRenderer.context(width: cw * 8, height: ch * rows)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        for cell in filled {
            let x = cell[1] * cw, y = (rows - 1 - cell[0]) * ch   // CG is bottom-up
            ctx.fill(CGRect(x: x + cw / 4, y: y + 2, width: cw / 2, height: ch / 2 + cell[1]))
        }
        return ctx.makeImage()!
    }

    private func full(rows: Int) -> Set<[Int]> {
        Set((0..<min(rows, 9)).flatMap { r in (0..<GPTPet.rowFrames[r]).map { [r, $0] } })
    }

    func testGridForBothVersionsAndScales() {
        XCTAssertEqual(GPTPet.grid(width: 1536, height: 2288)?.rows, 11)
        XCTAssertEqual(GPTPet.grid(width: 1536, height: 1872)?.rows, 9)
        let half = GPTPet.grid(width: 768, height: 1144)
        XCTAssertEqual(half?.rows, 11)
        XCTAssertEqual(half?.cellWidth, 96)
        XCTAssertEqual(half?.cellHeight, 104)
        XCTAssertEqual(GPTPet.grid(width: 3072, height: 3744)?.rows, 9)
        XCTAssertNil(GPTPet.grid(width: 1536, height: 1536))
        XCTAssertNil(GPTPet.grid(width: 1024, height: 2288))
    }

    func testBlankCellsAreSkippedAndCroppedToOneBox() throws {
        let rows = try GPTPet.cells(sheet(filled: [[0, 0], [0, 2], [1, 0], [3, 7]]))
        XCTAssertEqual(rows.map(\.count), [2, 1, 0, 0, 0, 0, 0, 0, 0])   // [3, 7] is past waving's 4 frames
        let sizes = Set(rows.flatMap { $0 }.map { "\($0.width)x\($0.height)" })
        XCTAssertEqual(sizes.count, 1)                                      // one box for every frame
        XCTAssertEqual(rows[0][0].width, 24)                                // the box, not the 48 px cell
        XCTAssertThrowsError(try GPTPet.cells(sheet(filled: [])))
    }

    func testRowsMapToPoses() throws {
        var filled = full(rows: 9)
        filled.subtract((0..<8).map { [7, $0] })                            // no 작업 중 row: 바쁨 runs instead
        let pack = try GPTPet.importPack(GPTPet.Source(sheet: sheet(rows: 9, filled: filled), id: "Test Pet!", name: "테스트 펫"), root: root)
        XCTAssertEqual(pack.id, "pack-gpt-test-pet")
        XCTAssertEqual(pack.displayName, "테스트 펫")
        XCTAssertTrue(pack.smooth)
        XCTAssertEqual(DogPose.allCases.map { pack.frames(for: $0).count }, [6, 8, 8, 8, 8, 8, 8])
        XCTAssertEqual(pack.frames(forExtra: .hungry)?.count, 6)
        XCTAssertNil(pack.frames(forExtra: .eat))
        XCTAssertEqual(pack.extraVariants(.special).map(\.count), [4, 5, 6])   // 인사, 점프, 생각
        XCTAssertEqual(pack.specialTitle, "인사")
        XCTAssertEqual(pack.frameSeconds["lying"], 0.18)
    }

    func testOneFrameRowsAreDoubledAndMissingPosesFallBack() throws {
        let pack = try GPTPet.importPack(GPTPet.Source(sheet: sheet(filled: [[4, 0]]), id: nil, name: nil), root: root)
        XCTAssertEqual(pack.id, "pack-gpt-pet")
        XCTAssertEqual(pack.frames(for: .lying).count, 1)
        XCTAssertEqual(pack.frames(for: .walk).count, 2)
        XCTAssertEqual(pack.extraVariants(.special).map(\.count), [2])
    }

    func testZipPathsThatLeaveAreRefused() throws {
        XCTAssertTrue(ZipReader.isSafe("pet/pet.json"))
        for bad in ["../pet.json", "pet/../../x", "/etc/passwd", "a\\..\\b", "C:x", ""] { XCTAssertFalse(ZipReader.isSafe(bad), bad) }
        let png = try GPTPet.png(sheet(filled: full(rows: 11)))
        let good = root.appendingPathComponent("good.zip"), evil = root.appendingPathComponent("evil.zip")
        try Self.zip(["kit/pet.json": Data(#"{"id":"kit","displayName":"키트","spritesheetPath":"spritesheet.png","extra":1}"#.utf8),
                      "kit/spritesheet.png": png]).write(to: good)
        try Self.zip(["../spritesheet.png": png]).write(to: evil)
        let source = try GPTPet.read(good)
        XCTAssertEqual(source.id, "kit")
        XCTAssertEqual(source.name, "키트")
        XCTAssertThrowsError(try GPTPet.read(evil)) { XCTAssertTrue("\($0.localizedDescription)".contains("경로")) }
        let junk = root.appendingPathComponent("junk.png")
        try Data("not a picture".utf8).write(to: junk)
        XCTAssertThrowsError(try GPTPet.read(junk))
    }

    func testPetFolderRefusesSheetPathOutside() throws {
        let dir = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"spritesheetPath":"../secret.png"}"#.utf8).write(to: dir.appendingPathComponent("pet.json"))
        try GPTPet.png(sheet(filled: full(rows: 11))).write(to: root.appendingPathComponent("secret.png"))
        XCTAssertThrowsError(try GPTPet.read(dir))
    }

    func testOnlyPNGOrWebPIsDecoded() throws {
        func encoded(_ type: UTType) -> Data {
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, sheet(filled: [[0, 0]]), nil)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
        XCTAssertNoThrow(try GPTPet.image(encoded(.png)))
        XCTAssertThrowsError(try GPTPet.image(encoded(.tiff)), "a TIFF named .png is refused")
    }

    func testExportThenImportKeepsFramesAndSize() throws {
        let e = try XCTUnwrap(GPTPet.exportables().first { $0.id == "original-tan-cat" })
        let dir = try GPTPet.export(e, to: root)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("pet.json"))) as? [String: Any]
        XCTAssertEqual(json?["spriteVersionNumber"] as? Int, 2)
        XCTAssertEqual(json?["spritesheetPath"] as? String, "spritesheet.png")
        let source = try GPTPet.read(dir)
        XCTAssertEqual(source.sheet.width, 1536)
        XCTAssertEqual(source.sheet.height, 2288)
        let rows = try GPTPet.cells(source.sheet)
        XCTAssertEqual(rows.map(\.count), GPTPet.rowFrames, "every frame of every row is drawn")
        let pack = try GPTPet.importPack(source, root: root.appendingPathComponent("packs"))
        XCTAssertEqual(DogPose.allCases.map { pack.frames(for: $0).count }, [6, 8, 8, 8, 8, 6, 8])
        XCTAssertEqual(pack.frames(for: .walk)[0].size, NSSize(width: 34, height: 20))
        XCTAssertFalse(GPTPet.exportables().contains { $0.id.hasPrefix("pack-") })   // packs never leave
    }

    /// A zip of stored entries.
    static func zip(_ files: [String: Data]) -> Data {
        func put(_ d: inout Data, _ fields: [(Int, Int)]) {
            for (v, n) in fields { d.append(contentsOf: (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }) }
        }
        var body = Data(), central = Data()
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let n = Data(name.utf8), offset = body.count
            put(&body, [(0x0403_4B50, 4), (20, 2), (0, 2), (0, 2), (0, 4), (0, 4), (data.count, 4), (data.count, 4), (n.count, 2), (0, 2)])
            body.append(n)
            body.append(data)
            put(&central, [(0x0201_4B50, 4), (20, 2), (20, 2), (0, 2), (0, 2), (0, 4), (0, 4), (data.count, 4), (data.count, 4),
                           (n.count, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (offset, 4)])
            central.append(n)
        }
        var out = body + central
        put(&out, [(0x0605_4B50, 4), (0, 2), (0, 2), (files.count, 2), (files.count, 2), (central.count, 4), (body.count, 4), (0, 2)])
        return out
    }
}
