import SwiftUI
import MelogoldCore

/// Пункты меню трека — порядок по REWRITE §3.11.3, одинаково на всех клиентах (docs/PROMPT.md §5.8). Пункты
/// библиотеки («В Избранное», «Добавить в плейлист…», «Скачать», «Не показывать этот трек») — со срезом 4.
struct TrackMenuItems: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        Section {
            Button { model.playNext([track]) } label: {
                Label("menu.playNext", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { model.enqueue([track]) } label: {
                Label("menu.addToQueue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
        Section {
            Button { model.searchOtherVersions(of: track) } label: {
                Label("menu.otherVersions", systemImage: "square.on.square")
            }
            Button { model.startRadio(track) } label: {
                Label("menu.startRadio", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        Section {
            if track.albumId != nil {
                Button { model.openAlbum(of: track) } label: {
                    Label("menu.goToAlbum", systemImage: "square.stack")
                }
            }
            if track.primaryArtistId != nil {
                Button { model.openArtist(of: track) } label: {
                    if track.isVideo && track.videoType != VideoType.video {
                        Label("menu.goToChannel", systemImage: "play.rectangle")
                    } else {
                        Label("menu.goToArtist", systemImage: "music.mic")
                    }
                }
            }
        }
        Section {
            ShareLink(item: ShareLinks.track(track)) {
                Label("menu.share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Кнопка «…» в строке трека (iPhone, iPad, Vision). На Mac меню — правым щелчком.
struct TrackMenuButton: View {
    let track: Track

    var body: some View {
        #if !os(macOS)
        Menu {
            TrackMenuItems(track: track)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("menu.more"))
        #endif
    }
}

extension AppModel {
    /// «Другие версии»: поиск по названию и исполнителю.
    func searchOtherVersions(of track: Track) {
        let query = [track.title, track.artistsText].compactMap { $0 }.joined(separator: " ")
        section = .search
        routes[.search] = []
        searchQuery = query
        search.submit(query)
    }
}

/// Нажатие по строке и меню строк в `List` (docs/PROMPT.md §5.4, §5.8): на iPhone, iPad и Vision нажатие играет
/// или открывает, долгое нажатие — меню; на Mac щелчок выделяет, двойной щелчок или Return играет, правый щелчок —
/// меню. Строки помечаются `tag(<id>)`, `target` переводит id в действие.
struct RowActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: (String) -> RowTarget?

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let target = target(id) {
                switch target {
                case .list(let tracks, let index): TrackMenuItems(track: tracks[index])
                case .single(let track): TrackMenuItems(track: track)
                case .open, .mix: EmptyView()
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let target = target(id) else { return }
            model.activate(target)
        }
    }
}

extension View {
    func rowActions(_ target: @escaping (String) -> RowTarget?) -> some View {
        modifier(RowActions(target: target))
    }
}

/// Id строки: раздел страницы и ключ элемента — один трек может стоять в двух разделах.
enum RowID {
    static func make(_ section: String, _ key: String) -> String { section + "|" + key }

    static func split(_ id: String) -> (section: String, key: String)? {
        guard let bar = id.firstIndex(of: "|") else { return nil }
        return (String(id[..<bar]), String(id[id.index(after: bar)...]))
    }
}
