# App Store и TestFlight: iPhone, iPad, Vision Pro, Apple Watch

Статус: открыто

Дополнение к `docs/PROMPT.md` (§3, грабли §9, п. 19), срез 8.

## 1. Что нужно пользователю

- iPhone, iPad, Apple Vision Pro и Apple Watch получают Melogold через App Store.
- Друзья тестируют через TestFlight.
- Сборки собираются и загружаются в App Store Connect из GitHub Actions. Секреты — только в GitHub Secrets.

## 2. Решение

- **Запись приложения** в App Store Connect одна: bundle ID `app.melogold.Melogold`, платформы iOS (iPhone и iPad) и visionOS. Приложение часов (`app.melogold.Melogold.watchkitapp`) едет внутри сборки iOS, своей записи у него нет. Mac в App Store не идёт (задание 0004).
- **Без fastlane:** хватает `xcodebuild` и ключа App Store Connect API — меньше зависимостей.
- **Workflow** `.github/workflows/testflight.yml` — по тегу `vX.Y.Z` и вручную (`workflow_dispatch`):
  1. временная связка ключей с «Apple Distribution» из секретов, ключ API — во временный файл;
  2. `xcodebuild archive` схемы `Melogold` для `generic/platform=iOS` (часы — внутри) и отдельно для `generic/platform=visionOS`, с `-allowProvisioningUpdates` и `-authenticationKeyPath`, `-authenticationKeyID`, `-authenticationKeyIssuerID`: профили подписи создаются сами;
  3. `xcodebuild -exportArchive` с `method = app-store-connect` и `destination = upload` — сборка уходит в App Store Connect тем же ключом;
  4. итог в `$GITHUB_STEP_SUMMARY`.
- **Версия и номер сборки** — как у Mac (`docs/PROMPT.md` §3). Одну версию дважды не загрузить: для повтора подними patch.
- **«Что тестировать»** в TestFlight — из `release-notes/X.Y.Z.ru.md` и `.en.md` через App Store Connect API, если это просто; иначе поле пустое.
- **Без секретов** архивы собираются без подписи (`CODE_SIGNING_ALLOWED=NO`), загрузки нет; в итоге — каких секретов не хватило.
- **`Info.plist` и манифест:**
  - `ITSAppUsesNonExemptEncryption = NO`;
  - `PrivacyInfo.xcprivacy` (образец — Clementine) с причинами для `UserDefaults`, времени файлов и свободного места;
  - описания разрешений: локальная сеть, Siri.
- **Тестирование:** внутренние тестировщики получают сборку сразу после обработки; внешние (друзья по ссылке) — после проверки бета-версии Apple. Публикация в App Store — только по команде пользователя.
- **Отказ проверки Apple:** покажи пользователю причину дословно и жди решения. Обходить правила проверки не пытайся.

## 3. Секреты

Те же `APPLE_TEAM_ID`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID` и `ASC_API_KEY_P8_BASE64`, что в задании 0004 (роль ключа — App Manager или Admin), и ещё:

| Секрет | Что это |
|---|---|
| `APPLE_DISTRIBUTION_P12_BASE64` | сертификат «Apple Distribution» с закрытым ключом, файл .p12 в base64 |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | пароль этого .p12 |

## 4. Что сделает пользователь

Когда будет удобно: аккаунт Apple Developer (подойдёт команда Clementine VPN), запись Melogold в App Store Connect с bundle ID `app.melogold.Melogold` и платформами iOS и visionOS, ключ App Store Connect API и сертификат «Apple Distribution» — в секреты, а для CarPlay — запрос права CarPlay Audio у Apple.

## 5. Проверка

- Workflow без секретов зелёный: оба архива собраны, в итоге — каких секретов не хватает.
- С секретами: сборки iOS и visionOS появляются в TestFlight; на iPhone из TestFlight ставятся приложение и приложение часов; на iPad — то же приложение.
