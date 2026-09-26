# Выпуск для Mac: DMG в GitHub Releases и обновления через Sparkle

Статус: в работе

Дополнение к `docs/PROMPT.md` (§3 «Обновления», грабли §9, п. 13–17), срез 8.

## 1. Что нужно пользователю

- Версия для Mac скачивается из GitHub Releases одним DMG: открыть, перетащить Melogold в «Программы».
- Дальше приложение обновляется само, как на Android и Windows: находит новую версию, показывает «Что нового» на русском или английском, ставит её и перезапускается.
- Релиз собирается в GitHub Actions, а не на Mac пользователя.
- Секреты — только в GitHub Secrets. Если их нет, workflow всё равно собирает DMG — без подписи Apple — и говорит об этом.

## 2. Решение

**Запуск:** `.github/workflows/release-macos.yml` — по тегу `vX.Y.Z` и вручную (`workflow_dispatch`). Раннер — macOS с тем же Xcode, что в CI (`docs/PROMPT.md` §3). Сами шаги — в `scripts/release-macos.sh`: workflow зовёт его, локально он запускается с `--dry-run`, без публикации.

**Версия:**
- `MARKETING_VERSION` в `Config/Version.xcconfig` — единственное место. Тег обязан совпасть с ней, иначе стоп.
- `CURRENT_PROJECT_VERSION` = major×10000 + minor×100 + patch.
- «Что нового» — `release-notes/X.Y.Z.ru.md` и `.en.md`, как у Windows. Без них выпуск не идёт.

**Шаги:**
1. `xcodebuild archive` схемы `Melogold`, `generic/platform=macOS`, Release, Hardened Runtime.
2. Подпись:
   - с секретами — временная связка ключей на раннере (`security create-keychain`, импорт .p12, `security set-key-partition-list`) и `xcodebuild -exportArchive` с `method = developer-id`;
   - без секретов — ad-hoc (`codesign --force --deep --sign -`) и без нотаризации.
3. Проверка собранного приложения: `CFBundleShortVersionString` = версия, `CFBundleVersion` = номер сборки, в `Info.plist` есть `SUFeedURL` и `SUPublicEDKey`. Иначе стоп: такое приложение не обновится никогда, и молча.
4. Нотаризация (с секретами): zip через `ditto` → `xcrun notarytool submit --key … --key-id … --issuer … --wait` → `xcrun stapler staple` приложения.
5. DMG: `hdiutil` из папки с `Melogold.app` и ссылкой на `/Applications`, формат UDZO, имя `Melogold-X.Y.Z.dmg`. С секретами — подпись DMG, его нотаризация и `xcrun stapler staple` самого DMG.
6. Appcast:
   - `generate_appcast` из Sparkle, ключ — из секрета через `--ed-key-file` (временный файл, в конце удаляется), `--download-url-prefix https://github.com/melogold-app/melogoldiOSmacOS/releases/download/vX.Y.Z/`;
   - в appcast — `sparkle:minimumSystemVersion` 26.0 и «Что нового» на двух языках (`xml:lang`). Если `generate_appcast` не даёт двух языков — `sign_update` и свой шаблон `appcast.xml`;
   - без ключа Sparkle appcast не публикуется.
7. Публикация: `gh release create vX.Y.Z Melogold-X.Y.Z.dmg appcast.xml --title "Melogold X.Y.Z" --notes-file <ru и en> --latest`. Тег — на собранный коммит; у workflow `permissions: contents: write`.
8. Итог в `$GITHUB_STEP_SUMMARY`: подписан ли DMG, нотаризован ли, есть ли appcast; чего не хватило — именами секретов.

Если секретов подписи нет, в описании релиза — строка, как открыть: «Системные настройки › Конфиденциальность и безопасность › Всё равно открыть».

**В приложении (Sparkle 2, только таргет Mac):**
- `SPUStandardUpdaterController`; «Проверить обновления…» в меню приложения и в «Настройки › О приложении»;
- `SUFeedURL` = `https://github.com/melogold-app/melogoldiOSmacOS/releases/latest/download/appcast.xml` — без лимитов API GitHub, как `update.json` у Android и Windows;
- `SUPublicEDKey` — публичный ключ, он лежит в репозитории;
- `SUEnableAutomaticChecks` = YES и `SUScheduledCheckInterval` = 21600: проверка идёт сама, не чаще раза в 6 часов, без вопроса при втором запуске;
- окно обновления — стандартное Sparkle (у него есть русский перевод). Установка — с согласия пользователя, не тихая.

## 3. Секреты

GitHub › репозиторий › Settings › Secrets and variables › Actions. Имена точно такие:

| Секрет | Что это |
|---|---|
| `APPLE_TEAM_ID` | ID команды Apple Developer (10 символов) |
| `MACOS_DEVELOPER_ID_P12_BASE64` | сертификат «Developer ID Application» с закрытым ключом, файл .p12 в base64 |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | пароль этого .p12 |
| `ASC_API_KEY_ID` | Key ID ключа App Store Connect API (нотаризация; тот же ключ — в задании 0005) |
| `ASC_API_ISSUER_ID` | Issuer ID того же ключа |
| `ASC_API_KEY_P8_BASE64` | файл `AuthKey_<Key ID>.p8` в base64 |
| `SPARKLE_ED_PRIVATE_KEY` | закрытый ключ EdDSA Sparkle — строка из `generate_keys -x` |

- Подпись без нотаризации не делай: пользователю она не лучше ad-hoc. Полная цепочка — только когда есть все секреты подписи и нотаризации (`APPLE_TEAM_ID`, `MACOS_DEVELOPER_ID_*`, `ASC_API_*`).
- Пару ключей Sparkle создаёт сессия на Mac (`generate_keys`) с согласия пользователя. Публичный — в `Info.plist`, закрытый — в секрет. Резервную копию закрытого хранит пользователь: секрет GitHub назад не прочитать, а без ключа установленные Mac больше не обновятся сами.

## 4. Проверка

- Workflow без секретов зелёный: в релизе DMG с ad-hoc-подписью, в итоге — каких секретов не хватает.
- С секретами: `spctl -a -vv` и `xcrun stapler validate` проходят для приложения и DMG; DMG, скачанный браузером, открывается без предупреждений.
- Обновление: поставить X.Y.Z из DMG, выпустить X.Y.(Z+1), «Проверить обновления…» → Sparkle находит новую версию, ставит, перезапускает; «О приложении» показывает новую версию. Первый раз — 0.1.0 → 0.1.1.
- Для ad-hoc-сборки проверь, ставит ли Sparkle следующую ad-hoc-сборку. Если нет — скажи пользователю, что автообновлению нужен Developer ID.
