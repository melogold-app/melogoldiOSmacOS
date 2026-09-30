import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import MelogoldCore
import MelogoldData
import MelogoldPlayback

/// «Сохранить файлом» (задание 0009, docs/PROMPT.md §4, Android `FileExport.kt`): .m4a без перекодирования, с тегами
/// и обложкой. Файл пишет свой `Mp4Writer`: DASH-m4a YouTube — фрагментированный MP4, а `AVAssetExportSession` читает его
/// целиком и удваивает длительность (§9 п. 21). Байты — из загрузок или кэша, недостающее — из сети тем же путём, что
/// плеер. Mac — в `~/Music/Melogold`, iPhone и iPad — системное окно сохранения в «Файлы».
enum FileExport {
    enum Failure: Error {
        case noFile
    }

    /// Готовый файл во временной папке.
    static func export(_ track: Track, services: Services) async throws -> URL {
        let source = try await completeFile(track, services: services)
        defer {
            if source.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: source) }
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let target = output.appendingPathComponent(fileName(track)).appendingPathExtension("m4a")
        let tags = Mp4Tags(title: track.title, artist: track.artistsText, album: track.albumTitle, cover: await cover(artwork: track.artworkURL))
        try await convert(source, to: target, tags: tags)
        return target
    }

    /// Запись файла — вне главного потока.
    @concurrent
    private static func convert(_ source: URL, to target: URL, tags: Mp4Tags) async throws {
        try Mp4Writer.write(fragmentedFile: source, to: target, tags: tags)
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

    /// Обложка для тегов: JPEG или PNG. Кадр видео 16:9 берётся серединой в квадрате (как в приложении, задание 0008),
    /// WebP и прочее — в JPEG.
    @concurrent
    private static func cover(artwork: String?) async -> Data? {
        guard let url = Thumbnails.sized(artwork, px: 1200).flatMap(URL.init(string:)),
              let (data, _) = try? await ArtworkSession.shared.data(from: url) else { return nil }
        return coverImage(data, square: Thumbnails.isWide(artwork))
    }

    nonisolated static func coverImage(_ data: Data, square: Bool) -> Data? {
        let isJPEG = data.starts(with: [0xFF, 0xD8]), isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(image.width, image.height)
        let needsCrop = square && image.width != image.height
        if (isJPEG || isPNG) && !needsCrop { return data }
        var picture = image
        if needsCrop, let cropped = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                              width: side, height: side)) {
            picture = cropped
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
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
    func saveAsFile(_ shown: Track) {
        // Теги файла — со своими названием, исполнителем и альбомом (задание 0014)
        let track = displayed(shown)
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
