import Foundation
import Synchronization

/// Прозрачный прокси для живых тестов: запрос уходит на настоящий сервер как есть, а тест видит, что клиент отправил
/// (например, что синк без правок не шлёт ops). Потоки событий (SSE) через него не идут: ответ отдаётся целиком.
final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    private static let log = Mutex<[StubServer.Request]>([])
    private static let upstream = URLSession(configuration: .ephemeral)
    private let forwarding = Mutex<URLSessionDataTask?>(nil)

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Запросы с этим access-токеном (у каждого устройства свой), по порядку.
    static func requests(token: String) -> [StubServer.Request] {
        log.withLock { $0.filter { $0.headers["Authorization"] == "Bearer \(token)" } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = request.httpBody ?? StubProtocol.readStream(request.httpBodyStream)
        Self.log.withLock {
            $0.append(StubServer.Request(method: request.httpMethod ?? "GET", path: url.path(), headers: request.allHTTPHeaderFields ?? [:], body: body))
        }
        var outgoing = request
        outgoing.httpBodyStream = nil
        outgoing.httpBody = body.isEmpty ? nil : body
        let task = Self.upstream.dataTask(with: outgoing) { [self] data, response, error in
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        forwarding.withLock { $0 = task }
        task.resume()
    }

    override func stopLoading() {
        forwarding.withLock { $0?.cancel() }
    }
}
