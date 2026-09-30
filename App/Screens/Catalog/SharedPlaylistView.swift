import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldServer

/// «Плейлист по ссылке» (задание 0019, API §4.11): название и треки снимка, который кто-то прислал ссылкой Melogold, —
/// слушать, перемешать или сохранить в Библиотеку своим плейлистом. Снимок читается без входа и с сервера из ссылки: он
/// может быть не тем, что выбран в Настройках, поэтому под названием — сервер. Без кнопки ничего не сохраняется.
struct SharedPlaylistView: View {
    @Environment(AppModel.self) private var model
    let server: String
    let shareId: String

    private enum LoadState {
        case loading
        case loaded(ShareDto)
        /// `404 share_not_found`: ссылка удалена или неверна.
        case gone
        /// Сервер ссылки не ответил.
        case offline
    }

    @State private var state = LoadState.loading
    @State private var saved: Int64?

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingView()
            case .gone:
                ContentUnavailableView {
                    Label("shared.gone", systemImage: "link.badge.plus")
                        .symbolVariant(.slash)
                }
            case .offline:
                ContentUnavailableView {
                    Label("shared.offline", systemImage: "wifi.slash")
                } actions: {
                    Button("common.retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded(let share):
                content(share)
            }
        }
        .navigationTitle(Text("shared.title"))
        .inlineTitle()
        .task { await load() }
    }

    private func content(_ share: ShareDto) -> some View {
        let tracks = share.playlistTracks
        return DetailPage(title: share.name, fullBleedHeader: DetailLayout.compactCover == .hero,
                          rowIds: tracks.map { RowID.make("t", $0.videoId) }, collectionName: share.name) {
            CollectionHeader(artworkURL: tracks.first?.thumbnailUrl, style: DetailLayout.compactCover, title: share.name) {
                HeaderSubtitle {
                    Text(verbatim: LibraryText.summary(tracks))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("shared.foreignServer \(ServerHost.display(server))")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("shared.host")
                }
            } actions: {
                PlayButton { model.playAll(tracks, shuffled: false) }
                ShuffleButton { model.playAll(tracks, shuffled: true) }
            }
            saveButton(share, tracks)
        } rows: {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackListRow(track: track, target: .list(tracks, index))
                    .tag(RowID.make("t", track.videoId))
            }
        } target: { id in
            guard let (_, key) = RowID.split(id), let index = tracks.firstIndex(where: { $0.videoId == key }) else { return nil }
            return .list(tracks, index)
        }
    }

    private func saveButton(_ share: ShareDto, _ tracks: [Track]) -> some View {
        Button {
            let name = share.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = model.createPlaylist(name: name.isEmpty ? share.name : name, tracks: tracks)
            saved = id
            if let id {
                model.toast = Toast(text: String(localized: "shared.saved"), actionTitle: "selection.open") { model.open(.localPlaylist(id)) }
            } else {
                model.toast = Toast(text: String(localized: "shared.saveFailed"))
            }
        } label: {
            Label(saved == nil ? "shared.save" : "shared.saved", systemImage: saved == nil ? "plus.rectangle.on.folder" : "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .frame(maxWidth: 420)
        .headerInset()
        .disabled(saved != nil || tracks.isEmpty)
        .accessibilityIdentifier("shared.save")
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await model.account.publicShare(server: server, id: shareId))
        } catch let error as APIError {
            state = error.status == 404 || error.code == "share_not_found" || error.code == "invalid_request" ? .gone : .offline
        } catch {
            state = .offline
        }
    }
}
