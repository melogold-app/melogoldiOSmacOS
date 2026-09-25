import SwiftUI
import MelogoldCore

/// Название и значок раздела — одинаковые на iPhone, iPad, Mac, Vision и часах.
extension AppSection {
    var title: LocalizedStringResource {
        switch self {
        case .trends: "section.trends"
        case .new: "section.new"
        case .library: "section.library"
        case .search: "section.search"
        case .settings: "section.settings"
        }
    }

    /// SF Symbols по смыслу значков Android (trending_up, new_releases, library_music, search, settings).
    var systemImage: String {
        switch self {
        case .trends: "chart.line.uptrend.xyaxis"
        case .new: "sparkles"
        case .library: "music.note.square.stack"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

extension ThemeMode {
    var title: LocalizedStringResource {
        switch self {
        case .system: "theme.system"
        case .light: "theme.light"
        case .dark: "theme.dark"
        }
    }

    /// `nil` — как в системе.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
