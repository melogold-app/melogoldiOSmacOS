import SwiftUI
import MelogoldCore
import MelogoldData

/// «Воспроизведение» (REWRITE §3.5.3): только то, что есть на Android. Скорость — одна глобальная настройка,
/// в меню плеера её нет (docs/PROMPT.md §4).
struct PlaybackSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let player = model.services.player
        Section("settings.playback") {
            Toggle("settings.normalize", isOn: $settings.normalization)
                .onChange(of: settings.normalization) { _, value in player.normalization = value }
            Toggle("settings.autoplay", isOn: $settings.autoplay)
                .onChange(of: settings.autoplay) { _, value in player.autoplayEnabled = value }
            Picker("settings.speed", selection: $settings.speed) {
                ForEach(AppSettings.speeds, id: \.self) { speed in
                    Text(verbatim: SpeedFormat.label(speed)).tag(speed)
                }
            }
            .onChange(of: settings.speed) { _, value in player.speed = Float(value) }
        }
    }
}

/// «Хранилище и данные» (задание 0003): размер кэша 32 МБ … 8 ГБ и «Без ограничений», по умолчанию 4 ГБ;
/// «занято X из Y» и «Очистить кэш прослушивания». Кэш не синхронизируется и не входит в копии.
struct StorageSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var used: Int64 = 0
    @State private var artwork: Int = 0
    @State private var confirmClear = false

    static let limits: [Int64] = [32 << 20, 128 << 20, 512 << 20, 1 << 30, 2 << 30, 4 << 30, 8 << 30, 0]

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Picker("settings.cacheSize", selection: $settings.cacheLimit) {
                ForEach(Self.limits, id: \.self) { limit in
                    if limit == 0 {
                        Text("settings.cacheNoLimit").tag(limit)
                    } else {
                        Text(verbatim: ByteFormat.string(limit)).tag(limit)
                    }
                }
            }
            .onChange(of: settings.cacheLimit) { _, value in
                model.services.cacheLimitChanged(value)
                refresh()
            }
            LabeledContent {
                Text(verbatim: ByteFormat.string(used))
            } label: {
                Text("settings.cacheUsed")
            }
            LabeledContent {
                Text(verbatim: ByteFormat.string(Int64(artwork)))
            } label: {
                Text("settings.artwork")
            }
            Button("settings.cacheClear", role: .destructive) { confirmClear = true }
                .disabled(used == 0)
                .confirmationDialog(Text("settings.cacheClear.title"), isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("settings.cacheClear", role: .destructive) {
                        let cache = model.services.cache
                        Task.detached {
                            cache?.clear()
                            await MainActor.run {
                                model.refreshCached()
                                refresh()
                            }
                        }
                    }
                }
        } header: {
            Text("settings.storage")
        } footer: {
            Text("settings.cacheFooter")
        }
        .task { refresh() }
    }

    private func refresh() {
        let cache = model.services.cache
        Task.detached(priority: .utility) {
            let bytes = cache?.totalBytes() ?? 0
            let artworkBytes = ArtworkSession.diskUsage
            await MainActor.run {
                used = bytes
                artwork = artworkBytes
            }
        }
    }
}

/// «1,25×» — знак «×» без пробела, дробь по локали (GLOSSARY §1.3).
enum SpeedFormat {
    static func label(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// Размер «640 МБ · 2,1 ГБ» по локали (GLOSSARY §1.3).
enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// «Библиотека и история» (docs/PROMPT.md §5.9): «Не сохранять историю», «Скрывать треки с пометкой E», «Скрытые».
struct LibrarySettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section("settings.libraryHistory") {
            Toggle("settings.historyPaused", isOn: $settings.historyPaused)
            Toggle("settings.hideExplicit", isOn: $settings.hideExplicit)
            NavigationLink(value: Route.hiddenTracks) {
                Text("settings.hidden")
            }
        }
    }
}

/// Загрузки в «Хранилище и данные»: сколько занимают, «Только по Wi‑Fi», «Удалить все загрузки» (REWRITE §4.7.5).
struct DownloadSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var settings = model.settings
        let _ = model.library?.downloadsRevision
        let store = model.services.downloads?.store
        let count = model.library?.counts.downloads ?? 0
        let bytes = store?.totalBytes() ?? 0
        Section {
            LabeledContent {
                Text(verbatim: "\(String(localized: "library.tracks \(count)")) · \(ByteFormat.string(bytes))")
            } label: {
                Text("settings.downloads")
            }
            Toggle("settings.downloadsWifiOnly", isOn: $settings.downloadsWifiOnly)
                .onChange(of: settings.downloadsWifiOnly) { _, value in model.services.downloads?.wifiOnly = value }
            Button("settings.downloadsRemoveAll", role: .destructive) { confirmRemove = true }
                .disabled(bytes == 0 && count == 0)
                .confirmationDialog(Text("settings.downloadsRemoveAll.confirm \(count) \(ByteFormat.string(bytes))"),
                                    isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("settings.downloadsRemoveAll", role: .destructive) { model.services.downloads?.removeAll() }
                }
        } footer: {
            Text("settings.downloadsFooter")
        }
    }
}
