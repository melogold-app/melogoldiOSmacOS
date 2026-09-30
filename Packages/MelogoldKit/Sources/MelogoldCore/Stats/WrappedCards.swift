import Foundation

/// Карточки «Итогов года» (задание 0018): минуты за год; трек года; топ-5 исполнителей; топ-5 треков; любимый месяц и время
/// суток; открытия. Карточка, для которой в году нет данных, не показывается.
public enum WrappedCard: String, CaseIterable, Sendable {
    case minutes, trackOfYear, topArtists, topTracks, favoriteTime, discoveries

    /// Сколько строк у карточек топов.
    public static let topShown = 5
}

extension ListeningStats {
    /// Карточки года по порядку; в году без прослушиваний — пусто (экран говорит «За этот год пока нечего показать»).
    public var wrappedCards: [WrappedCard] {
        guard !isEmpty else { return [] }
        var cards: [WrappedCard] = [.minutes]
        if !topTracks.isEmpty { cards.append(.trackOfYear) }
        if !topArtists.isEmpty { cards.append(.topArtists) }
        if !topTracks.isEmpty { cards.append(.topTracks) }
        cards.append(.favoriteTime)
        if (discoveries?.count ?? 0) > 0 { cards.append(.discoveries) }
        return cards
    }

    /// Минут музыки за период, округлённо; не меньше единицы, если что-то играло.
    public var totalMinutes: Int {
        guard totalMs > 0 else { return 0 }
        return max(1, Int((Double(totalMs) / 60_000).rounded()))
    }

    /// Любимый месяц года — месяц с самым большим временем (`bars` года — 12 месяцев).
    public var favoriteMonth: Date? { window.period == .year ? busiestBar?.date : nil }
}
