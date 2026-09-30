import SwiftUI

/// Дизайн-основа Melogold (docs/PROMPT.md §5.1, docs/RELEASE-PLAN.md — слайс S2). Одна шкала отступов, радиусов и
/// размеров, типографика на системных стилях (Dynamic Type), стекло только у слоя управления и правила значков.
///
/// **Стекло (Liquid Glass, HIG «Materials»).** Стеклом рисуются панели, кнопки управления, мини-плеер и листы — слой
/// навигации и управления, который лежит над контентом. Контент (строки списков, текст песни, обложки) стеклом не
/// рисуется. Своё стекло — через `controlGlass` и `glassCircle` ниже: на visionOS они превращаются в стекло окна.
///
/// **Значки.** SF Symbols, системный шрифт. Значки управления одноцветные (`.primary`); акцентом (`.tint`, системным)
/// подсвечивается только включённое — перемешивание, повтор, «Текст», «Очередь». Многослойные значки (AirPlay) —
/// иерархическая раскраска системы. Единственный «цветной» значок — заполненное сердце `♥` избранного (`.pink`).
/// Синими в строках не бывает ничего, кроме действий, — кнопка «…» строки нейтральная.
///
/// **Отклик.** Ключевые действия отвечают `sensoryFeedback`: play и pause, следующий и предыдущий трек, ♡, включение
/// режимов, начало и конец перемотки.
enum Design {
    /// Шаг сетки — 4 pt.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        /// Мелкие обложки и метки.
        static let small: CGFloat = 8
        /// Подложка строки текста песни (задание 0012).
        static let medium: CGFloat = 12
        /// Крупная обложка «Сейчас играет».
        static let cover: CGFloat = 20
        /// Плавающая панель воспроизведения Mac.
        static let bar: CGFloat = 22
    }

    enum Size {
        /// Минимальная зона нажатия (HIG «Buttons»).
        static let minTap: CGFloat = 44
        /// Круги нажатия кнопок транспорта «Сейчас играет» (значок — половина круга): обычный и компактный вид (текст
        /// песни, низкое окно).
        static let playButton: CGFloat = 80
        static let skipButton: CGFloat = 64
        static let compactPlayButton: CGFloat = 64
        static let compactSkipButton: CGFloat = 52
        /// Стеклянные круги ♡ и «…» у названия.
        static let actionCircle: CGFloat = 38
    }
}

// MARK: - Типографика

extension Font {
    /// Название и исполнитель на «Сейчас играет»; шаг вверх на широких экранах — у вызывающего.
    static let playerTitle = Font.title2.weight(.bold)
    static let playerArtist = Font.title3
    /// Время у полосы перемотки.
    static let playerTime = Font.footnote.monospacedDigit()
}

// MARK: - Стекло

extension View {
    /// Стекло слоя управления в форме `shape`. На visionOS — стекло окна.
    @ViewBuilder
    func controlGlass<S: InsettableShape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: shape)
        #else
        glassEffect(makeGlass(interactive: interactive, tint: tint), in: shape)
        #endif
    }

    /// Круглая кнопка управления на стекле: диаметр `diameter`, зона нажатия — весь круг. С `id` и пространством имён
    /// участвует в морфинге внутри `ControlGlassGroup` (кнопки одного вида перетекают друг в друга).
    @ViewBuilder
    func glassCircle(_ diameter: CGFloat, id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        let base = frame(width: diameter, height: diameter).contentShape(Circle())
        #if os(visionOS)
        base.glassBackgroundEffect(in: Circle())
        #else
        if let id, let namespace {
            base.glassEffect(.regular.interactive(), in: Circle()).glassEffectID(id, in: namespace)
        } else {
            base.glassEffect(.regular.interactive(), in: Circle())
        }
        #endif
    }
}

#if !os(visionOS)
private func makeGlass(interactive: Bool, tint: Color?) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    return interactive ? glass.interactive() : glass
}
#endif

extension View {
    /// Главная кнопка экрана на стекле (`glassProminent`); на visionOS такого стиля нет — `borderedProminent`.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        #if os(visionOS)
        buttonStyle(.borderedProminent)
        #else
        buttonStyle(.glassProminent)
        #endif
    }
}

/// Группа стеклянных элементов: система рисует близкие фигуры одной каплей и морфит появление и исчезновение
/// (`GlassEffectContainer`). На visionOS — просто содержимое.
struct ControlGlassGroup<Content: View>: View {
    var spacing: CGFloat = Design.Space.xs
    @ViewBuilder var content: Content

    var body: some View {
        #if os(visionOS)
        content
        #else
        GlassEffectContainer(spacing: spacing) { content }
        #endif
    }
}

// MARK: - Значки

extension View {
    /// Значок управления: одноцветный, акцентом (системным) — только когда включён; `muted` — выключенный приглушён.
    func controlSymbol(active: Bool = false, muted: Bool = false) -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    /// Значки не растут вместе с крупным шрифтом дальше, чем помещаются в ряд: подписи и время растут без границ.
    func iconTypeSize() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
