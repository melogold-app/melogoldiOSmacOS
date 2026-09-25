import Foundation

/// Итог проверки адреса сервера, который ввёл человек (API §7.1).
public enum ServerAddress: Equatable, Sendable {
    /// `url` — base URL `scheme://host[:port][/prefix]` без `/` в конце; `insecure` — `http`.
    case valid(url: String, insecure: Bool)
    /// Отказ с кодом из `spec/server-address.vectors.json`.
    case invalid(ServerAddressError)

    public var url: String? {
        if case .valid(let url, _) = self { return url }
        return nil
    }
}

/// Коды отказа: `empty | malformed | unsupported_scheme | credentials_or_params | https_required`.
public enum ServerAddressError: String, Error, Sendable {
    case empty
    case malformed
    case unsupportedScheme = "unsupported_scheme"
    case credentialsOrParams = "credentials_or_params"
    case httpsRequired = "https_required"
}

/// Правила адреса сервера, общие для всех клиентов (API §7.1, векторы `spec/server-address.vectors.json`).
///
/// trim; без схемы — `https://`; схема и хост в нижнем регистре; `/` в конце убирается, префикс пути остаётся;
/// логин, параметры и фрагмент — отказ. `https` — на любой хост, `http` — только на частный. Проверку после DNS
/// делает вызывающий код (`isPrivateAddress`), здесь имена не резолвятся.
public enum ServerAddressPolicy {
    private static let privateSuffixes = [".local", ".lan", ".home.arpa", ".internal"]

    public static func normalize(_ input: String?) -> ServerAddress {
        let text = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .invalid(.empty) }
        let withScheme = hasScheme(text) ? text : "https://" + text

        guard let schemeRange = withScheme.range(of: "://") else { return .invalid(.malformed) }
        let scheme = withScheme[..<schemeRange.lowerBound].lowercased()
        guard scheme == "https" || scheme == "http" else { return .invalid(.unsupportedScheme) }

        let rest = withScheme[schemeRange.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        let authority = String(authorityEnd.map { rest[..<$0] } ?? rest)
        let tail = String(authorityEnd.map { rest[$0...] } ?? "")

        if authority.contains("@") || tail.contains("?") || tail.contains("#") {
            return .invalid(.credentialsOrParams)
        }
        if authority.isEmpty { return .invalid(.malformed) }

        let host: String
        let portText: String
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return .invalid(.malformed) }
            host = authority[...close].lowercased()
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty, !after.hasPrefix(":") { return .invalid(.malformed) }
            portText = after.isEmpty ? "" : String(after.dropFirst())
            guard IPv6.parse(String(host.dropFirst().dropLast())) != nil else { return .invalid(.malformed) }
        } else {
            if let colon = authority.lastIndex(of: ":") {
                host = authority[..<colon].lowercased()
                portText = String(authority[authority.index(after: colon)...])
            } else {
                host = authority.lowercased()
                portText = ""
            }
            guard isValidHostName(host) else { return .invalid(.malformed) }
        }

        var port = ""
        if !portText.isEmpty {
            guard portText.allSatisfy(\.isASCIIDigit), let number = Int(portText), (1...65535).contains(number) else {
                return .invalid(.malformed)
            }
            port = ":\(number)"
        }

        if tail.contains(where: \.isWhitespace) { return .invalid(.malformed) }
        var path = tail
        while path.hasSuffix("/") { path.removeLast() }

        let insecure = scheme == "http"
        if insecure, !isPrivateHost(host) { return .invalid(.httpsRequired) }
        return .valid(url: "\(scheme)://\(host)\(port)\(path)", insecure: insecure)
    }

    /// Хост, на который можно по `http`: IPv4 `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `127/8`,
    /// `100.64/10`; IPv6 `fc00::/7`, `fe80::/10`, `::1` (в скобках); имя `*.local`, `*.lan`, `*.home.arpa`,
    /// `*.internal` или из одного слова.
    public static func isPrivateHost(_ host: String) -> Bool {
        if host.hasPrefix("["), host.hasSuffix("]") {
            guard let bytes = IPv6.parse(String(host.dropFirst().dropLast())) else { return false }
            return isPrivateIPv6(bytes)
        }
        if isNumericHost(host) {
            guard let octets = parseIPv4(host) else { return false }
            return isPrivateIPv4(octets)
        }
        if !host.contains(".") { return true }
        return privateSuffixes.contains { host.hasSuffix($0) && host.count > $0.count }
    }

    /// Адрес из частной сети — для проверки после DNS: при `http` все адреса имени должны быть такими.
    /// Принимает 4 байта IPv4 или 16 байт IPv6 (IPv4, отображённый в IPv6, проверяется как IPv4).
    public static func isPrivateAddress(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4:
            return isPrivateIPv4(bytes)
        case 16:
            let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
            return mapped ? isPrivateIPv4(Array(bytes[12..<16])) : isPrivateIPv6(bytes)
        default:
            return false
        }
    }

    // MARK: - Разбор

    private static func hasScheme(_ text: String) -> Bool {
        guard let range = text.range(of: "://") else { return false }
        let scheme = text[..<range.lowerBound]
        guard let first = scheme.first, first.isASCIILetter else { return false }
        return scheme.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "+" || $0 == "." || $0 == "-" }
    }

    /// `^\d+(\.\d+)*$` — числовой хост; такой должен быть верным IPv4.
    private static func isNumericHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
    }

    /// Имя или IPv4 без скобок: метки `[a-z0-9-]`, числовой хост — только верный IPv4. Последняя метка имени
    /// начинается с буквы (как у `java.net.URI`): «1.2.3» — не имя.
    private static func isValidHostName(_ host: String) -> Bool {
        if host.isEmpty { return false }
        if isNumericHost(host) { return parseIPv4(host) != nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard let first = label.first, let last = label.last else { return false }
            let allowed = label.allSatisfy { $0.isASCIILowercaseLetter || $0.isASCIIDigit || $0 == "-" }
            let edgesOK = (first.isASCIILowercaseLetter || first.isASCIIDigit) && (last.isASCIILowercaseLetter || last.isASCIIDigit)
            if !allowed || !edgesOK { return false }
        }
        return labels.last?.first?.isASCIILetter == true
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCIIDigit), let value = Int(part), value <= 255 else {
                return nil
            }
            result.append(UInt8(value))
        }
        return result
    }

    private static func isPrivateIPv4(_ octets: [UInt8]) -> Bool {
        let a = octets[0], b = octets[1]
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
        return loopback || (bytes[0] & 0xFE) == 0xFC || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80)
    }
}

/// Разбор текстового IPv6 (RFC 4291: группы, `::`, хвост IPv4) в 16 байт — без сети и без `inet_pton`,
/// одинаково на всех платформах Apple.
enum IPv6 {
    static func parse(_ text: String) -> [UInt8]? {
        if text.isEmpty || text.contains("%") { return nil }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var result: [UInt16] = []
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index == pieces.count - 1, piece.contains(".") {
                    let octets = piece.split(separator: ".", omittingEmptySubsequences: false)
                    guard octets.count == 4 else { return nil }
                    var values: [UInt8] = []
                    for octet in octets {
                        guard (1...3).contains(octet.count), octet.allSatisfy(\.isASCIIDigit),
                              let value = Int(octet), value <= 255 else { return nil }
                        values.append(UInt8(value))
                    }
                    result.append(UInt16(values[0]) << 8 | UInt16(values[1]))
                    result.append(UInt16(values[2]) << 8 | UInt16(values[3]))
                } else {
                    guard (1...4).contains(piece.count), piece.allSatisfy(\.isHexDigit),
                          let value = UInt16(piece, radix: 16) else { return nil }
                    result.append(value)
                }
            }
            return result
        }

        guard let head = groups(halves[0]) else { return nil }
        let tailGroups: [UInt16]
        if halves.count == 2 {
            guard let parsed = groups(halves[1]) else { return nil }
            tailGroups = parsed
            guard head.count + tailGroups.count <= 7 else { return nil }
        } else {
            tailGroups = []
            guard head.count == 8 else { return nil }
        }
        let zeros = Array(repeating: UInt16(0), count: 8 - head.count - tailGroups.count)
        let all = head + zeros + tailGroups
        return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
    var isASCIILowercaseLetter: Bool { isASCII && isLowercase }
}
