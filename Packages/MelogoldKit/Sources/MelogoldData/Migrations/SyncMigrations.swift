import Foundation
import GRDB

/// Снимки синка (`sync_state`, `synced_likes`, `synced_bookmarks`, `synced_playlists`, `synced_lyrics`) — срез 5,
/// его ведёт отдельная сессия. Миграции применяются после `LibraryMigrations`, дописываются в конец списка.
enum SyncMigrations {
    static let all: [DatabaseMigration] = []
}
