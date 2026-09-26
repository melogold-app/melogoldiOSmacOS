import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// «Сейчас играет» (docs/PROMPT.md §5.7): обложка (нажатие — текст), название, исполнитель, ♡, ползунок перемотки,
/// ⇄ ⏮ ⏯ ⏭ ⟲, «Текст», AirPlay. В широком окне и на iPhone боком — обложка слева, управление справа (REWRITE
/// §3.10.11); с текстом — слева обложка и управление, справа текст. На узком экране текст встаёт на место обложки,
/// а название — в строку над ним. Очередь, таймер и фон по цвету обложки — в срезе 7.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let player = model.services.player
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height * 1.1
            Group {
                if let track = player.currentTrack {
                    if wide {
                        HStack(spacing: 40) {
                            if model.lyricsVisible {
                                VStack(spacing: 20) {
                                    artwork(track, side: min(proxy.size.height * 0.42, proxy.size.width * 0.3))
                                    controls(track)
                                }
                                .frame(maxWidth: 420)
                                lyricsColumn
                            } else {
                                artwork(track, side: min(proxy.size.height - 80, proxy.size.width / 2 - 60))
                                controls(track).frame(maxWidth: 440)
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 56)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.lyricsVisible {
                        VStack(spacing: 12) {
                            compactHeader(track)
                                .padding(.top, 56)
                            lyricsColumn
                            controls(track, showsTitle: false)
                                .padding(.bottom, 12)
                        }
                        .padding(.horizontal, 24)
                    } else {
                        VStack(spacing: 28) {
                            Spacer(minLength: 0)
                            artwork(track, side: min(proxy.size.width - 48, proxy.size.height * 0.5))
                            controls(track)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 24)
                    }
                } else {
                    ContentUnavailableView { Label("player.nothingPlaying", systemImage: "music.note") }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(.background)
        .overlay(alignment: .topLeading) {
            Button { dismiss(); model.showNowPlaying = false } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel(Text("common.collapse"))
            .keyboardShortcut(.cancelAction)
        }
        .sheet(isPresented: $model.lyricsSearch) { LyricsSearchSheet() }
        #if os(macOS)
        .sheet(isPresented: $model.lyricsEditor) { LyricsEditorView() }
        #elseif os(iOS)
        .fullScreenCover(isPresented: $model.lyricsEditor) { LyricsEditorView() }
        #endif
    }

    private var lyricsColumn: some View {
        LyricsPanel()
            .overlay(alignment: .topTrailing) { LyricsMenu() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func artwork(_ track: Track, side: CGFloat) -> some View {
        Button {
            withAnimation(.snappy) { model.lyricsVisible = true }
        } label: {
            NowPlayingArtwork(url: track.artworkURL, side: max(120, side))
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("player.lyrics"))
    }

    /// Узкий экран с текстом: маленькая обложка и название над текстом; нажатие по обложке — обратно к обложке.
    private func compactHeader(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { model.lyricsVisible = false }
            } label: {
                ArtworkView(url: track.artworkURL, size: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("lyrics.artwork"))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(1)
                PlayerStatusLine(font: .subheadline)
            }
            Spacer(minLength: 8)
            LikeButton(size: .title3)
        }
    }

    private func controls(_ track: Track, showsTitle: Bool = true) -> some View {
        VStack(spacing: showsTitle ? 20 : 12) {
            if showsTitle {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PlayerStatusLine(font: .title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LikeButton(size: .title2)
                }
            }
            SeekBar()
            HStack(spacing: 28) {
                ShuffleToggle(size: .title3)
                PreviousButton(size: .title)
                PlayPauseButton(size: .largeTitle)
                NextButton(size: .title)
                RepeatToggle(size: .title3)
            }
            HStack(spacing: 32) {
                Button {
                    withAnimation(.snappy) { model.lyricsVisible.toggle() }
                } label: {
                    Image(systemName: model.lyricsVisible ? "quote.bubble.fill" : "quote.bubble")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.lyricsVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(Text("player.lyrics"))
                RoutePickerButton()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text("player.airplay"))
            }
        }
    }
}

/// Большая обложка «Сейчас играет» (задание 0008): кадр видео — целиком, прямоугольником 16:9 той же ширины;
/// песня и обложка сингла из видео-«статики» (после срезки полей она квадратная) — квадрат. Форма — по картинке
/// после срезки полей: шире 1,2:1 — прямоугольник.
struct NowPlayingArtwork: View {
    let url: String?
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var wide = false

    var body: some View {
        ArtworkView(url: url, size: side, shape: wide ? .wide : .rounded)
            .animation(.snappy, value: wide)
            .task(id: url) {
                wide = false
                guard Thumbnails.isWide(url) else { return }
                let sized = Thumbnails.sized(url, px: Int((side * displayScale).rounded(.up)))
                if let image = await ArtworkLoader.shared.image(sized) {
                    wide = Double(image.width) > Double(image.height) * 1.2
                }
            }
    }
}
