<p align="center">
  <img src=".github/melogold-icon.png" width="128" height="128" alt="Melogold">
</p>

<h1 align="center">Melogold для Apple</h1>

<p align="center">Клиент <a href="https://github.com/melogold-app/melogoldAndroid">Melogold</a> для iPhone, iPad, Mac, Apple Vision Pro и Apple Watch: музыка из YouTube Music и обычного YouTube с общими Избранным, плейлистами и сохранёнными альбомами на всех устройствах.</p>

## Статус

В разработке. Основа клиента — [docs/PROMPT.md](docs/PROMPT.md), задания — [tasks/](tasks/).

- **Платформы:** iPhone, iPad, Mac, Apple Vision Pro и Apple Watch — iOS, iPadOS, macOS, visionOS и watchOS 26 и новее.
- **Приложение:** Swift и SwiftUI, одна кодовая база; часы — самостоятельное приложение: свой вход, поиск, поток и загрузки без iPhone.
- **Распространение:**
  - iPhone, iPad, Vision Pro и часы — App Store, тесты — TestFlight;
  - Mac — DMG из [GitHub Releases](https://github.com/melogold-app/melogoldiOSmacOS/releases), дальше приложение
    обновляется само через Sparkle (см. [«Скачать для Mac»](#скачать-для-mac)).
- Работает без аккаунта; по желанию — вход на [сервер Melogold](https://github.com/melogold-app/melogoldServer) и
  синхронизация.

Иконка приложения — `Melogold.icon` (Icon Composer, Liquid Glass) и `Assets/AppIcon-1024.png`.

## Скачать для Mac

1. Скачайте `Melogold-<версия>.dmg` из [последнего выпуска](https://github.com/melogold-app/melogoldiOSmacOS/releases/latest)
   (macOS 26 и новее, Apple silicon и Intel).
2. Откройте DMG и перетащите Melogold в «Программы». Запускайте из «Программ»: из DMG или «Загрузок» приложение не
   сможет обновить само себя.
3. Первый запуск: macOS скажет, что не может проверить приложение. Нажмите «Готово», откройте «Системные настройки ›
   Конфиденциальность и безопасность» и внизу нажмите «Всё равно открыть» рядом с Melogold, затем подтвердите.
   Это нужно один раз.
4. Дальше приложение обновляется само (Sparkle): раз в несколько часов проверяет новый выпуск и спрашивает, ставить
   ли его. Вручную — «Melogold › Проверить обновления…».

**Почему macOS предупреждает.** Предупреждение показывается для любого приложения, которое не прошло нотаризацию Apple,
а нотаризация доступна только участникам платной программы Apple Developer. Melogold распространяется бесплатно, с
открытым кодом, и ему эта программа не нужна: приложение не использует того, что Apple открывает только
разработчикам с аккаунтом (сетевые расширения, как у VPN-клиентов, iCloud, push-уведомления). VPN-клиенту без
аккаунта разработчика на организацию не обойтись, потому что системное сетевое расширение без него не запустится.
Плееру, который просто играет звук и ходит в интернет, достаточно обычной подписи.

Что защищает вместо нотаризации:

- каждый выпуск собирается из этого репозитория на GitHub Actions ([workflow](.github/workflows/release-macos.yml)) —
  его можно проверить и пересобрать самому;
- приложение подписано постоянным сертификатом Melogold, а каждое обновление ещё и ключом EdDSA: Sparkle не установит
  файл, подписанный кем-то другим, даже если его подменят на GitHub.

Если «Всё равно открыть» не появилось, можно снять карантин в Терминале:
`xattr -dr com.apple.quarantine /Applications/Melogold.app`.

iPhone, iPad, Apple Vision Pro и Apple Watch получат Melogold через App Store и TestFlight — это следующий шаг.

### Download for Mac

Get `Melogold-<version>.dmg` from the [latest release](https://github.com/melogold-app/melogoldiOSmacOS/releases/latest),
drag Melogold to Applications and open it from there. On first launch macOS says it cannot verify the app: open System
Settings › Privacy & Security and click **Open Anyway** next to Melogold (once). After that Melogold updates itself via
Sparkle. The warning appears because the app is not notarized by Apple, which requires a paid Apple Developer account;
Melogold is free and open source and uses nothing that needs such an account (unlike a VPN client, whose network
extension cannot run without one). Releases are built from this repository by GitHub Actions, signed with a permanent
Melogold certificate, and every update is also signed with an EdDSA key that Sparkle checks before installing.

## Сборка

Нужен Xcode 27. Проект генерируется из `project.yml`; XcodeGen собирается сам из `BuildTools/`, Homebrew не нужен.

```sh
scripts/generate-project.sh                          # Melogold.xcodeproj из project.yml
swift test --package-path Packages/MelogoldKit       # правила, парсеры и общие векторы
open Melogold.xcodeproj                              # схемы Melogold (iPhone, iPad, Mac, Vision) и Melogold Watch
```

Подпись по умолчанию — ad-hoc; своя команда — в `Config/Local.xcconfig` (образец — `Config/Local.example.xcconfig`). Ход работы и что проверено — [docs/STATUS.md](docs/STATUS.md).

## Лицензия

[GPL-3.0](./LICENSE).

## Остальные части Melogold

| Платформа | Репозиторий |
|---|---|
| Android | [melogoldAndroid](https://github.com/melogold-app/melogoldAndroid) |
| Сервер | [melogoldServer](https://github.com/melogold-app/melogoldServer) |
| Windows | [melogoldWindows](https://github.com/melogold-app/melogoldWindows) |
| Linux | [melogoldLinux](https://github.com/melogold-app/melogoldLinux) |
| iPhone, iPad, Mac, Vision Pro, Watch | [melogoldiOSmacOS](https://github.com/melogold-app/melogoldiOSmacOS) |
