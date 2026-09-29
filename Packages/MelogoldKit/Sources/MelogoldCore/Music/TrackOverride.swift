import Foundation

/// Своё название, исполнитель и альбом трека поверх метаданных YouTube (задание 0014): альбом, собранный из
/// разрозненных видео, выглядит одним альбомом на всех устройствах. Поле без правки — `nil` (показывается как на
/// YouTube); правка без полей — её нет.
public struct TrackOverride: Equatable, Hashable, Sendable {
    public var title: String?
    public var artistsText: String?
    public var albumTitle: String?

    /// Самое длинное поле, которое хранит сервер (API §11), в единицах UTF-16.
    public static let maxLength = 500

    public init(title: String? = nil, artistsText: String? = nil, albumTitle: String? = nil) {
        self.title = Self.clean(title)
        self.artistsText = Self.clean(artistsText)
        self.albumTitle = Self.clean(albumTitle)
    }

    public var isEmpty: Bool { title == nil && artistsText == nil && albumTitle == nil }

    /// Поле, как его хранит сервер (API §4.8): без пробелов по краям, не длиннее 500 единиц UTF-16, пустое — без правки.
    public static func clean(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.utf16.count > maxLength else { return text }
        var end = text.utf16.index(text.utf16.startIndex, offsetBy: maxLength)
        // Не разрывать суррогатную пару
        if UTF16.isTrailSurrogate(text.utf16[end]) { end = text.utf16.index(before: end) }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Трек, как его показывать: правленые поля поверх; правка исполнителя убирает карту исполнителей YouTube (она
    /// вела бы на чужую страницу), правка альбома — ссылку на альбом YouTube.
    public func apply(to track: Track) -> Track {
        var shown = track
        if let title { shown.title = title }
        if let artistsText {
            shown.artistsText = artistsText
            shown.artists = []
        }
        if let albumTitle {
            shown.albumTitle = albumTitle
            shown.albumId = nil
        }
        return shown
    }
}

/// Закреплённый текст песни (задание 0015): ссылка на найденный текст у поставщика, одинаковая на всех устройствах.
/// Сервер хранит ссылку, а не текст.
public struct LyricsPin: Equatable, Hashable, Sendable {
    /// `youtube_music`, `lrclib` или `kugou` — слова сервера.
    public var source: String
    /// Номер текста у поставщика: запись LrcLib, browseId текста YouTube Music (`MPLYt…`), `<id>:<accesskey>` KuGou.
    public var ref: String
    /// Сдвиг «позже» синхронного текста, мс.
    public var startTimeMs: Int64?

    public static let sources: Set<String> = ["youtube_music", "lrclib", "kugou"]
    public static let refMaxLength = 200

    public init?(source: String, ref: String, startTimeMs: Int64? = nil) {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.sources.contains(source), !trimmed.isEmpty, trimmed.utf16.count <= Self.refMaxLength else { return nil }
        self.source = source
        self.ref = trimmed
        self.startTimeMs = startTimeMs.flatMap { (0 ... 86_400_000).contains($0) ? $0 : nil }
    }
}
