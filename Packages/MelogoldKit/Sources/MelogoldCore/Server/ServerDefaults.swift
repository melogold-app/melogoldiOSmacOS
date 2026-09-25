/// Константы сборки для сервера Melogold.
public enum ServerDefaults {
    /// Адрес сервера по умолчанию (docs/PROMPT.md §1). Скоро у сервера будет нормальный домен, старый адрес
    /// продолжит работать; смена — правкой этой константы.
    public static let baseURL = "https://178-250-187-202.sslip.io"

    /// Официальный сервер для значка «Официальный» (API §7.1 п. 5): origin и `serverId` должны совпасть.
    public static let officialOrigin = "https://api.melogold.app"
}
