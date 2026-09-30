import SwiftUI

/// Ритм экранов со списками и полками (слайс S3, docs/PROMPT.md §5.8). Поля страницы, отступы между полками и размеры
/// обложек в строках — в одном месте, чтобы Тренды, Новое, Библиотека, выдача и детальные экраны держали одну сетку.
extension Design {
    enum Layout {
        /// Между полками на экране: заголовок одной полки не липнет к карточкам предыдущей.
        static let shelfGap: CGFloat = 32
        /// Заголовок полки — содержимое полки.
        static let headerGap: CGFloat = 12
        /// Обложка в строке списка; сторона квадрата, вокруг него по 8 pt — строка в 64 pt, как в «Музыке» (у системного
        /// отступа строка была 77 pt).
        static let rowArtwork: CGFloat = 48
        static let rowPadding: CGFloat = 8
        /// Поле списка: 16 pt в узком окне, 20 pt в широком — как у заголовков секций и системных строк.
        static func rowMargin(regular: Bool) -> CGFloat { regular ? 20 : 16 }
        /// «…» в строке: зона нажатия 44 pt заходит под поле списка, а сам значок (он уже зоны на 13 pt с каждой стороны)
        /// стоит на общем поле.
        static let menuButtonSlack: CGFloat = 13
        /// Плитки библиотеки и карточки «Новый плейлист».
        static let tileRadius: CGFloat = 16
    }
}

/// Радиус обложки по стороне: строки — 5–6 pt, карточки полок и шапки — не больше 14 pt, как в системных приложениях
/// (прежние 12 % стороны давали «пузыри» у крупных карточек). Крупной обложке «Сейчас играет» радиус задаёт `Design.Radius.cover`.
extension Design.Radius {
    static func artwork(_ side: CGFloat) -> CGFloat { min(14, max(5, side * 0.09)) }
}

private struct ShelfInset: ViewModifier {
    @Environment(\.cardMetrics) private var metrics

    func body(content: Content) -> some View {
        content.padding(.horizontal, metrics.margin)
    }
}

extension View {
    /// Поля полки и заголовков на экране без `List`: те же, что у карусели (16 pt на iPhone, 20 pt на широком экране).
    /// Раньше заголовки стояли на системных 16 pt, а карточки — на 20 pt, и на iPad и Mac края не совпадали.
    func shelfInset() -> some View { modifier(ShelfInset()) }

    /// Поиск сворачивается в кнопку панели (iOS 26): поле фильтра не лежит поверх фото-шапки. Там, где модификатора нет
    /// (Mac), поле остаётся в панели инструментов.
    @ViewBuilder
    func searchMinimizedInToolbar() -> some View {
        #if os(iOS)
        searchToolbarBehavior(.minimize)
        #else
        self
        #endif
    }

    /// Разделитель строки начинается у текста, а не у края обложки — как в «Музыке» и «Подкастах».
    func rowSeparatorAtText() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// Нажатие по карточке полки: без синей подсветки, под пальцем — лёгкое затемнение.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            #if !os(macOS)
            .hoverEffect(.highlight)
            #endif
    }
}
