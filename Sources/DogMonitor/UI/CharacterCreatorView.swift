import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Editor state for a new or saved custom character. Loading and cutting out a picture runs off the main thread;
/// drawing the previews from the cut-outs (실사 or 도트) is quick and runs on it.
final class CreatorModel: ObservableObject {
    let editingID: UUID?
    private let created: Date
    @Published var name: String
    /// Its own 말투 (.auto = the custom kind's) and, for 울음소리 말투, its sounds as typed ("멍!, 왕왕").
    @Published var voice: PersonaStyle
    @Published var cries: String
    @Published var lightRim: Bool { didSet { rebuild() } }
    @Published var flipped: Bool { didSet { rebuild() } }
    @Published var chibi: Bool { didSet { rebase() } }
    /// 실사 or 도트, size and outline. New characters start 실사; ones saved before 2.0 open as the 도트 they were made as.
    @Published var look: PhotoLook { didSet { if oldValue.size != look.size || oldValue.style != look.style { rebase() } else { rebuild() } } }
    /// AI drawings are already pixel art, which 실사 would only blur.
    var shownLook: PhotoLook { var l = look; if allPixelArt { l.style = .pixel }; return l }
    @Published private(set) var inputs: [CustomSlot: CGImage] = [:]
    @Published private(set) var working: Set<CustomSlot> = []
    @Published var message: String?
    /// Every pose at 4x, and at real size for the menu bar mock-ups, in DogPose order. nil until there is a picture.
    /// 실사 draws both from the 1024 px cut-outs at their own size; `extras` are its hungry, eat and special motions.
    @Published private(set) var preview: [[NSImage]]?
    @Published private(set) var bar: [[NSImage]]?
    @Published private(set) var extras: [[NSImage]] = []
    private var bases: [CustomSlot: Bitmap] = [:]

    /// 자동 다듬기: after the pictures change, the AI draws the poses that have no picture, in the background, as
    /// photos of the same subject (this Mac's own ChatGPT sign-in; without one: nothing).
    /// The user's own picture for a pose always wins; `aiCuts` only fill the empty slots.
    enum AutoStatus: Equatable { case drawing, done, failed(String) }
    @Published private(set) var auto: AutoStatus?
    /// Frames 내 Claude drew (characters from before 자동 다듬기); adding a picture turns it into a picture character.
    @Published private(set) var art: FrameArt?
    var showsArt: Bool { art != nil }
    private var drawTask: Task<Void, Never>?
    /// Bumped on every picture change, so a drawing started for an older set of pictures is dropped.
    private var generation = 0
    /// Set by save, so a drawing that finishes after 저장 still lands in the saved character.
    private var savedID: UUID?
    private let store: CustomCharacterStore
    /// Photos added in this session (sent to the AI at up to 512 px), the user's cut-outs, and the AI's.
    private var photos: [CustomSlot: CGImage] = [:]
    private var photoCuts: [CustomSlot: CGImage] = [:]
    private var aiCuts: [CustomSlot: CGImage] = [:]
    func showsAI(_ slot: CustomSlot) -> Bool { photoCuts[slot] == nil && aiCuts[slot] != nil }
    /// Every shown picture is already pixel art (an AI drawing), which 귀여운 비율 does not change.
    var allPixelArt: Bool { !inputs.isEmpty && inputs.values.allSatisfy(CustomSprite.isPixelArt) }
    /// What the AI gets: this session's photos, else saved cut-outs, never pixel art.
    private var aiSources: [CustomSlot: CGImage] {
        photoCuts.reduce(into: [CustomSlot: CGImage]()) { out, e in
            if let photo = photos[e.key] { out[e.key] = photo } else if !CustomSprite.isPixelArt(e.value) { out[e.key] = e.value }
        }
    }

    /// QA renders fill a new character with these, and show 자동 다듬기 in a given state (no AI call).
    static var qaInputs: [CustomSlot: CGImage] = [:]
    struct QAState { var drawing: Bool; var cuts: [CustomSlot: CGImage]; var failure: String? = nil }
    static var qaAI: QAState?

    init(editing: CustomCharacter?, store: CustomCharacterStore, look initialLook: PhotoLook? = nil) {
        self.store = store
        editingID = editing?.id
        created = editing?.created ?? Date()
        name = editing?.name ?? ""
        voice = editing?.voice ?? .auto
        cries = (editing?.cries ?? []).joined(separator: ", ")
        lightRim = editing?.lightRim ?? false
        flipped = editing?.flipped ?? false
        chibi = editing?.chibi ?? true
        look = initialLook ?? editing.map { $0.art == nil ? $0.look : PhotoLook() } ?? PhotoLook()
        let saved = editing.map { store.inputs($0.id) } ?? Self.qaInputs
        let drawn = editing.map { store.aiSlots($0.id) } ?? []
        for (slot, image) in saved {
            if drawn.contains(slot) { aiCuts[slot] = image } else { photoCuts[slot] = image }
            place(image, slot)
        }
        art = editing?.art
        if let qa = Self.qaAI {
            aiCuts = qa.cuts.filter { photoCuts[$0.key] == nil }
            auto = qa.drawing ? .drawing : qa.failure.map { .failed($0) } ?? (qa.cuts.isEmpty ? nil : .done)
            for slot in CustomSlot.allCases { showCurrent(slot) }
        }
        rebuild()
    }

    func add(url: URL, to slot: CustomSlot) { process(slot) { CustomSprite.load(url: url) } }
    func add(data: Data, to slot: CustomSlot) { process(slot) { CustomSprite.load(data: data) } }

    /// Removing the user's picture redraws the AI's poses from what is left; removing an AI pose just drops it.
    func remove(_ slot: CustomSlot) {
        let own = photoCuts[slot] != nil
        photos[slot] = nil
        photoCuts[slot] = nil
        aiCuts[slot] = nil
        showCurrent(slot)
        if own { picturesChanged() } else { rebuild() }
    }

    /// The pictures changed: the AI's poses were drawn from the old ones, so they go, and after a short pause (more
    /// pictures may follow) the empty poses are drawn again.
    // ponytail: redraws every AI pose on any change, even one whose source picture stayed; track sources if quota bites.
    private func picturesChanged() {
        generation += 1
        drawTask?.cancel()
        drawTask = nil
        aiCuts = [:]
        auto = nil
        for slot in CustomSlot.allCases { showCurrent(slot) }
        rebuild()
        let current = generation
        // Holds the model: saved within the pause and closed, the drawing still starts and lands in the saved character.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.generation == current else { return }
            self.startAuto()
        }
    }

    /// Drawings still running, closed creators' included: the automatic update waits for them.
    static private(set) var inFlight = 0

    /// 설정's 자동 다듬기 on, never in QA renders, never for a 도트 character (photo poses would not match its art).
    /// Shows nothing at all when no AI can draw on this Mac.
    #if !MAS
    func startAuto(chatGPT: ChatGPTCharacterClient = ChatGPTCharacterClient()) {
        guard Self.qaAI == nil, AppSettings.shared.aiAutoRefine, art == nil, drawTask == nil,
              !photoCuts.values.contains(where: CustomSprite.isPixelArt) else { return }
        let sources = aiSources
        let missing = Set(CustomSlot.allCases.filter { photoCuts[$0] == nil })
        guard !sources.isEmpty, !missing.isEmpty else { return }
        let current = generation
        let basis = photoCuts.mapValues { CGSize(width: $0.width, height: $0.height) }
        Self.inFlight += 1
        drawTask = Task.detached(priority: .utility) {
            var cuts: [CustomSlot: CGImage] = [:], failure: String?
            let route = await AutoRefine.resolve(chatGPT: chatGPT)
            if route != nil {
                await MainActor.run { if self.generation == current { self.auto = .drawing } }
                do {
                    let images = try chatGPT.draw(photos: sources, real: true)
                    // A photo on light grey: the same Vision cut-out as the user's own pictures.
                    for (slot, image) in images where missing.contains(slot) {
                        if let cut = CustomSprite.checkedCutout(image)?.image { cuts[slot] = RealSprite.source(cut) }
                    }
                    if cuts.isEmpty { failure = L("AI 그림에서 모습을 찾지 못했어요.") }
                } catch {
                    failure = (error as? AICharacterClient.Failure)?.message ?? L("AI 다듬기에 실패했어요.")
                }
            }
            let (drawn, problem, cancelled) = (cuts, failure, Task.isCancelled)
            await MainActor.run {
                Self.inFlight -= 1
                guard !cancelled, self.generation == current else { return }
                self.drawTask = nil
                guard route != nil else { self.auto = nil; return }
                for (slot, cut) in drawn where self.photoCuts[slot] == nil {
                    self.aiCuts[slot] = cut
                    self.showCurrent(slot)
                }
                self.auto = problem.map { .failed($0) } ?? .done
                self.rebuild()
                // Landed after 저장: merged into what is saved now, never a rewrite from this (maybe stale) editor.
                if let id = self.savedID, !drawn.isEmpty { self.store.mergeAI(id, cuts: drawn, basis: basis) }
            }
        }
    }
    #else
    func startAuto() {}   // App Store build: no AI drawing (AIDraw/AICharacter.swift)
    #endif

    /// The creator closed. A drawing for a saved character keeps going and updates it; an unsaved one stops.
    func leave() {
        guard savedID == nil else { return }
        generation += 1
        drawTask?.cancel()
        drawTask = nil
    }

    func save(to store: CustomCharacterStore) throws -> CustomCharacter {
        let saved = try store.save(id: editingID ?? savedID ?? UUID(), name: name.trimmingCharacters(in: .whitespaces),
                                   lightRim: lightRim, flipped: flipped, chibi: chibi, look: shownLook,
                                   inputs: showsArt ? photoCuts : inputs, aiSlots: showsArt ? [] : Set(aiCuts.keys),
                                   art: showsArt ? art : nil, created: created,
                                   voice: voice, cries: cries.split(separator: ",").map(String.init))
        savedID = saved.id
        return saved
    }

    private func process(_ slot: CustomSlot, _ load: @escaping () -> CGImage?) {
        working.insert(slot)
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let photo = load()
            // Trimmed with the 2 px margin here, off the main thread, so 실사 resamples cleanly at the edges.
            let cut = photo.flatMap { CustomSprite.checkedCutout($0) }.map { c in
                (image: CustomSprite.isPixelArt(c.image) ? c.image : RealSprite.source(c.image), unclear: c.unclear, box: c.box)
            }
            DispatchQueue.main.async {
                self.working.remove(slot)
                guard let cut else {
                    self.message = L("이 그림에서 모습을 찾지 못했어요. 배경이 단순한 다른 그림을 써 보세요.")
                    return
                }
                if cut.unclear { self.message = L("주인공이 잘 안 보여요. 한 대상만 크게 찍힌 그림이 좋아요.") }
                let first = self.inputs.isEmpty
                // The AI gets the subject and a little around it, not the whole frame shrunk to 512 px.
                self.photos[slot] = photo.map { CustomSprite.crop($0, around: cut.box) }
                self.photoCuts[slot] = cut.image
                self.art = nil   // a picture character from now on
                self.place(cut.image, slot)
                // Leaning and speed lines assume facing right; guess the direction from the first picture.
                if first, let base = self.bases[slot] { self.flipped = CustomSprite.facesLeft(base) }
                self.picturesChanged()
            }
        }
    }

    /// The user's own photo cut-out of `slot`, which 다듬기 works on; nil for an AI pose or pixel art.
    func editableCut(_ slot: CustomSlot) -> CGImage? { photoCuts[slot].flatMap { CustomSprite.isPixelArt($0) ? nil : $0 } }

    /// 다듬기 finished: the cleaned cut-out (trimmed again) replaces the picture, like a new one.
    func replaceCut(_ slot: CustomSlot, with image: CGImage) {
        photoCuts[slot] = RealSprite.source(image)
        showCurrent(slot)
        picturesChanged()
    }

    private func showCurrent(_ slot: CustomSlot) {
        if let cut = photoCuts[slot] ?? aiCuts[slot] {
            place(cut, slot)
        } else {
            inputs[slot] = nil
            bases[slot] = nil
        }
    }

    private func place(_ cut: CGImage, _ slot: CustomSlot) {
        inputs[slot] = cut
        bases[slot] = CustomSprite.base(cut, chibi: chibi, height: look.size.points * CustomSprite.density)
    }

    private func rebase() {
        for (slot, cut) in inputs { bases[slot] = CustomSprite.base(cut, chibi: chibi, height: look.size.points * CustomSprite.density) }
        rebuild()
    }

    // ponytail: redrawn on the main thread on every change (about 0.1 s for 실사); move off it if toggles feel slow.
    private func rebuild() {
        let drawn = showsArt ? art?.frames(flipped: flipped) : nil
        guard !inputs.isEmpty || drawn != nil else { preview = nil; bar = nil; extras = []; return }
        let look = shownLook
        if drawn == nil, look.style == .real {
            let real = RealSprite(sources: inputs, look: look, flipped: flipped, lightRim: lightRim)
            preview = real.poseImages(pixelSize: 4, scales: [1, 2])
            bar = real.poseImages(pixelSize: 1)
            extras = ExtraMotion.allCases.map { real.extraImages($0, pixelSize: 4, scales: [1, 2]) }
            return
        }
        let frames = drawn ?? CustomSprite.frames(bases, lightRim: lightRim, flip: flipped, ring: Int(look.outline.width * 2))
        // As made: the editor shows the 스타일 chosen here, not the app's 그림 스타일.
        let big = DogSpriteCache(profile: .defaultDog, custom: frames, pixelSize: 4, style: .auto)
        let small = DogSpriteCache(profile: .defaultDog, custom: frames, pixelSize: 1, style: .auto)
        preview = DogPose.allCases.map { big.frames(for: $0) }
        bar = DogPose.allCases.map { small.frames(for: $0) }
        extras = []
    }
}

/// "새 캐릭터 만들기" page, and 꾸미기 for a saved custom character: name, one picture (two more optional), live previews.
struct CharacterCreatorView: View {
    @ObservedObject var settings: AppSettings
    let store: CustomCharacterStore
    let onDone: () -> Void
    @StateObject private var model: CreatorModel
    @State private var confirmDelete = false
    @State private var showMore = false
    /// The picture open in 배경 다듬기.
    @State private var trimming: CustomSlot?
    @ObservedObject private var refine = AutoRefine.shared

    /// `initialLook`: QA renders only.
    init(settings: AppSettings, store: CustomCharacterStore = .shared, editing: CustomCharacter?, initialLook: PhotoLook? = nil,
         onDone: @escaping () -> Void) {
        self.settings = settings
        self.store = store
        self.onDone = onDone
        _model = StateObject(wrappedValue: CreatorModel(editing: editing, store: store, look: initialLook))
    }

    private var isNew: Bool { model.editingID == nil }

    var body: some View {
        PageScaffold(title: isNew ? L("새 캐릭터 만들기") : L("꾸미기"), onBack: onDone, footer: AnyView(footer)) {
            VStack(spacing: 8) {
                Panel {
                    HStack(spacing: 8) {
                        Text("이름").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField(CustomCharacter.defaultName, text: $model.name).textFieldStyle(.roundedBorder).labelsHidden()
                        Picker("말투", selection: $model.voice) {
                            ForEach(PersonaStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize().controlSize(.small)
                    }
                    if model.voice == .cry {
                        HStack(spacing: 8) {
                            Text("울음소리").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField(Persona.neutralCries.joined(separator: ", "), text: $model.cries)
                                .textFieldStyle(.roundedBorder).labelsHidden()
                        }
                        Text("쉼표로 나눠 6개까지, 하나에 8자까지 써요").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                slotView(.normal, height: 128)
                DisclosureGroup("다른 모습도 넣기 (선택)", isExpanded: moreSlots) {
                    HStack(alignment: .top, spacing: 8) { slotView(.rest); slotView(.busy) }
                        .padding(.top, 4)
                }
                .font(.system(size: 11))
                autoLine.frame(maxWidth: .infinity, alignment: .leading)
                Text(((settings.aiAutoRefine ? refine.destination : nil)
                        .map { L("자동 다듬기: 빈 모습을 그릴 때 사진이 \($0)로 보내져요 (설정에서 끌 수 있어요)") }
                        ?? L("사진은 이 맥 안에서만 변환돼요")) + L(" · 직접 권리를 가진 이미지를 써 주세요"))
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let message = model.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let preview = model.preview, let bar = model.bar {
                    Panel {
                        // 내 Claude's frames bring their own proportions and outline.
                        if !model.showsArt { lookPickers }
                        if !model.allPixelArt && !model.showsArt && model.shownLook.style == .pixel {
                            Toggle("귀여운 비율 (머리 크게)", isOn: $model.chibi)
                        }
                        Toggle("좌우 뒤집기 (오른쪽을 보게)", isOn: $model.flipped)
                        if !model.showsArt { Toggle("어두운 메뉴바용 밝은 테두리", isOn: $model.lightRim) }
                    }
                    .font(.system(size: 12))
                    menuBars(bar)
                    poses(preview)
                } else {
                    Text("그림 한 장이면 충분해요. 넣으면 움직이는 모습을 여기서 미리 볼 수 있어요")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
            }
        }
        // Off while 배경 다듬기 covers it, so Return and Esc reach the editor's 완료 and 뒤로, not this page's.
        .disabled(trimming != nil)
        .accessibilityHidden(trimming != nil)
        .overlay {
            if let slot = trimming, let cut = model.editableCut(slot) {
                CutoutEditorView(image: cut, onDone: { model.replaceCut(slot, with: $0); trimming = nil }, onCancel: { trimming = nil })
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onAppear { StatusItemController.holdOpen = true; refine.check() }
        .onDisappear { StatusItemController.holdOpen = false; model.leave() }
        .alert("이 캐릭터를 지울까요?", isPresented: $confirmDelete) {
            Button("지우기", role: .destructive, action: delete)
            Button("취소", role: .cancel) {}
        } message: {
            Text("만든 캐릭터와 저장된 그림이 이 맥에서 사라져요.")
        }
    }

    // MARK: Pictures

    /// Open while 쉴 때 or 바쁠 때 holds a picture, so a saved one is never hidden.
    private var moreSlots: Binding<Bool> {
        Binding(get: { showMore || model.inputs[.rest] != nil || model.inputs[.busy] != nil }, set: { showMore = $0 })
    }

    private func title(_ slot: CustomSlot) -> String { slot == .normal ? L("캐릭터 그림") : slot.label }

    private func slotView(_ slot: CustomSlot, height: CGFloat = 84) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                if model.working.contains(slot) {
                    ProgressView().controlSize(.small)
                } else if let image = model.inputs[slot] {
                    Image(decorative: image, scale: 1).resizable()
                        .interpolation(CustomSprite.isPixelArt(image) ? .none : .high).scaledToFit().padding(6)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
                    VStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                        Text("그림 넣기").font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .onTapGesture { choose(slot) }
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { drop($0, slot) }
            .overlay(alignment: .topLeading) {
                if model.showsAI(slot) && !model.working.contains(slot) {
                    Text("AI").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor)).padding(5)
                        .accessibilityLabel("AI가 그린 그림")
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.inputs[slot] != nil && !model.working.contains(slot) {
                    Button { model.remove(slot) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("\(slot.label) 그림 빼기")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if model.editableCut(slot) != nil && !model.working.contains(slot) {
                    Button { trimming = slot } label: {
                        Image(systemName: "eraser").font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(4).background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help(L("남은 배경 지우기"))
                    .accessibilityLabel("\(slot.label) 배경 다듬기")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(slot.label) 그림")
            .accessibilityAddTraits(.isButton)
            Text(title(slot)).font(.system(size: 11, weight: .semibold))
            Text(slot == .normal ? L("한 장이면 모든 동작을 만들어요")
                 : model.inputs[slot] == nil ? slot.source(among: Set(model.inputs.keys)).map { L("비우면 \($0.label) 모습을 써요") } ?? slot.hint
                 : slot.hint)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func choose(_ slot: CustomSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        panel.message = L("\(slot.label) 모습이 담긴 그림을 골라 주세요")
        NSApp.activate(ignoringOtherApps: true)
        if PopoverLayer.runModal({ panel.runModal() }) == .OK, let url = panel.url { model.add(url: url, to: slot) }
    }

    private func drop(_ providers: [NSItemProvider], _ slot: CustomSlot) -> Bool {
        guard let item = providers.first else { return false }
        if item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = item.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { model.add(url: url, to: slot) }
            }
            return true
        }
        if item.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = item.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { model.add(data: data, to: slot) }
            }
            return true
        }
        return false
    }

    // MARK: AI

    /// One quiet line while 자동 다듬기 runs or after it, nothing when no AI could draw.
    @ViewBuilder private var autoLine: some View {
        switch model.auto {
        case .drawing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("AI가 자는 모습·뛰는 모습을 그리는 중… 먼저 저장해도 다 그리면 반영돼요")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        case .done:
            Text("AI가 비어 있던 모습을 그렸어요 ('AI' 표시)").font(.system(size: 10)).foregroundStyle(.secondary)
        case .failed(let reason):
            Text("AI 다듬기를 못 해서 사진으로 만들었어요").font(.system(size: 10)).foregroundStyle(.secondary).help(reason)
        case nil:
            EmptyView()
        }
    }

    // MARK: Look

    /// 스타일, 크기, 외곽선 as segmented rows.
    private var lookPickers: some View {
        VStack(alignment: .leading, spacing: 6) {
            lookRow(L("스타일"), $model.look.style, PhotoLook.Style.allCases, \.label)
                .disabled(model.allPixelArt)
            if model.allPixelArt {
                Text("AI가 그린 도트 그림은 도트로 보여요").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if model.look.style == .real {
                Text("실사: 잘라낸 사진을 그대로 고해상도로 움직여요").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            lookRow(L("크기"), $model.look.size, PhotoLook.Size.allCases, \.label)
            lookRow(L("외곽선"), $model.look.outline, PhotoLook.Outline.allCases, \.label)
        }
    }

    private func lookRow<T: Hashable>(_ title: String, _ value: Binding<T>, _ all: [T], _ label: KeyPath<T, String>) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Picker(title, selection: value) {
                ForEach(all, id: \.self) { Text($0[keyPath: label]).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: Previews

    /// Real size, on a light and a dark menu bar.
    private func menuBars(_ bar: [[NSImage]]) -> some View {
        HStack(spacing: 8) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 6) {
                    FramePlayer(frames: bar[DogPose.walk.rawValue], every: DogSpriteCache.frameDuration(for: .walk, cpu: 0.2))
                    FramePlayer(frames: bar[DogPose.sprint.rawValue], every: DogSpriteCache.frameDuration(for: .sprint, cpu: 0.75))
                    Text("23%").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(dark ? Color.white : Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(dark ? Color(white: 0.17) : Color(white: 0.93)))
                .accessibilityLabel(dark ? "어두운 메뉴바 미리보기" : "밝은 메뉴바 미리보기")
            }
        }
    }

    private func poses(_ preview: [[NSImage]]) -> some View {
        let tiles = DogPose.allCases.map { pose in
            (preview[pose.rawValue], DogSpriteCache.frameDuration(for: pose, cpu: pose.sampleCPU),
             "\(CustomSlot.forPose(pose).source(among: Set(model.inputs.keys))?.label ?? "") · \(pose.label)")
        } + zip(ExtraMotion.allCases, model.extras).map { extra, frames in
            (frames, extra == .special ? 0.12 : 0.22, L("상황 · \(Self.extraLabel(extra))"))
        }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(tiles.indices, id: \.self) { i in
                VStack(spacing: 2) {
                    FramePlayer(frames: tiles[i].0, every: tiles[i].1)
                    Text(tiles[i].2).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    static func extraLabel(_ extra: ExtraMotion) -> String {
        switch extra {
        case .hungry: return L("배고플 때")
        case .eat: return L("밥 먹을 때")
        case .special: return L("신날 때")
        }
    }

    // MARK: Save and delete

    private var footer: some View {
        HStack(spacing: 8) {
            if !isNew {
                Button("삭제…", role: .destructive) { confirmDelete = true }
            }
            Spacer()
            Button(isNew ? "저장하고 메뉴바에 두기" : "변경 저장", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(model.inputs.isEmpty && !model.showsArt || !model.working.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
    }

    private func save() {
        do {
            let saved = try model.save(to: store)
            settings.useCustom(saved.id)
            onDone()
        } catch {
            model.message = store.isFull && isNew ? L("캐릭터는 \(CustomCharacterStore.maxCount)개까지 만들 수 있어요.")
                                                  : L("저장하지 못했어요: \(error.localizedDescription)")
        }
    }

    private func delete() {
        guard let id = model.editingID else { return }
        do {
            try store.delete(id)
            if settings.character == .custom && settings.customCharacterID == id.uuidString { settings.character = .dog }
            onDone()
        } catch {
            model.message = L("지우지 못했어요: \(error.localizedDescription)")
        }
    }
}

/// 배경 다듬기: clears what the automatic cut-out left of the background. 비슷한 색 (a click clears the patch of that
/// colour) or 지우개 (drag), 되돌리기 up to 10 steps; 완료 hands the result back, 뒤로 drops it. Only the user's own photos.
struct CutoutEditorView: View {
    enum Tool: CaseIterable {
        case similar, brush
        var label: String { self == .similar ? L("비슷한 색 지우기") : L("지우개") }
    }

    let onDone: (CGImage) -> Void
    let onCancel: () -> Void
    @State private var bitmap: Bitmap
    @State private var shown: CGImage
    @State private var undo = UndoStack<Bitmap>(limit: 10)
    @State private var tool = Tool.similar
    @State private var tolerance = 40.0
    @State private var radius = 10.0
    /// The brush stroke's last point in view coordinates; nil between strokes.
    @State private var last: CGPoint?
    @State private var note: String?

    init(image: CGImage, onDone: @escaping (CGImage) -> Void, onCancel: @escaping () -> Void) {
        self.onDone = onDone
        self.onCancel = onCancel
        _bitmap = State(initialValue: Bitmap(image))
        _shown = State(initialValue: image)
    }

    var body: some View {
        PageScaffold(title: L("배경 다듬기"), onBack: onCancel, footer: AnyView(footer)) {
            VStack(spacing: 8) {
                Picker("도구", selection: $tool) {
                    ForEach(Tool.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                canvas
                HStack(spacing: 8) {
                    Text(tool == .similar ? L("비슷한 정도") : L("지우개 크기")).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    if tool == .similar { Slider(value: $tolerance, in: 8...120) } else { Slider(value: $radius, in: 3...30) }
                }
                .font(.system(size: 11)).controlSize(.small)
                Text(tool == .similar ? L("남은 배경을 누르면 이어진 비슷한 색이 한 번에 지워져요")
                                      : L("문질러서 지워요. 잘못 지우면 되돌리기를 눌러 주세요"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Color.warn).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let rect = fit(geo.size)
            Canvas { ctx, _ in
                let cell: CGFloat = 8
                for row in 0..<Int((rect.height / cell).rounded(.up)) {
                    for col in 0..<Int((rect.width / cell).rounded(.up)) where (row + col) % 2 == 0 {
                        let r = CGRect(x: rect.minX + CGFloat(col) * cell, y: rect.minY + CGFloat(row) * cell, width: cell, height: cell)
                        ctx.fill(Path(r.intersection(rect)), with: .color(.primary.opacity(0.1)))
                    }
                }
                ctx.draw(Image(decorative: shown, scale: 1), in: rect)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { touch($0.location, rect, ended: false) }
                .onEnded { touch($0.location, rect, ended: true) })
        }
        .frame(height: 240)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityLabel("다듬는 그림")
    }

    /// The picture fitted into `size`, centred.
    private func fit(_ size: CGSize) -> CGRect {
        let k = min(size.width / CGFloat(bitmap.width), size.height / CGFloat(bitmap.height))
        let w = CGFloat(bitmap.width) * k, h = CGFloat(bitmap.height) * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func touch(_ p: CGPoint, _ rect: CGRect, ended: Bool) {
        let k = CGFloat(bitmap.width) / max(1, rect.width)
        func pixel(_ q: CGPoint) -> (Int, Int) { (Int((q.x - rect.minX) * k), Int((q.y - rect.minY) * k)) }
        note = nil
        switch tool {
        case .similar:
            let (x, y) = pixel(p)
            guard ended, let next = CutoutEdit.eraseSimilar(bitmap, x: x, y: y, tolerance: Int(tolerance)) else { return }
            undo.push(bitmap)
            bitmap = next
        case .brush:
            if last == nil { undo.push(bitmap) }
            // Stamped along the drag, so a quick stroke leaves no gaps.
            let from = last ?? p, steps = max(1, Int(hypot(p.x - from.x, p.y - from.y) / max(1, radius / 2)))
            // One copy out of @State per drag event, not one per stamp.
            var b = bitmap
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let (x, y) = pixel(CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t))
                CutoutEdit.brush(&b, x: x, y: y, radius: Int(radius * k))
            }
            bitmap = b
            last = ended ? nil : p
        }
        // ponytail: redraws the whole picture (up to 1024 px) per drag step; draw only the touched box if it lags.
        shown = bitmap.cgImage
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("되돌리기") {
                guard let prev = undo.pop() else { return }
                bitmap = prev
                shown = prev.cgImage
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(undo.isEmpty)
            Spacer()
            Button("완료") {
                guard CutoutEdit.hasSubject(bitmap) else { note = L("모두 지워졌어요. 되돌리기로 돌아가 주세요"); return }
                onDone(bitmap.cgImage)
            }
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
    }
}

extension CustomSlot {
    var hint: String {
        switch self {
        case .rest: return L("쉬고 잘 때")
        case .normal: return L("걷고 달릴 때")
        case .busy: return L("아주 바쁠 때")
        }
    }
}

extension DogPose {
    /// A busyness inside this pose's band, for previews.
    var sampleCPU: Double {
        switch self {
        case .lying: return 0.02
        case .slowWalk: return 0.1
        case .walk: return 0.22
        case .fastWalk: return 0.37
        case .run: return 0.55
        case .sprint: return 0.75
        case .exhausted: return 0.92
        }
    }
}

/// Plays ready-made frames (any character, any size) through AnimatedSpriteView, sized to the first frame.
struct FramePlayer: NSViewRepresentable {
    let frames: [NSImage]
    let every: TimeInterval

    func makeNSView(context: Context) -> AnimatedSpriteView {
        let v = AnimatedSpriteView()
        v.setAccessibilityElement(false)
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: AnimatedSpriteView, context: Context) {
        v.play(frames, every: max(0.04, (every * 50).rounded() / 50))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedSpriteView, context: Context) -> CGSize? {
        frames.first?.size ?? .zero
    }
}
