import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ChatGPT 펫 under 캐릭터 선택 (GPTPet): 가져오기 (a sheet, a pet folder or a zip, picked or dropped here, or one of this
/// Mac's Codex pets) and 내보내기 (one of our own characters as a pet, saved or put straight into Codex).
struct GPTPetRow: View {
    @ObservedObject var store: CustomCharacterStore
    /// The imported pack's id: the picker opens its preview.
    let onImported: (String) -> Void
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ChatGPT 펫").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("가져오기…") { if let id = GPTPetFlow.pick() { onImported(id) } }
                    .controlSize(.small)
                Menu("내보내기") {
                    ForEach(GPTPet.exportables(store: store)) { e in
                        Menu(e.name) {
                            Button("폴더에 저장…") { GPTPetFlow.save(e) }
                            #if !MAS
                            Button("Codex 에 바로 설치") { GPTPetFlow.install(e) }
                            #endif
                        }
                    }
                }
                .controlSize(.small).fixedSize()
            }
            Text("ChatGPT 펫 시트(PNG·WebP), 펫 폴더, zip 을 여기에 끌어다 놓아도 돼요")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            #if !MAS
            let found = GPTPet.discovered()
            if !found.isEmpty {
                HStack(spacing: 4) {
                    Text("이 맥의 Codex 펫").font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(found, id: \.url) { pet in
                        Button(pet.name) { if let id = GPTPetFlow.add(pet.url) { onImported(id) } }.controlSize(.mini)
                    }
                }
            }
            #endif
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(dropping ? Color.accentColor : .clear, lineWidth: 1.5))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { if let id = GPTPetFlow.add(url) { onImported(id) } }
            }
            return true
        }
    }
}

/// Panels and alerts of GPTPetRow.
@MainActor
enum GPTPetFlow {
    static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .webP, .zip, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("ChatGPT 펫 시트(PNG·WebP), pet.json 이 든 펫 폴더, 또는 zip 을 골라 주세요")
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ panel.runModal() }) == .OK, let url = panel.url else { return nil }
        return add(url)
    }

    /// Imports `url` as a pack, shown at once (no relaunch); nil after telling what went wrong.
    static func add(_ url: URL) -> String? {
        do {
            let pack = try GPTPet.importPack(GPTPet.read(url), root: CharacterPack.defaultRoot)
            OriginalCatalog.all.removeAll { $0.id == pack.id }
            OriginalCatalog.all.append(pack)
            return pack.id
        } catch {
            show(L("ChatGPT 펫을 가져오지 못했어요"), error.localizedDescription)
            return nil
        }
    }

    static func save(_ e: GPTPet.Exportable) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("여기에 저장")
        panel.message = L("펫 폴더(pet.json 과 spritesheet.png)를 만들 곳을 골라 주세요")
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ panel.runModal() }) == .OK, let url = panel.url else { return }
        guard replaceOK(url.appendingPathComponent(e.id, isDirectory: true), L("이 폴더에 이미 같은 펫이 있어요. 바꿀까요?")) else { return }
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try GPTPet.export(e, to: url)])
        } catch {
            show(L("내보내지 못했어요"), error.localizedDescription)
        }
    }

    #if !MAS
    static func install(_ e: GPTPet.Exportable) {
        guard replaceOK(GPTPet.codexPets.appendingPathComponent(e.id, isDirectory: true), L("Codex 에 이미 같은 펫이 있어요. 바꿀까요?")) else { return }
        do {
            try GPTPet.export(e, to: GPTPet.codexPets)
            show(L("Codex 에 넣었어요"), L("ChatGPT 나 Codex 의 Settings > Pets 에서 Refresh 를 누르고 '\(e.name)' 을 고르세요."))
        } catch {
            show(L("설치하지 못했어요"), error.localizedDescription)
        }
    }
    #endif

    /// True when `dir` is not there yet, or the user says to replace it.
    private static func replaceOK(_ dir: URL, _ question: String) -> Bool {
        guard FileManager.default.fileExists(atPath: dir.path) else { return true }
        let ask = NSAlert()
        ask.messageText = question
        ask.informativeText = dir.path
        ask.addButton(withTitle: L("바꾸기"))
        ask.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        return PopoverLayer.runModal({ ask.runModal() }) == .alertFirstButtonReturn
    }

    private static func show(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        _ = PopoverLayer.runModal { a.runModal() }
    }
}
