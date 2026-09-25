import Foundation

/// Версия приложения: одно место — `MARKETING_VERSION` в `Config/Version.xcconfig`, без суффиксов.
/// Номер сборки считается из неё, как `versionCode` Android: major×10000 + minor×100 + patch (docs/PROMPT.md §3).
public enum AppVersion {
    /// Номер сборки для «X.Y.Z», или `nil`, если строка не такая.
    public static func buildNumber(for version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        guard numbers[1] < 100, numbers[2] < 100 else { return nil }
        return numbers[0] * 10_000 + numbers[1] * 100 + numbers[2]
    }

    /// `CFBundleShortVersionString` приложения, в котором работает код.
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// `CFBundleVersion`.
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
