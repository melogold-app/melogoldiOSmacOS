import Foundation

/// Коды, которые человек вводит руками (API §1.6): код входа `XXXX-XXXX` и код восстановления
/// `XXXX-XXXX-XXXX-XXXX-XXXX`. Алфавит Crockford; ввод: верхний регистр, пробелы, `-` и `_` убираются, `O→0`,
/// `I` и `L → 1`.
public enum LinkCode {
    static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Код входа из ввода: восемь символов или `nil`.
    public static func userCode(_ input: String) -> String? {
        normalize(input, length: 8)
    }

    /// Код восстановления из ввода: двадцать символов или `nil`.
    public static func recoveryCode(_ input: String) -> String? {
        normalize(input, length: 20)
    }

    /// `K7QXM2PD` → `K7QX-M2PD`: группы по четыре.
    public static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4)
            .map { start in
                let from = code.index(code.startIndex, offsetBy: start)
                return String(code[from ..< (code.index(from, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex)])
            }
            .joined(separator: "-")
    }

    static func normalize(_ input: String, length: Int) -> String? {
        var result = ""
        for character in input.uppercased() {
            switch character {
            case " ", "-", "_", "\t", "\n": continue
            case "O": result.append("0")
            case "I", "L": result.append("1")
            default:
                guard alphabet.contains(character) else { return nil }
                result.append(character)
            }
        }
        return result.count == length ? result : nil
    }
}
