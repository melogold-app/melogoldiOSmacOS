# Векторы правил

Копии общих файлов правил: те же случаи прогоняют сервер, Android, Windows и этот клиент (Swift Testing в `Packages/MelogoldKit/Tests`). Случаи здесь не правятся — только копируются заново из источника.

| Файл | Правило | Источник |
|---|---|---|
| `server-address.vectors.json` | адрес сервера, API §7.1 | `melogoldAndroid/docs/spec`, коммит `0348ed26` |
| `youtube-links.vectors.json` | ссылки YouTube, REWRITE §4.9 | `melogoldAndroid/docs/spec`, коммит `0348ed26` |
| `title-cleaner.vectors.json` | очистка названий, REWRITE §4.10.8 | `melogoldAndroid/docs/spec`, коммит `0348ed26` |
| `lyrics.vectors.json`, `lyrics.md` | модель текстов, LRC и TTML | `melogoldAndroid/docs/spec`, коммит `0348ed26` |
| `import-ids.vectors.json` | ImportIds — id прослушиваний из копии | `melogoldAndroid/docs/spec`, коммит `0348ed26` |
| `backup-format.md` | формат копии библиотеки | `melogoldAndroid/docs/spec`, коммит `64db1bc4` |
| `hwid.vectors.json` | идентификатор устройства, API §1.6 | `melogoldServer/spec`, коммит `90f5149` |
| `pow.vectors.json` | доказательство работы при регистрации, API §4.3 | `melogoldServer/spec`, коммит `90f5149` |
| `playlist-ops.vectors.json` | ключи порядка и ops плейлиста, API §4.8 | `melogoldServer/spec`, коммит `90f5149` |
| `error-codes.json` | реестр кодов ошибок, API §2 | `melogoldServer/spec`, коммит `90f5149` |

Обновить: скопировать файлы из источника (`git -C ../melogoldAndroid show origin/main:docs/spec/<файл>`), поправить коммит в таблице, прогнать `swift test` в `Packages/MelogoldKit`.
