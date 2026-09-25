import SwiftUI
import MelogoldCore

/// iPhone, Vision и узкое окно iPad: `TabView` с пятью разделами, у каждого свой `NavigationStack`.
/// «Поиск» — `Tab(role: .search)`: в iOS 26 система сама выносит его отдельной кнопкой к правому краю,
/// на visionOS разделы — вертикальный орнамент у левого края окна.
struct TabShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView(selection: Binding(get: { model.section }, set: { model.select($0) })) {
            Tab(value: AppSection.trends) {
                SectionStack(section: .trends)
            } label: {
                Label(AppSection.trends.title, systemImage: AppSection.trends.systemImage)
            }
            Tab(value: AppSection.new) {
                SectionStack(section: .new)
            } label: {
                Label(AppSection.new.title, systemImage: AppSection.new.systemImage)
            }
            Tab(value: AppSection.library) {
                SectionStack(section: .library)
            } label: {
                Label(AppSection.library.title, systemImage: AppSection.library.systemImage)
            }
            Tab(value: AppSection.search, role: .search) {
                SectionStack(section: .search)
            } label: {
                Label(AppSection.search.title, systemImage: AppSection.search.systemImage)
            }
            Tab(value: AppSection.settings) {
                SectionStack(section: .settings)
            } label: {
                Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
            }
        }
        // Вкладка поиска iOS 26: при выборе поле встаёт в панель вкладок внизу экрана, где до него дотягивается
        // большой палец (HIG «Search fields»). Само поле — у раздела «Поиск» (`SearchView`), не у TabView:
        // иначе оно появляется в каждом разделе.
        #if os(iOS)
        .tabViewSearchActivation(.searchTabSelection)
        #endif
    }
}

/// Стек раздела на iPhone и Vision.
struct SectionStack: View {
    let section: AppSection
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: model.path(for: section)) {
            SectionRoot(section: section)
        }
    }
}
