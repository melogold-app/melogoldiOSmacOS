import Foundation
import Synchronization

/// Сервер-заглушка для тестов: у каждого теста свой хост, поэтому тесты идут параллельно.
final class StubServer: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    /// Статус меньше нуля — сети нет: запрос падает с `URLError.notConnectedToInternet`.
    typealias Handler = @Sendable (Request) -> (Int, String)

    static let offline = -1

    let host: String
    private let routes = Mutex<[String: Handler]>([:])
    private let received = Mutex<[Request]>([])

    init() {
        host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
        StubProtocol.register(self)
    }

    var baseURL: String { "https://\(host)" }

    func on(_ method: String, _ path: String, _ handler: @escaping Handler) {
        routes.withLock { $0["\(method) \(path)"] = handler }
    }

    func requests(_ method: String, _ path: String) -> [Request] {
        received.withLock { $0.filter { $0.method == method && $0.path == path } }
    }

    func handle(_ request: Request) -> (Int, String) {
        received.withLock { $0.append(request) }
        guard let handler = routes.withLock({ $0["\(request.method) \(request.path)"] }) else {
            return (404, #"{"statusCode":404,"error":"Not Found","message":"Not Found","code":"not_found"}"#)
        }
        return handler(request)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: StubServer]>([:])

    static func register(_ server: StubServer) {
        servers.withLock { $0[server.host] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.servers.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let stub = StubServer.Request(
            method: request.httpMethod ?? "GET",
            path: url.path(),
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? readStream(request.httpBodyStream)
        )
        let (status, text) = server.handle(stub)
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
