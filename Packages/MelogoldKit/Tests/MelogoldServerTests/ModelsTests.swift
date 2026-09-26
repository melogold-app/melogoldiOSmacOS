import Foundation
import Testing
@testable import MelogoldServer

/// Примеры ответов из API.md сервера разбираются моделями клиента.
@Suite("Модели API — примеры API.md")
struct ModelsTests {
    @Test func serverInfo() throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(Self.serverInfo.utf8))
        #expect(info.software == "melogold-server")
        #expect(info.registrationOpen)
        #expect(info.features.sync?.protocolVersion == 1)
        #expect(info.features.deviceLinking?.modes == ["request", "invite"])
        #expect(info.features.registrationPow?.version == 1)
        #expect(info.limits?.account?.maxDevices == 20)
        #expect(info.limits?.account?.password?.minLength == 8)
    }

    @Test func authSession() throws {
        let session = try JSONDecoder().decode(AuthSession.self, from: Data(Self.register.utf8))
        #expect(session.user.login == "maxim")
        #expect(session.device.isCurrent)
        #expect(session.recoveryCode == "7KQ2-MX9D-4TNP-B8RW-3HZF")
        #expect(IsoTime.date(session.tokens.accessTokenExpiresAt) != nil)
    }

    @Test func devices() throws {
        let list = try JSONDecoder().decode(DeviceListResponse.self, from: Data(Self.devices.utf8))
        #expect(list.devices.count == 1)
        #expect(list.maxDevices == 20)
    }

    @Test func errorEnvelope() throws {
        let error = try JSONDecoder().decode(ErrorResponse.self, from: Data(Self.error.utf8)).error(status: 409)
        #expect(error.code == "device_limit_reached")
        #expect(error.deviceLimit == 20)
        #expect(error.deviceCount == 20)
    }

    @Test func isoTime() throws {
        let date = try #require(IsoTime.date("2026-09-23T10:00:00.000Z"))
        #expect(IsoTime.string(date) == "2026-09-23T10:00:00.000Z")
        #expect(IsoTime.date("2026-09-23T10:00:00Z") == date)
    }

    /// Каждая миллисекунда секунды туда и обратно — ровно она же (через `Double` половина уходила на 1 мс раньше).
    @Test func isoTimeKeepsEveryMillisecond() {
        for ms in Int64(1_790_157_600_000) ..< 1_790_157_601_000 {
            let text = IsoTime.string(epochMs: ms)
            #expect(text.hasSuffix(String(format: ".%03dZ", Int(ms % 1000))), "\(ms) → \(text)")
            #expect(IsoTime.epochMs(text) == ms, "\(ms) → \(text)")
        }
        #expect(IsoTime.string(epochMs: 1_790_157_600_001) == "2026-09-23T10:00:00.001Z")
        #expect(IsoTime.string(epochMs: 0) == "1970-01-01T00:00:00.000Z")
        #expect(IsoTime.string(epochMs: -1) == "1969-12-31T23:59:59.999Z")
        #expect(IsoTime.string(Date(timeIntervalSince1970: 1_790_157_600.001)) == "2026-09-23T10:00:00.001Z")
    }

    @Test func renameEncodesNullName() throws {
        let json = String(decoding: try JSONEncoder().encode(RenameDeviceRequest(name: nil, password: nil)), as: UTF8.self)
        #expect(json == #"{"name":null}"#)
    }

    static let serverInfo = #"""
{"software":"melogold-server","version":"0.1.0","revision":"3f9c2ab","apiVersion":1,"minApiVersion":1,
 "serverId":"6f1c2c0e-8a3b-4f7e-9c1d-2b5e7a9f0c11","instanceName":"Melogold","publicUrl":"https://api.melogold.app",
 "secureTransport":true,"registration":"open",
 "features":{"sync":{"protocol":1,"minProtocol":1,"kinds":["like.set","bookmark.set","playlist.create","playlist.update","playlist.delete","playlist.items.add","playlist.item.remove","playlist.item.move","playlist.items.replace","playlist.import","play.add","play.baseline","history.clear","history.forget"],"streams":["library","history"]},
  "playback":{"version":1},"deviceLinking":{"version":1,"modes":["request","invite"],"ttlSeconds":300,"longPollSeconds":25},
  "recoveryCode":{"version":1},"export":{"version":1},"accountDeletion":{"version":1},"registrationPow":{"version":1},"lyrics":{"version":1}},
 "limits":{"sync":{"maxOpsPerRequest":500,"maxBodyBytes":4194304,"maxWorkUnitsPerRequest":20000,"defaultPageSize":500,"maxPageSize":2000,"maxVideoIdsPerAdd":500,"maxVideoIdsPerList":10000,"maxBaselineEntries":500,"maxIncludeKeys":1000,"maxPlaylists":1000,"maxPlaylistItems":10000,"maxItemsTotal":100000,"maxLikes":100000,"maxBookmarksPerType":20000,"maxTracks":150000,"maxPlayStats":100000,"maxPlayEvents":60000,"playAddPerHour":2000},
  "history":{"retentionDays":400,"maxEvents":50000,"mergeUploadMax":20000},
  "playback":{"queueMax":200,"maxBodyBytes":131072},
  "account":{"maxDevices":20,"newDeviceRestrictHours":24,"login":{"minLength":3,"maxLength":32,"pattern":"^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$"},"password":{"minLength":8,"maxLength":128}}},
 "links":{"source":"https://github.com/melogold-app/melogoldServer/tree/3f9c2ab1d0e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8","privacy":"https://melogold.app/privacy","contact":null},
 "serverTime":"2026-09-23T10:00:00.000Z"}
"""#

    static let register = #"""
{"user":{"id":"0c3f6a2e-5d1b-4c7a-9e8f-1a2b3c4d5e6f","login":"maxim","createdAt":"2026-09-23T10:00:00.000Z","passwordChangedAt":"2026-09-23T10:00:00.000Z","recoveryCodeStatus":{"createdAt":"2026-09-23T10:00:00.000Z","confirmed":false}},
 "device":{"id":"9b1e2f4a-7c3d-4e5f-8a9b-0c1d2e3f4a5b","name":"Google Pixel 8","reportedName":"Google Pixel 8","customName":null,"platform":"android","osVersion":"16","model":"Google Pixel 8","clientVersion":"1.3.0","linkedVia":"register","linkedByDeviceId":null,"createdAt":"2026-09-23T10:00:00.000Z","lastSeenAt":"2026-09-23T10:00:00.000Z","lastSyncAt":null,"recentUntil":null,"isCurrent":true},
 "tokens":{"accessToken":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.c2ln","accessTokenExpiresAt":"2026-09-23T10:15:00.000Z","refreshToken":"mgrt1.eyJ0eXAiOiJyZWZyZXNoIn0.Xk3q","refreshTokenExpiresAt":"2026-12-22T10:00:00.000Z"},
 "serverId":"6f1c2c0e-8a3b-4f7e-9c1d-2b5e7a9f0c11","serverTime":"2026-09-23T10:00:00.000Z","recoveryCode":"7KQ2-MX9D-4TNP-B8RW-3HZF","signedOutDevices":0}
"""#

    static let devices = #"""
{"devices":[{"id":"9b1e2f4a-7c3d-4e5f-8a9b-0c1d2e3f4a5b","name":"Google Pixel 8","reportedName":"Google Pixel 8","customName":null,"platform":"android","osVersion":"16","model":"Google Pixel 8","clientVersion":"1.3.0","linkedVia":"register","linkedByDeviceId":null,"createdAt":"2026-09-23T10:00:00.000Z","lastSeenAt":"2026-09-23T10:05:00.000Z","lastSyncAt":"2026-09-23T10:04:00.000Z","recentUntil":null,"isCurrent":true}],"maxDevices":20}
"""#

    static let error = #"""
{"statusCode":409,"error":"Device limit reached","message":"Device limit reached","code":"device_limit_reached","deviceLimit":20,"deviceCount":20}
"""#
}
