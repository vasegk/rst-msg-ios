import PhotosUI
import SwiftUI

/// Что открыть в окне набора: имя (из ссылки) или картинку стикера (из переписки).
struct StickerSetRef: Identifiable, Hashable {
    var name: String?
    var fileUrl: String?
    var id: String { name ?? fileUrl ?? "" }
}

/// Сетка картинок стикеров.
private struct StickerGrid: View {
    let stickers: [StickerDto]
    var size: CGFloat = 72
    var onTap: ((StickerDto) -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size), spacing: 8)], spacing: 8) {
            ForEach(stickers) { st in
                PlainImageView(fileUrl: st.fileUrl, size: size)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?(st) }
            }
        }
    }
}

// MARK: - Панель стикеров в поле ввода

/// Вкладка стикеров: добавленные наборы, кнопка мастерской.
struct StickerPanelSheet: View {
    var onPick: (StickerDto) -> Void
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let sets = (services.stickers.sets ?? []).filter { !$0.stickers.isEmpty }
                    if !loaded && services.stickers.sets == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if sets.isEmpty {
                        Text(services.stickers.error ?? "Стикеров пока нет. Соберите свой набор в мастерской или добавьте чужой — нажмите на стикер в переписке.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 30)
                    }
                    ForEach(sets) { set in
                        Text(set.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        StickerGrid(stickers: set.stickers) { st in
                            dismiss()
                            onPick(st)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Стикеры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { StickerStudioView() } label: { Label("Мастерская", systemImage: "paintbrush") }
                }
            }
            .task {
                await services.stickers.load()
                loaded = true
            }
        }
    }
}

// MARK: - Окно набора

/// Набор: посмотреть, добавить себе или убрать, скопировать ссылку.
struct StickerSetSheet: View {
    let ref: StickerSetRef
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var set: StickerSetDto?
    @State private var error: String?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let set {
                        Text(StickerStore.countText(set.stickers.count)).font(.system(size: 14)).foregroundStyle(Theme.muted)
                        if set.stickers.isEmpty {
                            Text("В наборе пока пусто.").foregroundStyle(Theme.muted)
                        }
                        StickerGrid(stickers: set.stickers, size: 80)
                    } else if let error {
                        Text(error).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding()
            }
            .navigationTitle(set?.title ?? "Набор стикеров")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                if let set {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            UIPasteboard.general.string = StickerStore.link(set.name)
                            notice = "Ссылка на набор скопирована"
                        } label: { Label("Ссылка", systemImage: "link") }
                    }
                    if set.mine != true {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(set.installed == true ? "Убрать" : "Добавить") { toggle(set) }
                                .disabled(busy)
                        }
                    }
                }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            var name = ref.name
            if name == nil, let file = ref.fileUrl { name = try await services.stickers.setName(forSticker: file) }
            guard let name else { throw CryptoError("Набора нет") }
            set = try await services.stickers.set(named: name)
        } catch {
            self.error = ref.fileUrl != nil ? "Набор удалён" : errorText(error)
        }
    }

    private func toggle(_ current: StickerSetDto) {
        busy = true
        Task {
            do {
                try await services.stickers.toggleInstall(current)
                dismiss()
            } catch {
                busy = false
                notice = errorText(error)
            }
        }
    }
}

// MARK: - Мастерская

/// Свои наборы из своих картинок; набор виден всем, кому пришлют стикер или ссылку.
struct StickerStudioView: View {
    @Environment(Services.self) private var services
    @State private var title = ""
    @State private var name = ""
    @State private var nameTouched = false
    @State private var busy = false
    @State private var error: String?
    @State private var opened: String?

    private var own: [StickerSetDto] { (services.stickers.sets ?? []).filter { $0.mine == true } }

    var body: some View {
        Form {
            Section {
                if own.isEmpty {
                    Text("Своих наборов пока нет.").foregroundStyle(Theme.muted)
                }
                ForEach(own) { set in
                    NavigationLink { StudioSetView(setName: set.name) } label: {
                        HStack(spacing: 12) {
                            if let first = set.stickers.first {
                                PlainImageView(fileUrl: first.fileUrl, size: 40)
                            } else {
                                Text("🗂").font(.system(size: 28)).frame(width: 40, height: 40)
                            }
                            VStack(alignment: .leading) {
                                Text(set.title)
                                Text("\(set.stickers.count) шт. · \(set.name)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            } footer: {
                Text("Свои наборы из своих картинок. Набор виден всем, кому вы пришлёте стикер или ссылку.")
            }
            Section("Новый набор") {
                TextField("Название набора", text: $title)
                    .onChange(of: title) { _, t in
                        if !nameTouched { name = StickerStore.suggestName(t) }
                    }
                TextField("Имя для ссылки: латиница, цифры, _", text: Binding(get: { name }, set: { name = $0; nameTouched = true }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Создать набор") { create() }.disabled(busy)
            }
        }
        .navigationTitle("Мастерская")
        .navigationDestination(item: $opened) { StudioSetView(setName: $0) }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task { await services.stickers.load(force: true) }
    }

    private func create() {
        let t = title.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { error = "Введите название набора"; return }
        guard StickerStore.isValidName(n) else { error = "Имя для ссылки: 3–32 знака — латиница, цифры, _"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let set = try await services.stickers.create(title: t, name: n)
                title = ""
                name = ""
                nameTouched = false
                opened = set.name
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

/// Свой набор: добавить картинки (ужимаются до 512 точек), убрать, удалить набор.
struct StudioSetView: View {
    let setName: String
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var set: StickerSetDto?
    @State private var emoji = "🙂"
    @State private var items: [PhotosPickerItem] = []
    @State private var adding = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Нажмите ＋ и выберите картинку: она ужмётся до 512 точек. PNG с прозрачным фоном смотрится лучше всего.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                HStack {
                    Text("Эмодзи для новых стикеров")
                    TextField("🙂", text: $emoji).frame(width: 60).textFieldStyle(.roundedBorder)
                }
                if let set {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(set.stickers) { st in
                            ZStack(alignment: .topTrailing) {
                                PlainImageView(fileUrl: st.fileUrl, size: 80)
                                Button { remove(st) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                                        .foregroundStyle(.white, Theme.danger)
                                }
                                .offset(x: 6, y: -6)
                            }
                            .overlay(alignment: .bottomLeading) {
                                Text(st.emoji ?? "").font(.system(size: 14))
                            }
                        }
                        if set.stickers.count < StickerStore.maxStickers {
                            PhotosPicker(selection: $items, maxSelectionCount: 20, matching: .images) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).stroke(Theme.outline, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                                    if adding { ProgressView() } else { Image(systemName: "plus").font(.system(size: 26)) }
                                }
                                .frame(width: 80, height: 80)
                            }
                            .disabled(adding)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding()
        }
        .navigationTitle(set?.title ?? setName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        UIPasteboard.general.string = StickerStore.link(setName)
                        notice = "Ссылка на набор скопирована"
                    } label: { Label("Ссылка", systemImage: "link") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Удалить набор", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Удалить набор? Он пропадёт у всех, кто его добавил.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteSet() }
        }
        .alert(error ?? notice ?? "", isPresented: Binding(get: { error != nil || notice != nil },
                                                          set: { if !$0 { error = nil; notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            items = []
            Task { await add(picked) }
        }
        .task { await reload() }
    }

    private func reload() async {
        do { set = try await services.stickers.set(named: setName) } catch { self.error = errorText(error) }
    }

    private func add(_ picked: [PhotosPickerItem]) async {
        guard let current = set else { return }
        adding = true
        defer { adding = false }
        for item in picked {
            guard (set?.stickers.count ?? 0) < StickerStore.maxStickers else { break }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let st = try await services.stickers.add(imageData: data, emoji: emoji, to: current)
                set?.stickers.append(st)
            } catch {
                self.error = errorText(error)
            }
        }
    }

    private func remove(_ st: StickerDto) {
        guard let current = set else { return }
        Task {
            do {
                try await services.stickers.remove(st, from: current)
                set?.stickers.removeAll { $0.id == st.id }
            } catch {
                self.error = errorText(error)
            }
        }
    }

    private func deleteSet() {
        guard let current = set else { return }
        Task {
            do {
                try await services.stickers.deleteSet(current)
                dismiss()
            } catch {
                self.error = errorText(error)
            }
        }
    }
}

/// Стикеры для «Любая реакция»: значение — «s:» + адрес картинки.
struct StickerReactionGrid: View {
    var onPick: (String) -> Void
    @Environment(Services.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let sets = (services.stickers.sets ?? []).filter { !$0.stickers.isEmpty }
            if sets.isEmpty {
                Text("Добавьте наборы стикеров — и ставьте их реакцией.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            ForEach(sets) { set in
                Text(set.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                StickerGrid(stickers: set.stickers, size: 56) { st in onPick("s:" + st.fileUrl) }
            }
        }
        .task { await services.stickers.load() }
    }
}
