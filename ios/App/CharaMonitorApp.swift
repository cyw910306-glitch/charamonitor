import CharaCore
import SwiftUI

@main
struct CharaMonitorApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {   // navigation titles in the app's cocoa ink and rounded face
        func font(_ style: UIFont.TextStyle) -> UIFont {
            let d = UIFont.preferredFont(forTextStyle: style).fontDescriptor.withSymbolicTraits(.traitBold)!
            return UIFont(descriptor: d.withDesign(.rounded) ?? d, size: 0)
        }
        let ink = UIColor(Palette.ink)
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: ink, .font: font(.largeTitle)]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: ink, .font: font(.headline)]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL(perform: model.importSetup)
        }
        .onChange(of: phase) {   // the widgets may not read the battery themselves; a focus run may have ended meanwhile
            if phase == .active { SharedState.saveBattery(); FocusStore.finishIfDone(); SharedState.changed() }
        }
    }
}

enum Tab: String { case home, friends, focus, settings }

/// The characters, who is chosen, and the last import. Main thread; packs are read off it.
@Observable final class AppModel {
    /// The packs here hold only their walk (Shared.characters); `chosen` has every frame.
    var characters: [CharaArt]
    var chosen: CharaArt
    var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "qaTab") ?? "") ?? .home
    var report: ImportReport?
    var importing = false

    init() {
        let list = Shared.characters()
        characters = list
        chosen = Shared.chosen(in: list)
        Task.detached(priority: .utility) { for art in list { _ = art.poses } }   // draw ahead, so the picker scrolls smoothly
        loadFull(chosen)
    }

    /// The characters the owner brought in with a setup file (after the built-ins).
    var imported: [CharaArt] { Array(characters.dropFirst(CharaArt.builtIn.count)) }

    func choose(_ art: CharaArt) {
        chosen = art
        Shared.defaults.set(art.id, forKey: Shared.chosenKey)
        SharedState.changed()
        loadFull(art)
    }

    /// A pack's other frames, read off the main thread; it walks until they are in.
    private func loadFull(_ art: CharaArt) {
        guard CharaArt.builtIn(art.id) == nil else { return }
        Task.detached(priority: .userInitiated) {
            let full = Shared.full(art)
            await MainActor.run { if self.chosen.id == art.id { self.chosen = full } }
        }
    }

    /// A file that passed CharaCore's checks, waiting for the owner's 가져오기 (nothing is replaced before that).
    var pending: PendingImport?

    /// A .charamonitor file: CharaCore checks it into a temporary folder first, then the owner is asked (packs and photo
    /// characters it brings, what it replaces) before anything in the app group changes. Nothing in it ever runs; its
    /// settings are not applied. Off the main thread: a file can be 300 MB.
    func importSetup(_ url: URL) {
        guard !importing, pending == nil else { return }
        importing = true
        tab = .friends
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            let checked = Result { try SetupFile.inspect(url) }
            if scoped { url.stopAccessingSecurityScopedResource() }
            Self.dropInboxCopy(url)
            await MainActor.run {
                self.importing = false
                switch checked {
                case .success(let staged): self.pending = PendingImport(staged: staged)
                case .failure(let error): self.report = ImportReport(error: error.localizedDescription)
                }
            }
        }
    }

    /// 취소: the checked copy goes, the app group is untouched.
    func cancelImport() {
        pending?.staged.discard()
        pending = nil
    }

    /// 가져오기: the checked folders go in; the ones they replace are kept in Backups.
    func confirmImport() {
        guard let p = pending else { return }
        pending = nil
        importing = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try SetupFile.importStaged(p.staged, into: Shared.root) }
            p.staged.discard()
            let list = Shared.characters(), skipped = PackArt.skipped.count
            let ids = Set(list.map(\.id))
            for key in [Shared.chosenKey, SharedState.widgetCharacterKey] {   // a pack the file no longer has
                if let id = Shared.defaults.string(forKey: key), !id.isEmpty, !ids.contains(id) { Shared.defaults.removeObject(forKey: key) }
            }
            let chosen = Shared.full(Shared.chosen(in: list))
            await MainActor.run {
                self.characters = list
                self.chosen = chosen
                switch result {
                case .success(let done):
                    self.report = ImportReport(names: self.imported.map(\.displayName), photos: done.characters, skipped: skipped)
                case .failure(let failed as SetupFile.SwapFailed):
                    self.report = ImportReport(error: failed.restored ? L("중간에 멈춰서 원래대로 돌려 놨어요. 아이폰의 친구들은 그대로예요.")
                                                                      : L("중간에 멈췄어요. 설정 파일을 한 번 더 가져와 주세요."))
                case .failure(let error):
                    self.report = ImportReport(error: error.localizedDescription)
                }
                self.importing = false
                SharedState.changed()
            }
        }
    }

    /// Files and Share hand the app a copy in Documents/Inbox (it does not open documents in place); it is not
    /// needed once read, and can be 300 MB.
    private static func dropInboxCopy(_ url: URL) {
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().path + "/"
        if url.resolvingSymlinksInPath().path.hasPrefix(inbox) { try? FileManager.default.removeItem(at: url) }
    }
}

/// A checked setup file waiting for 가져오기. The staged folder is only read and moved, never shared while in use.
final class PendingImport: Identifiable, @unchecked Sendable {
    let id = UUID()
    let staged: SetupFile.Staged
    init(staged: SetupFile.Staged) { self.staged = staged }
}

/// What an import brought: the packs' names, how many photo characters were kept, how many packs were bad.
struct ImportReport: Identifiable {
    let id = UUID()
    var names: [String] = []
    var photos = 0
    var skipped = 0
    var error: String?
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            HomeView().tag(Tab.home).tabItem { Label("홈", systemImage: "house.fill") }
            PickerView().tag(Tab.friends).tabItem { Label("친구들", systemImage: "pawprint.fill") }
            FocusView().tag(Tab.focus).tabItem { Label("집중", systemImage: "timer") }
            SettingsView().tag(Tab.settings).tabItem { Label("설정", systemImage: "gearshape.fill") }
        }
        .tint(Palette.accent)
        .fontDesign(.rounded)
        .sheet(item: $model.report) { ImportSheet(report: $0) }
        .alert("설정 파일을 가져올까요?", isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.cancelImport() } }),
               presenting: model.pending) { _ in
            Button("가져오기") { model.confirmImport() }
            Button("취소", role: .cancel) { model.cancelImport() }
        } message: { p in
            Text("캐릭터 팩 \(p.staged.packs)개와 사진 캐릭터 \(p.staged.characters)개가 들어 있어요. 지금 아이폰에 있는 팩과 사진 캐릭터를 바꾸고, 원래 것은 백업해 둬요.")
        }
        .overlay {
            if model.importing {
                ProgressView { Text("설정 파일을 읽는 중이에요") }
                    .padding(24)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.15).ignoresSafeArea())
            }
        }
    }
}

struct ImportSheet: View {
    let report: ImportReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: report.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(report.error == nil ? Palette.accent : .orange)
            Text(report.error == nil ? LocalizedStringKey("설정 파일을 가져왔어요") : "가져오지 못했어요").font(.title3.bold())
            if let error = report.error {
                Text(error).multilineTextAlignment(.center).foregroundStyle(Palette.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("캐릭터 팩 \(report.names.count)개").font(.headline)
                    if !report.names.isEmpty {
                        Text(report.names.joined(separator: ", ")).foregroundStyle(Palette.muted)
                    }
                    if report.photos > 0 {
                        Text("사진으로 만든 캐릭터 \(report.photos)개는 보관해 두었어요. 아이폰에서는 아직 보여 줄 수 없어요.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if report.skipped > 0 {
                        Text("맞지 않는 팩 \(report.skipped)개는 건너뛰었어요.").font(.footnote).foregroundStyle(Palette.muted)
                    }
                }
                .card()
                Text("그림과 이름만 읽었고, 파일 안의 어떤 것도 실행하지 않았어요.")
                    .font(.footnote).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }
            Button { dismiss() } label: { Text("확인").frame(maxWidth: .infinity).foregroundStyle(Palette.onPrimary) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Palette.primary)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground(Palette.bg)
        .foregroundStyle(Palette.ink)
    }
}
