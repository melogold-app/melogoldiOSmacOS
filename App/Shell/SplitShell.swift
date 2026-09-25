import SwiftUI
import MelogoldCore

/// iPad в широком окне и Mac: `NavigationSplitView` — те же пять разделов в боковой панели и одна
/// `NavigationStack` на всю колонку детали (грабли §9 п. 18: без неё у открытой страницы нет «Назад»,
/// а свой стек в каждом разделе рисует второй заголовок). Стек текущего раздела берётся из модели,
/// поэтому при переключении разделов он сохраняется.
struct SplitShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(model.section) }, set: { if let section = $0 { model.select(section) } })) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            #else
            .navigationTitle(Text(verbatim: "Melogold"))
            #endif
        } detail: {
            NavigationStack(path: model.path(for: model.section)) {
                SectionRoot(section: model.section)
            }
            .id(model.section)
        }
    }
}
