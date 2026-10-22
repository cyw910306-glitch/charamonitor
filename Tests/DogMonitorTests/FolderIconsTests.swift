import XCTest
@testable import DogMonitor

/// 폴더 아이콘 입히기: the art, dressing only folders without their own icon, and 원래대로.
final class FolderIconsTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "folder-icons-tests")
        defaults.removePersistentDomain(forName: "folder-icons-tests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: "folder-icons-tests")
    }

    private func folder(_ name: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func hasIcon(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.appendingPathComponent("Icon\r").path) }

    func testArtIsSquareAndDrawsTheCharacter() throws {
        let art = try XCTUnwrap(FolderIcons.art())
        XCTAssertEqual(art.size, NSSize(width: 512, height: 512))
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(art.tiffRepresentation))?.representation(using: .png, properties: [:]))
        if let out = ProcessInfo.processInfo.environment["FOLDER_ICON_PNG"] { try png.write(to: URL(fileURLWithPath: out)) }
    }

    func testDressesThenRestoresOnlyItsOwn() throws {
        let a = try folder("a"), mine = try folder("mine")
        XCTAssertTrue(NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(for: .application), forFile: mine.path, options: []))
        let icons = FolderIcons(defaults: defaults)
        XCTAssertEqual(icons.dress([a, mine]), 1)
        XCTAssertTrue(hasIcon(a))
        XCTAssertEqual(icons.dressed, [a.path])
        XCTAssertEqual(FolderIcons(defaults: defaults).dressed, [a.path])   // remembered

        icons.undress()
        XCTAssertFalse(hasIcon(a))
        XCTAssertTrue(hasIcon(mine))   // the user's own icon stays
        XCTAssertEqual(icons.dressed, [])
    }

    func testDressingAgainKeepsItsFolders() throws {
        let a = try folder("a")
        let icons = FolderIcons(defaults: defaults)
        icons.dress([a])
        XCTAssertEqual(icons.dress([a]), 1)   // ours already: dressed again, not taken for the user's icon
        XCTAssertEqual(icons.dressed, [a.path])
    }
}

extension FolderIconsTests {
    func testEveryStyleDrawsAndOldPrefsKeepStanding() throws {
        let png = ProcessInfo.processInfo.environment["FOLDER_ICON_DIR"]
        for style in FolderIconStyle.allCases {
            let art = try XCTUnwrap(FolderIcons.art(style: style))
            XCTAssertEqual(art.size, NSSize(width: 512, height: 512))
            if let png, let rep = NSBitmapImageRep(data: try XCTUnwrap(art.tiffRepresentation)) {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(png)/\(style.rawValue).png"))
            }
        }
        let old = try JSONDecoder().decode(FolderPrefs.self, from: Data(#"{"on":true,"iconStyle":"spin"}"#.utf8))
        XCTAssertEqual(old.iconStyle, .stand)
    }
}
