import Foundation

/// Правила действий с выделенными треками (задание 0013, как `Selection.kt` Android и `TrackActions` Windows).
public enum SelectionRules {
    /// Выделенные треки списка в порядке списка, без повторов: «Слушать» и «Новый плейлист» берут их так, а не в порядке
    /// нажатий.
    public static func selected(in list: [Track], ids: Set<String>) -> [Track] {
        var seen = Set<String>()
        return list.filter { ids.contains($0.videoId) && seen.insert($0.videoId).inserted }
    }

    /// Альбом, общий для всех (название по умолчанию у нового плейлиста и у «Указать альбом…»); `nil` — у кого-то его нет
    /// или они разные.
    public static func commonAlbum(_ albums: [String?]) -> String? {
        var names = Set<String>()
        for album in albums {
            guard let name = album?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            names.insert(name)
        }
        return names.count == 1 ? names.first : nil
    }

    /// Альбом выделенного, каким его показывают строки (своя правка, иначе YouTube).
    public static func commonAlbum(of tracks: [Track]) -> String? {
        commonAlbum(tracks.map(\.albumTitle))
    }

    /// Что запускает «Скачать» для выделенного: трансляции не скачиваются, а скачанное и то, что уже скачивается
    /// (`busy` — их `videoId`), пропускается; неудавшееся скачивается заново.
    public static func toDownload(_ tracks: [Track], busy: Set<String>) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { $0.videoType != VideoType.live && !busy.contains($0.videoId) && seen.insert($0.videoId).inserted }
    }
}
