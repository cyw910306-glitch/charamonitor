import AppKit

/// SetupFile (CharaCore: the format, its limits and checks): this Mac's export, install and backups.
extension SetupFile {
    /// Set by an import; the next launch says hello once.
    static let helloKey = "setupImportedHello"
    /// Backups kept: older ones go with each import.
    static let keptBackups = 3
    /// Set once an import replaced the setup: from then on `AppDefaults.owner` takes no writes from this copy, so nothing
    /// it still holds in memory (the pet, the clones' spots, a setting changed before the restart) lands over the file's.
    static var replaced = false

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
        let aside: URL
        do { aside = try swapIn(staged, dirs: dirs) } catch let failed as SwapFailed {
            staged.discard()
            throw Problem(failed.restored ? L("중간에 멈춰서 원래대로 돌려 놨어요. 이 맥의 설정은 그대로예요.")
                                          : L("중간에 멈췄어요. 설정 > 가져오기 전 백업 보기에서 가장 최근 백업을 열면 되돌아가요."))
        } catch {
            staged.discard()
            throw error
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

    /// A point on one of `screens` stays; else it moves inside the first (the main screen).
    static func clamp(_ p: CGPoint, into screens: [CGRect]) -> CGPoint {
        guard let main = screens.first, !screens.contains(where: { $0.contains(p) }) else { return p }
        return CGPoint(x: min(max(p.x, main.minX), max(main.minX, main.maxX - 160)),
                       y: min(max(p.y, main.minY), max(main.minY, main.maxY - 160)))
    }
}

extension SetupFile.Dirs {
    static var app: SetupFile.Dirs { SetupFile.Dirs(root: CharacterPack.defaultRoot.deletingLastPathComponent()) }
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
