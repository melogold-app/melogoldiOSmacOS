import Foundation

/// Шаг пути по ответу InnerTube: ключ объекта или индекс массива.
enum JSONKey: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    init(stringLiteral value: String) { self = .key(value) }
    init(integerLiteral value: Int) { self = .index(value) }
}

/// Навигация по ответам InnerTube: пути, `runs`, обложки. Всё терпит отсутствующие ключи (как `J` у Windows).
/// Живёт только внутри разбора одного ответа — наружу уходят готовые модели `MelogoldCore`.
struct JSON {
    let value: Any?

    init(_ value: Any?) {
        self.value = value is NSNull ? nil : value
    }

    static func parse(_ data: Data) throws -> JSON {
        JSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    var exists: Bool { value != nil }

    subscript(key: String) -> JSON {
        JSON((value as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = value as? [Any], index >= 0, index < array.count else { return JSON(nil) }
        return JSON(array[index])
    }

    func at(_ path: JSONKey...) -> JSON { at(path) }

    func at(_ path: [JSONKey]) -> JSON {
        var node = self
        for step in path {
            switch step {
            case .key(let key): node = node[key]
            case .index(let index): node = node[index]
            }
            if !node.exists { return node }
        }
        return node
    }

    /// Первый существующий узел из нескольких путей.
    func first(_ paths: [JSONKey]...) -> JSON {
        for path in paths {
            let node = at(path)
            if node.exists { return node }
        }
        return JSON(nil)
    }

    var string: String? { value as? String }

    func str(_ path: JSONKey...) -> String? { at(path).string }

    var int64: Int64? {
        if let number = value as? NSNumber, !(value is Bool) { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    func int(_ path: JSONKey...) -> Int64? { at(path).int64 }

    var double: Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    var bool: Bool {
        if let flag = value as? Bool { return flag }
        return (value as? NSNumber)?.boolValue ?? false
    }

    func flag(_ path: JSONKey...) -> Bool { at(path).bool }

    var array: [JSON] { (value as? [Any])?.map { JSON($0) } ?? [] }

    func items(_ path: JSONKey...) -> [JSON] { at(path).array }

    var object: [String: Any]? { value as? [String: Any] }

    /// Первое вложенное значение с ключом (обход в глубину).
    func find(_ key: String) -> JSON? {
        switch value {
        case let object as [String: Any]:
            if let direct = object[key], !(direct is NSNull) { return JSON(direct) }
            for inner in object.values {
                if let found = JSON(inner).find(key) { return found }
            }
            return nil
        case let array as [Any]:
            for inner in array {
                if let found = JSON(inner).find(key) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// Все вложенные значения с ключом.
    func findAll(_ key: String) -> [JSON] {
        var result: [JSON] = []
        collect(key, into: &result)
        return result
    }

    private func collect(_ key: String, into result: inout [JSON]) {
        switch value {
        case let object as [String: Any]:
            for (name, inner) in object {
                if name == key { result.append(JSON(inner)) } else { JSON(inner).collect(key, into: &result) }
            }
        case let array as [Any]:
            for inner in array { JSON(inner).collect(key, into: &result) }
        default:
            break
        }
    }

    /// Текст узла `{runs: [...]}`, `{simpleText}` или `{content}`.
    var text: String? {
        if let runs = self["runs"].value as? [Any] {
            return runs.map { JSON($0).str("text") ?? "" }.joined()
        }
        return str("simpleText") ?? str("content")
    }

    var runs: [Run] {
        (self["runs"].value as? [Any])?.map { Run(node: JSON($0)) } ?? []
    }

    /// Самая большая обложка из массива `thumbnails`.
    var bestThumbnail: String? {
        let candidates = array.filter { $0.str("url") != nil }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { ($0.int("width") ?? 0) < ($1.int("width") ?? 0) }?.str("url")
    }
}

/// Кусок текста с возможным переходом.
struct Run {
    let node: JSON

    var text: String { node.str("text") ?? "" }
    var browseId: String? { node.str("navigationEndpoint", "browseEndpoint", "browseId") }
    var pageType: String? {
        node.str("navigationEndpoint", "browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType")
    }
    var watchVideoId: String? { node.str("navigationEndpoint", "watchEndpoint", "videoId") }
    var isSeparator: Bool { text == " • " || text == " · " || text == "•" }
}
