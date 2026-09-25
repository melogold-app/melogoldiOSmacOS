import Foundation
import Testing
import MelogoldCore
@testable import MelogoldInnerTube

@Suite("Клиент InnerTube: язык, регион, обложки")
struct ClientTests {
    @Test func russianLocaleGivesRuAndCountry() {
        let (language, region) = InnerTubeClient.localeFrom(preferredLanguages: ["ru-RU"], locale: Locale(identifier: "ru_RU"))
        #expect(language == "ru")
        #expect(region == "RU")
    }

    @Test func kazakhstanRussian() {
        let (language, region) = InnerTubeClient.localeFrom(preferredLanguages: ["ru-KZ"], locale: Locale(identifier: "ru_KZ"))
        #expect(language == "ru")
        #expect(region == "KZ")
    }

    @Test func unsupportedLanguageFallsBackToEnglish() {
        let (language, _) = InnerTubeClient.localeFrom(preferredLanguages: ["eo"], locale: Locale(identifier: "eo"))
        #expect(language == "en")
    }

    @Test func traditionalChinese() {
        let (language, _) = InnerTubeClient.localeFrom(preferredLanguages: ["zh-Hant-TW"], locale: Locale(identifier: "zh_TW"))
        #expect(language == "zh-TW")
    }

    @Test func thumbnails() {
        #expect(Thumbnails.sized("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj", px: 544) == "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
        #expect(Thumbnails.sized("https://i.ytimg.com/vi/xtxjm7ciwmc/hqdefault.jpg?sqp=1", px: 120) == "https://i.ytimg.com/vi/xtxjm7ciwmc/mqdefault.jpg")
        #expect(Thumbnails.sized("https://i.ytimg.com/vi/xtxjm7ciwmc/hqdefault.jpg", px: 720) == "https://i.ytimg.com/vi/xtxjm7ciwmc/hq720.jpg")
        #expect(Thumbnails.sized("//yt3.ggpht.com/x=s88", px: 88) == "https://yt3.ggpht.com/x=w88-h88-l90-rj")
        #expect(Thumbnails.isWide("https://i.ytimg.com/vi/xtxjm7ciwmc/mqdefault.jpg"))
    }

    @Test func durations() {
        #expect(Durations.parse("4:45") == 285_000)
        #expect(Durations.parse("1:02:10") == 3_730_000)
        #expect(Durations.parse("LIVE") == nil)
        #expect(Durations.format(285_000) == "4:45")
        #expect(Durations.format(3_730_000) == "1:02:10")
    }
}
