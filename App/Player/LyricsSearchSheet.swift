import SwiftUI
import UniformTypeIdentifiers
import MelogoldCore
import MelogoldInnerTube
import MelogoldLyrics

/// «Найти текст» (docs/PROMPT.md §5.7): поиск по LRCLIB — выбранный результат становится своим текстом трека (задание
/// 0011: свой для синка, источник остаётся `lrclib`) и переезжает на другие устройства; «Импорт из файла» (`.lrc`,
/// `.ttml`, текст) — свой текст, источник `file`. Лист открыт для трека `track`, а не для того, что играет сейчас:
/// выбор и импорт пишутся именно в него.
struct LyricsSearchSheet: View {
    let track: Track
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pending: LrcLibTrack?
    @State private var query = ""
    @State private var results: [LrcLibTrack] = []
    @State private var searching = false
    @State private var failed = false
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(text: $query) { Text("lyrics.find.prompt") }
                            .onSubmit { search() }
                            .textFieldStyle(.plain)
                        if searching { ProgressView() }
                    }
                }
                Section {
                    ForEach(results) { result in
                        Button {
                            choose(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: result.trackName).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                AdaptiveStack(spacing: 6, alignment: .firstTextBaseline) {
                                    Text(verbatim: result.artistName)
                                    Text(verbatim: Durations.format(Int64(result.duration * 1000)))
                                        .monospacedDigit()
                                    if result.syncedLyrics?.nilIfBlank != nil {
                                        Text("lyrics.find.synced")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.tint.opacity(0.15), in: Capsule())
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            }
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                    }
                    if results.isEmpty, !searching, !query.isEmpty {
                        Text(failed ? "error.offline" : "search.nothingFound").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(verbatim: "LRCLIB")
                }
            }
            .navigationTitle(Text("lyrics.find"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("lyrics.import", systemImage: "doc.badge.plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.types) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
                      model.services.lyrics.importFile(text, for: track.videoId) else {
                    model.toast = Toast(text: String(localized: "lyrics.import.failed"))
                    return
                }
                model.toast = Toast(text: String(localized: "lyrics.import.done"))
                dismiss()
            }
        }
        .confirmationDialog(Text("lyrics.replace.title"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { result in
            Button("lyrics.replace.confirm", role: .destructive) { choose(result, replacingTyped: true) }
        } message: { _ in
            Text("lyrics.replace.message")
        }
        .onAppear {
            let clean = TitleCleaner.clean(title: track.title, channel: track.artistsText, videoType: track.videoType)
            query = [clean.artist, clean.title].compactMap { $0 }.joined(separator: " ")
            search()
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private static let types: [UTType] = [
        UTType(filenameExtension: "lrc") ?? .plainText, UTType(filenameExtension: "ttml") ?? .xml, .xml, .plainText,
    ]

    /// Выбранный результат заменяет текст трека; набранный или импортированный текст — только после подтверждения.
    private func choose(_ result: LrcLibTrack, replacingTyped: Bool = false) {
        switch model.services.lyrics.use(synced: result.syncedLyrics?.nilIfBlank, plain: result.plainLyrics?.nilIfBlank,
                                         for: track.videoId, replacingTyped: replacingTyped) {
        case .applied: dismiss()
        case .needsConfirmation: pending = result
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        failed = false
        let lrcLib = model.services.lyricsFetcher.lrcLib
        Task {
            do {
                results = try await lrcLib.search(text)
            } catch {
                results = []
                failed = true
            }
            searching = false
        }
    }
}
