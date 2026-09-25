import Foundation
import GRDB
import MelogoldCore

/// База приложения — SQLite через GRDB (docs/PROMPT.md §3 «Данные»). Схема и имена — как у Windows
/// (`src/Melogold.Core/Data/LibraryDatabase.cs`), чего у Windows нет — по Android REWRITE §4.2 и §4.12a.
/// Кэш музыки и загрузки — только локально, в синк и копию библиотеки не входят.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// База в `Application Support/Melogold/melogold.sqlite`, режим WAL.
    public static func open(at url: URL) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "melogold"
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// База в памяти — для тестов.
    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    /// Миграции по порядку: сначала библиотека и кэш (`LibraryMigrations`), затем синк (`SyncMigrations`).
    /// Миграции только дописываются в конец своего списка и после выпуска не меняются.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for migration in LibraryMigrations.all + SyncMigrations.all {
            migrator.registerMigration(migration.identifier, migrate: migration.migrate)
        }
        return migrator
    }
}

/// Одна миграция базы: имя и шаг.
public struct DatabaseMigration: Sendable {
    public let identifier: String
    public let migrate: @Sendable (Database) throws -> Void

    public init(_ identifier: String, migrate: @escaping @Sendable (Database) throws -> Void) {
        self.identifier = identifier
        self.migrate = migrate
    }
}

/// Время в базе — epoch-мс UTC (API §1.5).
public enum EpochMs {
    public static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}
