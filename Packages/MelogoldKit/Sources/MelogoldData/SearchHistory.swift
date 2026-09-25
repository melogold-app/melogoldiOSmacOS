import Foundation
import GRDB
import MelogoldCore

/// «Недавние запросы» Поиска (REWRITE §3.1.1): до 10 последних, при «Не сохранять историю» не пишутся.
public struct SearchHistory: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func recent(limit: Int = 10) -> [String] {
        (try? database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT query FROM search_history ORDER BY searched_at DESC LIMIT ?", arguments: [limit])
        }) ?? []
    }

    public func add(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = try? database.writer.write { db in
            try db.execute(sql: "INSERT INTO search_history (query, searched_at) VALUES (?, ?) ON CONFLICT(query) DO UPDATE SET searched_at = excluded.searched_at",
                           arguments: [text, EpochMs.now()])
        }
    }

    public func remove(_ query: String) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "DELETE FROM search_history WHERE query = ?", arguments: [query])
        }
    }

    public func clear() {
        _ = try? database.writer.write { db in try db.execute(sql: "DELETE FROM search_history") }
    }
}
