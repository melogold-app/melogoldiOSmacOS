import Foundation
import MelogoldPlayback

/// Тексты «трек закрыт в стране» (задание 0010): страна — по коду на языке интерфейса («Россия», «Russia»), число
/// стран — с формами множественного числа. Страна неизвестна — `nil`: остаётся общий текст «Недоступно в вашей стране».
enum GeoText {
    /// Карточка ошибки: «Недоступно в стране «Россия»: YouTube считает, что вы там, а правообладатель открыл трек в 122
    /// других странах. С VPN выберите сервер другой страны…».
    static func message(_ failure: PlaybackFailure) -> String? {
        guard failure.kind == .geo, let country = countryName(failure.country) else { return nil }
        if let count = failure.availableCountries, count > 0 {
            let countries = String(localized: "player.error.geo.countries \(count)")
            return String(localized: "player.error.geo.opened \(country) \(countries)")
        }
        return String(localized: "player.error.geo.closed \(country)")
    }

    /// Часы — коротко: «Недоступно в стране «Россия»».
    static func short(_ failure: PlaybackFailure) -> String? {
        guard failure.kind == .geo, let country = countryName(failure.country) else { return nil }
        return String(localized: "player.error.geo.short \(country)")
    }

    static func countryName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }
}
