#if os(iOS)
import CarPlay
import MelogoldCore
import MelogoldData

/// CarPlay (docs/PROMPT.md §4 «Система», REWRITE §3.14.3 — аналог Android Auto): вкладки «Недавние», «Избранное»,
/// «Плейлисты», «Скачанное», «Для вас» и «Сейчас играет» с ♡. Нужно право CarPlay Audio от Apple (задание 0005):
/// без него система приложение в CarPlay не показывает.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        MainActor.assumeIsolated {
            let tabs = CPTabBarTemplate(templates: [
                list("carplay.recent", systemImage: "clock") { $0.library?.library.recentHistory(limit: 50).map(\.track) ?? [] },
                list("library.favorites", systemImage: "heart") { $0.library?.library.favorites() ?? [] },
                playlists(),
                list("library.downloads", systemImage: "arrow.down.circle") {
                    ($0.services.downloads?.store.entries() ?? []).filter { $0.state == .completed }.compactMap(\.track)
                },
                list("new.forYou", systemImage: "sparkles") { $0.services.forYou.picks?.tracks ?? [] },
            ])
            interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
            configureNowPlaying()
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    @MainActor
    private func list(_ title: LocalizedStringResource, systemImage: String, tracks: @escaping @MainActor (AppModel) -> [Track]) -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: title), sections: [])
        template.tabImage = UIImage(systemName: systemImage)
        reload(template, tracks: tracks)
        return template
    }

    @MainActor
    private func reload(_ template: CPListTemplate, tracks: @escaping @MainActor (AppModel) -> [Track]) {
        guard let model = AppModel.current else { return }
        let list = Array(tracks(model).prefix(CPListTemplate.maximumItemCount))
        let items = list.enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artistsText)
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    AppModel.current?.play(list, startAt: index)
                    self?.showNowPlaying()
                }
                completion()
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
    }

    @MainActor
    private func playlists() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "library.playlists"), sections: [])
        template.tabImage = UIImage(systemName: "music.note.list")
        guard let library = AppModel.current?.library?.library else { return template }
        let items = library.playlists().prefix(CPListTemplate.maximumItemCount).map { playlist -> CPListItem in
            let item = CPListItem(text: playlist.name, detailText: String(localized: "library.tracks \(playlist.trackCount)"))
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    let tracks = library.playlistTracks(playlist.id)
                    if !tracks.isEmpty {
                        AppModel.current?.play(tracks, startAt: 0)
                        self?.showNowPlaying()
                    }
                }
                completion()
            }
            return item
        }
        template.updateSections([CPListSection(items: Array(items))])
        return template
    }

    /// «Сейчас играет» системы с ♡ (`likeCommand` уже у `MPRemoteCommandCenter`), очередь и повтор.
    @MainActor
    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false
        nowPlaying.isAlbumArtistButtonEnabled = false
        let like = CPNowPlayingImageButton(image: UIImage(systemName: "heart") ?? UIImage()) { _ in
            MainActor.assumeIsolated {
                guard let model = AppModel.current, let track = model.services.player.currentTrack else { return }
                model.toggleLike(track)
            }
        }
        nowPlaying.updateNowPlayingButtons([CPNowPlayingShuffleButton { _ in
            MainActor.assumeIsolated {
                guard let player = AppModel.current?.services.player else { return }
                player.setShuffled(!player.shuffled)
            }
        }, CPNowPlayingRepeatButton { _ in
            MainActor.assumeIsolated {
                guard let player = AppModel.current?.services.player else { return }
                player.repeatMode = player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off
            }
        }, like])
    }

    @MainActor
    private func showNowPlaying() {
        guard let interfaceController, interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
#endif
