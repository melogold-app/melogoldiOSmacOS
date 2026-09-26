import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Меню «…» плеера — короткое (docs/PROMPT.md §5.7, REWRITE §3.10.5 «Короче»): трек → текст (пока он показан) →
/// таймер сна → «Не показывать этот трек». Группы разделены линиями, без заголовков и вложенного «Ещё». Скорость и
/// «Сведения о потоке» — в Настройках.
struct PlayerMoreMenu: View {
    @Environment(AppModel.self) private var model
    var size: Font = .title3

    var body: some View {
        Menu {
            if let track = model.services.player.currentTrack {
                PlayerMenuItems(track: track)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(size)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("menu.more"))
    }
}

struct PlayerMenuItems: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        Section {
            Button { model.playlistPicker = PlaylistPickerRequest(tracks: [track]) } label: {
                Label("menu.addToPlaylist", systemImage: "text.badge.plus")
            }
            if model.services.downloads != nil {
                if model.library?.downloadStates[track.videoId] == .completed {
                    Button(role: .destructive) { model.removeDownload(track) } label: { Label("menu.removeDownload", systemImage: "trash") }
                } else if model.library?.downloadStates[track.videoId] == nil {
                    Button { model.download(track) } label: { Label("menu.download", systemImage: "arrow.down.circle") }
                }
            }
            Button { model.searchOtherVersions(of: track); model.showNowPlaying = false } label: {
                Label("menu.otherVersions", systemImage: "square.on.square")
            }
            Button { model.startRadio(track) } label: { Label("menu.startRadio", systemImage: "dot.radiowaves.left.and.right") }
            if track.albumId != nil {
                Button { model.showNowPlaying = false; model.openAlbum(of: track) } label: {
                    Label("menu.goToAlbum", systemImage: "square.stack")
                }
            }
            if track.primaryArtistId != nil {
                Button { model.showNowPlaying = false; model.openArtist(of: track) } label: {
                    Label(track.isVideo && track.videoType != VideoType.video ? "menu.goToChannel" : "menu.goToArtist", systemImage: "music.mic")
                }
            }
            ShareLink(item: ShareLinks.track(track)) { Label("menu.share", systemImage: "square.and.arrow.up") }
        }
        if model.lyricsVisible, model.showNowPlaying {
            Section {
                let lyrics = model.services.lyrics
                if lyrics.synced != nil {
                    Button { lyrics.preferSynced.toggle() } label: {
                        Label(lyrics.showingSynced ? "lyrics.plainView" : "lyrics.syncedView", systemImage: "text.alignleft")
                    }
                }
                Button { model.lyricsSearch = true } label: { Label("lyrics.find", systemImage: "magnifyingglass") }
                #if !os(visionOS)
                Button { model.lyricsEditor = true } label: { Label("lyrics.edit", systemImage: "pencil") }
                #endif
            }
        }
        Section {
            SleepTimerMenu()
        }
        Section {
            Button { model.hide(track) } label: { Label("menu.hide", systemImage: "eye.slash") }
        }
    }
}

/// Таймер сна: 15 · 30 · 45 · 60 мин, «До конца трека», «Выключить таймер» (REWRITE §3.10.7).
struct SleepTimerMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.services.player
        Menu {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("sleep.minutes \(minutes)") { player.setSleepTimer(minutes: minutes) }
            }
            Button("sleep.endOfTrack") { player.setSleepAtTrackEnd() }
            if player.sleepTimerEnd != nil || player.sleepAtTrackEnd {
                Divider()
                Button("sleep.off", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            Label {
                if let end = player.sleepTimerEnd {
                    Text("sleep.title.remaining \(SleepFormat.remaining(end))")
                } else if player.sleepAtTrackEnd {
                    Text("sleep.title.endOfTrack")
                } else {
                    Text("sleep.title")
                }
            } icon: {
                Image(systemName: "moon.zzz")
            }
        }
    }
}

/// Чипы плеера, когда они активны: таймер сна («☾ 23 мин» — открывает варианты) и скорость («1,25×» — ведёт
/// в Настройки).
struct PlayerChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.services.player
        HStack(spacing: 8) {
            if player.sleepTimerEnd != nil || player.sleepAtTrackEnd {
                Menu {
                    SleepTimerMenuOptions()
                } label: {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Label {
                            Text(verbatim: player.sleepTimerEnd.map(SleepFormat.remaining) ?? String(localized: "sleep.chip.endOfTrack"))
                        } icon: {
                            Image(systemName: "moon.fill")
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.fill.tertiary, in: Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel(Text("sleep.title"))
            }
            if player.speed != 1 {
                Button {
                    model.showNowPlaying = false
                    model.select(.settings)
                } label: {
                    Text(verbatim: SpeedFormat.label(Double(player.speed)))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.fill.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("settings.speed"))
            }
        }
    }
}

private struct SleepTimerMenuOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.services.player
        ForEach([15, 30, 45, 60], id: \.self) { minutes in
            Button("sleep.minutes \(minutes)") { player.setSleepTimer(minutes: minutes) }
        }
        Button("sleep.endOfTrack") { player.setSleepAtTrackEnd() }
        Divider()
        Button("sleep.off", role: .destructive) { player.cancelSleepTimer() }
    }
}
