import SwiftUI
import MelogoldCore

/// Строка трека (docs/PROMPT.md §5.8): обложка (у видео квадратная), название, исполнитель и альбом, справа длительность
/// и метки — E, «скачано», «в кэше», «YouTube». У играющего трека вместо обложки — значок «играет».
struct TrackRow: View {
    let track: Track
    var subtitle: String?
    var isCurrent = false
    var cached = false
    var dimmed = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(url: track.artworkURL, size: 48)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .frame(width: 48, height: 48)
                    // Столбики под реальный звук — срез 7 (docs/PROMPT.md §4); до тех пор значок стоит.
                    Image(systemName: "waveform")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                let line = subtitle ?? track.subtitle
                if !line.isEmpty {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            badges
            if let duration = track.durationLabel {
                Text(duration)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(dimmed || track.unavailable ? 0.38 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if track.explicit {
                Image(systemName: "e.square.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("badge.explicit"))
            }
            if cached {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("badge.cached"))
            }
            if track.isVideo {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: "YouTube"))
            }
        }
        .font(.footnote)
    }
}

/// Строка видео в выдаче YouTube (REWRITE §3.11.2): превью 16:9 с длительностью или «В ЭФИРЕ», название до двух строк,
/// «канал · просмотры». Строки из ответа YouTube только показываются, числа из них не разбираются.
struct VideoRow: View {
    let track: Track
    var isCurrent = false
    var dimmed = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(url: track.artworkURL, size: 114, shape: .wide)
                if track.videoType == VideoType.live {
                    Text("badge.live")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(4)
                } else if let duration = track.durationLabel {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                Text([track.artistsText, track.viewsText].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .opacity(dimmed ? 0.38 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Строка альбома, исполнителя или плейлиста.
struct CollectionRow: View {
    let item: MusicItem

    var body: some View {
        HStack(spacing: 12) {
            switch item {
            case .album(let album):
                ArtworkView(url: album.thumbnailUrl, size: 48)
                labels(album.title, album.subtitle)
            case .artist(let artist):
                ArtworkView(url: artist.thumbnailUrl, size: 48, shape: .circle)
                labels(artist.name, artist.subtitle ?? "")
            case .playlist(let playlist):
                ArtworkView(url: playlist.thumbnailUrl, size: 48)
                labels(playlist.title, playlist.subtitle ?? "")
            case .mood(let mood):
                labels(mood.title, "")
            case .track(let track):
                TrackRow(track: track)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func labels(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body).lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
