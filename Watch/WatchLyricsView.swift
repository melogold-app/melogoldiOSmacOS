import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Текст на часах (docs/PROMPT.md §5.6): синхронный — текущая строка яркая, прокрутка колесиком, нажатие по строке
/// перематывает; иначе обычный. Цепочка поиска та же; редактора, импорта и «Найти текст» на часах нет.
struct WatchLyricsView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let lyrics = model.services.lyrics
        let player = model.services.player
        Group {
            if lyrics.showingSynced {
                let rows = lyrics.rows
                let active = LyricRows.activeIndex(rows, at: lyrics.lyricsPosition(player.position))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                if case .sung(let line) = row {
                                    let alignment: Alignment = line.side == .end ? .trailing : .leading
                                    Button {
                                        player.seek(to: max(0, Double(line.startMs - lyrics.offsetMs) / 1000))
                                    } label: {
                                        Text(verbatim: line.text)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .multilineTextAlignment(line.side == .end ? .trailing : .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: alignment)
                                    }
                                    .buttonStyle(LyricLineStyle(distance: index - active))
                                    .id(index)
                                } else if index == active {
                                    // Проигрыш: три точки, бегущая подсветка
                                    Image(systemName: "ellipsis")
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .symbolEffect(.variableColor.iterative.reversing)
                                        .id(index)
                                }
                            }
                        }
                        .padding(.top, 6)
                        // Последние строки доходят до верха: текущая — всегда у верхнего края, как на узком экране iPhone
                        .padding(.bottom, 150)
                        .animation(.smooth(duration: 0.5), value: active)
                    }
                    .onChange(of: active) { _, index in
                        if index >= 0 { withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.04)) } }
                    }
                    .onAppear { if active >= 0 { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.04)) } }
                }
            } else if let plain = lyrics.plain {
                ScrollView {
                    Text(verbatim: plain)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if lyrics.state == .loading {
                ProgressView()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "quote.bubble")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(lyrics.state == .offline ? "lyrics.offline" : "lyrics.notFound")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if lyrics.state == .offline {
                        Button("common.retry") { lyrics.retry() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if lyrics.isCommunity {
                Text("lyrics.community").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text("player.lyrics"))
        .playerBackground()
        .onAppear { if let track = player.currentTrack { lyrics.load(track) } }
        .onChange(of: player.currentTrack?.videoId) { if let track = player.currentTrack { lyrics.load(track) } }
    }
}

/// Строка текста: текущая — яркая и крупная, соседние тише и чуть мельче, дальние ещё и слегка размыты (как в Apple Music);
/// смена текущей строки плавно перетекает, нажатие слегка сжимает строку.
private struct LyricLineStyle: ButtonStyle {
    /// Сколько строк от текущей: 0 — она, меньше нуля — спетые.
    let distance: Int

    func makeBody(configuration: Configuration) -> some View {
        let current = distance == 0
        configuration.label
            .foregroundStyle(.white)
            .opacity(current ? 1 : distance < 0 ? 0.3 : 0.55)
            .scaleEffect(current ? 1 : 0.92, anchor: .leading)
            // Размыты только дальние: ближайшая следующая строка читается, её ждут глазами
            .blur(radius: abs(distance) <= 1 ? 0 : min(Double(abs(distance) - 1) * 0.4, 1.0))
            .scaleEffect(configuration.isPressed ? 0.96 : 1, anchor: .leading)
            .animation(.smooth(duration: 0.5), value: distance)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
