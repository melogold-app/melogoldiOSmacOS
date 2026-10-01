import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Действия меню Mac и панели воспроизведения (docs/PROMPT.md §5.4): «К текущему треку», перемотка на 10 секунд,
/// показ текста, очереди и «Сейчас играет». Меню зовёт их же, что и кнопки окна, — у каждого одно поведение.
extension AppModel {
    /// «Сведения о треке…» (⌘I) — играющий трек.
    func showCurrentTrackDetails() {
        trackDetails = services.player.currentTrack
    }

    /// «К текущему треку» (⌘L): туда, откуда начали играть (раздел и стек), иначе альбом трека, иначе исполнитель,
    /// иначе «Сейчас играет». Музыка не прерывается.
    func goToCurrentTrack() {
        guard let track = services.player.currentTrack else { return }
        showNowPlaying = false
        if let source = playSource {
            section = source.section
            routes[source.section] = source.routes
        } else if let albumId = track.albumId {
            open(.album(albumId), in: section)
        } else if let artistId = track.primaryArtistId {
            open(.artist(artistId), in: section)
        } else {
            showNowPlaying = true
        }
    }

    /// Перемотка на `seconds` (отрицательное — назад); не выходит за границы трека.
    /// «Без звука» (⌥⌘↓): громкость в ноль и обратно — к той, что была.
    func toggleMute() {
        let player = services.player
        if player.volume > 0 {
            volumeBeforeMute = player.volume
            player.volume = 0
        } else {
            player.volume = volumeBeforeMute
        }
    }

    /// «Переключить повтор» (⌥⌘R): выключен → очередь → трек → выключен, как кнопка в панели.
    func cycleRepeat() {
        let player = services.player
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    func seek(by seconds: Double) {
        let player = services.player
        guard player.currentTrack != nil, player.duration > 0 else { return }
        player.seek(to: min(player.duration, max(0, player.position + seconds)))
    }

    /// Текст песни показан: «Сейчас играет» открыт с текстом.
    var lyricsShown: Bool { showNowPlaying && lyricsVisible }

    /// «Показать текст» и «Скрыть текст» (⌥⌘L): текст живёт в «Сейчас играет».
    func toggleLyrics() {
        if lyricsShown {
            lyricsVisible = false
        } else {
            lyricsVisible = true
            showNowPlaying = true
        }
    }

    /// «Показать очередь» и «Скрыть очередь» (⌥⌘U): колонка справа; пока открыт «Сейчас играет», она внутри него.
    func toggleQueue() {
        queueVisible.toggle()
    }

    /// «Показать Сейчас играет» и «Скрыть» (⌥⌘N).
    func toggleNowPlaying() {
        guard services.player.currentTrack != nil else { return }
        showNowPlaying.toggle()
    }
}
