# Ход работы: Melogold для Apple

Что сделано по срезам `docs/PROMPT.md` §7, как проверено и что осталось. Следующая сессия продолжает отсюда.

## Как проверять

- `scripts/generate-project.sh` — проект из `project.yml` (XcodeGen собирается из `BuildTools/`).
- `swift test --package-path Packages/MelogoldKit` — правила и общие векторы (`spec/`).
- Сборки (одна `xcodebuild` за раз — Mac общий):
  - `xcodebuild -scheme Melogold -destination 'generic/platform=iOS Simulator' build` — iPhone, iPad и встроенные часы;
  - `-destination 'platform=macOS'`, `'generic/platform=visionOS Simulator'`; схема `Melogold Watch` — `'generic/platform=watchOS Simulator'`.
- UI-тесты iPhone: `TEST_RUNNER_MELOGOLD_SHOTS_DIR=<папка> xcodebuild test -scheme Melogold -destination 'platform=iOS Simulator,id=<UDID>'` — нажатия и снимки экрана.
- Симуляторы: iPhone 18 Pro `0FAF8790-…`, iPad Pro 13 `AB782A98-…`, Apple Watch Series 12 46 мм `4BC3A3E8-…`, Apple Vision Pro `DC9E9E35-…`.
  Параметры запуска: `-shell.lastTab <раздел>`, `-AppleLanguages "(ru)"`, `-MelogoldOpenURL <ссылка>`.
- Mac: пока экран заблокирован, системный снимок чёрный; отладочная сборка снимает своё окно сама
  (`-MelogoldSnapshotPath <png> -MelogoldSnapshotQuit YES`), но боковую панель на стекле в такой снимок система не отдаёт.

## Срезы

| Срез | Состояние | Коммит |
|---|---|---|
| 0. Бриф и задания под самостоятельные часы | сделано | `093a014` |
| 1. Каркас | сделано | см. `git log --grep "каркас"` |
| 2. Воспроизведение (+ задание 0003) | не начат | |
| 3. Каталог | не начат | |
| 4. Библиотека | не начат | |
| 5. Аккаунт и синк (+ 0002) | не начат | |
| 6. Тексты (+ 0001) | не начат | |
| 7. Отделка плеера | не начат | |
| 8. Выпуск (+ 0004, 0005, 0006) | не начат | |

### Срез 1. Каркас

Сделано:
- `project.yml` → `Melogold.xcodeproj`: таргет `Melogold` (iOS, macOS, visionOS — одно приложение), `Melogold Watch` (самостоятельное приложение watchOS, встроено в iOS), `MelogoldUITests`; версия в `Config/Version.xcconfig` (0.1.0, сборка 100), `scripts/set-version.sh` и `scripts/check-version.sh`.
- Пакет `MelogoldKit`: `MelogoldCore` (разделы, ключи настроек Android, `ServerAddressPolicy`, ссылки `melogold://`, журнал, MetricKit, версия), `MelogoldData` (папки `Application Support/Melogold` с `isExcludedFromBackup` у кэша и загрузок, настройки на `UserDefaults`), заготовки `MelogoldInnerTube`, `MelogoldServer`, `MelogoldPlayback`.
- Оболочка: iPhone и Vision — `TabView` с `Tab(role: .search)` (iOS 26: поле поиска внизу, в панели вкладок); iPad в широком окне и Mac — `NavigationSplitView` с одной `NavigationStack` в колонке детали; повторное нажатие на раздел — к корню; последний раздел при запуске; Mac — одно окно, ⌘1…⌘5, ⌘F, ⌘, и ⌘[.
- Настройки: «работает без аккаунта», «Сервер Melogold» (адрес по `ServerAddressPolicy`, «Незащищённое соединение» для http), тема, язык, версия.
- Ссылки `melogold://server` (экран «Сервер» с адресом) и `melogold://link` (инструкция; вход — срез 5).
- Иконки: `.icon` для iPhone, iPad, Mac и часов; набор visionOS (`AppIcon.solidimagestack`) из того же рисунка.
- Строки — `Shared/Resources/Localizable.xcstrings` (ru и en), `scripts/strings.py`; `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption = NO`.
- CI: `.github/workflows/ci.yml` на образе `xcode-27`.

Проверено:
- `swift test`: 18 тестов, 37 векторов адреса сервера.
- Сборка: macOS, iOS Simulator (с часами), visionOS Simulator, watchOS Simulator.
- UI-тесты iPhone (6): повторное нажатие → корень, стеки разделов сохраняются, раздел восстанавливается после перезапуска, поле поиска внизу, ссылка `melogold://server` открывает «Сервер».
- Запуск: iPhone 18 Pro, iPad Pro 13 (боковая панель), Apple Watch Series 12 без iPhone, Apple Vision Pro (орнамент разделов), Mac (окно, колонка детали; боковая панель — только после разблокировки экрана).

Не сделано в срезе 1: снимок Mac с боковой панелью (экран Mac заблокирован); проверка меню Mac клавишами.
