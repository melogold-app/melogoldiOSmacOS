import SwiftUI
import MelogoldCore
import MelogoldPlayback
#if os(macOS)
import AppKit
#endif

/// «Сведения о потоке» (Настройки › Воспроизведение, GLOSSARY §4.10): что играет, откуда, кодек, битрейт, размер,
/// громкость и применённое усиление, клиент извлечения и срок жизни ссылки. «Копировать» — всё текстом.
struct StreamInfoView: View {
    @Environment(AppModel.self) private var model
    @State private var details: PlayerEngine.StreamDetails?
    @State private var loaded = false

    var body: some View {
        Group {
            if let details {
                Form {
                    Section {
                        Text(verbatim: details.track.title).font(.headline)
                        if !details.track.subtitle.isEmpty {
                            Text(verbatim: details.track.subtitle).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach(rows(details), id: \.label.key) { row in
                            LabeledContent {
                                Text(verbatim: row.value).monospacedDigit()
                            } label: {
                                Text(row.label)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    Section {
                        Button("common.copy") { copy(details) }
                    }
                }
                .formStyle(.grouped)
            } else if loaded {
                ContentUnavailableView("player.nothingPlaying", systemImage: "waveform")
            } else {
                Color.clear
            }
        }
        .navigationTitle(Text("settings.streamInfo"))
        .inlineTitle()
        .task {
            // Пока экран открыт: трек мог смениться, байты — докачаться.
            while !Task.isCancelled {
                details = await model.services.player.currentStreamDetails()
                loaded = true
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private struct Row {
        let label: LocalizedStringResource
        let value: String
    }

    private func rows(_ details: PlayerEngine.StreamDetails) -> [Row] {
        let source = details.source
        var rows: [Row] = []
        // Адреса потока ещё нет — байты пока идут из кэша (трек в нём частью или целиком).
        let origin: LocalizedStringResource = source.downloaded ? "stream.source.download"
            : details.fromCache || source.info == nil ? "stream.source.cache" : "stream.source.network"
        rows.append(Row(label: "stream.source", value: String(localized: origin)))
        if let info = source.info, info.source != "cache" {
            rows.append(Row(label: "stream.client", value: info.source))
        }
        let mime = source.info?.mimeType ?? source.content?.mimeType
        if let mime {
            let codec = mime.contains("opus") ? "Opus" : mime.contains("mp4a") || mime.contains("mp4") ? "AAC" : mime
            let itag = source.info.map { " · itag \($0.itag)" } ?? ""
            rows.append(Row(label: "stream.codec", value: codec + itag))
        }
        if let bitrate = source.info?.bitrate, bitrate > 0 {
            rows.append(Row(label: "stream.bitrate", value: String(localized: "stream.kbps \(bitrate / 1000)")))
        }
        if let length = source.content?.length ?? source.info?.contentLength {
            rows.append(Row(label: "stream.size", value: ByteFormat.string(length)))
        }
        if let loudness = source.content?.loudnessDb ?? source.info?.loudnessDb {
            rows.append(Row(label: "stream.loudness", value: Self.decibels(loudness)))
        }
        rows.append(Row(label: "stream.gain", value: Self.decibels(details.gainDb)))
        if source.networkBytes > 0 {
            rows.append(Row(label: "stream.networkBytes", value: ByteFormat.string(source.networkBytes)))
        }
        if let info = source.info, !info.url.isEmpty {
            rows.append(Row(label: "stream.expires", value: info.expiresAt.formatted(.relative(presentation: .named))))
        }
        return rows
    }

    /// «−3,2 дБ» по локали.
    static func decibels(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .automatic))
        return String(localized: "stream.db \(number.replacingOccurrences(of: "-", with: "−"))")
    }

    private func copy(_ details: PlayerEngine.StreamDetails) {
        let lines = ["\(details.track.title) · \(details.track.videoId)"]
            + rows(details).map { "\(String(localized: $0.label)): \($0.value)" }
        let text = lines.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        model.toast = Toast(text: String(localized: "common.copied"))
    }
}
