import Foundation
import Testing
@testable import MelogoldInnerTube

/// Задание 0010: страна из `visitorData` и диагноз ответа `player` клиента WEB.
@Suite("Трек закрыт в стране — диагноз YouTube")
struct PlayabilityTests {
    @Test func countryFromVisitorData() {
        #expect(VisitorData.country("CgtRTWpHWl9XellHZyjBhN7VBjIoCgJOTBIiEh4SHAsMDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicgYw%3D%3D") == "NL")
        #expect(VisitorData.country("Cgs4bmZBZU9NZ2hGVSiLhd7VBjIOCgJERRIIEgAgRlICCHE6AggBYuACCt0CMTguWVRFPUdHUjNxZUdSUDVfUTFNMXVSVVVVYVRs") == "DE")
    }

    @Test(arguments: [nil, "", "not base64 at all!", "CgtRTWpHWl9XellHZw"])
    func nothingUsable(_ value: String?) {
        #expect(VisitorData.country(value) == nil)
    }

    @Test func parsesTheWebAnswer() throws {
        let json = #"{"responseContext":{"visitorData":"CgtRTWpHWl9XellHZyjBhN7VBjIoCgJOTBIiEh4SHAsMDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicgYw%3D%3D"},"playabilityStatus":{"status":"UNPLAYABLE","reason":"The uploader has not made this video available in your country"},"microformat":{"playerMicroformatRenderer":{"availableCountries":["DE","FR","US"]}}}"#
        let playability = Playability.parse(try JSON.parse(Data(json.utf8)))
        #expect(playability.status == "UNPLAYABLE" && playability.country == "NL" && playability.availableCountries == ["DE", "FR", "US"])
        #expect(playability.isBlockedHere)
        #expect(!Playability(status: "OK", reason: nil, country: "DE", availableCountries: ["DE"]).isBlockedHere)
        #expect(!Playability(status: "OK", reason: nil, country: nil, availableCountries: ["DE"]).isBlockedHere)
    }
}
