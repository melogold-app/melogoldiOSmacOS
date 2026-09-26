# Копия библиотеки Melogold, формат 1

Один файл SQLite 3. Его делает «Сохранить копию» любого клиента Melogold (Android, Windows, Apple), а «Импорт» любого клиента читает. Устроен он как копия ViTune и ViMusic: те же таблицы и колонки плюс несколько колонок Melogold. Поэтому у каждого клиента один читатель на всё: копию ViTune, ViMusic, их форков и Melogold любой платформы.

Эталон — Android:
- чтение и слияние: `app/src/main/kotlin/app/melogold/android/data/importer/LegacyImporter.kt`;
- id прослушиваний: `core/domain/src/main/kotlin/app/melogold/domain/importer/ImportIds.kt`, векторы `docs/spec/import-ids.vectors.json`;
- тест: `app/src/testDebug/kotlin/app/melogold/android/data/importer/LegacyImporterTest.kt`.

## 1. Файл

- Имя: `Melogold_backup_<ггггММддЧЧммсс>.db`.
- `PRAGMA user_version` не меньше 31. Android пишет версию своей базы Room (сейчас 36), Windows и Apple — 31.
- `journal_mode=DELETE`: копия — один файл, без `-wal` и `-shm`.
- Снимок цельный, даже если база в это время пишется:
  - Android — `VACUUM INTO` (API 30+), до API 30 — копия файла под блокировкой записи;
  - Windows и Apple — все таблицы копии читаются в одной читающей транзакции.
- Таблица-метка `MelogoldBackup(key TEXT PRIMARY KEY, value TEXT)`, строки:
  - `format` = `1`;
  - `platform` — `android`, `windows`, `macos`, `ios`, `ipados`, `visionos` (API §1.6);
  - `appVersion`;
  - `createdAt` — ISO 8601 UTC.

  Метка нужна для сообщений и логов, читатель её не требует: в копиях ViTune и в старых копиях Android её нет.
- Прочие таблицы и колонки читатель пропускает, отсутствующая колонка читается как NULL.

## 2. Таблицы

Имена таблиц и колонок — с учётом регистра, как ниже. Время — миллисекунды Unix, `INTEGER`. Логические значения — `0` и `1`.

| Таблица | Колонки | Смысл |
|---|---|---|
| `Song` | `id TEXT PRIMARY KEY` | `videoId` YouTube |
| | `title TEXT NOT NULL`, `artistsText TEXT`, `durationText TEXT` («3:45»), `thumbnailUrl TEXT` | как в каталоге |
| | `likedAt INTEGER` | в Избранном с этого момента; `NULL` — нет |
| | `totalPlayTimeMs INTEGER NOT NULL DEFAULT 0` | сколько всего слушали |
| | `blacklisted INTEGER NOT NULL DEFAULT 0` | трек скрыт |
| | `explicit INTEGER NOT NULL DEFAULT 0` | |
| `Event` | `id INTEGER PRIMARY KEY` | порядковый номер в файле |
| | `songId TEXT NOT NULL`, `timestamp INTEGER NOT NULL`, `playTime INTEGER NOT NULL` | прослушивание: трек, начало, сколько играл |
| | `syncId TEXT` | `eventId` операции `play.add` (API §4.4) |
| | `deviceId TEXT` | id устройства аккаунта на сервере, которое играло; `NULL` — устройство, сделавшее копию |
| `Lyrics` | `songId TEXT PRIMARY KEY` | |
| | `fixed TEXT`, `synced TEXT` | обычный текст; синхронный (LRC или TTML) |
| | `startTime INTEGER` | где начинается синхронный текст; положительный — позже. У Windows и Apple `offset_ms = −startTime` |
| | `fixedSource TEXT`, `syncedSource TEXT` | откуда текст: `User`, `File`, `YouTubeMusic`, `LrcLib`, `KuGou` |
| `Album` | `id TEXT PRIMARY KEY` (`browseId`), `title`, `thumbnailUrl`, `year`, `authorsText`, `shareUrl` — `TEXT` | |
| | `timestamp INTEGER`, `bookmarkedAt INTEGER` | `bookmarkedAt` — сохранён в Библиотеку |
| `Artist` | `id TEXT PRIMARY KEY` (`browseId` или `channelId`), `name`, `thumbnailUrl` — `TEXT`; `timestamp`, `bookmarkedAt` — `INTEGER` | |
| `SongAlbumMap` | `songId TEXT`, `albumId TEXT`, `position INTEGER` | трек в альбоме |
| `SongArtistMap` | `songId TEXT`, `artistId TEXT` | исполнитель трека |
| `Playlist` | `id INTEGER PRIMARY KEY`, `name TEXT NOT NULL`, `browseId TEXT`, `thumbnail TEXT` | свой плейлист; `browseId` — связанный плейлист YouTube |
| | `syncId TEXT` | id плейлиста на сервере аккаунта |
| `SongPlaylistMap` | `songId TEXT`, `playlistId INTEGER`, `position INTEGER` | порядок 0…n−1 |
| `SearchQuery` | `id INTEGER PRIMARY KEY`, `query TEXT` | история поиска, новые — с большим `id` |

В копию не входят:
- настройки, вход в аккаунт и токены, состояние синка;
- кэш музыки, загрузки, обложки;
- тексты, найденные в сети автоматически, — их можно не класть. Свои тексты (`User`, `File`) кладутся всегда.

## 3. Чтение (импорт)

1. **Файл.** Копировать во временную папку и работать с копией, оригинал не трогать. Первые 16 байт должны быть `SQLite format 3\0`. Открыть и выполнить `PRAGMA journal_mode=DELETE`.
2. **Распознавание:**
   - есть `Song` → этот формат: ViTune, ViMusic, их форки, Melogold любой платформы;
   - есть `song` в нижнем регистре → InnerTune, Metrolist и родня: «Копии InnerTune, Metrolist и похожих приложений пока не поддерживаются»;
   - `user_version` от 1 до 11 → «Эта копия слишком старая»;
   - иначе → «Это не копия ViTune, ViMusic или Melogold».

   Колонки читаются по наличию (`PRAGMA table_info`). У ViMusic v11 таблица плейлиста называется `SongInPlaylist`.
3. **Слияние** — одна транзакция. Сбой посередине не меняет ничего, из библиотеки ничего не удаляется.
   - **Даты.** Прослушивания, лайки и закладки со временем вне [2000-01-01, 2100-01-01) — то есть вне [946684800000, 4102444800000) — отбрасываются: сервер их не примет. Число идёт в итог.
   - **Song.**
     - `id` не по `^[A-Za-z0-9_-]{11}$` — локальный файл: пропуск, число идёт в итог.
     - Пустой `title` → `title = id`; `likedAt` учитывается только больше нуля.
     - Трек новый — добавить. Трек уже есть — взять самый ранний лайк и наибольшее `totalPlayTimeMs`, заполнить пустые исполнителя, длительность и обложку, заменить заглушку-название (равно `id`); `blacklisted` и `explicit` — «или».
   - **Event** — только для треков, которые есть в библиотеке после шага Song.
     - `playTime` зажать в 1…86 400 000.
     - Прослушивание того же трека в тот же `timestamp` уже есть → пропуск, число идёт в итог («уже были»).
     - id прослушивания — `syncId` из копии. Если его нет — UUIDv5 от пространства `4a3b8c8a-1d9c-48f2-938b-3077d54ab4fb` и строки `"<videoId>|<timestamp>|<playTime>"` из уже зажатых значений, в нижнем регистре. Поэтому одна копия, импортированная на двух устройствах, не удвоит историю на сервере.
     - `deviceId` сохраняется. Прослушивание с `deviceId` уже есть на сервере: оно отмечается отправленным. Остальные уходят как свои `play.add` этого устройства.
   - **Lyrics.** Заполняются только пустые стороны (`NULL` или пустая строка): обычный текст, синхронный вместе со `startTime`. Источники переносятся вместе со своей стороной.
   - **Album, Artist.**
     - Недостающие строки добавляются. Закладка — самая ранняя из двух.
     - `SongAlbumMap` и `SongArtistMap` — только если обе стороны есть.
   - **Playlist.** Совпадение ищется по порядку:
     1. тот же `syncId`;
     2. тот же `browseId`;
     3. ровно один ещё не занятый плейлист с тем же `norm(name)`.

     Совпал — недостающие треки дописываются в конец в порядке копии. Не совпал — новый плейлист с новым id, без `syncId` из копии. Каждый плейлист библиотеки занимается один раз. Пустое имя → «—». Имя не длиннее 200 единиц UTF-16.

     `norm(s)`: NFKC → trim → схлопнуть пробельные символы в один пробел → нижний регистр. Так же сопоставляет сервер (API §4.7).
   - **SearchQuery** — последние 200.
4. **Итог.**
   - Числа: новых треков, прослушиваний, в Избранном, текстов, плейлистов (новых и дополненных), сохранённых альбомов и исполнителей.
   - Треки и тексты считаются только у треков, которые библиотека показывает: прослушанных, в Избранном, в плейлистах. ViTune хранит и треки всех альбомов, которые просто открывали (в настоящей копии — 1132 из 1330). Они тоже импортируются, для страниц альбомов и текстов, но в итог не входят: пользователь нигде их не найдёт.
   - Примечания, если числа не нулевые: «уже были», «локальные файлы не перенесены», «невозможные даты пропущены».
   - При входе в аккаунт: «На другие устройства история уйдёт через сервер постепенно — до 2000 прослушиваний в час».

   Тексты — как в `app/src/main/res/values*/strings_import.xml`.
5. **Синк после импорта.** При входе в аккаунт:
   - прослушивания уходят как неотправленные `play.add`, пачками, с учётом `retryAfter`;
   - затем заново `play.baseline atLeast`: у Android для этого сбрасывается метка базовой линии;
   - лайки, закладки и плейлисты уходят обычным синком библиотеки.

## 4. Запись (экспорт)

Экспорт пишет таблицы раздела 2 и метку `MelogoldBackup`. Затем `PRAGMA user_version` и `journal_mode=DELETE`. Файл сначала пишется рядом под временным именем и только потом переименовывается.

- **Android:** база Room и есть этот формат. Экспорт — снимок базы (п. 1) плюс метка.
- **Windows и Apple:** своя схема переводится в таблицы раздела 2:

  | Откуда | Куда |
  |---|---|
  | `tracks` | `Song`: `video_id → id`, `artists_text → artistsText`, `duration_text → durationText` (если пусто — из `duration_ms` как `m:ss`), `thumbnail_url → thumbnailUrl`, `liked_at → likedAt`, `total_play_ms → totalPlayTimeMs`, `explicit` |
  | `content_blocks` с `type = 'track'` | `Song.blacklisted = 1` |
  | `albums`, `artists` | `Album`, `Artist`: `browse_id → id`, `bookmarked_at → bookmarkedAt`, `artists_text → authorsText` |
  | `tracks.album_id`, исполнители трека с `browseId` | `SongAlbumMap`, `SongArtistMap` (только на строки `Album` и `Artist` из копии) |
  | `playlists`, `playlist_items` | `Playlist` (`sync_id → syncId`, `thumbnail_url → thumbnail`), `SongPlaylistMap` (`video_id → songId`, `position`) |
  | `play_events` | `Event`: `event_id → syncId`, `video_id → songId`, `played_at → timestamp`, `play_time_ms → playTime`, id устройства → `deviceId` (своё — `NULL`) |
  | `lyrics` | `Lyrics`: `plain → fixed`, `synced`, `startTime = −offset_ms` (0 → `NULL`), источники из слов API (`user`, `file`, `youtube_music`, `lrclib`, `kugou`) в `User`, `File`, `YouTubeMusic`, `LrcLib`, `KuGou` |
  | `search_history` | `SearchQuery` по возрастанию `searched_at` |

  Импорт переводит обратно по той же таблице.

## 5. Проверка у каждого клиента

- Синтетическая копия ViTune v30 из теста Android: 2 трека (1 локальный), 5 прослушиваний (1 с невозможной датой, 1 у локального), текст, закладка альбома, плейлист «Дорога», поиск. Ожидается: треков 2, локальных 1, прослушиваний 3, дат пропущено 1, в Избранном 1, текстов 1, плейлистов 1, сохранённых 1. Повторный импорт: прослушиваний 0, «уже были» 3.
- Векторы `import-ids.vectors.json` — все четыре.
- Круг: экспорт → импорт в пустую библиотеку даёт те же числа. Экспорт на одной платформе → импорт на другой.
- Настоящая копия ViTune v30 есть у пользователя. Она приватная, в репозиторий не класть. В пустой библиотеке ожидается: 195 треков, 16 046 прослушиваний, 21 в Избранном, 173 текста, 3 сохранённых, 16 локальных пропущено.
