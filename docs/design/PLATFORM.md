# Выжимка руководств: Apple (iOS, iPadOS, macOS, watchOS, visionOS)

Ядро клиента по `docs/DESIGN-DOCTRINE.md` §2: SwiftUI, Human Interface Guidelines, Liquid Glass. Руководства: [HIG](https://developer.apple.com/design/human-interface-guidelines), [SwiftUI](https://developer.apple.com/documentation/swiftui).

Сверено: 2026-10-01, HIG для iOS/macOS/watchOS 26–27.

HIG не нумерует версии: прочитано живое состояние страниц на 2026-10-01. Самые свежие правки в прочитанном: layout (2026-09-09); sidebars, menus, tab-bars, search-fields, searching, scroll-views (2026-06-08); sheets (2026-03-24); toolbars, buttons, typography, color (2025-12-16). При следующей сверке смотреть «Change log» этих страниц.

Порядок приоритета: macOS, затем iOS, затем watchOS; iPadOS и visionOS — отдельным коротким разделом перед «Частыми ошибками».

## Как читать

- **Mac**, **iPhone**, **часы** — метка платформы у правила; без метки правило общее.
- **(SwiftUI, не HIG)**, в таблице сокращённо **(S)** — опора на знание SwiftUI, а не на руководство; имена API с версиями сверены с документацией Apple, поведение — проверять в Xcode.
- «HIG чисел не даёт» — руководство не называет значение; число задаёт системный компонент, в коде своего числа не писать (доктрина §2, «Числа — от системы»).
- Страницы HIG цитируются ссылками вида `[slug]`; адреса — в конце файла.

## Прочитанные страницы

Все по адресу `https://developer.apple.com/design/human-interface-guidelines/<slug>`:
[lists-and-tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) · [outline-views](https://developer.apple.com/design/human-interface-guidelines/outline-views) · [column-views](https://developer.apple.com/design/human-interface-guidelines/column-views) · [collections](https://developer.apple.com/design/human-interface-guidelines/collections) · [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) · [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) · [menus](https://developer.apple.com/design/human-interface-guidelines/menus) · [context-menus](https://developer.apple.com/design/human-interface-guidelines/context-menus) · [the-menu-bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) · [dock-menus](https://developer.apple.com/design/human-interface-guidelines/dock-menus) · [edit-menus](https://developer.apple.com/design/human-interface-guidelines/edit-menus) · [pull-down-buttons](https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons) · [pop-up-buttons](https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons) · [keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) · [pointing-devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices) · [gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) · [focus-and-selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection) · [drag-and-drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop) · [undo-and-redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo) · [searching](https://developer.apple.com/design/human-interface-guidelines/searching) · [search-fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) · [sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) · [alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) · [action-sheets](https://developer.apple.com/design/human-interface-guidelines/action-sheets) · [modality](https://developer.apple.com/design/human-interface-guidelines/modality) · [popovers](https://developer.apple.com/design/human-interface-guidelines/popovers) · [panels](https://developer.apple.com/design/human-interface-guidelines/panels) · [buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) · [toggles](https://developer.apple.com/design/human-interface-guidelines/toggles) · [sliders](https://developer.apple.com/design/human-interface-guidelines/sliders) · [text-fields](https://developer.apple.com/design/human-interface-guidelines/text-fields) · [entering-data](https://developer.apple.com/design/human-interface-guidelines/entering-data) · [disclosure-controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls) · [progress-indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) · [feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) · [loading](https://developer.apple.com/design/human-interface-guidelines/loading) · [windows](https://developer.apple.com/design/human-interface-guidelines/windows) · [split-views](https://developer.apple.com/design/human-interface-guidelines/split-views) · [tab-bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) · [tab-views](https://developer.apple.com/design/human-interface-guidelines/tab-views) · [going-full-screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen) · [settings](https://developer.apple.com/design/human-interface-guidelines/settings) · [launching](https://developer.apple.com/design/human-interface-guidelines/launching) · [layout](https://developer.apple.com/design/human-interface-guidelines/layout) · [scroll-views](https://developer.apple.com/design/human-interface-guidelines/scroll-views) · [typography](https://developer.apple.com/design/human-interface-guidelines/typography) · [color](https://developer.apple.com/design/human-interface-guidelines/color) · [dark-mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) · [materials](https://developer.apple.com/design/human-interface-guidelines/materials) · [sf-symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) · [icons](https://developer.apple.com/design/human-interface-guidelines/icons) · [images](https://developer.apple.com/design/human-interface-guidelines/images) · [image-views](https://developer.apple.com/design/human-interface-guidelines/image-views) · [motion](https://developer.apple.com/design/human-interface-guidelines/motion) · [playing-haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) · [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) · [voiceover](https://developer.apple.com/design/human-interface-guidelines/voiceover) · [playing-audio](https://developer.apple.com/design/human-interface-guidelines/playing-audio) · [airplay](https://developer.apple.com/design/human-interface-guidelines/airplay) · [activity-views](https://developer.apple.com/design/human-interface-guidelines/activity-views) · [offering-help](https://developer.apple.com/design/human-interface-guidelines/offering-help) · [generative-ai](https://developer.apple.com/design/human-interface-guidelines/generative-ai) · [digital-crown](https://developer.apple.com/design/human-interface-guidelines/digital-crown) · [always-on](https://developer.apple.com/design/human-interface-guidelines/always-on) · [designing-for-macos](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) · [designing-for-ios](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios) · [designing-for-ipados](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados) · [designing-for-watchos](https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos) · [designing-for-visionos](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos)

Не HIG, но прочитано для имён и версий API и для Liquid Glass: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) (обзор технологий Apple), справочник SwiftUI (`glassEffect`, `tabViewBottomAccessory` и др.), [Adding a Now Playing view](https://developer.apple.com/documentation/watchkit/adding-a-now-playing-view).

---

## Компоненты по умолчанию

Столбцы «Mac / iPhone / Часы» — подбор SwiftUI-компонента (не HIG). В «Что даёт сам» факты HIG без пометки, знание SwiftUI — с **(S)**. Элементы Melogold, для которых в HIG нет компонента, помечены прямо.

| Элемент Melogold | Mac | iPhone | Часы | Что даёт сам | Ссылка |
|---|---|---|---|---|---|
| Список треков | `List(selection:)` с `Set` или `Table` для колонок; стиль `.inset(alternatesRowBackgrounds:)` (S) | `List`; `.swipeActions`, `EditButton` и `EditMode` для выбора, `.onMove` (S) | `List` в системном стиле (эллиптический/карусель), мало строк, «Ещё» для длинного | Постоянная подсветка выбранной строки в навигации, выбор акцентным цветом; Mac: сортировка по заголовку колонки, ширина колонок, чередование строк; iPhone: выбор только в режиме правки. (S) Mac: ⇧/⌘-щелчок, ⌘A, стрелки, поиск набором, drag, VoiceOver по строкам | [lists-and-tables], [outline-views], [focus-and-selection] |
| Сетка и полка обложек | `LazyVGrid` с `GridItem(.adaptive)`; полка — горизонтальный `ScrollView` + `LazyHStack` (S) | то же, `scrollTargetBehavior` (S) | Коллекций на часах нет (HIG: не поддерживаются) — `List` или вертикальные страницы | HIG: стандартная сетка или ряд, не свой layout; запас вокруг картинок, чтобы фокус и наведение читались. (S) SwiftUI-сетка не даёт выбор, фокус, наведение — `.contextMenu`, `.onHover`, `.focusable`, `.accessibilityLabel` добавлять самим. Полка — исключение «Полки» (доктрина §3) | [collections], [image-views] |
| Меню трека и контекстное меню | `.contextMenu(forSelectionType:menu:primaryAction:)` на `List`/`Table` (меню по выделению, `primaryAction` — двойной щелчок) + те же команды в строке меню (`CommandMenu`) (S) | `.contextMenu` (долгое нажатие) и кнопка «…» = `Menu`; `.swipeActions` — те же верхние действия (S) | Контекстных меню на часах нет (HIG); действия трека — на экране-детали, в `.confirmationDialog` или `.toolbar` | Набор пунктов совпадает с основным интерфейсом, ≤ ~3 групп, один уровень подменю, недоступное прячется (Mac: Cut/Copy/Paste тускнеют), разрушительное последним и красным (iPhone), сочетания в контекстном меню не показывают | [context-menus], [menus], [pull-down-buttons] |
| Поиск | `.searchable(text:placement:)` — поле справа в панели инструментов; в боковой панели, если она фильтруется; `.searchSuggestions`, `.searchScopes`, `.searchFocused` (S) | Вкладка поиска (`Tab(role: .search)`) или `.searchable` в панели навигации/нижней панели, `.searchToolbarBehavior` (S) | `.searchable` — системный экран ввода на весь экран | Значок лупы, кнопка очистки, подсказка-плейсхолдер, поиск по мере набора, подсказки, область и токены. Результаты: самое релевантное первым, по категориям. (S) Mac: ⌘F переводит в `.searchable` — проверить | [search-fields], [searching] |
| Фильтр списка | Тот же `.searchable` на экране этого списка, плейсхолдер называет область («Поиск в медиатеке»); по признаку — `Picker` `.menu` (всплывающая кнопка) с галочками; сортировка — `Menu` и заголовки `Table` (S) | Встроенное поле `.searchable` над списком (как «Медиатека» в Музыке); тумблер-кнопка с `line.3.horizontal.decrease` (S) | Не нужен; `Picker` | HIG: в iOS-Музыке поиск по песням и альбомам работает как фильтр текущего вида; область поиска показана плейсхолдером, заголовком или scope-панелью; параметры задачи (фильтр, сортировка) держать на самом экране, не в настройках | [searching], [search-fields], [pull-down-buttons], [pop-up-buttons], [settings] |
| Лист | `.sheet` (модальный к окну, размер по содержимому); для повторяющегося ввода — `.inspector` или панель | `.sheet`, `.presentationDetents`, `.presentationDragIndicator(.visible)`; «Отменить» слева, «Готово» справа (S) | `.sheet` на весь экран, только для задач со своим содержимым | Mac: родительское окно затемнено, другие окна доступны; iPhone: свайп вниз закрывает, при несохранённом — action sheet; один лист за раз; Liquid Glass фон не перекрашивать | [sheets], [modality], [panels], [popovers] |
| Диалог и алерт | `.alert` (значок приложения даёт система); варианты к своему действию — `.confirmationDialog` (S) | `.alert`; варианты действия — `.confirmationDialog` (action sheet от кнопки) | `.alert`; `.confirmationDialog` ≤ 4 кнопок с «Отменить» | До трёх кнопок; роли `cancel`/`destructive`; Return — кнопка по умолчанию; Esc и ⌘. отменяют (Mac); «OK» только в информационных; деструктивный стиль — для неожиданного разрушения | [alerts], [action-sheets], [modality] |
| Всплывающее сообщение | **В HIG такого компонента нет** (ни toast, ни snackbar). Ближайшее по руководству: статус прямо в интерфейсе, `UndoManager` и «Правка > Отменить …» (⌘Z) на Mac | то же; встряхивание = отмена | Индикаторы без конца избегать; уведомление по завершении | HIG: не показывать алерт для обратимых частых действий; не использовать самоскрывающиеся по таймеру элементы как единственный путь. «Отменить во всплывающем сообщении» (доктрина §4.7) — исключение Melogold: записать в `EXCEPTIONS.md`, оставить системный путь отмены и объявление для VoiceOver (S) | [feedback], [undo-and-redo], [accessibility], [alerts] |
| Панель инструментов | `.toolbar` (`ToolbarItem(placement:)`, группы, `ToolbarSpacer`), `.navigationTitle`, `toolbar(id:)` для настройки (S) | `.toolbar` в панели навигации/нижней, крупный заголовок, пункт «Ещё» (`Menu`, `ellipsis`) (S) | `.toolbar` с `.topBarLeading` / `.topBarTrailing` / `.bottomBar` | Liquid Glass, углы концентричны панели, переполнение в меню делает система (Mac), значки без рамок, главное действие `.prominent` одно и справа; каждый пункт есть в строке меню (Mac) | [toolbars], [buttons] |
| Боковая панель и вкладки | Mac: `NavigationSplitView` + `List` `.sidebar`, `SidebarCommands`, `.inspector` (S) | `TabView` + `Tab`, поиск вкладкой; мини-плеер — `tabViewBottomAccessory` (iOS 26.1+, не macOS), `tabBarMinimizeBehavior` (S); iPad: `.sidebarAdaptable` | `NavigationStack`/`NavigationSplitView`, вертикальные страницы `TabView` | Mac: до двух уровней, показать/скрыть, значки SF Symbols в цвете акцента, размер строк от системной настройки; iPhone: панель плавает на стекле, сворачивается при прокрутке; для tab bar на macOS отдельных правил HIG не даёт (действуют общие), навигация Mac-приложения — боковая панель | [sidebars], [split-views], [tab-bars], [tab-views] |
| Настройки | Сцена `Settings` (⌘, и «Настройки…» в меню приложения), панели переключает панель инструментов; `Form` `.formStyle(.grouped)` (S) | Экран настроек: `Form` или сгруппированный `List`; переключатель `Toggle` только в строке списка | Раздела настроек в системных нет: пара опций внизу главного экрана или в «Ещё» | Mac: кнопки свернуть и развернуть приглушены, заголовок = панель, помнит последнюю панель; опции задачи — на самом экране; системные настройки (тема, доступность) не дублировать | [settings], [toggles] |
| Кнопки | `Button` + `.bordered` / `.borderedProminent` / `.borderless` / `.glass`; push-кнопки в окне, квадратные и image-кнопки только внутри вида, в панели — `ToolbarItem`; `.help("…")` (S) | `Button` + `.glass` / `.glassProminent`; зона ≥ 44×44 pt | Полноширинная капсула для главного действия; ≤ 3 глифа или ≤ 2 текста в ряд | Состояния нажатия, роли (primary/cancel/destructive), Return у кнопки по умолчанию, подсказка при наведении (Mac), `…` в названии, если открывает ещё окно | [buttons], [toolbars] |
| «Сейчас играет» и управление воспроизведением | Экран — исключение Melogold (§3). Системное: `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (медиаклавиши, наушники) (S); громкость — `Slider` допустим (запрет HIG — только iOS/iPadOS); транспорт — в панели инструментов, не внизу окна (вывод из [layout]); Dock-меню: пауза/далее | Свой экран; системное: `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` (экран блокировки, центр управления); громкость — системный вид `MPVolumeView`, не `Slider`; мини-плеер — `tabViewBottomAccessory` | `NowPlayingView` — системный, на весь экран, без других элементов; свой плеер — исключение; `handGestureShortcut(.primaryAction)` на паузу | HIG: управлять только когда играет своё, не менять смысл кнопок, продолжать при уходе в фон и блокировке; iPhone: «volume view» включает ползунок и выбор вывода; часы: Now Playing view показывает источник сам | [playing-audio], [airplay], [sliders], [dock-menus], [gestures], [tab-bars] |
| Выбор вывода звука | `AVRoutePickerView` (AVKit, обёртка `NSViewRepresentable`) (S) | `AVRoutePickerView` или внутри `MPVolumeView`; обёртка `UIViewRepresentable` (S) | AirPlay на часах HIG не поддерживает; выбор вывода — системный (S, проверить) | Не рисовать свой значок и слово «AirPlay» в интерактивной кнопке, только символы Apple; в своём плеере значок AirPlay внизу справа (iOS 16+); при подключении наушников звук идёт сам, при отключении — пауза | [airplay], [playing-audio] |
| Поделиться | `ShareLink` (меню «Поделиться» в панели/контекстном меню) (S) | `ShareLink` — системный лист | — | Не делать свой лист и не дублировать системные действия; значок `square.and.arrow.up` | [activity-views], [icons] |

---

## Отступы и сетка

- HIG чисел отступов строки списка, ширины боковой панели, полей окна и размеров обложек не даёт; их задаёт системный компонент (стиль `List`/`Table`/`Form`, `.scenePadding`) — в коде своих чисел для этого не писать (SwiftUI, не HIG) → [lists-and-tables], [layout]
- Liquid Glass (iOS/iPadOS/macOS 26): строки списков, таблиц, форм выше, отступы больше, радиус секций больше — подтягивается при пересборке, если метрики не прописаны вручную; стандартные интервалы не переопределять → [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) (не HIG)
- Размер зоны нажатия: общее правило страницы buttons — 44×44 pt (visionOS 60×60); страница accessibility уточняет по платформам: iPhone и часы 44×44 (минимум 28), Mac 28×28 (минимум 20); для Mac брать значения accessibility (между страницами HIG не единообразен) → [accessibility], [buttons]
- Воздух вокруг контролей: около 12 pt вокруг элемента с рамкой, около 24 pt вокруг без рамки; у image-кнопки около 10 px между картинкой и краем → [accessibility], [pointing-devices], [buttons]
- **Mac**: не размещать контролы и важное внизу окна и внизу боковой панели — окно часто сдвигают за нижний край экрана (касается мини-плеера и панели воспроизведения) → [layout], [windows], [sidebars]
- **Mac**: не выводить контент под вырез камеры; уважать безопасные области и системные layout guides → [layout]
- **iPhone**: раскладка по size class, а не по типу устройства и ориентации; функции те же при любом размере, меняется объём видимого; на широком — вкладки уходят в боковую панель → [layout]
- **Mac** split view: тонкий разделитель (1 pt — единственное число в источнике), разумные минимум и максимум панелей, скрытие панели и возврат кнопкой или командой с сочетанием → [split-views]
- Порядок по важности: главное сверху и в начале строки; выравнивание и отступ выражают иерархию; группировать пустотой, контейнерами, разделителями; прогрессивное раскрытие для второстепенного → [layout]
- Отделять управление от контента стеклом и scroll edge effect, а не сплошной подложкой; полноэкранный фон тянуть под боковую панель, панель инструментов и вкладки (`backgroundExtensionEffect`) → [layout], [sidebars], [scroll-views]
- **часы**: не больше трёх кнопок с глифами или двух с текстом в ряд; главное действие на всю ширину → [layout], [buttons]

## Типографика

- Системный шрифт SF (SF Pro на Mac и iPhone, SF Compact на часах), не встраивать; размеры — через стили текста (`.body`, `.headline`, …), не числами (SwiftUI, не HIG) → [typography]
- Размер по умолчанию / минимум: iPhone 17 / 11 pt, Mac 13 / 10 pt, часы 16 / 12 pt; избегать начертаний Ultralight, Thin, Light → [typography]
- **Mac**, стили: Large Title 26, Title 1 22, Title 2 17, Title 3 15, Headline 13 bold, Body 13, Callout 12, Subheadline 11, Footnote 10, Caption 1–2 10 pt → [typography]
- **iPhone**, стили при размере Large (по умолчанию): Large Title 34, Title 1 28, Title 2 22, Title 3 20, Headline 17 semibold, Body 17, Callout 16, Subhead 15, Footnote 13, Caption 1 12, Caption 2 11; самый крупный размер доступности AX5: Body 53 pt → [typography]
- **часы**, 40–42 мм по умолчанию: Large Title 36, Title 1 34, Title 2 28, Title 3 19, Headline 16 semibold, Body 16, Caption 1 15, Caption 2 14, Footnote 13/12; 44–49 мм: Body и Headline 17; самый крупный размер AX3: Body 23 pt → [typography]
- **Mac**: Dynamic Type не поддерживается (прямо в HIG); текст в стандартных контролах — через системные стили и динамические системные варианты шрифта; но accessibility просит дать увеличение текста не меньше 200% «своим интерфейсом или Dynamic Type» — на Mac это решение проекта (например, свой масштаб текста в настройках), в HIG ответа нет; пункт «Крупный шрифт» доктрины §4.1 для Mac уточнить → [typography], [accessibility]
- **iPhone**, **часы**: поддерживать Dynamic Type и проверять на самом крупном размере доступности; на iPhone включается в Настройки > Универсальный доступ > Дисплей и размер текста > Увеличенный текст → [typography], [accessibility]
- При крупном шрифте: строки растут, горизонтальное складывается в стопку, колонок меньше, значки растут вместе с текстом; на размерах доступности показывать столько же полезного текста, сколько на самом крупном обычном; порядок важного не меняется → [typography], [layout]
- Не обрезать текст в прокручиваемых областях без экрана для полного прочтения; не увеличивать всё подряд (подписи вкладок не растут) → [typography]
- Усечение в узких таблицах — многоточие посередине (сохраняет начало и конец имени); **Mac**: подсказка-расширение с полным текстом для обрезанного в поле → [lists-and-tables], [outline-views], [text-fields]
- Акцент — символическими чертами (`.bold()`: у стилей заданы усиленные начертания), а не новым кеглем; меньше шрифтов, не смешивать много гарнитур → [typography]
- Регистр в HIG описан для английского (пункты меню — title-style, заголовок алерта-предложения — sentence-style, подсказки — sentence case, до 60–75 знаков); для русского принять sentence case как решение проекта, не HIG → [menus], [alerts], [offering-help]

## Цвет и материалы

- Цвета — семантические через API (`Color`, `.primary`/`.secondary`, `foregroundStyle`), значения не хардкодить; смысл системных ролей не переопределять (separator не как цвет текста, secondaryLabel не как фон) → [color]
- Свой цвет — набор светлый / тёмный / повышенный контраст (Color Set), даже если приложение в одной теме; без своей настройки темы — следовать системной → [color], [dark-mode]
- Контраст не ниже 4.5:1 (для своего мелкого текста стремиться к 7:1); WCAG AA: до 17 pt — 4.5:1, 18 pt — 3:1, жирный — 3:1 → [dark-mode], [accessibility]
- Не только цветом: статус «играет», «недоступно», ошибка — ещё формой, значком или текстом → [color], [accessibility]
- **Mac**: акцентный цвет выбирает человек — выделение, кнопки и значки боковой панели следуют ему; фиксированный цвет значка — редко и со смыслом → [color], [sidebars]
- **Mac**: выбранная строка списка рисуется системными цветами (выбранный фон, текст выбора, приглушённый вариант в неактивном окне, чередование строк) — системный `List`/`Table` делает это сам, свою подсветку выбора не рисовать → [color], [focus-and-selection]
- Liquid Glass — слой управления и навигации (панель инструментов, вкладки, боковая панель, плавающие кнопки); в слое контента (строки, карточки, обложки, фон экрана) не использовать; исключение — ползунок и переключатель в момент нажатия → [materials]
- Своё стекло (`glassEffect`) — экономно, только для важных функциональных элементов, группы в `GlassEffectContainer`, не стекло на стекле (SwiftUI, не HIG) → [materials], [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- Regular — по умолчанию и там, где много текста (алерты, боковые панели, поповеры); clear — только над богатым медиа-фоном (фото, видео), при светлом фоне подложка затемнения около 35% → [materials]
- Не красить панели, вкладки, листы своим цветом или оттенком обложки: цвет живёт в слое контента, подписи на стекле одноцветные, акцент — на фоне кнопки главного действия, а не на подписи → [toolbars], [color], [buttons]
- **часы**: не заливать весь экран цветом на долго живущих экранах (тренировка, воспроизведение звука); материал фона модального листа не убирать → [color], [materials]
- **Mac**: прозрачность в своих компонентах — только в нейтральном состоянии (подкраска окна от рабочего стола); неактивное окно без материалов; «Уменьшить прозрачность» и «Повысить контраст» проверять на своих элементах → [dark-mode], [windows], [materials]

## Навигация

- **Mac**: каркас — боковая панель + split view (+ инспектор справа); для tab bar на macOS отдельных правил нет (действуют общие), а «tab-based window» — вкладки окон из меню «Вид»/«Окно»; `tab view` на Mac — переключатель панелей внутри окна, не больше шести вкладок → [sidebars], [split-views], [tab-bars], [tab-views]
- **Mac**, боковая панель: до двух уровней иерархии; по умолчанию видна; скрывается кнопкой и командами «Показать/Скрыть боковую панель» в меню «Вид»; текущий выбор подсвечен постоянно; не ставить важное внизу; можно дать настроить состав → [sidebars], [split-views]
- **Mac**, панель инструментов: слева Назад, переключатель боковой панели, заголовок; в центре частые действия; справа важное, поиск, «Ещё»; не больше трёх групп; заголовок до 15 знаков и не название приложения; главное действие одно, справа → [toolbars]
- **Mac**: Назад и Закрыть — стандартные кнопки со стандартным значком, без текста «Назад»; поиск справа в панели инструментов, фильтрующий боковую панель — вверху боковой; область «Поиск» с подборками — пункт боковой панели (как в Музыке) → [toolbars], [search-fields]
- **Mac**: окно системное, своего окна и своих кнопок окна не рисовать; новое окно — когда уместно (команда в меню, пункт контекстного меню), слово «окно» в текстах; полноэкранный режим — системный (View > Enter Full Screen, ⌃⌘F), размер окна самим не менять, управление плеером остаётся доступным → [windows], [going-full-screen]
- **Mac**: окно настроек — пункт «Настройки…» ⌘, в меню приложения, панели в панели инструментов, заголовок = текущая панель, запоминает последнюю; при перезапуске восстанавливать состояние до подробностей: окна, положение прокрутки → [settings], [launching]
- **iPhone**: вкладки плавают внизу на стекле; не прятать и не отключать вкладку (пустой раздел объяснить), подписи одним словом, заливные значки, избегать «Ещё», поиск — отдельная вкладка справа; мини-плеер — аксессуар панели вкладок → [tab-bars], [search-fields]
- **iPhone**: крупный заголовок, при прокрутке — обычный; в панели инструментов только важное, остальное в «Ещё»; листы: «Отменить» слева, «Готово» справа, не показывать «Отменить», «Готово» и «Назад» вместе → [toolbars], [sheets]
- **iPhone**: не показывать поповеры в компактной ширине — вместо них лист; одно модальное окно за раз → [popovers], [modality]
- **часы**: иерархия мелкая, Digital Crown — главный способ навигации; список → детали, детали-страницы — вертикальные `TabView`; не показывать алерт при запуске и неопределённые индикаторы загрузки → [designing-for-watchos], [digital-crown], [split-views], [feedback], [loading]

## Значки

- Значки — SF Symbols; для частых действий — системные: `trash`, `square.and.arrow.up`, `magnifyingglass`, `line.3.horizontal.decrease` (фильтр), `ellipsis` (Ещё), `plus`, `xmark`, `checkmark`, `pencil`, `folder`; в таблице HIG «Нравится» — `hand.thumbsup`, сердца там нет: ♡ как «Избранное» — решение Melogold, не HIG → [icons], [sf-symbols]
- Вес значка равен весу соседнего текста; вариант (контур или заливка) выбирает вид: контур — панель инструментов и списки, заливка — вкладки iOS, свайп-действия и выбор → [sf-symbols], [icons]
- Свои варианты «выбрано» для значков в системных компонентах не рисовать — система меняет вид сама → [icons]
- Панель инструментов: значки без рамок (секция даёт контейнер сама), текст и значки в одной группе не смешивать; подпись для VoiceOver у каждого значка → [toolbars], [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- Пункты меню: значки экономно; в группе — у всех или ни у одного; для стандартных действий — стандартные значки; верхние действия контекстного меню совпадают со свайп-действиями → [menus], [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- Боковая панель: SF Symbols или собственный символ (не растр); цвет по умолчанию — акцент приложения/системы → [sidebars]
- Свои значки: вектор (PDF/SVG) или собственный SF Symbol, одинаковый размер, вес и детализация, подпись для VoiceOver → [icons], [sf-symbols]
- AirPlay: только символы Apple и только неинтерактивно; SF Symbols не использовать в значке приложения и логотипе → [airplay], [sf-symbols]
- Значок приложения — слои, система сама маскирует и красит (Icon Composer; светлый, тёмный, прозрачный, тонированный вид) → [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- Обложки показывать как изображения (`Image`), не как значки; текст поверх картинки — с контрастом, тенью или подложкой → [image-views]

## Движение

- Движение — по делу и необязательное: не единственный способ передать важное, дополнять звуком и тактильным откликом → [motion]
- Анимации обратной связи — короткие и точные; не добавлять движения к частым действиям; не заставлять ждать конца анимации → [motion]
- «Уменьшить движение»: меньше автоматических и повторяющихся анимаций, пружины жёстче, переходы по осям заменить затуханием, не уходить в размытие и из него, движение следует за жестом → [accessibility]
- Движение Liquid Glass система сама ослабляет для трекпада и по настройкам; стандартные компоненты подстраиваются, свои анимации (прокрутка текста песни, зум обложек) проверять в этих режимах → [motion], [materials]
- Анимации символов (`symbolEffect`) — только с понятной целью; «заменить» — для смены состояния (play/pause) → [sf-symbols]
- Индикаторы прогресса — системные; определённый лучше неопределённого; не превращать полоску в кружок; в одном и том же месте; по возможности дать «Отменить» → [progress-indicators]
- **часы**: анимации раскладки со встроенным замедлением, отключить нельзя; неопределённый индикатор избегать (человек будет смотреть на экран) → [motion], [feedback], [loading]
- Тактильный отклик: системные образцы по смыслу, ненавязчиво, с возможностью отключить; `sensoryFeedback` (SwiftUI, не HIG) → [playing-haptics]

## Доступность

- Подписи VoiceOver для всех ключевых элементов и собственных контролов; значки — со своим описанием; чисто декоративные картинки скрывать; у обложки в строке, где название уже озвучено, — скрывать, иначе описывать только то, что она передаёт → [voiceover]
- Группировать связанные элементы и задавать порядок чтения; сообщать VoiceOver об изменениях экрана; заголовки и ротор для навигации → [voiceover]
- Full Keyboard Access (iPhone, iPad, Mac): все контролы достижимы с клавиатуры; команды вне строки меню труднее найти и вызвать с ним; на iPad своей навигации по кнопкам не делать → [keyboards], [the-menu-bar]
- Размеры контролов: iPhone/часы 44 pt (минимум 28), Mac 28 (минимум 20); интервалы около 12 pt (с рамкой) и 24 pt (без) → [accessibility]
- Крупный текст: давать увеличение не меньше 200% (на часах 140%) своим интерфейсом или через Dynamic Type; на Mac Dynamic Type нет — решение за проектом → [accessibility], [typography]
- Контраст по WCAG AA: до 17 pt — 4.5:1, 18 pt — 3:1, жирный — 3:1; при ненадёжном контрасте — вариант для «Повысить контраст»; проверять оба оформления → [accessibility], [dark-mode]
- Не передавать смысл только цветом; не звуком (дублировать тактильным откликом и визуально) → [accessibility], [color]
- Сложные жесты — только с альтернативой; смахивание строки дублировать кнопкой или пунктом меню; перетаскивание дублировать командами → [accessibility], [drag-and-drop]
- Управление Voice Control и Switch Control: подписи у всех нажимаемых; Siri и «Быстрые команды» — по желанию → [accessibility]
- Не автоматически играть без управления и без явного действия человека; управление воспроизведением понятное и находимое; текст песни — текстовая альтернатива звуку (по духу «transcripts» из раздела о слухе, вывод), показывать целиком → [accessibility]
- Автоматическое закрытие по таймеру — избегать (нужно больше времени тем, кто пользуется помощью) → [accessibility]
- **iPhone**: Assistive Access — оставить ядро функций, разбить сложное на шаги, дважды подтверждать трудно обратимое → [accessibility]
- ИИ-синхронизация текста песни: сообщать, что это ИИ, задавать ожидания, давать «Исправить», «Отменить», «Повторить» рядом с результатом, спрашивать разрешение на персональные данные → [generative-ai]
- Проверять Accessibility Inspector, VoiceOver, Voice Control, Full Keyboard Access (включается в Универсальном доступе) → [accessibility], [keyboards]

## Клавиатура, мышь, жесты

**Mac — строка меню и команды**

- Порядок меню: Приложение, Файл, Правка, Формат (если есть текст), Вид, свои меню, Окно, Справка; «Вид» и «Окно» делать всегда (в «Окно» — Свернуть и Масштабировать, в «Вид» — боковая панель, панель инструментов, полный экран) → [the-menu-bar]
- Один и тот же набор пунктов всегда: недоступное отключать, не прятать; каждая команда приложения есть в строке меню (так её находят и вызывают с Full Keyboard Access); каждый пункт панели инструментов — тоже команда меню → [the-menu-bar], [toolbars], [menus]
- Свои команды — в своих меню между «Вид» и «Окно», от общего к частному; для плеера — меню «Воспроизведение» (play/пауза, далее, назад, перемотка, повтор, перемешать, громкость) (SwiftUI, не HIG: `CommandMenu`) → [the-menu-bar]
- Стандартные сочетания не переиспользовать для другого смысла: ⌘A выбрать всё, ⇧⌘A снять выбор, ⌘, настройки, ⌘F найти, ⌥⌘F к полю поиска, ⌘Z / ⇧⌘Z, ⌘C/X/V, ⌘N, ⌘W, ⌘M, ⌘Q, ⌘H, ⌘? справка, ⌘. и Esc — отмена, ⌃⌘F полный экран, ⌥⌘T панель инструментов, ⌘I «Сведения», ⌥⌘I инспектор; менять допустимо, только если исходное действие в приложении не имеет смысла → [keyboards]
- Свои сочетания — только для самых частых команд: основной модификатор ⌘, ⇧ — дополнение, ⌥ — редко, ⌃ избегать; порядок записи ⌃⌥⇧⌘; не добавлять ⇧ к верхнему символу клавиши; система сама локализует и зеркалит → [keyboards]
- Сочетания показывать в строке меню; в контекстных меню — не показывать (избыточно) → [context-menus], [menus]
- Пробел (пауза), Return (играть выделенное), Delete (убрать), стрелки: HIG таких правил для приложений не даёт, Пробел в его списке стандартных не значится — это конвенция Музыки и QuickTime; Delete равен пункту «Удалить» (не «Стереть», не «Очистить»); Return — кнопка по умолчанию в листах и диалогах (SwiftUI, не HIG: `.onKeyPress`, `.onDeleteCommand`, `.keyboardShortcut(.defaultAction)`) → [the-menu-bar], [buttons]
- ⌘[ как «Назад» — конвенция Finder и Safari; в таблице HIG ⌘[ — «выровнять по левому краю», но при отсутствии форматирования текста переопределять можно; Esc — «отменить действие» (закрывает лист и алерт, вместе с ⌘.) → [keyboards], [alerts]
- Фокус: Tab и ⇧Tab между контролами, ⌃Tab — к следующей группе или таблице, ⌃ со стрелками — между ячейками таблицы; фокус-кольцо для текстовых и поисковых полей, подсветка строки — для списков и коллекций → [keyboards], [focus-and-selection]

**Mac — мышь, трекпад, перетаскивание**

- Основной щелчок выбирает/активирует, вторичный (правая кнопка, ⌃-щелчок, касание двумя пальцами) открывает контекстное меню; в редактируемой ячейке одиночный щелчок правит, двойной — открывает; для трека двойной щелчок = «играть» → [pointing-devices], [context-menus], [outline-views]
- Подсказка при наведении у кнопок без подписи: глагол, без повтора названия, до 60–75 знаков, sentence case, без точки (SwiftUI, не HIG: `.help`) → [offering-help], [buttons]
- Подсветка строки при наведении: HIG для Mac не описывает (для iPadOS — эффекты указателя highlight/lift/hover, без украшательств); это контракт доктрины §4.2, не HIG; делать сдержанно → [pointing-devices]
- Системные жесты трекпада не переопределять; одинаковый отклик на жесты во всей системе → [pointing-devices]
- Перетаскивание: поддерживать повсюду, несколько элементов сразу, значок-число при перетаскивании нескольких, ⌥ при броске — копия, отмена броска, из неактивного окна без активации; всегда альтернатива командой меню → [drag-and-drop]
- Контекстное меню: Control-щелчок и вторичный щелчок; пункты те же, что в основном интерфейсе; ≤ ~3 групп, один уровень подменю; разрушительное последним; недоступное прячется, а не тускнеет (Mac: Cut/Copy/Paste — исключение); Dock-меню и значок в строке меню — дублирующий путь, на них не полагаться → [context-menus], [dock-menus], [the-menu-bar]
- Меню строки меню: подпись — глагол, «…» если нужен ещё ввод, один изменяемый пункт вместо пары «Показать/Скрыть», галочка для включённого, подменю редко и ≤ ~5 пунктов, пункты, зависящие от клавиши ⌥ — не единственный способ → [menus], [the-menu-bar]

**iPhone**

- Жесты: нажатие, смахивание, перетаскивание, долгое нажатие (контекстное меню); системные (встряска и трёхпальцевое смахивание — отмена, жест от края) не переопределять; у каждого жеста есть кнопка или пункт меню → [gestures], [undo-and-redo], [accessibility]
- Свайп-действия строки — те же, что верхние пункты контекстного меню; выбор нескольких — режим правки (в iOS нужен режим правки, чтобы выбирать строки таблицы) → [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [lists-and-tables]
- Для одного элемента — контекстное меню или меню правки, не оба сразу → [context-menus]
- Важное — в средней и нижней части экрана, свайп назад и свайп по строке для действий → [designing-for-ios]
- Аппаратная клавиатура на iPad: строка меню с теми же сочетаниями, что на Mac; команды динамических пунктов не единственный путь → [the-menu-bar], [keyboards]

**Часы**

- Digital Crown — прокрутка и навигация; нажатие зарезервировано системой; на вращение — видимый отклик; любое действие дублировать касанием → [digital-crown]
- Двойное касание: основное действие на экране управления воспроизведением — play/pause (`handGestureShortcut(.primaryAction)`), не назначать в экранах со списками и прокруткой → [gestures]
- Не конфликтовать с жестом от края экрана; простые жесты, мало касаний → [gestures]
- Always On: приглушить второстепенное, не убирать контролы, не менять раскладку, движение плавно останавливать → [always-on]

---

## iPadOS и visionOS — где отличается

- **iPadOS**: строка меню есть, скрыта до вызова, те же меню и сочетания, что на Mac; динамические пункты не единственный путь, пункт «Настройки…» ведёт в раздел Настроек iPadOS → [the-menu-bar]
- **iPadOS**: панель вкладок вверху, с кнопкой превращения в боковую панель (`sidebarAdaptable`); настраиваемая, по умолчанию не больше пяти вкладок; окна меняют размер плавно, органы управления окна могут перекрыть левые кнопки панели → [tab-bars], [windows]
- **iPadOS**: указатель — эффекты highlight/lift/hover, выбор нескольких рамкой; предпочитать форму `page` или `form` для листа; клавиатурный фокус в текстовых полях и боковых панелях (кнопки — через Full Keyboard Access) → [pointing-devices], [sheets], [keyboards]
- **visionOS**: окно со стеклом (стекло не убирать), панель инструментов внизу окна, вкладки вертикально слева, зона кнопки 60×60 pt и центры кнопок не ближе 60 pt друг к другу; лист — по центру поля зрения, не снизу окна → [windows], [toolbars], [tab-bars], [buttons], [sheets]
- **visionOS**: строки меню нет — панель инструментов должна давать всё главное при любом размере окна; контекстное меню лучше панели; громкость — Digital Crown → [toolbars], [context-menus], [digital-crown]

---

## Частые ошибки, которые проверять при аудите

1. Свои числа вместо системных полей списка: ручные `padding`, `listRowInsets`, высота строки, фон строки на Mac; нет `List`/`Table` стиля → [lists-and-tables], [layout]
2. Свой фильтр (своё текстовое поле) вместо системного поиска `.searchable`; поле не справа в панели инструментов на Mac; нет кнопки очистки, плейсхолдера с областью → [search-fields], [searching]
3. Команда есть только на кнопке, а не в строке меню Mac; нет меню «Вид» и «Окно»; пункты прячутся вместо отключения; сочетание не показано в меню → [the-menu-bar], [toolbars]
4. Список без выделения нескольких (нет `selection: Set`, ⌘A, ⇧-щелчка; на iPhone нет режима выбора) и действия недоступны для выделенного → [lists-and-tables], [keyboards]
5. Контекстное меню строки не работает на выделении («по одной строке»), отличается набором от кнопки «…», показывает сочетания, тускнеет вместо скрытия недоступного → [context-menus]
6. Кнопки меньше системной зоны: iPhone и часы — меньше 44 pt, Mac — меньше 28 pt (минимум 20); нет состояния нажатия; нет подсказки при наведении на Mac → [accessibility], [buttons]
7. **Часы**: системные кнопки панели инструментов (углы, время, заголовок) наезжают на управление воспроизведением; свои элементы добавлены в `NowPlayingView`; полноэкранный фон оттенка обложки на экране плеера → [toolbars], [color], [playing-audio]
8. Текст обрезан «…» при крупном шрифте: фиксированная высота строки, `lineLimit(1)` без запасного варианта, подписи колонок и полки, текст песни; на Mac Dynamic Type нет (HIG) — проверять стили текста и свой масштаб → [typography], [layout]
9. Панель инструментов Mac: заголовок = название приложения или длиннее 15 знаков; значки в рамках; свой фон или цвет обложки на панели; кнопок больше трёх групп; текст рядом со значком без разделителя → [toolbars]
10. Стекло в слое контента (карточки, строки, обложки) или стекло на стекле; своя подложка на панели вкладок, панели инструментов, листе, поповере; цвет акцента на подписи вместо фона → [materials], [color]
11. **Mac**: мини-плеер и важные кнопки внизу окна или внизу боковой панели без записи исключения → [layout], [windows], [sidebars]
12. Состояние только цветом (играет, недоступно, ошибка); нет повышенного контраста; контраст ниже 4.5:1 → [accessibility], [color]
13. Анимации без «Уменьшить движение» (прокрутка текста песни, зум обложки, переходы по осям); элементы, исчезающие по таймеру, как единственный путь; нет возможности прервать анимацию → [accessibility], [motion]
14. Алерт на каждое обратимое удаление; нет отмены (⌘Z, пункт «Правка > Отменить …»); «OK» вместо глагола; деструктивная кнопка по умолчанию; у алерта нет «Отменить»; больше трёх кнопок → [alerts], [feedback], [undo-and-redo]
15. Лист: «Готово» без «Отменить»; «Отменить» и «Готово» не по краям (iPhone: слева и справа); несколько листов друг на друге; на Mac лист не закрывается Esc; поповер в компактной ширине iPhone → [sheets], [popovers], [modality]
16. Громкость на iPhone — свой `Slider` вместо системного вида; свой значок или слово «AirPlay» на кнопке; нет выбора вывода звука → [sliders], [airplay], [playing-audio]
17. Боковая панель Mac: больше двух уровней; нельзя скрыть, нет «Показать/Скрыть боковую панель» в меню; значки случайных цветов не следуют акценту; вкладки iPhone спрятаны или отключены, «Ещё» → [sidebars], [tab-bars]
18. Системные сочетания заняты под своё (⌘, ⌘F, ⌘W и т. п.); свои — с ⌃ или без ⌘; команды с сочетаниями (Пробел, ⌘[) не вынесены в строку меню → [keyboards], [the-menu-bar]
19. Своя кнопка и свой лист «Поделиться» вместо `ShareLink`; своя иконка «Поделиться» → [activity-views], [icons]
20. ИИ-текст песни без пометки ИИ и без «Исправить / Отменить / Повторить» рядом с результатом → [generative-ai]

---

## Где доктрина шире HIG или расходится с ним (для реестра исключений и правки доктрины)

- §4.5 «44 pt Apple»: страница buttons даёт 44×44 pt вообще, но таблица accessibility для Mac — 28 pt (минимум 20), для iPhone и часов — 44 pt (минимум 28); в доктрине указать по платформам → [accessibility], [buttons]
- §4.1 «Крупный шрифт» на Mac: macOS не поддерживает Dynamic Type, а accessibility просит увеличение ≥ 200% «своим интерфейсом или Dynamic Type» — для Mac нужно решение проекта, проверку «самым крупным размером платформы» переформулировать → [typography], [accessibility]
- §4.4 «Недоступный пункт выключен, а не спрятан»: так в строке меню и обычных меню; в контекстном меню HIG велит прятать (Mac: исключение Cut/Copy/Paste) → [menus], [the-menu-bar], [context-menus]
- §4.4 «Сочетания видны в меню»: в основных меню — да; в контекстном меню HIG показывать их не рекомендует → [context-menus]
- §4.7 «Отменить во всплывающем сообщении»: в HIG такого компонента нет; нужна запись в `EXCEPTIONS.md` и системный путь отмены рядом → [feedback], [undo-and-redo]
- §4.2 «Наведение подсвечивает строку» и «Пробел — пауза», «Return — играть», «⌘[ — назад»: HIG для Mac этого не требует (⌘[ в его таблице занят выравниванием, Пробела в таблице нет) — конвенции Музыки/Finder/Safari → [keyboards], [pointing-devices]
- §3 «Мини-плеер»: на Mac нижняя панель противоречит правилу «не ставить управление внизу окна»; на iPhone есть системный аксессуар вкладок; на часах — системный `NowPlayingView` → [layout], [tab-bars], [playing-audio]
- ♡ вместо `hand.thumbsup` в таблице стандартных значков — решение продукта → [icons]

---

[accessibility]: https://developer.apple.com/design/human-interface-guidelines/accessibility
[action-sheets]: https://developer.apple.com/design/human-interface-guidelines/action-sheets
[activity-views]: https://developer.apple.com/design/human-interface-guidelines/activity-views
[airplay]: https://developer.apple.com/design/human-interface-guidelines/airplay
[alerts]: https://developer.apple.com/design/human-interface-guidelines/alerts
[always-on]: https://developer.apple.com/design/human-interface-guidelines/always-on
[buttons]: https://developer.apple.com/design/human-interface-guidelines/buttons
[collections]: https://developer.apple.com/design/human-interface-guidelines/collections
[color]: https://developer.apple.com/design/human-interface-guidelines/color
[context-menus]: https://developer.apple.com/design/human-interface-guidelines/context-menus
[dark-mode]: https://developer.apple.com/design/human-interface-guidelines/dark-mode
[designing-for-ios]: https://developer.apple.com/design/human-interface-guidelines/designing-for-ios
[designing-for-watchos]: https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos
[digital-crown]: https://developer.apple.com/design/human-interface-guidelines/digital-crown
[dock-menus]: https://developer.apple.com/design/human-interface-guidelines/dock-menus
[drag-and-drop]: https://developer.apple.com/design/human-interface-guidelines/drag-and-drop
[feedback]: https://developer.apple.com/design/human-interface-guidelines/feedback
[focus-and-selection]: https://developer.apple.com/design/human-interface-guidelines/focus-and-selection
[generative-ai]: https://developer.apple.com/design/human-interface-guidelines/generative-ai
[gestures]: https://developer.apple.com/design/human-interface-guidelines/gestures
[going-full-screen]: https://developer.apple.com/design/human-interface-guidelines/going-full-screen
[icons]: https://developer.apple.com/design/human-interface-guidelines/icons
[image-views]: https://developer.apple.com/design/human-interface-guidelines/image-views
[keyboards]: https://developer.apple.com/design/human-interface-guidelines/keyboards
[launching]: https://developer.apple.com/design/human-interface-guidelines/launching
[layout]: https://developer.apple.com/design/human-interface-guidelines/layout
[lists-and-tables]: https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
[loading]: https://developer.apple.com/design/human-interface-guidelines/loading
[materials]: https://developer.apple.com/design/human-interface-guidelines/materials
[menus]: https://developer.apple.com/design/human-interface-guidelines/menus
[modality]: https://developer.apple.com/design/human-interface-guidelines/modality
[motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[offering-help]: https://developer.apple.com/design/human-interface-guidelines/offering-help
[outline-views]: https://developer.apple.com/design/human-interface-guidelines/outline-views
[panels]: https://developer.apple.com/design/human-interface-guidelines/panels
[playing-audio]: https://developer.apple.com/design/human-interface-guidelines/playing-audio
[playing-haptics]: https://developer.apple.com/design/human-interface-guidelines/playing-haptics
[pointing-devices]: https://developer.apple.com/design/human-interface-guidelines/pointing-devices
[pop-up-buttons]: https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons
[popovers]: https://developer.apple.com/design/human-interface-guidelines/popovers
[progress-indicators]: https://developer.apple.com/design/human-interface-guidelines/progress-indicators
[pull-down-buttons]: https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons
[scroll-views]: https://developer.apple.com/design/human-interface-guidelines/scroll-views
[search-fields]: https://developer.apple.com/design/human-interface-guidelines/search-fields
[searching]: https://developer.apple.com/design/human-interface-guidelines/searching
[settings]: https://developer.apple.com/design/human-interface-guidelines/settings
[sf-symbols]: https://developer.apple.com/design/human-interface-guidelines/sf-symbols
[sheets]: https://developer.apple.com/design/human-interface-guidelines/sheets
[sidebars]: https://developer.apple.com/design/human-interface-guidelines/sidebars
[sliders]: https://developer.apple.com/design/human-interface-guidelines/sliders
[split-views]: https://developer.apple.com/design/human-interface-guidelines/split-views
[tab-bars]: https://developer.apple.com/design/human-interface-guidelines/tab-bars
[tab-views]: https://developer.apple.com/design/human-interface-guidelines/tab-views
[text-fields]: https://developer.apple.com/design/human-interface-guidelines/text-fields
[the-menu-bar]: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
[toggles]: https://developer.apple.com/design/human-interface-guidelines/toggles
[toolbars]: https://developer.apple.com/design/human-interface-guidelines/toolbars
[typography]: https://developer.apple.com/design/human-interface-guidelines/typography
[undo-and-redo]: https://developer.apple.com/design/human-interface-guidelines/undo-and-redo
[voiceover]: https://developer.apple.com/design/human-interface-guidelines/voiceover
[windows]: https://developer.apple.com/design/human-interface-guidelines/windows
