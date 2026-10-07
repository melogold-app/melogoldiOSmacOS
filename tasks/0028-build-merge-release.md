# Собрать, проверить и слить правки 07.10.2026; выпуск (делается на Маке)

Статус: открыто. Правки написаны на ThinkPad (Fedora) без Swift — **ни разу не собирались**. Ветки:

| Ветка | Что | Задание |
|---|---|---|
| `fix/stream-403-new-session` | 403 при чтении потока → новый `visitorData` перед свежим адресом | 0025 |
| `fix/wait-for-network` (поверх предыдущей) | нет сети — трек ждёт её на той же позиции, `NWPathMonitor` | 0026 |
| `feat/handoff-position` (от `main`) | перенос на другое устройство сразу с позиции; «Слушать здесь» — сразу с места | 0027 |

## Сделать

1. `cd Packages/MelogoldKit && swift build && swift test` на каждой ветке; поправить, что не собирается.
2. Тест ожидания сети по образцу Linux (`engine::without_network_the_track_waits_instead_of_skipping`) и Windows
   (`NetworkWaitTests`): сетевая ошибка → трек не пропущен, буферизация; сигнал сети → повтор сразу; предел → ошибка.
3. Собрать приложение в Xcode (iOS и macOS), проверить руками: обрыв сети посреди трека, перенос на другое
   устройство и «Слушать здесь» (нужен сервер 0.1.3 — `melogoldServer` задание 0006).
4. Слить `fix/wait-for-network` и `feat/handoff-position` в `main` (конфликт будет только в `tasks/README.md`).
5. Выпуск — `scripts/release-testflight.sh` / `scripts/release-macos.sh`, как обычно.

Отметить «сделано» в заданиях 0025–0028 и в `tasks/README.md`.
