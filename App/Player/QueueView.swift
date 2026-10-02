import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Очередь (docs/PROMPT.md §5.7, REWRITE §3.10.4): «Далее · 24 трека · 1 ч 32 мин», «Перемешать», «Сохранить как
/// плейлист», «Очистить»; текущий трек со столбиками; перетаскивание (VoiceOver — «Переместить выше/ниже»); смахивание
/// убирает трек с «Отменить», на Mac — клавиша Delete; блок «Далее — автовоспроизведение» с переключателем. iPhone —
/// лист, iPad и Mac — колонка справа.
struct QueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var inSheet = false
    @State private var selection: Set<UUID> = []
    @State private var saveAsPlaylist = false

    var body: some View {
        if let target = model.remoteTarget?.target {
            // Музыка играет на другом устройстве: здешняя очередь к ней не относится (задание 0020)
            ContentUnavailableView {
                Label("remote.queueThere \(target.name)", systemImage: DeviceSymbol.name(for: target.platform))
            } description: {
                Text("remote.queueThere.hint")
            }
            .modifier(QueueTitle(inSheet: inSheet))
            .toolbar {
                if inSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
                }
            }
        } else {
            localQueue
        }
    }

    @ViewBuilder
    private var localQueue: some View {
        let player = model.services.player
        let current = player.index ?? 0
        let upcoming = player.upcoming
        let userItems = upcoming.filter { !$0.fromAutoplay }
        let autoplayItems = upcoming.filter(\.fromAutoplay)
        List(selection: $selection) {
            if let item = player.current {
                Section {
                    // Текущий трек — мягкая плашка акцента: строка списка — контент, стекла под ним нет
                    QueueRow(item: item, isCurrent: true)
                        .listRowBackground(Color.accentColor.opacity(0.12))
                } header: {
                    Text("queue.nowPlaying")
                }
            }
            Section {
                ForEach(userItems) { item in
                    QueueRow(item: item, isCurrent: false)
                        .tag(item.id)
                        .swipeActions { removeButton(item) }
                        .accessibilityActions { moveActions(item, in: userItems) }
                }
                .onMove { source, destination in move(source, destination, within: userItems, base: current + 1) }
            } header: {
                // Действия очереди — меню «…» у заголовка (HIG «Toolbars», «Menus»: второстепенное — в меню «Ещё»): ряд кнопок
                // в заголовке не помещался и уезжал за край — «Сохранить как плейлист» обрезалось, «Очистить» было не видно
                HStack(spacing: 8) {
                    Text("queue.upNext \(LibraryText.summary(userItems.map(\.track)))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Toggle(isOn: Binding(get: { player.shuffled }, set: { player.setShuffled($0) })) {
                            Label("collection.shuffle", systemImage: "shuffle")
                        }
                        Button { saveAsPlaylist = true } label: { Label("queue.saveAsPlaylist", systemImage: "text.badge.plus") }
                            .disabled(player.items.isEmpty)
                        Divider()
                        Button(role: .destructive) { clear() } label: { Label("queue.clear", systemImage: "xmark.circle") }
                            .disabled(upcoming.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(minWidth: Design.Size.minTap, minHeight: Design.Size.minTap)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(Text("menu.more"))
                }
                .textCase(nil)
            }
            Section {
                ForEach(autoplayItems) { item in
                    QueueRow(item: item, isCurrent: false)
                        .opacity(0.8)
                        .tag(item.id)
                        .swipeActions { removeButton(item) }
                }
            } header: {
                Toggle(isOn: Binding(get: { model.settings.autoplay }, set: {
                    model.settings.autoplay = $0
                    player.autoplayEnabled = $0
                })) {
                    Text("queue.autoplay")
                }
                .textCase(nil)
            }
        }
        .playerBarClearance()
        #if os(macOS)
        .onDeleteCommand {
            for id in selection { player.remove(id) }
            selection = []
        }
        #endif
        .modifier(QueueTitle(inSheet: inSheet))
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .newPlaylistAlert(isPresented: $saveAsPlaylist, tracks: player.items.filter { !$0.fromAutoplay }.map(\.track)) { _ in
            model.toast = Toast(text: String(localized: "library.playlistCreated"))
        }
    }

    private func removeButton(_ item: QueueItem) -> some View {
        Button(role: .destructive) { model.removeFromQueue(item) } label: {
            Label("menu.removeFromQueue", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func moveActions(_ item: QueueItem, in list: [QueueItem]) -> some View {
        if let position = list.firstIndex(where: { $0.id == item.id }) {
            let base = (model.services.player.index ?? 0) + 1
            if position > 0 {
                Button("playlist.moveUp") { model.services.player.move(fromOffsets: [base + position], toOffset: base + position - 1) }
            }
            if position + 1 < list.count {
                Button("playlist.moveDown") { model.services.player.move(fromOffsets: [base + position], toOffset: base + position + 2) }
            }
        }
    }

    /// Смещения раздела — в индексы всей очереди.
    private func move(_ source: IndexSet, _ destination: Int, within list: [QueueItem], base: Int) {
        let absolute = IndexSet(source.map { $0 + base })
        model.services.player.move(fromOffsets: absolute, toOffset: destination + base)
    }

    private func clear() {
        let player = model.services.player
        let saved = player.upcoming
        player.clearUpcoming()
        model.toast = Toast(text: String(localized: "queue.cleared"), actionTitle: "common.undo") {
            player.restoreUpcoming(saved)
        }
    }
}

/// Строка очереди: у текущего — столбики вместо обложки; меню — короткое (REWRITE §3.10.4).
private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(url: item.track.artworkURL, size: 44)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45)).frame(width: 44, height: 44)
                    MusicBars(color: .white).frame(width: 22, height: 18)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title).lineLimit(stacked ? nil : 1).foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(item.track.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(stacked ? nil : 1)
                // Крупный шрифт: длительность третьей строкой — справа названию не хватало места
                if stacked, let duration = item.track.durationLabel { durationText(duration) }
            }
            if !stacked {
                Spacer(minLength: 4)
                if let duration = item.track.durationLabel { durationText(duration) }
            }
        }
        .contentShape(Rectangle())
        #if os(visionOS)
        .hoverEffect()
        #endif
        .onTapGesture(count: 2) { if !isCurrent { model.services.player.jump(to: item.id) } }
        #if !os(macOS)
        .onTapGesture { if !isCurrent { model.services.player.jump(to: item.id) } }
        #endif
        .contextMenu {
            if !isCurrent {
                Button { model.services.player.jump(to: item.id) } label: { Label("action.play", systemImage: "play") }
                Button { model.removeFromQueue(item) } label: { Label("menu.removeFromQueue", systemImage: "minus.circle") }
            }
            Button { model.playlistPicker = PlaylistPickerRequest(tracks: [item.track]) } label: {
                Label("menu.addToPlaylist", systemImage: "text.badge.plus")
            }
            if item.track.albumId != nil {
                Button { model.openAlbum(of: item.track) } label: { Label("menu.goToAlbum", systemImage: "square.stack") }
            } else if item.track.primaryArtistId != nil {
                Button { model.openArtist(of: item.track) } label: { Label("menu.goToChannel", systemImage: "play.rectangle") }
            }
        }
        .accessibilityElement(children: .combine)
        // VoiceOver: строка — кнопка «играть с неё»; текущая отмечена и называется
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(isCurrent ? Text("queue.nowPlaying") : Text(verbatim: ""))
        .accessibilityAction { if !isCurrent { model.services.player.jump(to: item.id) } }
        .accessibilityAction(named: Text("menu.removeFromQueue")) { if !isCurrent { model.removeFromQueue(item) } }
    }

    private func durationText(_ text: String) -> some View {
        Text(text).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
    }
}

/// Столбики «играет»: низ, середина и верх того, что звучит (docs/PROMPT.md §4). При «Уменьшении движения» и на паузе
/// стоят.
struct MusicBars: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = .accentColor

    var body: some View {
        let player = model.services.player
        if reduceMotion || !player.isPlaying {
            bars((0.5, 0.8, 0.35))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                let levels = player.currentLevels()
                bars((Double(levels.low), Double(levels.mid), Double(levels.high)))
            }
        }
    }

    private func bars(_ values: (Double, Double, Double)) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width / 4
            HStack(alignment: .bottom, spacing: width / 2) {
                ForEach(Array([values.0, values.1, values.2].enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: width / 2)
                        .fill(color)
                        .frame(width: width, height: max(width, proxy.size.height * min(1, max(0.12, value))))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

extension AppModel {
    /// «Убрать из очереди» с «Отменить».
    func removeFromQueue(_ item: QueueItem) {
        let player = services.player
        guard let position = player.items.firstIndex(where: { $0.id == item.id }), position != player.index else { return }
        let before = player.items
        player.remove(item.id)
        toast = Toast(text: String(localized: "queue.removed \(item.track.title)"), actionTitle: "common.undo") {
            // Вернуть на то же место: очередь до удаления, если текущий трек тот же.
            guard player.current != nil else { return }
            let upcomingBefore = before.drop { $0.id != player.current?.id }.dropFirst()
            player.restoreUpcoming(Array(upcomingBefore))
        }
    }
}

/// Заголовок «Очередь». В листе (iPhone, Vision) — заголовок листа. В колонке справа (Mac, iPad) — строка сверху самой
/// колонки, а не `navigationTitle`: заголовок колонки окна не принадлежит (30.09.2026: окно называлось «Очередь» на любом
/// экране, пока очередь даже закрыта, — содержимое колонки остаётся в иерархии и его `navigationTitle` перебивало название
/// раздела и страницы).
private struct QueueTitle: ViewModifier {
    let inSheet: Bool

    func body(content: Content) -> some View {
        if inSheet {
            content
                .navigationTitle(Text("player.queue"))
                .inlineTitle()
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text("player.queue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Design.Space.m)
                        .padding(.vertical, Design.Space.s)
                        .accessibilityAddTraits(.isHeader)
                }
        }
    }
}

