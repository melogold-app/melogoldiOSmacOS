import Foundation
import MelogoldCore
import MelogoldInnerTube

/// Список клиентов InnerTube для потока (docs/PROMPT.md §4): `config/stream-clients.json` в этом репозитории.
/// При старте — сохранённая копия, потом свежий файл с `main`: поломку на стороне YouTube можно чинить без релиза.
/// Встроенный список (`builtIn`) остаётся запасным, негодный файл не применяется.
public enum StreamClients {
    public static let url = URL(string: "https://raw.githubusercontent.com/melogold-app/melogoldiOSmacOS/main/Config/stream-clients.json")!
    public static let schema = 1
    public static let builtIn: [ClientProfile] = [.visionOS]

    private struct Config: Decodable {
        struct Entry: Decodable {
            var name: String?
            var id: Int?
            var version: String?
            var host: String?
            var userAgent: String?
            var referer: String?
            var platform: String?
            var deviceMake: String?
            var deviceModel: String?
            var osName: String?
            var osVersion: String?
            var androidSdkVersion: Int?
            var mediaUserAgent: String?
        }

        var schema: Int?
        var clients: [Entry]?
    }

    /// Профили из файла; `nil` — не та схема, пустой список или клиент без обязательных полей.
    public static func parse(_ data: Data) -> [ClientProfile]? {
        guard let config = try? JSONDecoder().decode(Config.self, from: data), config.schema == schema,
              let clients = config.clients, !clients.isEmpty else { return nil }
        var profiles: [ClientProfile] = []
        for entry in clients {
            guard let name = entry.name, !name.isEmpty, let id = entry.id, id > 0, let version = entry.version, !version.isEmpty,
                  let host = entry.host, !host.isEmpty, let userAgent = entry.userAgent, !userAgent.isEmpty else { return nil }
            profiles.append(ClientProfile(
                name: name, id: id, version: version, host: host, userAgent: userAgent, referer: entry.referer,
                platform: entry.platform, deviceMake: entry.deviceMake, deviceModel: entry.deviceModel, osName: entry.osName,
                osVersion: entry.osVersion, androidSdkVersion: entry.androidSdkVersion, mediaUserAgent: entry.mediaUserAgent
            ))
        }
        return profiles
    }

    /// Сохранённый список, если он есть и годен.
    public static func saved(at file: URL) -> [ClientProfile]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parse(data)
    }

    /// Свежий список с GitHub; годный сохраняется рядом с базой. `nil` — сети нет или файл негоден.
    public static func refresh(saveTo file: URL, userAgent: String) async -> [ClientProfile]? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await HTTPConfiguration.session(timeout: 15).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let profiles = parse(data) else {
                Log.warning("stream", "Список клиентов потока с GitHub не принят")
                return nil
            }
            try data.write(to: file, options: .atomic)
            Log.info("stream", "Список клиентов потока обновлён: \(profiles.map(\.name).joined(separator: ", "))")
            return profiles
        } catch {
            Log.info("stream", "Список клиентов потока не обновлён: \(error.localizedDescription)")
            return nil
        }
    }
}
