import Foundation
import Testing
import MelogoldInnerTube
@testable import MelogoldPlayback

/// Задание 0010 §2.3: итог диагноза по порядку правил.
@Suite("Трек закрыт в стране — итог")
struct GeoDiagnosisTests {

    @Test func countryOutsideTheListIsGeoWithTheCount() throws {
        let playability = Playability(status: "UNPLAYABLE", reason: "Video unavailable", country: "RU",
                                      availableCountries: (1 ... 122).map { "X\($0)" })
        let result = try #require(StreamError.diagnosed(playability, streamMessage: "VISIONOS: UNPLAYABLE"))
        #expect(result.kind == .geo && result.country == "RU" && result.availableCountries == 122)
        #expect(result.isFinal)
        let failure = PlaybackFailure(result, videoId: "cYKAr38pZcY")
        #expect(failure.kind == .geo && failure.country == "RU" && failure.availableCountries == 122)
    }

    @Test func openHereKeepsTheOldError() {
        let playability = Playability(status: "OK", reason: nil, country: "DE", availableCountries: ["DE", "RU"])
        #expect(StreamError.diagnosed(playability, streamMessage: "VISIONOS: some bot check") == nil)
    }

    @Test func phrasesDecideWithoutTheList() {
        let none = Playability(status: "UNPLAYABLE", reason: nil, country: "RU", availableCountries: [])
        let geo = StreamError.diagnosed(none, streamMessage: "The uploader has not made this video available in your country")
        #expect(geo?.kind == .geo && geo?.country == "RU" && geo?.availableCountries == nil)
        #expect(StreamError.diagnosed(none, streamMessage: "Sign in to confirm your age")?.kind == .age)
        #expect(StreamError.diagnosed(none, streamMessage: "This video has been removed by the uploader")?.kind == .unavailable)
        #expect(StreamError.diagnosed(none, streamMessage: "Private video")?.kind == .unavailable)
        #expect(StreamError.diagnosed(none, streamMessage: "something else") == nil)
    }
}
