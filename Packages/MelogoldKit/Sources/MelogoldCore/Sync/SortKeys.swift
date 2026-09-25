import Foundation

/// Ключи порядка треков плейлиста (API §8, DESIGN §3.7): fractional indexing по алфавиту base62 `0-9A-Za-z`,
/// сравнение побайтовое (цифры < заглавные < строчные). Ключи выдаёт только сервер, клиенты сортируют по
/// `(sortKey, videoId)`. Порт `melogoldServer/src/modules/sync/playlists/sort-keys.ts` — векторы
/// `spec/playlist-ops.vectors.json` (раздел `sortKeys`) проверяют, что ключи совпадают бит в бит.
///
/// Ключ — `<целая часть><дробь>`: первая буква целой части задаёт её длину (`a`…`z` → 2…27 знаков, растут вверх;
/// `Z`…`A` → 2…27 знаков, отрицательные), дробь — строка base62 без `0` в конце.
public enum SortKeys {
    public static let alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    /// Ключ длиннее — сервер выдаёт все ключи плейлиста заново.
    public static let maxLength = 48

    public struct KeyError: Error, Equatable, Sendable {
        public let reason: String
    }

    private static let zero = UInt8(ascii: "0")
    private static let base = 62
    private static let smallestInteger: [UInt8] = [UInt8(ascii: "A")] + Array(repeating: zero, count: 26)

    // MARK: - Порядок

    /// Побайтовое сравнение ключей или `videoId` (грабли §9 п. 10): отрицательное, ноль или положительное.
    public static func compare(_ a: String, _ b: String) -> Int {
        compare(Array(a.utf8), Array(b.utf8))
    }

    /// `a` раньше `b` в порядке сервера.
    public static func precedes(_ a: String, _ b: String) -> Bool {
        compare(a, b) < 0
    }

    static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    public static func isValid(_ key: String) -> Bool {
        (try? validate(Array(key.utf8))) != nil
    }

    // MARK: - Ключи между соседями

    /// Ключ строго между `a` и `b`; `nil` — открытый конец. Ошибка — неверная граница или `a >= b`.
    public static func keyBetween(_ a: String?, _ b: String?) throws(KeyError) -> String {
        String(decoding: try keyBetween(a.map { Array($0.utf8) }, b.map { Array($0.utf8) }), as: UTF8.self)
    }

    /// `n` возрастающих ключей строго между `a` и `b`. С обеими границами ключи раскладываются делением пополам,
    /// поэтому их длина растёт как log62(n), а не как n.
    public static func keysBetween(_ a: String?, _ b: String?, count n: Int) throws(KeyError) -> [String] {
        guard n >= 0 else { throw KeyError(reason: "negative count") }
        if n == 0 {
            let lower = a.map { Array($0.utf8) }, upper = b.map { Array($0.utf8) }
            if let lower { try validate(lower) }
            if let upper { try validate(upper) }
            if let lower, let upper, compare(lower, upper) >= 0 { throw KeyError(reason: "bounds out of order") }
            return []
        }
        if n == 1 { return [try keyBetween(a, b)] }
        if b == nil {
            var keys = [try keyBetween(a, nil)]
            for _ in 1 ..< n { keys.append(try keyBetween(keys.last, nil)) }
            return keys
        }
        if a == nil {
            var keys = [try keyBetween(nil, b)]
            for _ in 1 ..< n { keys.append(try keyBetween(nil, keys.last)) }
            return keys.reversed()
        }
        let middle = n / 2
        let key = try keyBetween(a, b)
        return try keysBetween(a, key, count: middle) + [key] + keysBetween(key, b, count: n - middle - 1)
    }

    static func keyBetween(_ a: [UInt8]?, _ b: [UInt8]?) throws(KeyError) -> [UInt8] {
        if let a { try validate(a) }
        if let b { try validate(b) }
        if let a, let b, compare(a, b) >= 0 { throw KeyError(reason: "bounds out of order") }
        guard let a else {
            guard let b else { return [UInt8(ascii: "a"), zero] }
            let integerB = try integerPart(b)
            let fractionB = Array(b[integerB.count...])
            if integerB == smallestInteger { return integerB + (try midpoint([], fractionB)) }
            if integerB.count < b.count { return integerB }
            guard let decremented = try decrement(integerB) else { throw KeyError(reason: "cannot decrement any more") }
            return decremented
        }
        let integerA = try integerPart(a)
        let fractionA = Array(a[integerA.count...])
        guard let b else {
            if let incremented = try increment(integerA) { return incremented }
            return integerA + (try midpoint(fractionA, nil))
        }
        let integerB = try integerPart(b)
        let fractionB = Array(b[integerB.count...])
        if integerA == integerB { return integerA + (try midpoint(fractionA, fractionB)) }
        guard let incremented = try increment(integerA) else { throw KeyError(reason: "cannot increment any more") }
        if compare(incremented, b) < 0 { return incremented }
        return integerA + (try midpoint(fractionA, nil))
    }

    // MARK: - Разбор

    private static func digitValue(_ char: UInt8) throws(KeyError) -> Int {
        switch char {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): Int(char - UInt8(ascii: "0"))
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"): Int(char - UInt8(ascii: "A")) + 10
        case UInt8(ascii: "a") ... UInt8(ascii: "z"): Int(char - UInt8(ascii: "a")) + 36
        default: throw KeyError(reason: "not a base62 digit")
        }
    }

    private static func digit(_ value: Int) throws(KeyError) -> UInt8 {
        switch value {
        case 0 ... 9: UInt8(ascii: "0") + UInt8(value)
        case 10 ... 35: UInt8(ascii: "A") + UInt8(value - 10)
        case 36 ... 61: UInt8(ascii: "a") + UInt8(value - 36)
        default: throw KeyError(reason: "digit out of range")
        }
    }

    private static func integerLength(_ head: UInt8) throws(KeyError) -> Int {
        switch head {
        case UInt8(ascii: "a") ... UInt8(ascii: "z"): Int(head - UInt8(ascii: "a")) + 2
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"): Int(UInt8(ascii: "Z") - head) + 2
        default: throw KeyError(reason: "invalid head of an order key")
        }
    }

    private static func integerPart(_ key: [UInt8]) throws(KeyError) -> [UInt8] {
        guard let head = key.first else { throw KeyError(reason: "empty key") }
        let length = try integerLength(head)
        guard length <= key.count else { throw KeyError(reason: "order key too short for its head") }
        return Array(key[..<length])
    }

    private static func validate(_ key: [UInt8]) throws(KeyError) {
        if key == smallestInteger { throw KeyError(reason: "invalid order key") }
        let integer = try integerPart(key)
        for char in key.dropFirst() { _ = try digitValue(char) }
        if key.count > integer.count && key.last == zero { throw KeyError(reason: "trailing zero") }
    }

    /// Дробь строго между `a` и `b` (`nil` — без верхней границы). Обе без `0` в конце.
    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) throws(KeyError) -> [UInt8] {
        if let b, compare(a, b) >= 0 { throw KeyError(reason: "bounds out of order") }
        if a.last == zero || b?.last == zero { throw KeyError(reason: "trailing zero") }
        if let b {
            // Общий префикс; `a` дополняется нулями
            var n = 0
            while n < b.count && (n < a.count ? a[n] : zero) == b[n] { n += 1 }
            if n > 0 {
                let restA = n < a.count ? Array(a[n...]) : []
                return Array(b[..<n]) + (try midpoint(restA, Array(b[n...])))
            }
        }
        let digitA = try a.first.map(digitValue) ?? 0
        let digitB: Int
        if let b {
            guard let first = b.first else { throw KeyError(reason: "not a base62 digit") }
            digitB = try digitValue(first)
        } else {
            digitB = base
        }
        if digitB - digitA > 1 { return [try digit((digitA + digitB + 1) / 2)] }
        // Первые цифры соседние
        if let b, b.count > 1 { return [b[0]] }
        return [try digit(digitA)] + (try midpoint(Array(a.dropFirst()), nil))
    }

    private static func increment(_ integer: [UInt8]) throws(KeyError) -> [UInt8]? {
        guard let head = integer.first else { throw KeyError(reason: "empty key") }
        var digits = Array(integer.dropFirst())
        var carry = true
        var index = digits.count - 1
        while carry && index >= 0 {
            let next = try digitValue(digits[index]) + 1
            if next == base {
                digits[index] = zero
            } else {
                digits[index] = try digit(next)
                carry = false
            }
            index -= 1
        }
        if !carry { return [head] + digits }
        if head == UInt8(ascii: "Z") { return [UInt8(ascii: "a"), zero] }
        if head == UInt8(ascii: "z") { return nil }
        let nextHead = head + 1
        if nextHead > UInt8(ascii: "a") { digits.append(zero) } else { digits.removeLast() }
        return [nextHead] + digits
    }

    private static func decrement(_ integer: [UInt8]) throws(KeyError) -> [UInt8]? {
        guard let head = integer.first else { throw KeyError(reason: "empty key") }
        let largest = try digit(base - 1)
        var digits = Array(integer.dropFirst())
        var borrow = true
        var index = digits.count - 1
        while borrow && index >= 0 {
            let next = try digitValue(digits[index]) - 1
            if next == -1 {
                digits[index] = largest
            } else {
                digits[index] = try digit(next)
                borrow = false
            }
            index -= 1
        }
        if !borrow { return [head] + digits }
        if head == UInt8(ascii: "a") { return [UInt8(ascii: "Z"), largest] }
        if head == UInt8(ascii: "A") { return nil }
        let nextHead = head - 1
        if nextHead < UInt8(ascii: "Z") { digits.append(largest) } else { digits.removeLast() }
        return [nextHead] + digits
    }
}
