import Foundation

/// Форма множественного числа по правилам CLDR для русского и английского (GLOSSARY §1.4). Нужна там, где подпись не
/// содержит числа («минута музыки за год»): String Catalog требует числа в подписи с вариациями, поэтому форма выбирается
/// здесь и подставляется в ключ: `stats.wrapped.minutes.<форма>`.
public enum PluralCategory: String, Sendable {
    case one, few, many, other

    public static func of(_ count: Int, language: String) -> PluralCategory {
        let n = abs(count)
        if language == "ru" {
            if n % 10 == 1, n % 100 != 11 { return .one }
            if (2 ... 4).contains(n % 10), !(12 ... 14).contains(n % 100) { return .few }
            return .many
        }
        return n == 1 ? .one : .other
    }
}
