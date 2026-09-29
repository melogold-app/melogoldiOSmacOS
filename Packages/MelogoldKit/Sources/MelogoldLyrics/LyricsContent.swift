import Foundation
import MelogoldCore

/// Что показывать по строке таблицы `lyrics`: обычный текст, разобранный синхронный (LRC и TTML с дуэтами, подпевкой
/// и словами) и его строки экрана. Всё выводится из строки, поэтому равенство — по строке.
public struct LyricsContent: Equatable, Sendable {
    public let stored: StoredLyrics?
    public let synced: SyncedLyrics?
    public let rows: [LyricRow]

    public init(_ stored: StoredLyrics?) {
        self.stored = stored
        synced = stored?.synced.flatMap { $0.isEmpty ? nil : LyricsFormats.parseSynced($0) }
        rows = synced.map(LyricRows.build) ?? []
    }

    /// Обычный текст: своя сторона или строки синхронного.
    public var plain: String? {
        if let text = stored?.plain, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return synced.map { $0.lines.map(\.text).joined(separator: "\n") }
    }

    public var hasAny: Bool { synced != nil || plain != nil }

    /// Сдвиг синхронного текста трека, мс (положительный — текст раньше).
    public var offsetMs: Int64 { stored?.offsetMs ?? 0 }

    public static func == (lhs: LyricsContent, rhs: LyricsContent) -> Bool { lhs.stored == rhs.stored }
}

extension String {
    public var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
