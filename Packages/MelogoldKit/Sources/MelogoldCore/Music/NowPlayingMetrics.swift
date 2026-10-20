import Foundation

/// Размеры «Сейчас играет» от области целиком — одни и те же числа на всех платформах (задания 0030 §3 и 0033 §4; Linux
/// `lyrics_view::font_size_for_page` и `now_playing::wide_layout`, Windows `NowPlayingMetrics`). Здесь только числа: вид
/// меряет то, что под обложкой, и расставляет по ним.
public enum NowPlayingMetrics {
    /// Размер строки, при котором заданы поля строки (16 по бокам) и остальные размеры текста: прежний `title` iPhone.
    public static let baseLyricsSize: Double = 28
    /// Поле от края области до блока «обложка + текст» в широкой раскладке, не меньше.
    public static let wideEdge: Double = 48
    /// Промежуток между колонкой обложки и текстом в широкой раскладке.
    public static let wideGap: Double = 72
    /// Текст уже этого — уступает обложка.
    public static let minLyricsWidth: Double = 240
    /// Обложка меньше этого не показывается вовсе: в низком окне (iPhone боком, крупный шрифт) остаются управление и текст.
    public static let minCover: Double = 96

    /// Размер строки текста песни: `clamp(0,042 · H, 18, 64)`, где `H` — высота всей области «Сейчас играет», а не колонки
    /// текста. Раньше размер шёл от колонки (её ширины и высоты), а колонка меняется с раскладкой — в одном окне текст
    /// огромный, в другом мелкий, переносы прыгали. Теперь в окне любой ширины видно одно и то же число строк. Целое число
    /// точек, как у Linux: дробный размер при каждом шаге окна чуть иначе переносит строки.
    public static func lyricsSize(areaHeight: Double) -> Double {
        min(64, max(18, 0.042 * areaHeight)).rounded()
    }

    /// Ширина колонки текста в широкой раскладке: около 28 знаков (знак — примерно 0,55 размера строки) и поля строки по
    /// бокам (16 при размере 28, дальше в том же масштабе) — Windows `LyricsMaxWidth`, Linux `lyrics_column_width`.
    public static func lyricsColumnWidth(lineSize: Double) -> Double {
        28 * 0.55 * lineSize + 2 * 16 * lineSize / baseLyricsSize
    }

    /// Стороны широкой раскладки, точки.
    public struct WideLayout: Equatable, Sendable {
        /// Сторона обложки; 0 — обложки нет (не помещается).
        public var cover: Double
        /// Колонка обложки — обложка, название, полоса и кнопки: не уже ряда кнопок.
        public var column: Double
        /// Колонка текста.
        public var lyrics: Double
        /// Поле слева от колонки обложки и справа от текста — поровну.
        public var edge: Double
    }

    /// Широкая раскладка с текстом — одним блоком посередине области (Максим, 19.10 про Windows и 20.10 про Linux: «криво:
    /// альбом и лирика не по середине окна; меньший отступ от краёв, чтобы были больше, и посередине»). Раньше область
    /// делилась пополам: обложка посередине левой половины, текст — посередине правой.
    ///
    /// - обложка `min(0,66 · h, h − below, 0,36 · W)`: `h` — высота под заголовком, `below` — то, что под обложкой
    ///   (название, полоса, кнопки и промежуток до них), измеренное при ширине колонки: длинное название переносится;
    /// - текст — колонкой по ширине длинной строки (`lyricsColumnWidth`), но не шире оставшегося; узко для текста (меньше
    ///   240) — обложка уступает, но не растёт (у Linux в этом случае она могла стать больше `h − below`);
    /// - колонка обложки не уже `columnMin` — ряда кнопок под ней;
    /// - поля по краям поровну и не меньше 48, между колонками 72.
    ///
    /// Отличие от Linux: там обложка не меньше 120 и может вылезти за низ окна; здесь обложка меньше `minCover` не
    /// показывается, как и раньше на iPhone боком с крупным шрифтом.
    public static func wideLayout(width: Double, height: Double, below: Double, columnMin: Double, lineSize: Double) -> WideLayout {
        let room = max(0, width - 2 * wideEdge - wideGap)
        var cover = min(0.66 * height, height - below, 0.36 * width)
        if room - max(cover, columnMin) < minLyricsWidth {
            cover = min(cover, room - minLyricsWidth)
        }
        cover = cover >= minCover ? cover.rounded() : 0
        let column = max(cover, columnMin.rounded(.up))
        let lyrics = max(0, min(lyricsColumnWidth(lineSize: lineSize), room - column)).rounded()
        let edge = max(0, ((width - column - wideGap - lyrics) / 2).rounded(.down))
        return WideLayout(cover: cover, column: column, lyrics: lyrics, edge: edge)
    }
}
