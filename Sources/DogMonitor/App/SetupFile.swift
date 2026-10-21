import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 내 설정 파일 (.charamonitor): this Mac's setup, to set up the owner's other Macs the same. One binary property list:
/// { format, app, created, settings (only `keys`: never Keychain items, consents, permission switches or this Mac's own
/// state), files (relative path: bytes, under Packs, Characters and Pictures, the 매단 사진 the friends hold) }. No
/// archive tool reads it: the app parses it, checks every name and size, and writes plain files into a fresh temp folder
/// (no links, modes, xattrs or ACLs come from the file). Importing keeps the current setup as Backups/<date>.charamonitor,
/// then replaces; the app restarts to load it (packs load at launch).
enum SetupFile {
    static let ext = "charamonitor"
    static let formatVersion = 2
    /// The file, and all the files it holds together.
    static let maxBytes: Int64 = 300 * 1024 * 1024
    static let maxEntries = 5000
    static let maxFileBytes = 50 * 1024 * 1024
    static let maxDepth = 8
    static let maxPictureBytes = 20 * 1024 * 1024
    static let maxPicturesBytes = 100 * 1024 * 1024
    /// One setting's value (a string, data or the 비서's lines): settings are read at every launch.
    static let maxSettingBytes = 1024 * 1024
    static let folders: Set<String> = ["Packs", "Characters", "Pictures"]
    /// Set by an import; the next launch says hello once.
    static let helloKey = "setupImportedHello"
    /// Backups kept: older ones go with each import.
    static let keptBackups = 3
    /// Set once an import replaced the setup: from then on `AppDefaults.owner` takes no writes from this copy, so nothing
    /// it still holds in memory (the pet, the clones' spots, a setting changed before the restart) lands over the file's.
    static var replaced = false
    /// Settings whose slots can hold a picture's path (a path on this Mac: the file carries the picture instead).
    static let pictureKeys = ["hangingFriends", "meadowFriends"]

    enum Kind { case bool, string, number, data, ints, stringMap }

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
    static let keys: [String: Kind] = [
        // AppSettings
        "profile": .data, "character": .string, "customCharacterID": .string, "catID": .string, "originalID": .string,
        "showCPUPercent": .bool, "characterColors": .data, "catLooks": .data,
        "hiddenCharacters": .data, "renderStyle": .string, "palette": .string, "motionLevel": .string,
        "friendSounds": .bool, "settingsTextLarge": .bool, "expandDetails": .bool,
        // 상황별 모션, 커서 친구, 퀵물어보기
        "motionPrefs": .data, "cursorBuddy": .bool, "cursorBuddySize": .string, "cursorBuddyBoost": .string,
        "cursorBuddyPlay": .bool, "quickAskTheme": .string, "quickAskTextSize": .string, "quickAskMotion": .string,
        "quickAskSound": .bool, "quickAskShowAvatar": .bool,
        // 데스크톱 친구들
        "hangingFriends": .data, "meadowFriends": .data, "desktopRug": .data, "desktopClones": .data,
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
        // the rest
        "petState": .data,
    ]

    struct Dirs {
        /// Application Support/DogMonitor (in the App Store build, inside the container).
        var root: URL
        var packs: URL { root.appendingPathComponent("Packs", isDirectory: true) }
        var characters: URL { root.appendingPathComponent("Characters", isDirectory: true) }
        var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
        var pictures: URL { root.appendingPathComponent("Pictures", isDirectory: true) }
        static var app: Dirs { Dirs(root: CharacterPack.defaultRoot.deletingLastPathComponent()) }
    }

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// A checked file, written out in a fresh temporary folder (`temp`/Packs, ...) until `install` or `discard`.
    struct Staged {
        let temp: URL
        let settings: [String: Any]
        let packs: Int
        let characters: Int
        func discard() { try? FileManager.default.removeItem(at: temp) }
    }

    static var contentType: UTType { UTType(filenameExtension: ext, conformingTo: .data) ?? .data }

    static var bad: Problem { Problem(L("캐릭모니터 설정 파일이 아니거나 망가진 파일이에요.")) }
    static var notAllowed: Problem { Problem(L("파일 안에 들어 있으면 안 되는 항목이 있어서 가져오지 않았어요.")) }
    static var tooBig: Problem { Problem(L("너무 커요. 설정 파일에는 300MB까지만 담을 수 있어요.")) }

    // MARK: Export

    /// The settings `keys` names that hold a value of the right type.
    static func snapshot(_ defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, kind) in keys { if let v = defaults.object(forKey: key), valid(v, kind) { out[key] = v } }
        return out
    }

    /// `skipped`: entries under Packs and Characters the file could not carry (see `collect`).
    @discardableResult
    static func export(to dest: URL, defaults: UserDefaults = AppDefaults.store, dirs: Dirs = .app,
                       now: Date = Date(), limit: Int64 = maxBytes) throws -> (packs: Int, characters: Int, settings: Int, skipped: Int) {
        var settings = snapshot(defaults)
        var g = Gather(limit: limit)
        collect(dirs.packs, ["Packs"], into: &g)
        collect(dirs.characters, ["Characters"], into: &g)
        guard !g.over else { throw tooBig }
        // Pictures go in the file as Pictures/<n>.<ext>; one that is not an image or too big is left out (the slot shows
        // the character).
        var n = 0, pictureBytes = 0
        for key in pictureKeys {
            guard let data = settings[key] as? Data else { continue }
            settings[key] = mapPictures(data) { path in
                guard let bytes = readFile(URL(fileURLWithPath: path), limit: maxPictureBytes),
                      pictureBytes + bytes.count <= maxPicturesBytes, let ext = imageExtension(bytes) else { return nil }
                n += 1
                let rel = "Pictures/\(n).\(ext)"
                guard components(rel) != nil else { return nil }
                pictureBytes += bytes.count
                g.files[rel] = bytes
                return rel
            }
        }
        let plist: [String: Any] = ["format": formatVersion, "app": AppInfo.version, "created": now,
                                    "settings": settings, "files": g.files]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        // Never a file this app would refuse to read back: the whole file counts, settings too.
        guard g.files.count <= maxEntries, Int64(data.count) <= limit else { throw tooBig }
        try data.write(to: dest, options: .atomic)
        return (count(g.files.keys, in: "Packs"), count(g.files.keys, in: "Characters"), settings.count, g.skipped)
    }

    /// What `collect` found: the files and their names, the bytes they claim, `over` once past `limit` or `maxEntries`
    /// (reading stops there), and `skipped`, the entries left out.
    struct Gather {
        var limit = maxBytes
        var files: [String: Data] = [:], names = Names(), bytes: Int64 = 0, over = false, skipped = 0
    }

    /// Regular files under `url`, by lstat: links and anything else are skipped, never followed; a folder that cannot be
    /// read is skipped too, so nothing planted in the app's folders can stop an export or a backup.
    static func collect(_ url: URL, _ parts: [String], into g: inout Gather) {
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
    static func readFile(_ url: URL, limit: Int = maxFileBytes) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size <= limit else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    /// The file extension of an image ImageIO can read, else nil.
    static func imageExtension(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let id = CGImageSourceGetType(src), let type = UTType(id as String), type.conforms(to: .image) else { return nil }
        return type.preferredFilenameExtension
    }

    // MARK: Import

    /// Reads and checks `file` and writes what it holds into a fresh temporary folder; nothing else changes.
    static func inspect(_ file: URL, limit: Int64 = maxBytes) throws -> Staged {
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
    static func stage(_ root: Any, limit: Int64 = maxBytes) throws -> Staged {
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
    static func components(_ path: String) -> [String]? {
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
    struct Names {
        private var files = Set<String>(), dirs = Set<String>()

        static func fold(_ parts: ArraySlice<String>) -> String {
            parts.joined(separator: "/").folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        }

        mutating func take(_ parts: [String]) -> Bool {
            let path = Self.fold(parts[...])
            let above = (1..<parts.count).map { Self.fold(parts[..<$0]) }
            guard !files.contains(path), !dirs.contains(path), !above.contains(where: files.contains) else { return false }
            files.insert(path)
            dirs.formUnion(above)
            return true
        }
    }

    /// Keeps the current setup in Backups, then puts the file's in its place. Returns the backup.
    @discardableResult
    static func install(_ staged: Staged, defaults: UserDefaults = AppDefaults.store, dirs: Dirs = .app,
                        screens: [CGRect] = NSScreen.screens.map(\.visibleFrame), now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dirs.backups, withIntermediateDirectories: true)
        var when = now, backup: URL
        repeat {   // two imports in one second: the second backup never overwrites the first
            backup = dirs.backups.appendingPathComponent("\(stamp.string(from: when)).\(ext)")
            when += 1
        } while fm.fileExists(atPath: backup.path)
        let skipped: Int
        do { skipped = try export(to: backup, defaults: defaults, dirs: dirs, now: now).skipped } catch {
            staged.discard()
            throw Problem(L("지금 상태를 백업하지 못해서 가져오지 않았어요.") + "\n" + error.localizedDescription)
        }
        // The old folders step aside first, so a failure halfway puts them back and nothing is mixed.
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
            staged.discard()
            throw Problem(back ? L("중간에 멈춰서 원래대로 돌려 놨어요. 이 맥의 설정은 그대로예요.")
                               : L("중간에 멈췄어요. 설정 > 가져오기 전 백업 보기에서 가장 최근 백업을 열면 되돌아가요."))
        }
        // What the backup could not carry (a link, a file over 50MB, a name the file refuses) stays next to it.
        if skipped > 0 { try? fm.moveItem(at: aside, to: leftovers(of: backup)) } else { try? fm.removeItem(at: aside) }
        for old in backups(in: dirs.backups).dropLast(keptBackups) {
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: leftovers(of: old))
        }
        var settings = staged.settings
        for key in pictureKeys {
            guard let data = settings[key] as? Data else { continue }
            settings[key] = mapPictures(data) { path in
                guard let parts = components(path), parts.count == 2, parts[0] == "Pictures" else { return nil }
                let url = dirs.pictures.appendingPathComponent(parts[1])
                var st = stat()
                return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG ? url.path : nil
            }
        }
        for key in keys.keys {
            if let v = settings[key] { defaults.set(v, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        if let x = defaults.object(forKey: "weatherX") as? Double, let y = defaults.object(forKey: "weatherY") as? Double {
            let p = clamp(CGPoint(x: x, y: y), into: screens)
            defaults.set(Double(p.x), forKey: "weatherX")
            defaults.set(Double(p.y), forKey: "weatherY")
        } else {   // half a spot is no spot
            defaults.removeObject(forKey: "weatherX")
            defaults.removeObject(forKey: "weatherY")
        }
        defaults.set(true, forKey: helloKey)
        staged.discard()
        return backup
    }

    /// Backup names: the local time with its offset, so the order holds across a time zone change.
    static var stamp: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss xx"
        return f
    }

    /// This app's backups in `dir`, oldest first; any other file there (the owner's own) is never counted or removed.
    static func backups(in dir: URL) -> [URL] {
        let f = stamp
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name -> (Date, URL)? in
            guard name.hasSuffix("." + ext), let d = f.date(from: String(name.dropLast(ext.count + 1))) else { return nil }
            return (d, dir.appendingPathComponent(name))
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The folders an import replaced, kept beside `backup` when it could not carry all of them.
    static func leftovers(of backup: URL) -> URL {
        backup.deletingLastPathComponent().appendingPathComponent(backup.deletingPathExtension().lastPathComponent + " 남은 파일", isDirectory: true)
    }

    /// The known keys with the right type; everything else in a file is dropped.
    static func filter(_ plist: [String: Any]) -> [String: Any] {
        plist.filter { key, v in (keys[key].map { valid(v, $0) } ?? false) && sane(key, v) }
    }

    /// Values stay small (`maxSettingBytes`) and numbers the app does math with stay in range (an Int64.max 목표 시간
    /// traps at `goal * 60`, a slot at x 1e308 hangs at inf); others are dropped.
    static func sane(_ key: String, _ v: Any) -> Bool {
        switch v {
        case let d as Data:
            return d.count <= maxSettingBytes && ((try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)).map(tame) ?? true)
        case let s as String: return s.utf8.count <= maxSettingBytes
        case let m as [String: String]: return m.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } <= maxSettingBytes
        case let a as [NSNumber]:   // 알림 시점: one of the picker's
            return key != "assistant.calendarLeads" || AssistantSettings.leadPresets.contains { $0.map(Double.init) == a.map(\.doubleValue) }
        case let n as NSNumber:
            let n = n.doubleValue
            switch key {
            case "focus.goal": return [0, 15, 25, 50].contains(n)   // the 목표 시간 picker
            case "weatherSize": return WeatherFrame.scales.indices.contains(Int(exactly: n) ?? -1)
            case "weatherLat": return abs(n) <= 90
            case "weatherLon": return abs(n) <= 180
            default: return n.isFinite
            }
        default: return true
        }
    }

    /// Every number in a JSON value finite and within 1e12 (a saved date is about 1e9), so no two multiply out to inf.
    static func tame(_ v: Any) -> Bool {
        switch v {
        case let n as NSNumber: return n.doubleValue.isFinite && abs(n.doubleValue) <= 1e12
        case let a as [Any]: return a.allSatisfy(tame)
        case let d as [String: Any]: return d.values.allSatisfy(tame)
        default: return true
        }
    }

    /// `data` (HangPrefs or MeadowPrefs JSON) with each slot's picture path passed through `f`; nil drops the picture.
    /// nil when it is not that JSON, so a path never passes unread.
    static func mapPictures(_ data: Data, _ f: (String) -> String?) -> Data? {
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

    static func valid(_ v: Any, _ kind: Kind) -> Bool {
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

    /// A point on one of `screens` stays; else it moves inside the first (the main screen).
    static func clamp(_ p: CGPoint, into screens: [CGRect]) -> CGPoint {
        guard let main = screens.first, !screens.contains(where: { $0.contains(p) }) else { return p }
        return CGPoint(x: min(max(p.x, main.minX), max(main.minX, main.maxX - 160)),
                       y: min(max(p.y, main.minY), max(main.minY, main.maxY - 160)))
    }

    /// Subfolders of `top` (packs or characters) that hold a file; names APFS takes for one ("ß", "ss") count once.
    static func count(_ paths: some Sequence<String>, in top: String) -> Int {
        Set(paths.compactMap { p -> String? in
            let c = p.split(separator: "/").map(String.init)
            return c.count >= 3 && c[0] == top ? Names.fold(c[1...1]) : nil
        }).count
    }
}

/// The 설정 buttons and a double-clicked file: panels, the confirm, the restart and the hello after it.
@MainActor
enum SetupFlow {
    static func exportPicked() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [SetupFile.contentType]
        panel.nameFieldStringValue = L("내 캐릭모니터") + "." + SetupFile.ext
        panel.message = L("다른 맥으로 옮길 내 설정 파일을 저장해요")
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            let m = try SetupFile.export(to: url), count = m.packs + m.characters
            SpeechBubbleCenter.shared.say(text: count > 0 ? L("내 설정을 꼭꼭 담았어요! 캐릭터 \(count)개도 같이 챙겼어요.") : L("내 설정을 꼭꼭 담았어요!"),
                                          source: .system, repeats: true)
        } catch {
            show(L("내보내지 못했어요"), error.localizedDescription)
        }
    }

    static func importPicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [SetupFile.contentType]
        panel.allowsMultipleSelection = false
        panel.message = L("가져올 내 설정 파일(.charamonitor)을 골라 주세요")
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ panel.runModal() }) == .OK, let url = panel.url else { return }
        confirmAndImport(url)
    }

    static func confirmAndImport(_ url: URL) {
        let staged: SetupFile.Staged
        do { staged = try SetupFile.inspect(url) } catch {
            show(L("가져올 수 없는 파일이에요"), error.localizedDescription)
            return
        }
        let ask = NSAlert()
        ask.messageText = L("이 맥의 캐릭모니터를 이 파일대로 바꿀까요?")
        ask.informativeText = L("캐릭터 팩 \(staged.packs)개, 내 캐릭터 \(staged.characters)개, 설정 \(staged.settings.count)가지로 바뀌어요. 지금 상태는 백업해 두고, 끝나면 앱을 다시 시작해요.")
        ask.addButton(withTitle: L("가져오기"))
        ask.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ ask.runModal() }) == .alertFirstButtonReturn else { staged.discard(); return }
        do { try SetupFile.install(staged) } catch {
            staged.discard()
            show(L("가져오지 못했어요"), error.localizedDescription)
            return
        }
        SetupFile.replaced = true
        let done = NSAlert()
        done.messageText = L("다 가져왔어요!")
        done.informativeText = L("다시 시작하면 그 맥의 캐릭모니터 그대로예요.")
        done.addButton(withTitle: L("다시 시작"))
        _ = PopoverLayer.runModal { done.runModal() }
        relaunch()
    }

    /// Packs and every store load at launch, so a new copy starts and this one quits.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error != nil { show(L("다시 시작하지 못했어요"), L("가져온 설정은 저장됐어요. 캐릭모니터를 직접 다시 열어 주세요.")) }
                NSApp.terminate(nil)
            }
        }
    }

    /// 가져오기 전 백업 보기: the newest backup in Finder. Opening one goes back to it, with the same confirm.
    static func showBackups() {
        guard let last = SetupFile.backups(in: SetupFile.Dirs.app.backups).last else {
            show(L("아직 백업이 없어요"), L("설정을 가져올 때마다 그 전 상태가 백업으로 남아요."))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([last])
    }

    /// After an import: one hello, 8 s in (the flag stays until it really showed).
    static func helloLater(_ d: UserDefaults = AppDefaults.store) {
        guard d.bool(forKey: SetupFile.helloKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if SpeechBubbleCenter.shared.say(text: L("짠! 내 설정 그대로 이사 왔어요. 여기서도 잘 부탁해요!"), source: .system) {
                d.removeObject(forKey: SetupFile.helloKey)
            }
        }
    }

    private static func show(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        _ = PopoverLayer.runModal { a.runModal() }
    }
}
