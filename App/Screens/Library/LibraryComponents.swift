import SwiftUI
import MelogoldCore
import MelogoldData

/// «312 треков · 18 ч 40 мин» — число треков и общая длительность (REWRITE §3.2.2).
enum LibraryText {
    static func summary(_ tracks: [Track]) -> String {
        let count = String(localized: "library.tracks \(tracks.count)")
        let seconds = tracks.reduce(Int64(0)) { $0 + ($1.durationMs ?? 0) } / 1000
        guard seconds > 0 else { return count }
        return count + " · " + duration(seconds)
    }

    /// «12 ч 40 мин», «45 мин».
    static func duration(_ seconds: Int64) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds).formatted(.units(allowed: allowed, width: .abbreviated))
    }

    static func playTime(_ ms: Int64) -> String {
        duration(max(60, ms / 1000))
    }
}

/// Шапка списка треков библиотеки: сводка и «Слушать · Перемешать», у скачиваемых — «Скачать».
struct TrackListHeader<Extra: View>: View {
    let summary: String
    let play: () -> Void
    let shuffle: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                PlayButton(action: play)
                ShuffleButton(action: shuffle)
                extra()
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
    }
}

extension TrackListHeader where Extra == EmptyView {
    init(summary: String, play: @escaping () -> Void, shuffle: @escaping () -> Void) {
        self.init(summary: summary, play: play, shuffle: shuffle, extra: { EmptyView() })
    }
}

/// «Скачать» коллекции (Избранное, плейлист, альбом): «k из n», затем «Скачано»; нажатие по «Скачано» спрашивает
/// «Удалить загрузку?» (REWRITE §3.2.2).
struct CollectionDownloadButton: View {
    @Environment(AppModel.self) private var model
    let kind: DownloadCollection.Kind
    let key: String
    let title: String?
    /// Перед загрузкой коллекции (альбом сохраняется в библиотеку).
    var prepare: (() -> Void)?
    @State private var confirmRemove = false

    var body: some View {
        let _ = model.library?.downloadsRevision
        let store = model.services.downloads?.store
        let active = store?.isCollection(kind, key: key) == true
        let collection = active ? store?.collections().first { $0.kind == kind && $0.key == key } : nil
        Button {
            if active {
                confirmRemove = true
            } else {
                prepare?()
                model.services.downloads?.setCollection(kind, key: key, title: title, downloading: true)
            }
        } label: {
            if let collection, collection.total > 0, collection.done >= collection.total {
                Label("download.done", systemImage: "arrow.down.circle.fill")
            } else if let collection {
                Label("download.progress \(collection.done) \(collection.total)", systemImage: "arrow.down.circle.dotted")
            } else {
                Label("menu.download", systemImage: "arrow.down.circle")
            }
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(Text(active ? "download.done" : "menu.download"))
        .confirmationDialog(Text("download.removeCollection"), isPresented: $confirmRemove) {
            Button("menu.removeDownload", role: .destructive) {
                model.services.downloads?.setCollection(kind, key: key, title: title, downloading: false)
            }
        }
        .disabled(model.services.downloads == nil)
    }
}

/// Меню сортировки списка: выбор сохраняется в `sort.<list>`.
struct SortMenu<Option: Hashable & RawRepresentable>: View where Option.RawValue == String {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> LocalizedStringResource

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            } label: {
                Text("library.sort")
            }
            .pickerStyle(.inline)
        } label: {
            Label("library.sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

extension AppSettings {
    /// Сохранённый выбор сортировки списка или вариант по умолчанию.
    func sortOption<Option: RawRepresentable>(_ list: String, default value: Option) -> Option where Option.RawValue == String {
        Option(rawValue: sort(for: list)) ?? value
    }
}

/// Фильтр по названию и исполнителю (REWRITE §3.2.2).
func matches(_ track: Track, _ filter: String) -> Bool {
    let text = filter.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return true }
    return track.title.localizedCaseInsensitiveContains(text) || (track.artistsText ?? "").localizedCaseInsensitiveContains(text)
}

/// Пусто или фильтр без совпадений — `ContentUnavailableView` в строке списка.
struct EmptyRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    var description: LocalizedStringResource?
    var filter: String = ""

    var body: some View {
        Group {
            if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView {
                    Label(title, systemImage: systemImage)
                } description: {
                    if let description { Text(description) }
                }
            } else {
                ContentUnavailableView.search(text: filter)
            }
        }
        .listRowSeparator(.hidden)
    }
}

/// Обложка своего плейлиста: мозаика из 4 обложек или своя картинка (REWRITE §3.8.1).
struct PlaylistArtwork: View {
    let playlist: LibraryPlaylist
    var size: CGFloat

    var body: some View {
        Group {
            if playlist.mosaic.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(playlist.mosaic[0], half)
                        tile(playlist.mosaic[1], half)
                    }
                    HStack(spacing: 0) {
                        tile(playlist.mosaic[2], half)
                        tile(playlist.mosaic[3], half)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.12), style: .continuous))
            } else if let url = playlist.thumbnailUrl ?? playlist.mosaic.first {
                ArtworkView(url: url, size: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: max(4, size * 0.12), style: .continuous).fill(.quaternary)
                    Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func tile(_ url: String, _ side: CGFloat) -> some View {
        ArtworkView(url: url, size: side, shape: .square)
    }
}
