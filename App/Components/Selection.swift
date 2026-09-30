import SwiftUI
import MelogoldCore
import MelogoldData

/// Что выделено в списке, как это понимают действия (задание 0013): id строк → треки в порядке списка, «Убрать…» по
/// контексту строк. Строки списка помечены `tag(<id>)`, `target` переводит id в трек, `rowIds` — все строки-треки в
/// порядке списка (по нему «Выбрать все» и порядок «Слушать»).
struct SelectionScope {
    let target: (String) -> RowTarget?
    let context: (String) -> TrackMenuContext?
    let rowIds: [String]
    let collectionName: String?

    func track(_ id: String) -> Track? {
        switch target(id) {
        case .list(let tracks, let index)?: tracks.indices.contains(index) ? tracks[index] : nil
        case .single(let track)?: track
        default: nil
        }
    }

    /// Выбранные строки в порядке списка; список без `rowIds` — по id.
    func ordered(_ ids: Set<String>) -> [String] {
        rowIds.isEmpty ? ids.sorted() : rowIds.filter(ids.contains)
    }

    /// Треки выделенных строк в порядке списка, без повторов.
    func tracks(_ ids: Set<String>) -> [Track] {
        var seen = Set<String>()
        return ordered(ids).compactMap(track).filter { seen.insert($0.videoId).inserted }
    }

    /// «Убрать…» — если у всех выделенных один и тот же контекст (плейлист, Избранное, История).
    func removal(_ ids: Set<String>) -> SelectionRemoval? {
        let contexts = ordered(ids).map { SelectionRemoval(context($0)) }
        guard let first = contexts.first, let removal = first, contexts.allSatisfy({ $0 == removal }) else { return nil }
        return removal
    }
}

/// Действия с выделенными треками: пункты правого щелчка на Mac и меню «…» панели (задание 0013). Одинаковые на всех
/// платформах; порядок — как на Android (`SelectionTopBar`) и у Windows.
struct SelectionMenuItems: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    var removal: SelectionRemoval?
    var collectionName: String?
    /// Пункты «Выбрать все» и «Снять выделение» есть только в панели.
    var selectAll: (() -> Void)?
    var clear: (() -> Void)?
    /// Выделение закончено действием (iPhone: выходит из режима выбора).
    var done: () -> Void = {}

    var body: some View {
        Section {
            Button { model.playSelection(tracks); done() } label: {
                Label("selection.play", systemImage: "play.fill")
            }
            Button { model.enqueueSelection(tracks); done() } label: {
                Label("selection.enqueue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
        Section {
            Button { model.likeSelection(tracks); done() } label: {
                Label("selection.favorite", systemImage: "heart")
            }
            Button { model.playlistPicker = PlaylistPickerRequest(tracks: tracks); done() } label: {
                Label("selection.addToPlaylist", systemImage: "text.badge.plus")
            }
            Button { model.promptNewPlaylist(tracks) } label: {
                Label("selection.newPlaylist", systemImage: "plus.rectangle.on.rectangle")
            }
            if model.services.downloads != nil {
                Button { model.downloadSelection(tracks); done() } label: {
                    Label("selection.download", systemImage: "arrow.down.circle")
                }
            }
            Button { model.promptSetAlbum(tracks, collectionName: collectionName) } label: {
                Label("selection.setAlbum", systemImage: "square.stack")
            }
        }
        if let removal {
            Section {
                Button(role: .destructive) { model.removeSelection(tracks, removal); done() } label: {
                    Label(removal.title, systemImage: removal.systemImage)
                }
            }
        }
        if selectAll != nil || clear != nil {
            Section {
                if let selectAll {
                    Button(action: selectAll) { Label("selection.selectAll", systemImage: "checkmark.circle") }
                }
                if let clear {
                    Button(action: clear) { Label("selection.clear", systemImage: "xmark.circle") }
                }
            }
        }
    }
}

/// Панель действий с выделенным: «Выбрано: N» и самые частые действия (задание 0013). iPhone, iPad, Vision — в режиме
/// выбора; Mac — от двух выделенных строк.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    var removal: SelectionRemoval?
    var collectionName: String?
    let selectAll: () -> Void
    let clear: () -> Void
    var done: () -> Void = {}

    var body: some View {
        let empty = tracks.isEmpty
        HStack(spacing: 4) {
            Text("selection.count \(tracks.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Button { model.playSelection(tracks); done() } label: {
                Label("selection.play", systemImage: "play.fill")
            }
            .disabled(empty)
            Button { model.likeSelection(tracks); done() } label: {
                Label("selection.favorite", systemImage: "heart")
            }
            .disabled(empty)
            if model.services.downloads != nil {
                Button { model.downloadSelection(tracks); done() } label: {
                    Label("selection.download", systemImage: "arrow.down.circle")
                }
                .disabled(empty)
            }
            Menu {
                SelectionMenuItems(tracks: tracks, removal: removal, collectionName: collectionName,
                                   selectAll: selectAll, clear: clear, done: done)
            } label: {
                Label("menu.more", systemImage: "ellipsis")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .disabled(empty)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Список с действиями (docs/PROMPT.md §5.4, §5.8, задание 0013). На Mac — выделение (⌘-щелчок, ⇧-щелчок, ⌘A, Esc
/// снимает), двойной щелчок или Return, правый щелчок (`contextMenu(forSelectionType:primaryAction:)`, строки помечены
/// `tag`), панель от двух выделенных. На iPhone, iPad и Vision — обычный список: действие и меню у самих строк, а
/// кнопка «Выбрать» включает режим выбора (`EditMode`) с отметками и нижней панелью.
struct SelectableList<Content: View>: View {
    @Environment(AppModel.self) private var model
    let target: (String) -> RowTarget?
    var context: (String) -> TrackMenuContext? = { _ in nil }
    /// Метки всех строк-треков в порядке списка: «Выбрать все» и порядок «Слушать». Пусто — выбор у списка выключен (на
    /// iPhone, iPad и Vision нет кнопки «Выбрать»).
    var rowIds: [String] = []
    /// Название плейлиста или альбома: «Указать альбом…» предлагает его, когда общего альбома нет.
    var collectionName: String?
    /// Кнопка «Выбрать» в панели навигации (iPhone, iPad, Vision); у экрана, где режим правки включает свой `EditButton`,
    /// её нет — тот же режим даёт и выбор.
    var showsSelectButton = true
    @ViewBuilder let content: () -> Content
    @State private var selection: Set<String> = []
    #if !os(macOS)
    /// Режим выбора — системный `editMode` (его же включает `EditButton` своего плейлиста); нет системного — свой.
    @Environment(\.editMode) private var systemEditMode
    @State private var ownEditMode: EditMode = .inactive
    private var editMode: Binding<EditMode> { systemEditMode ?? $ownEditMode }
    #endif

    private var scope: SelectionScope {
        SelectionScope(target: target, context: context, rowIds: rowIds, collectionName: collectionName)
    }

    private var isSelecting: Bool {
        #if os(macOS)
        selection.count >= 2
        #else
        editMode.wrappedValue.isEditing
        #endif
    }

    var body: some View {
        let scope = scope
        Group {
            #if os(macOS)
            List(selection: $selection, content: content)
                .rowActions(target, context: context, rowIds: rowIds, collectionName: collectionName)
                .onExitCommand(perform: selection.isEmpty ? nil : { selection = [] })
                .onDeleteCommand(perform: deleteAction(scope))
            #else
            List(selection: isSelecting ? $selection : nil, content: content)
                .environment(\.editMode, editMode)
                .toolbar {
                    if showsSelectButton, !rowIds.isEmpty {
                        // Своя «капсула» у «Выбрать»: значки действий экрана и выбор не слипаются в одну панель (выбор — отдельный режим)
                        #if !os(visionOS)
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                        #endif
                        // Значок, а не слово: с тремя группами кнопок название экрана («Избранное») обрезалось до «Избран…»
                        ToolbarItem(placement: .primaryAction) {
                            if isSelecting {
                                Button("common.done") { toggleSelecting() }
                            } else {
                                Button { toggleSelecting() } label: {
                                    Label("selection.select", systemImage: "checkmark.circle")
                                }
                                .accessibilityIdentifier("selection.select")
                            }
                        }
                    }
                }
                .toolbarVisibility(isSelecting ? .hidden : .automatic, for: .tabBar)
                .onChange(of: rowIds.isEmpty) { _, empty in if empty { stopSelecting() } }
            #endif
        }
        .safeAreaBar(edge: .bottom) {
            if isSelecting {
                SelectionBar(tracks: scope.tracks(selection), removal: scope.removal(selection), collectionName: collectionName,
                             selectAll: { selection = Set(rowIds) }, clear: { selection = [] }, done: stopSelecting)
            }
        }
        // «Новый плейлист…» и «Указать альбом…» кончаются в окне поверх списка: выделение снимается, когда они выполнены
        .onChange(of: model.selectionFinished) { stopSelecting() }
        #if DEBUG
        // -MelogoldPreselect <n>: первые n строк выделены (снимки выбора без нажатий; на iPhone включает режим выбора)
        .task(id: rowIds.count) {
            let count = UserDefaults.standard.integer(forKey: "MelogoldPreselect")
            guard count > 0, selection.isEmpty, !rowIds.isEmpty else { return }
            #if !os(macOS)
            editMode.wrappedValue = .active
            #endif
            selection = Set(rowIds.prefix(count))
        }
        #endif
    }

    #if !os(macOS)
    private func toggleSelecting() {
        withAnimation { editMode.wrappedValue = isSelecting ? .inactive : .active }
        if !isSelecting { selection = [] }
    }
    #endif

    private func stopSelecting() {
        #if os(macOS)
        selection = []
        #else
        withAnimation { editMode.wrappedValue = .inactive }
        selection = []
        #endif
    }

    /// Delete на Mac: «Убрать…» там, где список это допускает (плейлист, Избранное, История).
    private func deleteAction(_ scope: SelectionScope) -> (() -> Void)? {
        guard let removal = scope.removal(selection), !selection.isEmpty else { return nil }
        return { model.removeSelection(scope.tracks(selection), removal); selection = [] }
    }
}
