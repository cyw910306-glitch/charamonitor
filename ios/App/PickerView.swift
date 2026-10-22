import CharaCore
import SwiftUI
import UniformTypeIdentifiers

/// Who lives in the app: the built-in dogs, cats and originals, then the packs from the owner's own setup file.
struct PickerView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var picked = 0
    @AppStorage(SharedState.hapticsKey, store: Shared.defaults) private var haptics = true

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
    static let setupType = UTType("com.jelly.charamonitor.setup") ?? .data

    var body: some View {
        let builtIn = CharaArt.builtIn
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.imported.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("가져온 친구들").font(.headline).foregroundStyle(Palette.ink)
                            importCard
                        }
                    } else {
                        section("가져온 친구들", model.imported)
                    }
                    section("강아지", builtIn.filter { $0.kind == .dog })
                    section("고양이", builtIn.filter { $0.kind == .cat })
                    section("오리지널", builtIn.filter { $0.kind == .original })
                }
                .padding(16)
            }
            .background(Palette.bg.ignoresSafeArea())
            .navigationTitle("친구들")
            .toolbar {
                Button { importing = true } label: { Label("설정 파일 가져오기", systemImage: "square.and.arrow.down") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [Self.setupType]) { result in
                if case .success(let url) = result { model.importSetup(url) }
            }
            .sensoryFeedback(trigger: picked) { _, _ in haptics ? .selection : nil }
        }
    }

    private func section(_ title: LocalizedStringKey, _ list: [CharaArt]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(list) { art in cell(art) }
            }
        }
    }

    private func cell(_ art: CharaArt) -> some View {
        let on = art.id == model.chosen.id
        return Button {
            model.choose(art)
            picked += 1
        } label: {
            VStack(spacing: 6) {
                FrameImage(art: art).frame(height: 48).padding(.top, 10)
                Text(verbatim: art.displayName)
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 6).padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
            .background(on ? Palette.soft : Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Palette.accent : Palette.line, lineWidth: on ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).padding(6) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("맥의 캐릭모니터에서 내보낸 설정 파일(.charamonitor)을 열면 내 캐릭터 팩이 여기에 들어와요.")
                .font(.subheadline).foregroundStyle(Palette.muted)
            Button { importing = true } label: { Label("설정 파일 가져오기", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
        }
        .card()
    }
}
