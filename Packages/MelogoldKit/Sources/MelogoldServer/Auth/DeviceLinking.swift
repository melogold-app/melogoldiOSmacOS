import Foundation
import Observation
import MelogoldCore

// Вход по коду (API §4.6, задание 0017), как `sync/DeviceLinking.kt` Android. Две стороны и два режима:
//
//   режим `request`: НОВОЕ устройство показывает код, вошедшее вводит его («Добавить устройство») и выбирает число;
//   режим `invite`:  ВОШЕДШЕЕ устройство показывает код, новое вводит его и показывает число.
//
// `NewDeviceLinker` — новое устройство (оба режима кончаются одним long-poll, который приносит сеанс);
// `InviteLinker` — вошедшее устройство, которое показывает код и ждёт, пока новое его заберёт.

/// Почему привязка никуда не привела — словами экранов (API §2.2). `error` — исходный отказ: по нему экран берёт
/// те же тексты, что при входе по паролю (лимит устройств, «Слишком много попыток», сеть).
public struct LinkFailure: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Другое устройство отказало или там выбрали не то число.
        case denied
        case expired
        case cancelled
        case deviceLimit
        case notFound
        case alreadyClaimed
        case wrongMode
        case throttled
        case network
        case unknown
    }

    public let reason: Reason
    public let error: APIError?

    public init(reason: Reason, error: APIError? = nil) {
        self.reason = reason
        self.error = error
    }

    public init(_ error: any Error) {
        guard let api = error as? APIError else {
            self.init(reason: .unknown)
            return
        }
        let reason: Reason = switch api.code {
        case "link_denied", "link_verify_mismatch": .denied
        case "link_expired": .expired
        case "link_cancelled": .cancelled
        case "link_not_found": .notFound
        case "link_already_claimed": .alreadyClaimed
        case "link_wrong_mode": .wrongMode
        case "device_limit_reached": .deviceLimit
        case "rate_limited", "login_throttled": .throttled
        default: api.isNetwork ? .network : .unknown
        }
        self.init(reason: reason, error: api)
    }

    /// Статус законченной `LinkDetails` как отказ; `nil`, пока она жива или кончилась хорошо.
    public static func status(_ status: String) -> LinkFailure? {
        switch status {
        case "denied": LinkFailure(reason: .denied)
        case "expired": LinkFailure(reason: .expired)
        case "cancelled": LinkFailure(reason: .cancelled)
        default: nil
        }
    }
}

public enum LinkTiming {
    /// Повтор после сети, `429` и `5xx` — не ошибка, а «Пробуем снова…» (задание 0017 §2.1).
    public static let retryDelay: Duration = .seconds(3)
    /// Приглашение без SSE читается раз в 3 с, с SSE — тоже, страховкой (API §4.6).
    public static let invitePoll: Duration = .seconds(3)
    /// Код живёт 5 минут (`LINK_TTL_SECONDS`), если время сервера не разобралось.
    static let defaultTTL: TimeInterval = 300

    static func expiry(_ iso: String, now: Date = Date()) -> Date {
        IsoTime.date(iso) ?? now.addingTimeInterval(defaultTTL)
    }

    /// `K7QX-M2PD` по знакам для VoiceOver: `K, 7, Q, X, M, 2, P, D`.
    public static func spokenCode(_ code: String) -> String {
        code.filter { $0 != "-" }.map(String.init).joined(separator: ", ")
    }
}

extension APIError {
    /// Сбой, после которого стоит молча повторить: нет сети, сервер занят, лимит частоты.
    var isTransient: Bool { isNetwork || status == 429 || status >= 500 }
}

// MARK: - Новое устройство

public enum NewDeviceLinkState: Equatable, Sendable {
    /// Ничего не просили или бросили.
    case idle
    /// Сервер выдаёт код (`request`) или проверяет введённый (`invite`).
    case starting
    /// Режим `request`: код этого устройства ждёт, пока его введут на вошедшем. `reconnecting` — нет связи, повтор.
    case showingCode(userCode: String, expiresAt: Date, reconnecting: Bool)
    /// Код у другой стороны: число, которое там выбрать, чей аккаунт и на каком устройстве.
    case verify(verifyCode: String, login: String, approverName: String, approverPlatform: String, expiresAt: Date, reconnecting: Bool)
    /// Сеанс взят — как после входа по паролю.
    case signedIn
    /// Привязка кончилась. `started == false` — она и не началась (кода нет, введённый код отвергнут).
    case failed(LinkFailure, started: Bool)
}

/// Что `NewDeviceLinker` нужно от сервера: `Account` в приложении, заглушка в тестах.
@MainActor
public protocol NewDeviceLinkPort: AnyObject {
    func startLinkRequest() async throws -> LinkCreated
    func claimLink(userCode: String) async throws -> LinkClaimed
    /// При `completed` сеанс уже сохранён.
    func pollLink(pollSecret: String, knownStatus: String) async throws -> LinkPollResponse
    func cancelLinkRequest(pollSecret: String) async
}

extension Account: NewDeviceLinkPort {}

/// Вход по коду нового устройства: `showCode()` просит код и ждёт одобрения на вошедшем устройстве (режим
/// `request`), `claim(userCode:)` вводит код, который показывает вошедшее (режим `invite`). Дальше состояние
/// переходит к `.verify` (число для другого устройства) и кончается `.signedIn` с уже сохранённым сеансом.
/// `cancel()` бросает привязку и на сервере.
@MainActor
@Observable
public final class NewDeviceLinker {
    public private(set) var state: NewDeviceLinkState = .idle

    @ObservationIgnored private let port: any NewDeviceLinkPort
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pollSecret: String?

    public init(port: any NewDeviceLinkPort, retryDelay: Duration = LinkTiming.retryDelay) {
        self.port = port
        self.retryDelay = retryDelay
    }

    /// Режим `request`: код этого устройства.
    public func showCode() {
        start { [self] in
            let created: LinkCreated
            do {
                created = try await port.startLinkRequest()
            } catch is CancellationError {
                return
            } catch {
                state = .failed(LinkFailure(error), started: false)
                return
            }
            guard let secret = created.pollSecret else {
                state = .failed(LinkFailure(reason: .unknown), started: false)
                return
            }
            pollSecret = secret
            state = .showingCode(userCode: created.userCode, expiresAt: LinkTiming.expiry(created.expiresAt), reconnecting: false)
            await follow(secret, knownStatus: "pending")
        }
    }

    /// Режим `invite`: `userCode` (нормализованный) показывает вошедшее устройство.
    public func claim(userCode: String) {
        start { [self] in
            let claimed: LinkClaimed
            do {
                claimed = try await port.claimLink(userCode: userCode)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(LinkFailure(error), started: false)
                return
            }
            pollSecret = claimed.pollSecret
            state = .verify(
                verifyCode: claimed.verifyCode,
                login: claimed.account.login,
                approverName: claimed.approverDevice.name,
                approverPlatform: claimed.approverDevice.platform,
                expiresAt: LinkTiming.expiry(claimed.expiresAt),
                reconnecting: false
            )
            await follow(claimed.pollSecret, knownStatus: "claimed")
        }
    }

    /// Бросает привязку здесь и на сервере; назад к `.idle`, если сеанс ещё не взят. Ответа сервера не ждёт.
    public func cancel() {
        task?.cancel()
        task = nil
        let secret = pollSecret
        pollSecret = nil
        if state != .signedIn { state = .idle }
        if let secret {
            let port = port
            Task { await port.cancelLinkRequest(pollSecret: secret) }
        }
    }

    private func start(_ body: @escaping @MainActor () async -> Void) {
        cancel()
        state = .starting
        task = Task { await body() }
    }

    /// Long-poll (API §4.6): ответ сразу, если статус сдвинулся, иначе через 25 с.
    private func follow(_ secret: String, knownStatus: String) async {
        var known = knownStatus
        while !Task.isCancelled {
            let answer: LinkPollResponse
            do {
                answer = try await port.pollLink(pollSecret: secret, knownStatus: known)
            } catch is CancellationError {
                return
            } catch {
                if let api = error as? APIError, api.isTransient {
                    setReconnecting(true)
                    do { try await Task.sleep(for: retryDelay) } catch { return }
                    continue
                }
                // Отказ, истёк, отменили, лимит устройств: привязка кончилась, отменять нечего
                pollSecret = nil
                state = .failed(LinkFailure(error), started: true)
                return
            }
            guard !Task.isCancelled else { return }
            switch answer.status {
            case "completed":
                pollSecret = nil
                state = .signedIn
                return
            case "claimed":
                known = "claimed"
                guard let code = answer.verifyCode, let login = answer.account?.login, let approver = answer.approverDevice else {
                    pollSecret = nil
                    state = .failed(LinkFailure(reason: .unknown), started: true)
                    return
                }
                state = .verify(
                    verifyCode: code, login: login, approverName: approver.name, approverPlatform: approver.platform,
                    expiresAt: LinkTiming.expiry(answer.expiresAt), reconnecting: false
                )
            default:
                setReconnecting(false)
            }
        }
    }

    private func setReconnecting(_ value: Bool) {
        switch state {
        case .showingCode(let code, let expiresAt, _):
            state = .showingCode(userCode: code, expiresAt: expiresAt, reconnecting: value)
        case .verify(let code, let login, let name, let platform, let expiresAt, _):
            state = .verify(verifyCode: code, login: login, approverName: name, approverPlatform: platform, expiresAt: expiresAt, reconnecting: value)
        default:
            break
        }
    }
}

// MARK: - Вошедшее устройство показывает код

/// SSE `link.updated`: `id` события отличает два одинаковых обновления подряд.
public struct LinkUpdate: Equatable, Sendable {
    public let id: String
    public let linkId: String
    public let status: String
}

public enum InviteState: Equatable, Sendable {
    case idle
    case starting
    /// Код для нового устройства.
    case waiting(userCode: String, expiresAt: Date)
    /// Новое устройство ввело код: его карточка и три числа (экран одобрения).
    case claimed(LinkDetails)
    /// Приглашение кончилось. `started == false` — кода так и не было.
    case failed(LinkFailure, started: Bool)
}

@MainActor
public protocol InvitePort: AnyObject {
    func createLinkInvite() async throws -> LinkCreated
    func link(_ linkId: String) async throws -> LinkDetails
    func cancelLink(_ linkId: String) async
}

extension Account: InvitePort {}

/// «Показать код для нового устройства» (режим `invite`): создаёт приглашение и следит за ним, пока новое устройство
/// его не заберёт. SSE `link.updated` (`nudge(linkId:)`) читает его сразу, опрос раз в 3 с — страховка (API §4.6).
/// Забранное приглашение тоже под присмотром: если новое устройство передумало или код истёк, состояние скажет.
/// `release()` перестаёт следить без отмены (после решения), `cancel()` отменяет приглашение на сервере.
@MainActor
@Observable
public final class InviteLinker {
    public private(set) var state: InviteState = .idle

    @ObservationIgnored private let port: any InvitePort
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Пауза между чтениями: толчок SSE её отменяет.
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    /// Толчок пришёл, пока приглашение читалось: следующее чтение — без паузы.
    @ObservationIgnored private var nudged = false
    @ObservationIgnored private var linkId: String?

    public init(port: any InvitePort, pollInterval: Duration = LinkTiming.invitePoll) {
        self.port = port
        self.pollInterval = pollInterval
    }

    public func start() {
        cancel()
        state = .starting
        task = Task { [self] in
            let created: LinkCreated
            do {
                created = try await port.createLinkInvite()
            } catch is CancellationError {
                return
            } catch {
                state = .failed(LinkFailure(error), started: false)
                return
            }
            guard !Task.isCancelled else {
                let port = port
                Task { await port.cancelLink(created.linkId) }
                return
            }
            linkId = created.linkId
            state = .waiting(userCode: created.userCode, expiresAt: LinkTiming.expiry(created.expiresAt))
            while !Task.isCancelled {
                await sleepOrNudge()
                guard !Task.isCancelled else { return }
                if await refresh(created.linkId) { return }
            }
        }
    }

    /// SSE `link.updated`: прочитать приглашение сейчас, не дожидаясь опроса.
    public func nudge(linkId: String) {
        guard linkId == self.linkId else { return }
        nudged = true
        sleeper?.cancel()
    }

    /// Перестать следить без отмены: привязка решена (одобрена или отклонена).
    public func release() {
        stop()
        linkId = nil
        state = .idle
    }

    /// Отменяет приглашение здесь и на сервере; назад к `.idle`.
    public func cancel() {
        stop()
        let id = linkId
        linkId = nil
        state = .idle
        if let id {
            let port = port
            Task { await port.cancelLink(id) }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        sleeper?.cancel()
        sleeper = nil
    }

    private func sleepOrNudge() async {
        if nudged {
            nudged = false
            return
        }
        let interval = pollInterval
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: interval) }
        self.sleeper = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        self.sleeper = nil
        nudged = false
    }

    /// Читает приглашение один раз; `true` — следить больше не за чем.
    private func refresh(_ id: String) async -> Bool {
        let details: LinkDetails
        do {
            details = try await port.link(id)
        } catch is CancellationError {
            return true
        } catch {
            if let api = error as? APIError, api.isTransient { return false }
            linkId = nil
            state = .failed(LinkFailure(error), started: true)
            return true
        }
        guard !Task.isCancelled else { return true }
        if let failure = LinkFailure.status(details.status) {
            linkId = nil
            state = .failed(failure, started: true)
            return true
        }
        switch details.status {
        case "claimed":
            if !details.verifyChoices.isEmpty, state != .claimed(details) { state = .claimed(details) }
            return false
        case "approved", "completed":
            // Решено здесь и завершено там: экран уже сказал, что нужно
            return true
        default:
            return false
        }
    }
}
