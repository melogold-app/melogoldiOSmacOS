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
    обновляется само через Sparkle.
- Работает без аккаунта; по желанию — вход на [сервер Melogold](https://github.com/melogold-app/melogoldServer) и
  синхронизация.

Иконка приложения — `Melogold.icon` (Icon Composer, Liquid Glass) и `Assets/AppIcon-1024.png`.

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
