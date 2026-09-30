import SwiftUI
import MelogoldCore
import MelogoldData

/// «Сведения о треке» (задание 0014): своё название, исполнитель и альбом поверх YouTube — на всех устройствах аккаунта.
/// В пустом поле серым то, как называет трек YouTube (оно и остаётся, пока поле пустое); под полем — «На YouTube: …».
/// «Сохранить» заменяет правку целиком, «Как на YouTube» снимает её, «Отмена» ничего не меняет.
struct TrackDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var hasOverride = false
    @FocusState private var focus: Field?

    private enum Field { case title, artist, album }

    /// Как называет трек YouTube: показанный трек помнит оригинал.
    private var original: Track { track.raw }

    var body: some View {
        NavigationStack {
            Form {
                field("details.name", text: $title, youTube: original.title, focus: .title)
                field("details.artist", text: $artist, youTube: original.artistsText, focus: .artist)
                field("details.album", text: $album, youTube: original.albumTitle, focus: .album)
                Section {
                    Button("details.reset", role: .destructive) {
                        model.library?.library.setTrackOverride(track.videoId, TrackOverride())
                        dismiss()
                    }
                    .disabled(!hasOverride)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("details.title"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("details.save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .onSubmit { advance() }
        }
        .onAppear(perform: load)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, youTube: String?, focus field: Field) -> some View {
        Section {
            TextField(label, text: text, prompt: youTube.map { Text(verbatim: $0) })
                .focused($focus, equals: field)
                .submitLabel(field == .album ? .done : .next)
                .autocorrectionDisabledForNames()
        } footer: {
            if let youTube, !youTube.isEmpty {
                Text("details.youtube \(youTube)")
                    .lineLimit(2)
            }
        }
    }

    private func advance() {
        switch focus {
        case .title: focus = .artist
        case .artist: focus = .album
        default: save()
        }
    }

    private func load() {
        let override = model.library?.library.trackOverride(track.videoId)
        title = override?.title ?? ""
        artist = override?.artistsText ?? ""
        album = override?.albumTitle ?? ""
        hasOverride = override != nil
    }

    private func save() {
        let value = TrackOverride(title: title, artistsText: artist, albumTitle: album).removingRedundant(against: original)
        model.library?.library.setTrackOverride(track.videoId, value)
        dismiss()
    }
}

private extension View {
    /// Названия и имена — не слова словаря: без автоисправления.
    func autocorrectionDisabledForNames() -> some View {
        #if os(macOS)
        self
        #else
        autocorrectionDisabled().textInputAutocapitalization(.sentences)
        #endif
    }
}

/// Окно с полем ввода для выделенного: «Новый плейлист…» и «Указать альбом…» (задание 0013). Состояние — в `AppModel`, как у
/// «Переименовать»: действие из правого щелчка и из панели не знает, где стоит список.
struct SelectionPromptModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { model.selectionPrompt != nil }, set: { if !$0 { model.selectionPrompt = nil } })) {
                TextField(text: $text) { Text(label) }
                Button("common.cancel", role: .cancel) { model.selectionPrompt = nil }
                Button(confirm) { commit() }
            }
            .onChange(of: model.selectionPrompt?.id) {
                switch model.selectionPrompt {
                case .newPlaylist(_, let name)?, .setAlbum(_, let name)?: text = name
                case nil: break
                }
            }
    }

    private var title: LocalizedStringKey {
        switch model.selectionPrompt {
        case .newPlaylist?: "library.newPlaylist"
        case .setAlbum?, nil: "selection.setAlbum.title"
        }
    }

    private var label: LocalizedStringKey {
        switch model.selectionPrompt {
        case .newPlaylist?: "playlist.name"
        case .setAlbum?, nil: "details.album"
        }
    }

    private var confirm: LocalizedStringKey {
        switch model.selectionPrompt {
        case .newPlaylist?: "playlist.create"
        case .setAlbum?, nil: "details.save"
        }
    }

    private func commit() {
        switch model.selectionPrompt {
        case .newPlaylist(let tracks, _)?: model.createPlaylist(from: tracks, name: text)
        case .setAlbum(let ids, _)?: model.setAlbum(text, for: ids)
        case nil: break
        }
        model.selectionPrompt = nil
    }
}
