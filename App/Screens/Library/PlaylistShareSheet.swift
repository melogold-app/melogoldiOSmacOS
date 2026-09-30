import SwiftUI
import MelogoldCore
import MelogoldData
import MelogoldServer

/// «Поделиться» своим плейлистом (задание 0019, API §4.11): лист делает ссылку — снимок на сервере аккаунта, если сервер
/// его делает и есть вход, иначе список первых 50 видео на YouTube («Ссылка откроет первые 50 треков на YouTube») — и
/// показывает её: «Поделиться» и «Скопировать ссылку».
struct PlaylistShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlist: LibraryPlaylist

    private enum Outcome {
        case making
        case link(URL, note: LocalizedStringResource?)
        case empty
        case limit
    }

    @State private var outcome = Outcome.making

    var body: some View {
        NavigationStack {
            // Крупный шрифт: содержимое листа прокручивается (на ровном месте — по центру, как раньше)
            GeometryReader { proxy in
                ScrollView {
                    content
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle(Text("menu.share"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .task { await make() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #else
        .sheetDetents([.medium])
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 20) {
            switch outcome {
            case .making:
                ProgressView()
                    .controlSize(.large)
                Text("share.creating")
                    .foregroundStyle(.secondary)
            case .link(let url, let note):
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(verbatim: playlist.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(verbatim: url.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("share.url")
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    ShareLink(item: url, subject: Text(verbatim: playlist.name), message: Text(verbatim: playlist.name)) {
                        Label("menu.share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.copyLink(url) } label: {
                        Label("share.copyLink", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: 360)
            case .empty:
                ContentUnavailableView {
                    Label("share.empty", systemImage: "music.note.list")
                }
            case .limit:
                ContentUnavailableView {
                    Label("share.limitReached", systemImage: "link.badge.plus")
                } actions: {
                    Button("myLinks.title") {
                        dismiss()
                        model.open(.account(.myShares), in: .settings)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func make() async {
        let tracks = model.library?.library.playlistTracks(playlist.id) ?? []
        switch await model.account.sharePlaylist(name: playlist.name, tracks: tracks) {
        case .onServer(let url, _): outcome = .link(url, note: nil)
        case .onYouTube(let url, let shown, let total):
            outcome = .link(url, note: total > shown ? "share.youtubeFirst50" : nil)
        case .noTracks: outcome = .empty
        case .limitReached: outcome = .limit
        }
    }
}
