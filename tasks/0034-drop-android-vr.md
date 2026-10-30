# Поток: убрать ANDROID_VR из встроенного списка (на Маке)

Статус: открыто — конфиг на main уже без него (30.10.2026, действует у всех без выпуска); осталось в коде.

То же на Android — задание 0033 в `melogoldAndroid` (коммит `6f5fd64`), там же таблица проверки клиентов.

Без PO-токена googlevideo отдаёт ANDROID_VR (а также IOS и ANDROID) только начало файла: 403 на втором куске по
512 КиБ, песня обрывалась на ~30-й секунде. Он отвечал «OK», поэтому до запасного пути дело не доходило. Файл целиком
сейчас отдаёт только VISIONOS — у Linux и Windows он и так один.

## Сделать

1. `Packages/MelogoldKit/Sources/MelogoldPlayback/StreamClients.swift`: `builtIn = [.visionOS]`; `ClientProfile.androidVR`
   убрать, если больше нигде не нужен.
2. `Packages/MelogoldKit/Tests/MelogoldPlaybackTests/PlaceholderTests.swift`, `streamClientsConfigInRepository`: ждать
   `["VISIONOS"]`, проверку `mediaUserAgent` у последнего клиента убрать — **сейчас этот тест красный**: файл на main
   уже без ANDROID_VR, а встроенный список ещё с ним.
3. `swift test`, выпуск — со следующим.
