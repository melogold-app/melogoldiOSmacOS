import Foundation
import Testing
@testable import MelogoldServer

/// Вход по коду (API §4.6, задание 0017): состояния нового устройства в обоих режимах, повтор без связи, отказы,
/// отмена; приглашение вошедшего устройства — толчок SSE, карточка, истечение. Как `DeviceLinkingTest` Android.
@MainActor
@Suite("Вход по коду — NewDeviceLinker и InviteLinker")
struct DeviceLinkingTests {
    static let expires = "2026-09-23T10:05:00.000Z"

    static func created(mode: String = "request", pollSecret: String? = "mgps_secret") -> LinkCreated {
        LinkCreated(linkId: "link-1", mode: mode, serverId: "server", linkToken: "token", userCode: "K7QX-M2PD",
                    pollSecret: pollSecret, expiresAt: expires, longPollSeconds: 25)
    }

    static func poll(_ status: String, verifyCode: String? = nil) -> LinkPollResponse {
        LinkPollResponse(
            linkId: "link-1", status: status, expiresAt: expires,
            account: verifyCode == nil ? nil : LinkAccount(login: "maxim"),
            approverDevice: verifyCode == nil ? nil : LinkApprover(name: "MacBook Air", platform: "macos"),
            verifyCode: verifyCode, session: nil
        )
    }

    static func details(_ status: String, choices: [String] = []) -> LinkDetails {
        LinkDetails(
            linkId: "link-1", mode: "invite", status: status, createdAt: expires, expiresAt: expires,
            device: choices.isEmpty ? nil : LinkDeviceInfo(name: "Google Pixel 8", platform: "android", osVersion: "16",
                                                           model: nil, clientVersion: nil, alreadyLinked: false),
            sameNetwork: nil, verifyChoices: choices
        )
    }

    static func apiError(_ code: String, status: Int) -> APIError {
        APIError(status: status, code: code, message: code)
    }

    /// Ждёт условие (состояние меняется в задачах линкера), до 2 с.
    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("не дождались: \(what)")
    }

    // MARK: - Новое устройство

    @Test func requestModeGoesFromCodeToNumberToSession() async throws {
        let port = FakeNewDevicePort()
        port.polls = [.success(Self.poll("pending")), .success(Self.poll("claimed", verifyCode: "47")), .success(Self.poll("completed"))]
        port.pollGate = true
        let linker = NewDeviceLinker(port: port, retryDelay: .milliseconds(1))
        linker.showCode()
        try await until("код") {
            if case .showingCode("K7QX-M2PD", _, false) = linker.state { return true }
            return false
        }
        port.openGate()
        try await until("сеанс") { linker.state == .signedIn }
        #expect(port.knownStatuses == ["pending", "pending", "claimed"])
        #expect(port.cancelled.isEmpty)
    }

    @Test func numberCarriesTheApproverAndAccount() async throws {
        let port = FakeNewDevicePort()
        port.polls = [.success(Self.poll("claimed", verifyCode: "85"))]
        let linker = NewDeviceLinker(port: port, retryDelay: .milliseconds(1))
        linker.showCode()
        try await until("число") {
            if case .verify("85", "maxim", "MacBook Air", "macos", _, false) = linker.state { return true }
            return false
        }
    }

    @Test func noNetworkIsReconnectingNotAFailure() async throws {
        let port = FakeNewDevicePort()
        port.polls = [.failure(.network(URLError(.notConnectedToInternet))), .failure(Self.apiError("rate_limited", status: 429))]
        let linker = NewDeviceLinker(port: port, retryDelay: .milliseconds(50))
        linker.showCode()
        try await until("нет связи") {
            if case .showingCode(_, _, true) = linker.state { return true }
            return false
        }
        port.polls = [.success(Self.poll("pending"))]
        try await until("связь вернулась") {
            if case .showingCode(_, _, false) = linker.state { return true }
            return false
        }
    }

    @Test(arguments: [
        ("link_denied", 403, LinkFailure.Reason.denied),
        ("link_expired", 410, .expired),
        ("link_cancelled", 410, .cancelled),
        ("device_limit_reached", 409, .deviceLimit),
    ])
    func pollRefusalEndsTheLink(code: String, status: Int, reason: LinkFailure.Reason) async throws {
        let port = FakeNewDevicePort()
        port.polls = [.failure(Self.apiError(code, status: status))]
        let linker = NewDeviceLinker(port: port, retryDelay: .milliseconds(1))
        linker.showCode()
        try await until("отказ") {
            if case .failed(let failure, true) = linker.state { return failure.reason == reason }
            return false
        }
        linker.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(port.cancelled.isEmpty, "кончившуюся привязку не отменяют")
    }

    @Test func codeThatCannotBeGottenHasNotStarted() async throws {
        let port = FakeNewDevicePort()
        port.request = .failure(.network(URLError(.timedOut)))
        let linker = NewDeviceLinker(port: port)
        linker.showCode()
        try await until("нет связи при получении кода") {
            if case .failed(let failure, false) = linker.state { return failure.reason == .network }
            return false
        }
    }

    @Test func inviteModeShowsTheNumberAtOnceAndPollsFromClaimed() async throws {
        let port = FakeNewDevicePort()
        port.polls = [.success(Self.poll("completed"))]
        port.pollGate = true
        let linker = NewDeviceLinker(port: port, retryDelay: .milliseconds(1))
        linker.claim(userCode: "K7QXM2PD")
        try await until("число сразу") {
            if case .verify("47", "maxim", "MacBook Air", "macos", _, false) = linker.state { return true }
            return false
        }
        #expect(port.claimedCodes == ["K7QXM2PD"])
        port.openGate()
        try await until("сеанс") { linker.state == .signedIn }
        #expect(port.knownStatuses == ["claimed"])
    }

    @Test(arguments: [
        ("link_wrong_mode", 409, LinkFailure.Reason.wrongMode),
        ("link_not_found", 404, .notFound),
        ("link_already_claimed", 409, .alreadyClaimed),
        ("link_expired", 410, .expired),
        ("login_throttled", 429, .throttled),
    ])
    func refusedClaimKeepsTheField(code: String, status: Int, reason: LinkFailure.Reason) async throws {
        let port = FakeNewDevicePort()
        port.claim = .failure(Self.apiError(code, status: status))
        let linker = NewDeviceLinker(port: port)
        linker.claim(userCode: "K7QXM2PD")
        try await until("отказ claim") {
            if case .failed(let failure, false) = linker.state { return failure.reason == reason && failure.error?.code == code }
            return false
        }
    }

    @Test func cancelTellsTheServer() async throws {
        let port = FakeNewDevicePort()
        port.pollGate = true
        let linker = NewDeviceLinker(port: port)
        linker.showCode()
        try await until("код") {
            if case .showingCode = linker.state { return true }
            return false
        }
        linker.cancel()
        #expect(linker.state == .idle)
        try await until("отмена на сервере") { port.cancelled == ["mgps_secret"] }
    }

    // MARK: - Вошедшее устройство показывает код

    @Test func inviteWaitsThenShowsTheCardOnANudge() async throws {
        let port = FakeInvitePort()
        port.details = [.success(Self.details("claimed", choices: ["12", "47", "85"]))]
        let linker = InviteLinker(port: port, pollInterval: .seconds(60))
        linker.start()
        try await until("код приглашения") {
            if case .waiting("K7QX-M2PD", _) = linker.state { return true }
            return false
        }
        #expect(port.reads == 0)
        linker.nudge(linkId: "other-link")
        try await Task.sleep(for: .milliseconds(20))
        #expect(port.reads == 0, "чужая привязка не будит")
        linker.nudge(linkId: "link-1")
        try await until("карточка") {
            if case .claimed(let details) = linker.state { return details.verifyChoices == ["12", "47", "85"] }
            return false
        }
        linker.release()
        #expect(linker.state == .idle)
        try await Task.sleep(for: .milliseconds(20))
        #expect(port.cancelled.isEmpty, "после решения приглашение не отменяют")
    }

    @Test func invitePollsWithoutSSEAndReportsExpiry() async throws {
        let port = FakeInvitePort()
        port.details = [
            .failure(.network(URLError(.notConnectedToInternet))),
            .success(Self.details("pending")),
            .success(Self.details("expired")),
        ]
        let linker = InviteLinker(port: port, pollInterval: .milliseconds(5))
        linker.start()
        try await until("код устарел") {
            if case .failed(let failure, true) = linker.state { return failure.reason == .expired }
            return false
        }
        #expect(port.reads == 3)
    }

    @Test func cancelledInviteIsCancelledOnTheServer() async throws {
        let port = FakeInvitePort()
        let linker = InviteLinker(port: port, pollInterval: .seconds(60))
        linker.start()
        try await until("код приглашения") {
            if case .waiting = linker.state { return true }
            return false
        }
        linker.cancel()
        try await until("отмена") { port.cancelled == ["link-1"] }
    }

    // MARK: - Тексты

    @Test func spokenCodeReadsCharacters() {
        #expect(LinkTiming.spokenCode("K7QX-M2PD") == "K, 7, Q, X, M, 2, P, D")
    }

    @Test func statusFailures() {
        #expect(LinkFailure.status("denied")?.reason == .denied)
        #expect(LinkFailure.status("expired")?.reason == .expired)
        #expect(LinkFailure.status("cancelled")?.reason == .cancelled)
        #expect(LinkFailure.status("claimed") == nil)
        #expect(LinkFailure(Self.apiError("link_verify_mismatch", status: 409)).reason == .denied)
        #expect(LinkFailure(Self.apiError("server_busy", status: 503)).reason == .unknown)
    }
}

@MainActor
final class FakeNewDevicePort: NewDeviceLinkPort {
    var request: Result<LinkCreated, APIError> = .success(DeviceLinkingTests.created())
    var claim: Result<LinkClaimed, APIError> = .success(
        LinkClaimed(linkId: "link-1", status: "claimed", pollSecret: "mgps_claimed", account: LinkAccount(login: "maxim"),
                    approverDevice: LinkApprover(name: "MacBook Air", platform: "macos"), verifyCode: "47",
                    expiresAt: DeviceLinkingTests.expires, longPollSeconds: 25)
    )
    /// Ответы опроса по очереди; кончились — опрос висит, как long-poll, пока задачу не отменят.
    var polls: [Result<LinkPollResponse, APIError>] = []
    /// Пока закрыто, опрос висит — чтобы тест успел увидеть промежуточное состояние.
    var pollGate = false
    private(set) var knownStatuses: [String] = []
    private(set) var claimedCodes: [String] = []
    private(set) var cancelled: [String] = []

    func openGate() { pollGate = false }

    func startLinkRequest() async throws -> LinkCreated { try request.get() }

    func claimLink(userCode: String) async throws -> LinkClaimed {
        claimedCodes.append(userCode)
        return try claim.get()
    }

    func pollLink(pollSecret: String, knownStatus: String) async throws -> LinkPollResponse {
        while pollGate || polls.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        knownStatuses.append(knownStatus)
        return try polls.removeFirst().get()
    }

    func cancelLinkRequest(pollSecret: String) async { cancelled.append(pollSecret) }
}

@MainActor
final class FakeInvitePort: InvitePort {
    var details: [Result<LinkDetails, APIError>] = []
    private(set) var reads = 0
    private(set) var cancelled: [String] = []

    func createLinkInvite() async throws -> LinkCreated { DeviceLinkingTests.created(mode: "invite", pollSecret: nil) }

    func link(_ linkId: String) async throws -> LinkDetails {
        while details.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        reads += 1
        return try details.removeFirst().get()
    }

    func cancelLink(_ linkId: String) async { cancelled.append(linkId) }
}
