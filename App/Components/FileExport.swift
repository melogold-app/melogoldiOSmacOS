import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import MelogoldCore
import MelogoldData
import MelogoldPlayback

/// «Сохранить файлом» (docs/PROMPT.md §4, Android `FileExport.kt`): .m4a без перекодирования, с тегами и обложкой —
/// `AVAssetExportSession` passthrough с метаданными. Байты — из загрузок или кэша, недостающее — из сети тем же путём,
/// что плеер. Mac — в `~/Music/Melogold`, iPhone и iPad — системное окно сохранения в «Файлы».
enum FileExport {
    enum Failure: Error {
        case noFile, exportFailed(String)
    }

    /// Готовый файл во временной папке.
    static func export(_ track: Track, services: Services) async throws -> URL {
        let source = try await completeFile(track, services: services)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.exportFailed("нет сеанса экспорта")
        }
        let name = fileName(track)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let target = output.appendingPathComponent(name).appendingPathExtension("m4a")
        session.metadata = await metadata(track)
        try await session.export(to: target, as: .m4a)
        if source.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: source) }
        return target
    }

    /// «Исполнитель — Название» без символов, которые файловая система не любит.
    static func fileName(_ track: Track) -> String {
        let raw = [track.artistsText, track.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ")
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
    }

    /// Файл трека целиком: скачанный, из кэша или собранный из сети во временную папку.
    private static func completeFile(_ track: Track, services: Services) async throws -> URL {
        if let downloads = services.downloads, downloads.store.isComplete(track.videoId) {
            return downloads.store.fileURL(track.videoId)
        }
        if let cache = services.cache, cache.isComplete(track.videoId) {
            return cache.fileURL(track.videoId)
        }
        let source = StreamSource(videoId: track.videoId, resolver: services.resolver, cache: services.cache,
                                  session: URLSession(configuration: .ephemeral))
        let length = try await source.contentInfo().length
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(track.videoId)-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < length {
            let data = try await source.read(offset: offset, length: Int(min(Int64(1 << 20), length - offset)))
            guard !data.isEmpty else { throw Failure.noFile }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
        }
        return file
    }

    private static func metadata(_ track: Track) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func item(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) {
            let metadata = AVMutableMetadataItem()
            metadata.identifier = identifier
            metadata.value = value
            metadata.extendedLanguageTag = "und"
            items.append(metadata)
        }
        item(.commonIdentifierTitle, track.title as NSString)
        if let artist = track.artistsText { item(.commonIdentifierArtist, artist as NSString) }
        if let album = track.albumTitle { item(.commonIdentifierAlbumName, album as NSString) }
        if let url = Thumbnails.sized(track.artworkURL, px: 1200).flatMap(URL.init(string:)),
           let (data, _) = try? await ArtworkSession.shared.data(from: url) {
            item(.commonIdentifierArtwork, data as NSData)
        }
        return items
    }

    #if os(macOS)
    /// Mac: `~/Music/Melogold`, имя без повторов.
    static func saveToMusic(_ file: URL) throws -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Melogold", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let base = file.deletingPathExtension().lastPathComponent
        var target = music.appendingPathComponent(file.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = music.appendingPathComponent("\(base) \(counter).m4a")
            counter += 1
        }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
    #endif
}

/// Готовый .m4a для системного окна сохранения (iPhone, iPad).
struct ExportedAudio: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Audio] }
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

extension AppModel {
    /// «Сохранить файлом»: на Mac — сразу в «Музыку», на iPhone и iPad — окно «Файлов».
    func saveAsFile(_ track: Track) {
        toast = Toast(text: String(localized: "export.preparing"))
        Task {
            do {
                let file = try await FileExport.export(track, services: services)
                #if os(macOS)
                let saved = try FileExport.saveToMusic(file)
                toast = Toast(text: String(localized: "export.savedMusic"), actionTitle: "export.show") {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                }
                #else
                exportedFile = ExportedAudio(url: file)
                toast = nil
                #endif
            } catch {
                Log.warning("export", "\(track.videoId): \(error)")
                toast = Toast(text: String(localized: "export.failed"))
            }
        }
    }
}
