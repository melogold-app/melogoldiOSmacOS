import SwiftUI

/// Доступность (слайс S8, docs/PROMPT.md §5.10): крупный Dynamic Type, «Уменьшение движения», «Повышенная контрастность».
/// Общие приёмы в одном месте, чтобы экраны не решали это каждый по-своему.

// MARK: - Крупный Dynamic Type

/// Ряд, который на размерах доступности (AX1–AX5) встаёт столбцом: подпись и кнопка рядом не помещаются и ломаются по
/// слогам («Недав-ние», «Очи-стить»), в столбце каждый элемент получает всю ширину. Пружинящие `Spacer` между ними ставит
/// `AdaptiveSpacer`: в столбце его нет.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat?
    /// Выравнивание элементов поперёк: в ряду — по вертикали, в столбце — по горизонтали.
    var alignment: VerticalAlignment = .center
    var columnAlignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: columnAlignment, spacing: spacing) { content }
        } else {
            HStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}

/// Пружина ряда `AdaptiveStack`: на размерах доступности (столбец) её нет.
struct AdaptiveSpacer: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var minLength: CGFloat = 0

    var body: some View {
        if !typeSize.isAccessibilitySize { Spacer(minLength: minLength) }
    }
}

extension View {
    /// Минимальная зона нажатия (HIG «Buttons»): 44 × 44 pt на сенсорных экранах и Vision, 28 pt на Mac (там нажимает
    /// указатель). Видимое не меняется — растут зона нажатия и рамка доступности.
    func tapTarget(_ side: CGFloat = Design.Size.hitTarget) -> some View {
        frame(minWidth: side, minHeight: side).contentShape(Rectangle())
    }
}

extension View {
    /// Высоты листа. На размерах доступности — только во весь экран: на половине высоты от формы или очереди видна одна строка.
    func sheetDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(SheetDetents(detents: detents))
    }
}

private struct SheetDetents: ViewModifier {
    let detents: Set<PresentationDetent>
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            // iPad: карточка листа на AX тоже высокая (`.page`), а не форма 540 × 620
            content
                .presentationDetents([.large])
                .presentationSizing(.page)
        } else {
            content.presentationDetents(detents)
        }
    }
}

// MARK: - Уменьшение движения

extension Design {
    /// «Уменьшение движения» включено в системе. Для `withAnimation` и переходов вне представления; у представления
    /// читать `\.accessibilityReduceMotion` — он обновится сам.
    @MainActor
    static var reduceMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }
}

/// `withAnimation`, который уважает «Уменьшение движения»: без неё — без анимации (HIG «Motion»: остаются смены состояний,
/// которые происходят затуханием, а не движением).
@MainActor
func withMotion<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Design.reduceMotion ? nil : animation, body)
}

extension View {
    /// `animation(_:value:)`, который уважает «Уменьшение движения» и обновляется вместе с ним.
    func motion<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// Появление снизу с затуханием; при «Уменьшении движения» — только затухание.
    func slideUpTransition() -> some View {
        modifier(SlideUpTransition())
    }

    /// Смена значка (▶ ↔ ⏸, ♡ ↔ ♥) с эффектом SF Symbols; при «Уменьшении движения» значок меняется сразу.
    func symbolReplace() -> some View {
        modifier(SymbolReplace())
    }
}

private struct SymbolReplace: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }
}

private struct MotionAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct SlideUpTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Контраст

extension Design {
    /// Цвет строки текста песни вне фокуса. Прошедшие приглушены сильнее будущих (docs/PROMPT.md §5.7), но обе читаются:
    /// у прежних `.secondary` и `.tertiary` на оттенке обложки выходило 3,2 и 1,8 к 1. При «Повышенной контрастности» обе
    /// ярче ещё на ступень.
    static func lyricsDim(past: Bool, increasedContrast: Bool) -> Color {
        Color.primary.opacity(increasedContrast ? (past ? 0.65 : 0.85) : (past ? 0.46 : 0.7))
    }

    /// Второстепенный текст и значки на оттенке обложки («Сейчас играет»): системный `.secondary` на нём — 3,2 к 1 (светлая
    /// тема) и 2,7 к 1 (тёмная, светлый верх оттенка), ниже порога; здесь — 6,4–7,1 к 1 (светлая) и 4,4–8,7 к 1 (тёмная),
    /// при «Повышенной контрастности» 8,5–11 к 1.
    static func secondaryOnTint(increasedContrast: Bool, dark: Bool) -> Color {
        Color.primary.opacity(increasedContrast ? 0.9 : (dark ? 0.85 : 0.66))
    }
}

extension EnvironmentValues {
    /// `Design.secondaryOnTint` для текущей темы и контрастности: значок или текст читают цвет из окружения и сами
    /// перекрашиваются при смене темы.
    var secondaryOnTint: Color {
        Design.secondaryOnTint(increasedContrast: colorSchemeContrast == .increased, dark: colorScheme == .dark)
    }
}

extension View {
    /// Второстепенный текст на оттенке обложки (см. `Design.secondaryOnTint`).
    func secondaryOnTint() -> some View { modifier(SecondaryOnTint()) }
}

private struct SecondaryOnTint: ViewModifier {
    @Environment(\.secondaryOnTint) private var color

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }
}

extension Design.Size {
    /// Зона нажатия мелких кнопок: 44 pt на iPhone, iPad и Vision, 28 pt на Mac.
    static var hitTarget: CGFloat {
        #if os(macOS)
        28
        #else
        minTap
        #endif
    }
}
