import SwiftUI
import MelogoldCore
import MelogoldData

/// «Воспроизведение» (REWRITE §3.5.3): только то, что есть на Android, и «Сведения о потоке». Скорость — одна
/// глобальная настройка, в меню плеера её нет (docs/PROMPT.md §4). «Не гасить экран» — только iPhone и iPad.
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
            #if os(iOS)
            Toggle("settings.keepScreenOn", isOn: $settings.lyricsKeepScreenOn)
            #endif
            NavigationLink(value: Route.streamInfo) { Text("settings.streamInfo") }
        }
        Section {
            Toggle("settings.remoteControl", isOn: $settings.remoteControl)
        } footer: {
            Text("settings.remoteControl.footer")
        }
    }
}

/// «Хранилище и данные» (задания 0003 и 0009): размер кэша прослушивания 32 МБ … 8 ГБ и «Без ограничений», по умолчанию
/// 4 ГБ; у кэша прослушивания и у обложек — «X использовано (N %)» и полоса заполнения (без лимита полосы нет);
/// «Очистить кэш прослушивания». Описание — как у Android: заполнится — старое сменится новым, делать ничего не нужно, а
/// скачанное в кэш не входит. Кэш не синхронизируется и не входит в копии.
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
            CacheUsageRow(used: used, limit: settings.cacheLimit)
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
        }
        .id("settings.storage")
        Section {
            CacheUsageRow(used: Int64(artwork), limit: Int64(ArtworkSession.diskCapacity))
        } header: {
            Text("settings.artwork")
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

/// Насколько заполнен кэш (Android `CacheUsageEntry`): «640 МБ использовано (16 %)» и полоса. Без лимита (`limit == 0`) —
/// только «640 МБ использовано». Кэш освобождается сам, поэтому переполнение показывается как 100 %.
struct CacheUsageRow: View {
    let used: Int64
    /// Байт в кэше; 0 — без ограничений.
    let limit: Int64

    var body: some View {
        let size = ByteFormat.string(used)
        let fraction = limit > 0 ? min(1, max(0, Double(used) / Double(limit))) : nil
        VStack(alignment: .leading, spacing: 8) {
            if let fraction {
                Text("settings.cacheUsed.percent \(size) \(Int((fraction * 100).rounded(.down)))")
                ProgressView(value: fraction)
                    .accessibilityHidden(true)
            } else {
                Text("settings.cacheUsed.size \(size)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Копия библиотеки в «Хранилище и данные» (задание 0006): «Сохранить копию» и «Импорт копии».
struct BackupSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Button("backup.save") { model.saveBackup() }
            Button("backup.import") { model.chooseBackupToImport() }
        } header: {
            Text("backup.title")
        } footer: {
            Text("backup.importFooter")
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

/// Загрузки в «Хранилище и данные» (REWRITE §4.7.5, задание 0009): «X · N треков», «Только по Wi‑Fi», «Удалить все
/// загрузки» с вопросом. В размер и лимит кэша они не входят, «Очистить кэш» их не трогает.
struct DownloadSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var settings = model.settings
        let _ = model.library?.downloadsRevision
        let store = model.services.downloads?.store
        let count = model.library?.counts.downloads ?? 0
        let bytes = store?.totalBytes() ?? 0
        let tracks = String(localized: "library.tracks \(count)")
        Section {
            LabeledContent {
                Text(verbatim: "\(ByteFormat.string(bytes)) · \(tracks)")
            } label: {
                Text("settings.downloads")
            }
            Toggle("settings.downloadsWifiOnly", isOn: $settings.downloadsWifiOnly)
                .onChange(of: settings.downloadsWifiOnly) { _, value in model.services.downloads?.wifiOnly = value }
            Button("settings.downloadsRemoveAll", role: .destructive) { confirmRemove = true }
                .disabled(bytes == 0 && count == 0)
                .confirmationDialog(Text("settings.downloadsRemoveAll.title"), isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("downloads.delete", role: .destructive) { model.services.downloads?.removeAll() }
                } message: {
                    Text("settings.downloadsRemoveAll.message \(tracks) \(ByteFormat.string(bytes))")
                }
        } footer: {
            Text("settings.downloadsFooter")
        }
    }
}
