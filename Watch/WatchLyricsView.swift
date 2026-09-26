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
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                if case .sung(let line) = row {
                                    Button {
                                        player.seek(to: max(0, Double(line.startMs - lyrics.offsetMs) / 1000))
                                    } label: {
                                        Text(verbatim: line.text)
                                            .font(.headline)
                                            .foregroundStyle(index == active ? AnyShapeStyle(.primary)
                                                : index < active ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                                            .multilineTextAlignment(line.side == .end ? .trailing : .leading)
                                            .frame(maxWidth: .infinity, alignment: line.side == .end ? .trailing : .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .id(index)
                                } else if index == active {
                                    Text(verbatim: "• • •").font(.headline).foregroundStyle(.secondary).id(index)
                                }
                            }
                        }
                        .padding(.vertical, 30)
                    }
                    .onChange(of: active) { _, index in
                        if index >= 0 { withAnimation { proxy.scrollTo(index, anchor: .center) } }
                    }
                }
            } else if let plain = lyrics.plain {
                ScrollView { Text(verbatim: plain).font(.body).frame(maxWidth: .infinity, alignment: .leading) }
            } else if lyrics.state == .loading {
                ProgressView()
            } else {
                Text(lyrics.state == .offline ? "lyrics.offline" : "lyrics.notFound")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if lyrics.isCommunity {
                Text("lyrics.community").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text("player.lyrics"))
        .onAppear { if let track = player.currentTrack { lyrics.load(track) } }
        .onChange(of: player.currentTrack?.videoId) { if let track = player.currentTrack { lyrics.load(track) } }
    }
}
