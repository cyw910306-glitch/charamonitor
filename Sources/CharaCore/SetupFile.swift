import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 내 설정 파일 (.charamonitor): this Mac's setup, to set up the owner's other Macs the same. One binary property list:
/// { format, app, created, settings (only `keys`: never Keychain items, consents, permission switches or this Mac's own
/// state), files (relative path: bytes, under Packs, Characters and Pictures, the 매단 사진 the friends hold) }. No
/// archive tool reads it: the app parses it, checks every name and size, and writes plain files into a fresh temp folder
/// (no links, modes, xattrs or ACLs come from the file). Importing keeps the current setup as Backups/<date>.charamonitor,
/// then replaces; the app restarts to load it (packs load at launch).
/// The file format and its checks; the Mac's export, install and backups extend it in DogMonitor/App/SetupFile.swift.
public enum SetupFile {
    public static let ext = "charamonitor"
    public static let formatVersion = 2
    /// The file, and all the files it holds together.
    public static let maxBytes: Int64 = 300 * 1024 * 1024
    public static let maxEntries = 5000
    public static let maxFileBytes = 50 * 1024 * 1024
    public static let maxDepth = 8
    public static let maxPictureBytes = 20 * 1024 * 1024
    public static let maxPicturesBytes = 100 * 1024 * 1024
    /// One setting's value (a string, data or the 비서's lines): settings are read at every launch.
    public static let maxSettingBytes = 1024 * 1024
    public static let folders: Set<String> = ["Packs", "Characters", "Pictures"]
    /// Settings whose slots can hold a picture's path (a path on this Mac: the file carries the picture instead).
    public static let pictureKeys = ["hangingFriends", "meadowFriends"]
    /// 알림 시점 a file may carry (AssistantSettings.leadPresets on the Mac) and how many 날씨 창문 sizes there are
    /// (WeatherFrame.scales, checked by SetupFileTests).
    public static let calendarLeadPresets: [[Int]] = [[5], [10], [15, 5], [30, 10]]
    public static let weatherScaleCount = 7

    public enum Kind { case bool, string, number, data, ints, stringMap }

    /// Every setting the file carries, with the type it must have. Anything else in a file is ignored. A received file
    /// must not be able to flip a security or consent switch, so these are left out on purpose:
    /// - AI keys and tokens (Keychain), 내 Claude login and 자동 다듬기 (consents to send things).
    /// - claudeRefine (한 번 더 다듬기): a second turn that sends the render to Claude again.
    /// - assistant.urlSay (링크로 말 걸기): lets any web page talk through the character.
    /// - autoUpdate: a file must not be able to switch updates off.
    /// - cleanerProtected: the apps the owner locked against quitting; a file could unlock them for 정리.
    /// - weatherWindow: turning it on starts calls to the forecast service (the city and look still travel, they only
    ///   matter once the owner turns it on here).
    /// - the 비서's calendar, reminders, mail, phone, inbox, BYO and agent settings (permissions, accounts, topics and
    ///   tokens), the photo path, update and advice dates, speed test, tour and migration flags.
    public static let keys: [String: Kind] = [
        // AppSettings
        "profile": .data, "character": .string, "customCharacterID": .string, "catID": .string, "originalID": .string,
        "showCPUPercent": .bool, "characterColors": .data, "catLooks": .data,
        "hiddenCharacters": .data, "renderStyle": .string, "palette": .string, "motionLevel": .string,
        "friendSounds": .bool, "settingsTextLarge": .bool, "expandDetails": .bool,
        // 상황별 모션, 커서 친구, 퀵물어보기
        "motionPrefs": .data, "cursorBuddy": .bool, "cursorBuddySize": .string, "cursorBuddyBoost": .string,
        "cursorBuddyPlay": .bool, "cursorBuddyCry": .bool, "cursorBuddyCryVolume": .number, "quickAskTheme": .string, "quickAskTextSize": .string, "quickAskMotion": .string,
        "quickAskSound": .bool, "quickAskShowAvatar": .bool,
        // 데스크톱 친구들
        "hangingFriends": .data, "meadowFriends": .data, "desktopRug": .data, "desktopClones": .data, "folderFriends": .data,
        "desktopToys": .data,
        "play.twoPlayer": .bool, "macDownloads": .bool, "macTrash": .bool, "macBusy": .bool, "friends.dance": .bool,
        // 날씨 창문 (weatherX/Y are screen points: clamped on import)
        "weatherSize": .number, "weatherOnTop": .bool, "weatherTheme": .string,
        "weatherShowTemp": .bool, "weatherChatter": .bool, "weatherSeasonal": .bool, "weatherCity": .string,
        "weatherLat": .number, "weatherLon": .number, "weatherTimeZone": .string, "weatherX": .number, "weatherY": .number,
        // 집중 타이머
        "focus.menuBar": .bool, "focus.menuEmoji": .bool, "focus.theme": .string, "focus.size": .string,
        "focus.goal": .number, "focus.sound": .bool,
        // 비서: how it talks only
        "assistant.persona": .string, "assistant.voice": .bool, "assistant.nudges": .string, "assistant.aiNudges": .bool,
        "assistant.lines": .stringMap, "assistant.workHours": .data,
        "assistant.calendarLeads": .ints,
        // the rest (후원 선물 that are open; 후원 친구's counters and on/off stay on each Mac)
        "petState": .data, "sponsor.gifts": .data,
    ]

    public struct Dirs {
        /// Application Support/DogMonitor (in the App Store build, inside the container).
        public var root: URL
        public init(root: URL) { self.root = root }
        public var packs: URL { root.appendingPathComponent("Packs", isDirectory: true) }
        public var characters: URL { root.appendingPathComponent("Characters", isDirectory: true) }
        public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
        public var pictures: URL { root.appendingPathComponent("Pictures", isDirectory: true) }
    }

    public struct Problem: LocalizedError {
        public let errorDescription: String?
        public init(_ text: String) { errorDescription = text }
    }

    /// A checked file, written out in a fresh temporary folder (`temp`/Packs, ...) until `install` or `discard`.
    public struct Staged {
        public let temp: URL
        public let settings: [String: Any]
        public let packs: Int
        public let characters: Int
        public func discard() { try? FileManager.default.removeItem(at: temp) }
    }

    public static var contentType: UTType { UTType(filenameExtension: ext, conformingTo: .data) ?? .data }

    public static var bad: Problem { Problem(L("캐릭모니터 설정 파일이 아니거나 망가진 파일이에요.")) }
    public static var notAllowed: Problem { Problem(L("파일 안에 들어 있으면 안 되는 항목이 있어서 가져오지 않았어요.")) }
    public static var tooBig: Problem { Problem(L("너무 커요. 설정 파일에는 300MB까지만 담을 수 있어요.")) }

    /// What `collect` found: the files and their names, the bytes they claim, `over` once past `limit` or `maxEntries`
    /// (reading stops there), and `skipped`, the entries left out.
    public struct Gather {
        public var limit = maxBytes
        public var files: [String: Data] = [:], names = Names(), bytes: Int64 = 0, over = false, skipped = 0
        public init(limit: Int64 = maxBytes) { self.limit = limit }
    }

    /// Regular files under `url`, by lstat: links and anything else are skipped, never followed; a folder that cannot be
    /// read is skipped too, so nothing planted in the app's folders can stop an export or a backup.
    public static func collect(_ url: URL, _ parts: [String], into g: inout Gather) {
        var st = stat()
        guard !g.over, lstat(url.path, &st) == 0 else { return }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            guard parts.count < maxDepth, let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                g.skipped += 1
                return
            }
            for name in names { collect(url.appendingPathComponent(name), parts + [name.precomposedStringWithCanonicalMapping], into: &g) }
        case S_IFREG:
            let rel = parts.joined(separator: "/")
            guard st.st_size <= maxFileBytes, components(rel) != nil, g.names.take(parts) else { g.skipped += 1; return }
            g.bytes += Int64(st.st_size)
            guard g.bytes <= g.limit, g.files.count < maxEntries else { g.over = true; return }
            guard let data = readFile(url) else { g.skipped += 1; return }
            g.files[rel] = data
        default:
            g.skipped += 1
        }
    }

    /// A plain file's bytes, `limit` at most; nil when it is (or became) a link, anything but a regular file, or a hard
    /// link (its other name may be a file anywhere, outside the app's folders).
    public static func readFile(_ url: URL, limit: Int = maxFileBytes) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size <= limit else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    /// The file extension of an image ImageIO can read, else nil.
    public static func imageExtension(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let id = CGImageSourceGetType(src), let type = UTType(id as String), type.conforms(to: .image) else { return nil }
        return type.preferredFilenameExtension
    }

    // MARK: Import

    /// Reads and checks `file` and writes what it holds into a fresh temporary folder; nothing else changes.
    public static func inspect(_ file: URL, limit: Int64 = maxBytes) throws -> Staged {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw bad }
        guard size <= limit else { throw tooBig }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw bad }
        guard data.count <= limit else { throw tooBig }
        // Binary only: the XML and old-style text parsers never see a received file.
        guard data.starts(with: Array("bplist00".utf8)),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { throw bad }
        return try stage(root, limit: limit)
    }

    /// `root` (a parsed file) checked strictly, its files written under a fresh temporary folder.
    public static func stage(_ root: Any, limit: Int64 = maxBytes) throws -> Staged {
        guard let root = root as? [String: Any], let format = root["format"] as? NSNumber, valid(format, .number),
              let version = Int(exactly: format.doubleValue) else { throw bad }
        guard version <= formatVersion else {
            throw Problem(L("더 새 캐릭모니터에서 만든 파일이에요. 앱을 업데이트한 뒤 다시 가져와 주세요."))
        }
        guard version == formatVersion, Set(root.keys) == ["format", "app", "created", "settings", "files"],
              root["app"] is String, root["created"] is Date, let settings = root["settings"] as? [String: Any],
              let files = root["files"] as? [String: Data] else { throw bad }
        guard files.count <= maxEntries else { throw notAllowed }
        var names = Names(), total: Int64 = 0, pictures = 0, checked: [([String], Data)] = []
        for (path, bytes) in files {
            guard let parts = components(path), names.take(parts) else { throw notAllowed }
            total += Int64(bytes.count)
            guard bytes.count <= maxFileBytes, total <= limit else { throw tooBig }
            if parts[0] == "Pictures" {   // as export makes them: images, side by side, within the picture sizes
                pictures += bytes.count
                guard parts.count == 2, bytes.count <= maxPictureBytes, pictures <= maxPicturesBytes,
                      imageExtension(bytes) != nil else { throw notAllowed }
            }
            checked.append((parts, bytes))
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            var made: Set<String> = []   // folded relative paths of the folders made here
            for (parts, bytes) in checked {
                var dir = temp
                for i in 0..<(parts.count - 1) {
                    dir.appendPathComponent(parts[i], isDirectory: true)
                    let key = Names.fold(parts[...i])
                    var st = stat()
                    if lstat(dir.path, &st) != 0 {
                        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
                        made.insert(key)
                    } else {
                        guard made.contains(key), st.st_mode & S_IFMT == S_IFDIR else { throw notAllowed }
                    }
                }
                let url = dir.appendingPathComponent(parts[parts.count - 1])
                try bytes.write(to: url, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
            return Staged(temp: temp, settings: filter(settings),
                          packs: count(files.keys, in: "Packs"), characters: count(files.keys, in: "Characters"))
        } catch {
            try? fm.removeItem(at: temp)
            throw error is Problem ? error : Problem(L("파일을 처리하지 못했어요."))
        }
    }

    /// A file's relative path, split: one of `folders` on top, then plain names (no ".", "..", "._" AppleDouble, backslash
    /// or control characters, NFC, 255 bytes each), `maxDepth` deep at most. nil when any of it fails.
    public static func components(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= maxDepth, folders.contains(parts[0]) else { return nil }
        for p in parts {
            guard !p.isEmpty, p != ".", p != "..", !p.hasPrefix("._"), p.utf8.count <= 255,
                  p.utf8.elementsEqual(p.precomposedStringWithCanonicalMapping.utf8),   // String == ignores NFC vs NFD
                  !p.unicodeScalars.contains(where: { $0 == "\\" || $0.properties.generalCategory == .control }) else { return nil }
        }
        return parts
    }

    /// Names already taken as files and as folders, folded (APFS may not tell "A" from "a"): no two files the same, and no
    /// file where a folder goes.
    public struct Names {
        private var files = Set<String>(), dirs = Set<String>()

        public init() {}

        public static func fold(_ parts: ArraySlice<String>) -> String {
            parts.joined(separator: "/").folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        }

        public mutating func take(_ parts: [String]) -> Bool {
            let path = Self.fold(parts[...])
            let above = (1..<parts.count).map { Self.fold(parts[..<$0]) }
            guard !files.contains(path), !dirs.contains(path), !above.contains(where: files.contains) else { return false }
            files.insert(path)
            dirs.formUnion(above)
            return true
        }
    }

    /// swapIn stopped halfway; `restored`: the old folders are back in place. Each app words it for its own setup.
    public struct SwapFailed: Error { public let restored: Bool }

    /// Puts the staged Packs, Characters and Pictures in place of `dirs`' own. The old folders step aside first (into the
    /// returned folder, for the caller to keep or remove), so a failure halfway puts them back and nothing is mixed.
    public static func swapIn(_ staged: Staged, dirs: Dirs) throws -> URL {
        let fm = FileManager.default
        let aside = dirs.root.appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        var moved: [(dest: URL, old: URL)] = [], placed: [URL] = []
        do {
            for (name, dest) in [("Packs", dirs.packs), ("Characters", dirs.characters), ("Pictures", dirs.pictures)] {
                if fm.fileExists(atPath: dest.path) {
                    let old = aside.appendingPathComponent(name, isDirectory: true)
                    try fm.moveItem(at: dest, to: old)
                    moved.append((dest, old))
                }
                let src = staged.temp.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: src.path) { try fm.moveItem(at: src, to: dest); placed.append(dest) }
            }
        } catch {
            for dest in placed { try? fm.removeItem(at: dest) }
            var back = true
            for m in moved { do { try fm.moveItem(at: m.old, to: m.dest) } catch { back = false } }
            if back { try? fm.removeItem(at: aside) }
            throw SwapFailed(restored: back)
        }
        return aside
    }

    /// The iPhone's import: checks `file` and puts its packs, characters and pictures in place of `root`'s
    /// (root/Packs, root/Characters, root/Pictures). No backup, no settings written; the file's checked settings come back.
    /// A stop halfway throws SwapFailed, for the app to word.
    @discardableResult
    public static func importFiles(_ file: URL, into root: URL) throws -> (packs: Int, characters: Int, settings: [String: Any]) {
        let staged = try inspect(file)
        defer { staged.discard() }
        return try importStaged(staged, into: root)
    }

    /// A file already checked (`inspect`, so the owner could be asked first) put in place. What was there before is kept
    /// in root/Backups/before-import (the last import's only), not deleted.
    public static func importStaged(_ staged: Staged, into root: URL) throws -> (packs: Int, characters: Int, settings: [String: Any]) {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let aside = try swapIn(staged, dirs: Dirs(root: root))
        let backup = root.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent("before-import", isDirectory: true)
        try? fm.removeItem(at: backup)
        try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.moveItem(at: aside, to: backup)) == nil { try? fm.removeItem(at: aside) }
        return (staged.packs, staged.characters, staged.settings)
    }

    /// The known keys with the right type; everything else in a file is dropped.
    public static func filter(_ plist: [String: Any]) -> [String: Any] {
        plist.filter { key, v in (keys[key].map { valid(v, $0) } ?? false) && sane(key, v) }
    }

    /// Values stay small (`maxSettingBytes`) and numbers the app does math with stay in range (an Int64.max 목표 시간
    /// traps at `goal * 60`, a slot at x 1e308 hangs at inf); others are dropped.
    public static func sane(_ key: String, _ v: Any) -> Bool {
        switch v {
        case let d as Data:
            return d.count <= maxSettingBytes && ((try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)).map(tame) ?? true)
        case let s as String: return s.utf8.count <= maxSettingBytes
        case let m as [String: String]: return m.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } <= maxSettingBytes
        case let a as [NSNumber]:   // 알림 시점: one of the picker's
            return key != "assistant.calendarLeads" || calendarLeadPresets.contains { $0.map(Double.init) == a.map(\.doubleValue) }
        case let n as NSNumber:
            let n = n.doubleValue
            switch key {
            case "focus.goal": return [0, 15, 25, 50].contains(n)   // the 목표 시간 picker
            case "weatherSize": return (0..<weatherScaleCount).contains(Int(exactly: n) ?? -1)
            case "weatherLat": return abs(n) <= 90
            case "weatherLon": return abs(n) <= 180
            default: return n.isFinite
            }
        default: return true
        }
    }

    /// Every number in a JSON value finite and within 1e12 (a saved date is about 1e9), so no two multiply out to inf.
    public static func tame(_ v: Any) -> Bool {
        switch v {
        case let n as NSNumber: return n.doubleValue.isFinite && abs(n.doubleValue) <= 1e12
        case let a as [Any]: return a.allSatisfy(tame)
        case let d as [String: Any]: return d.values.allSatisfy(tame)
        default: return true
        }
    }

    /// `data` (HangPrefs or MeadowPrefs JSON) with each slot's picture path passed through `f`; nil drops the picture.
    /// nil when it is not that JSON, so a path never passes unread.
    public static func mapPictures(_ data: Data, _ f: (String) -> String?) -> Data? {
        guard var prefs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let raw = prefs["slots"] {
            guard let slots = raw as? [[String: Any]] else { return nil }
            prefs["slots"] = slots.map { s in
                var s = s
                s["imagePath"] = (s["imagePath"] as? String).flatMap(f)
                return s
            }
        }
        return try? JSONSerialization.data(withJSONObject: prefs)
    }

    public static func valid(_ v: Any, _ kind: Kind) -> Bool {
        func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
        switch kind {
        case .bool: return (v as? NSNumber).map(isBool) ?? false
        case .number: return (v as? NSNumber).map { !isBool($0) } ?? false
        case .string: return v is String
        case .data: return v is Data
        case .ints: return (v as? [NSNumber])?.allSatisfy { !isBool($0) } ?? false
        case .stringMap: return v is [String: String]
        }
    }

    /// Subfolders of `top` (packs or characters) that hold a file; names APFS takes for one ("ß", "ss") count once.
    public static func count(_ paths: some Sequence<String>, in top: String) -> Int {
        Set(paths.compactMap { p -> String? in
            let c = p.split(separator: "/").map(String.init)
            return c.count >= 3 && c[0] == top ? Names.fold(c[1...1]) : nil
        }).count
    }
}

