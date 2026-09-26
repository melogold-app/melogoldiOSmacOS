import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Текст в «Сейчас играет» (docs/PROMPT.md §5.7, `spec/lyrics.md` «Отображение»): текущая строка яркая, прошедшие
/// приглушены сильнее будущих, без размытия и масштаба; пословный текст загорается по словам; подпевка мельче, под
/// строкой; строки второго исполнителя дуэта — у конечного края; нажатие по строке перематывает; ручная прокрутка
/// останавливает слежение на 3 с, есть «К текущей строке»; в паузе без слов точки появляются по одной и лопаются перед
/// строкой. Нет синхронного — обычный текст.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lyrics = model.services.lyrics
        VStack(spacing: 0) {
            switch lyrics.state {
            case .loading where !lyrics.hasAny:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notFound where !lyrics.hasAny, .idle:
                ContentUnavailableView {
                    Label("lyrics.notFound", systemImage: "text.quote")
                } actions: {
                    Button("lyrics.find") { model.lyricsSearch = true }
                }
            case .offline where !lyrics.hasAny:
                ContentUnavailableView { Label("lyrics.offline", systemImage: "wifi.slash") }
            default:
                if lyrics.showingSynced {
                    SyncedLyricsView()
                } else {
                    PlainLyricsView(text: lyrics.plain ?? "")
                }
            }
            if lyrics.isCommunity {
                Text("lyrics.community")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .onAppear { if let track = model.services.player.currentTrack { lyrics.load(track) } }
        .onChange(of: model.services.player.currentTrack?.videoId) {
            if let track = model.services.player.currentTrack { lyrics.load(track) }
        }
        #if os(iOS)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = model.settings.lyricsKeepScreenOn }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }
}

/// Меню текста (docs/PROMPT.md §5.7): вид (подпись — по тому, что на экране), «Найти текст», «Редактировать текст»,
/// сдвиг ±0,1 и ±0,5 с.
struct LyricsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lyrics = model.services.lyrics
        Menu {
            if lyrics.synced != nil {
                Button {
                    lyrics.preferSynced.toggle()
                } label: {
                    if lyrics.showingSynced {
                        Label("lyrics.plainView", systemImage: "text.alignleft")
                    } else {
                        Label("lyrics.syncedView", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
            }
            Button { model.lyricsSearch = true } label: { Label("lyrics.find", systemImage: "magnifyingglass") }
            #if !os(visionOS)
            Button { model.lyricsEditor = true } label: { Label("lyrics.edit", systemImage: "pencil") }
            #endif
            if lyrics.showingSynced {
                Menu {
                    Button("lyrics.offset.minus05") { lyrics.shift(by: -500) }
                    Button("lyrics.offset.minus01") { lyrics.shift(by: -100) }
                    Button("lyrics.offset.plus01") { lyrics.shift(by: 100) }
                    Button("lyrics.offset.plus05") { lyrics.shift(by: 500) }
                    if lyrics.offsetMs != 0 {
                        Button("lyrics.offset.reset") { lyrics.shift(by: nil) }
                    }
                } label: {
                    Label {
                        Text("lyrics.offset \(OffsetFormat.label(lyrics.offsetMs))")
                    } icon: {
                        Image(systemName: "timer")
                    }
                }
            }
        } label: {
            Label("menu.more", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("lyrics.menu"))
    }
}

/// «+0,3 с» по локали.
enum OffsetFormat {
    static func label(_ ms: Int64) -> String {
        let seconds = Double(ms) / 1000
        let number = seconds.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
        return number
    }
}

struct PlainLyricsView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.title3.weight(.semibold))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
        }
        .scrollIndicators(.hidden)
    }
}

struct SyncedLyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var manualUntil: Date?
    @State private var followTick = 0

    var body: some View {
        let lyrics = model.services.lyrics
        let player = model.services.player
        let rows = lyrics.rows
        let position = lyrics.lyricsPosition(player.position)
        let active = LyricRows.activeIndex(rows, at: position)
        let following = manualUntil.map { $0 < Date() } ?? true
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 80)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        LyricRowView(row: row, index: index, active: active)
                            .id(index)
                    }
                    Color.clear.frame(height: 240)
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { manualUntil = Date().addingTimeInterval(3) }
            }
            .onChange(of: active) { _, index in
                guard manualUntil.map({ $0 < Date() }) ?? true, index >= 0 else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
            .onAppear { if active >= 0 { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.35)) } }
            .overlay(alignment: .bottom) {
                if !following, active >= 0 {
                    Button {
                        manualUntil = nil
                        withAnimation { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.35)) }
                    } label: {
                        Label("lyrics.backToCurrent", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    #if os(visionOS)
                    .glassBackgroundEffect(in: .capsule)
                    #else
                    .glassEffect(.regular.interactive(), in: .capsule)
                    #endif
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Через 3 с после ручной прокрутки кнопка уходит, слежение возвращается.
            .task(id: manualUntil) {
                guard let until = manualUntil else { return }
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 0.1))
                followTick += 1
                if active >= 0 { withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.35)) } }
            }
        }
    }
}

/// Строка текста: спетая — по словам, если есть время слов; проигрыш — три точки, пока он идёт.
private struct LyricRowView: View {
    @Environment(AppModel.self) private var model
    let row: LyricRow
    let index: Int
    let active: Int

    var body: some View {
        switch row {
        case .sung(let line):
            sung(line)
        case .interlude(let start, let end, let side):
            if index == active {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    InterludeDots(progress: progress(start, end))
                }
                .frame(maxWidth: .infinity, alignment: side == .end ? .trailing : .leading)
                .accessibilityHidden(true)
            }
        }
    }

    private func progress(_ start: Int64, _ end: Int64) -> Double {
        let position = model.services.lyrics.lyricsPosition(model.services.player.livePosition())
        return min(1, max(0, Double(position - start) / Double(max(1, end - start))))
    }

    private func sung(_ line: SyncedLine) -> some View {
        let isActive = index == active
        let isPast = index < active
        let alignment: HorizontalAlignment = line.side == .end ? .trailing : .leading
        return Button {
            let target = Double(line.startMs - model.services.lyrics.offsetMs) / 1000
            model.services.player.seek(to: max(0, target))
        } label: {
            VStack(alignment: alignment, spacing: 4) {
                if isActive, !line.words.isEmpty {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                        words(line.words, font: .title.weight(.bold))
                    }
                } else {
                    Text(verbatim: line.text)
                        .font(.title.weight(.bold))
                        .foregroundStyle(color(isActive: isActive, isPast: isPast))
                }
                if let background = line.background {
                    if isActive, background.words.count > 1 {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                            words(background.words, font: .title3.weight(.semibold))
                        }
                    } else {
                        Text(verbatim: background.text)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(color(isActive: isActive, isPast: isPast).opacity(0.8))
                    }
                }
                if let translation = line.translation {
                    Text(verbatim: translation).font(.body).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(line.side == .end ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: line.side == .end ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.25), value: isActive)
        .accessibilityLabel(Text(verbatim: line.text))
        .accessibilityHint(Text("lyrics.tapToSeek"))
    }

    /// Прошедшие строки приглушены сильнее будущих (docs/PROMPT.md §5.7).
    private func color(isActive: Bool, isPast: Bool) -> AnyShapeStyle {
        if isActive { return AnyShapeStyle(.primary) }
        return isPast ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
    }

    /// Слова загораются по времени; текущее — по мере звучания.
    private func words(_ words: [SyncedWord], font: Font) -> Text {
        let position = model.services.lyrics.lyricsPosition(model.services.player.livePosition())
        return words.reduce(Text(verbatim: "")) { text, word in
            let fill: Double = if position >= word.endMs {
                1
            } else if position <= word.startMs {
                0
            } else {
                Double(position - word.startMs) / Double(max(1, word.endMs - word.startMs))
            }
            return text + Text(verbatim: word.text).font(font).foregroundStyle(Color.primary.opacity(0.35 + 0.65 * fill))
        }
    }
}

/// Три точки проигрыша: выскакивают по одной и лопаются перед следующей строкой.
private struct InterludeDots: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                let appear = Double(index) / 3 * 0.85
                let visible = progress >= appear
                let popping = progress > 0.93
                Circle()
                    .fill(.primary)
                    .frame(width: 12, height: 12)
                    .scaleEffect(popping ? 1.6 : (visible ? 1 : 0.2))
                    .opacity(popping ? 0 : (visible ? 0.9 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: visible)
                    .animation(.easeIn(duration: 0.2), value: popping)
            }
        }
        .padding(.vertical, 8)
    }
}
