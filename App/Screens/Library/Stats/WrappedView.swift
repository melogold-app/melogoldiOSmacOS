import SwiftUI
import MelogoldCore
import MelogoldData

/// «Итоги года» на весь экран (задание 0018, Android `WrappedScreen.kt`): до шести карточек — минуты за год; трек года;
/// топ-5 исполнителей; топ-5 треков; любимый месяц и время суток; открытия. Листаются касанием (левая треть — назад),
/// стрелками и кнопками; «Поделиться» — картинка 1080×1920. Фон — оттенок обложки трека года.
struct WrappedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let year: Int

    @State private var stats: ListeningStats?
    @State private var loaded = false
    @State private var page = 0
    @State private var cover: CGImage?
    @State private var tint = ArtworkTint.brand
    @State private var shareImage: WrappedShareImage?
    @FocusState private var focused: Bool

    private var calendar: Calendar { .current }
    private var locale: Locale { .current }

    var body: some View {
        let cards = stats?.wrappedCards ?? []
        ZStack {
            LinearGradient(colors: [tint.color, tint.darker.color], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header(count: cards.count)
                if let stats, !cards.isEmpty {
                    let card = cards[min(page, cards.count - 1)]
                    cardView(card, stats)
                        .id(card)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay { tapZones(count: cards.count) }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("stats.wrapped.page \(min(page, cards.count - 1) + 1) \(cards.count)"))
                } else if loaded {
                    Text("stats.wrapped.empty")
                        .font(.title3.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer(count: cards.count)
            }
            .padding(.horizontal, 20)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .onKeyPress(.rightArrow) { step(1, count: cards.count); return .handled }
        .onKeyPress(.leftArrow) { step(-1, count: cards.count); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .task { await load() }
        .onAppear { focused = true }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 760, idealHeight: 820)
        #endif
        .accessibilityIdentifier("wrapped")
    }

    // MARK: - Оболочка

    /// Полоска прогресса, как в историях, и «Закрыть».
    private func header(count: Int) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0 ..< max(count, 1), id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index <= page ? 0.9 : 0.28))
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
            HStack {
                Text("stats.wrapped.title \(String(year))")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Label("stats.wrapped.close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wrapped.close")
            }
        }
        .padding(.top, 12)
    }

    private func footer(count: Int) -> some View {
        HStack {
            Button { step(-1, count: count) } label: {
                Label("stats.wrapped.back", systemImage: "chevron.left").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            .disabled(page == 0)
            Spacer()
            if let shareImage {
                ShareLink(item: shareImage, subject: Text("stats.share.text \(String(year))"), message: Text("stats.share.text \(String(year))"),
                          preview: SharePreview(String(localized: "stats.share.text \(String(year))"))) {
                    Label("stats.share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(tint.darker.color)
                .accessibilityIdentifier("wrapped.share")
            }
            Spacer()
            Button { step(1, count: count) } label: {
                Label("stats.wrapped.next", systemImage: "chevron.right").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            .disabled(page >= count - 1)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
    }

    /// Касание: левая треть — назад, остальное — дальше. Кнопки и «Поделиться» его не перехватывают.
    private func tapZones(count: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).onTapGesture { step(-1, count: count) }
                .frame(maxWidth: .infinity)
            Color.clear.contentShape(Rectangle()).onTapGesture { step(1, count: count) }
                .frame(maxWidth: .infinity)
                .layoutPriority(0)
                .containerRelativeFrame(.horizontal) { width, _ in width * 2 / 3 }
        }
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int, count: Int) {
        let target = page + delta
        guard (0 ..< count).contains(target) else { return }
        if reduceMotion { page = target } else { withAnimation(.easeInOut(duration: 0.25)) { page = target } }
    }

    // MARK: - Карточки

    @ViewBuilder
    private func cardView(_ card: WrappedCard, _ stats: ListeningStats) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            switch card {
            case .minutes: minutes(stats)
            case .trackOfYear: if let top = stats.topTracks.first { trackOfYear(top) }
            case .topArtists:
                list("stats.topArtists", stats.topArtists.prefix(WrappedCard.topShown).map {
                    Row(id: $0.id, title: $0.name, subtitle: nil, url: $0.thumbnailUrl, ms: $0.ms, round: true)
                })
            case .topTracks:
                list("stats.topTracks", stats.topTracks.prefix(WrappedCard.topShown).map {
                    Row(id: $0.id, title: $0.title, subtitle: $0.artist, url: $0.track.thumbnailUrl, ms: $0.ms, round: false)
                })
            case .favoriteTime: favorite(stats)
            case .discoveries: discoveries(stats)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .multilineTextAlignment(.center)
    }

    private func minutes(_ stats: ListeningStats) -> some View {
        VStack(spacing: 8) {
            Text(verbatim: stats.totalMinutes.formatted(.number.locale(locale)))
                .font(.system(size: 88, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityIdentifier("wrapped.minutes")
            Text(verbatim: Self.plural("stats.wrapped.minutes", stats.totalMinutes))
                .font(.title3.weight(.medium))
                .opacity(0.9)
            Text(verbatim: StatsFormat.listeningTime(ms: stats.totalMs, locale: locale))
                .font(.subheadline)
                .opacity(0.75)
        }
    }

    private func trackOfYear(_ top: TopTrack) -> some View {
        VStack(spacing: 14) {
            Text("stats.wrapped.track").font(.headline).opacity(0.85)
            ArtworkView(url: top.track.thumbnailUrl, size: 240)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            Text(verbatim: top.title).font(.title.weight(.bold)).lineLimit(3).minimumScaleFactor(0.7)
            if let artist = top.artist { Text(verbatim: artist).font(.title3).opacity(0.85).lineLimit(1) }
            Text(verbatim: "\(String(localized: "stats.playsCount \(top.plays)")) · \(StatsFormat.listeningTime(ms: top.ms, locale: locale))")
                .font(.subheadline)
                .opacity(0.75)
        }
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let url: String?
        let ms: Int64
        let round: Bool
    }

    private func list(_ title: LocalizedStringResource, _ rows: [Row]) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title2.weight(.bold))
            VStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        Text(verbatim: "\(index + 1)").font(.title3.weight(.bold)).monospacedDigit().frame(width: 26)
                        ArtworkView(url: row.url, size: 48, shape: row.round ? .circle : .rounded)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.title).font(.body.weight(.semibold)).lineLimit(1)
                            if let subtitle = row.subtitle { Text(verbatim: subtitle).font(.subheadline).opacity(0.8).lineLimit(1) }
                        }
                        Spacer(minLength: 4)
                        Text(verbatim: StatsFormat.listeningTime(ms: row.ms, locale: locale)).font(.subheadline).monospacedDigit().opacity(0.8)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func favorite(_ stats: ListeningStats) -> some View {
        VStack(spacing: 22) {
            if let month = stats.favoriteMonth {
                VStack(spacing: 4) {
                    Text("stats.wrapped.month").font(.headline).opacity(0.85)
                    Text(verbatim: StatsFormat.capitalizedMonth(month, calendar: calendar, locale: locale))
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            if let part = stats.favoriteDayPart {
                VStack(spacing: 4) {
                    Text("stats.wrapped.time").font(.headline).opacity(0.85)
                    Text(part.title)
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                    if let hour = stats.peakHour {
                        Text("stats.wrapped.peak \(StatsFormat.hourLabel(hour))").font(.subheadline).opacity(0.75)
                    }
                }
            }
        }
    }

    private func discoveries(_ stats: ListeningStats) -> some View {
        let discoveries = stats.discoveries
        return VStack(spacing: 14) {
            Text("stats.wrapped.discoveries").font(.headline).opacity(0.85)
            Text(verbatim: (discoveries?.count ?? 0).formatted(.number.locale(locale)))
                .font(.system(size: 88, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
            Text(verbatim: Self.plural("stats.wrapped.newTracks", discoveries?.count ?? 0)).font(.title3.weight(.medium))
            VStack(spacing: 10) {
                ForEach(Array((discoveries?.top ?? []).prefix(3).enumerated()), id: \.element.id) { _, top in
                    HStack(spacing: 12) {
                        ArtworkView(url: top.track.thumbnailUrl, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: top.title).font(.body.weight(.semibold)).lineLimit(1)
                            if let artist = top.artist { Text(verbatim: artist).font(.subheadline).opacity(0.8).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 6)
        }
    }

    /// Подпись без числа с нужной формой множественного числа: `<ключ>.<форма>`.
    static func plural(_ key: String, _ count: Int) -> String {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return Bundle.main.localizedString(forKey: "\(key).\(PluralCategory.of(count, language: language).rawValue)", value: nil, table: nil)
    }

    // MARK: - Загрузка

    private func load() async {
        guard let library = model.library?.library else { loaded = true; return }
        let calendar = calendar
        let today = calendar.date(from: DateComponents(year: year, month: 6, day: 15)) ?? Date()
        let window = StatsWindow.make(.year, today: today, calendar: calendar)
        let overrides = library.allTrackOverrides().mapValues(\.statOverride)
        let result = await Task.detached(priority: .userInitiated) {
            library.listeningStats(window: window, overrides: overrides, calendar: calendar)
        }.value
        stats = result
        loaded = true
        // Обложка трека года: из неё — оттенок фона и картинка «Поделиться»
        if let url = result.topTracks.first?.track.thumbnailUrl {
            cover = await ArtworkLoader.shared.image(Thumbnails.sized(url, px: 640))
        }
        if let cover, let found = ArtworkTint.tint(of: cover) { tint = found }
        if !result.wrappedCards.isEmpty {
            shareImage = WrappedShareImage.make(year: year, stats: result, cover: cover, tint: tint, locale: locale)
            #if DEBUG
            // -MelogoldSaveWrappedImage <путь> — готовая картинка «Поделиться» для снимка
            if let path = UserDefaults.standard.string(forKey: "MelogoldSaveWrappedImage"), let shareImage {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.copyItem(at: shareImage.url, to: URL(fileURLWithPath: path))
            }
            #endif
        }
    }
}

/// Показ «Итогов года»: на iPhone, iPad и Vision — на весь экран, на Mac — листом.
struct WrappedPresentation: ViewModifier {
    @Environment(AppModel.self) private var model

    private struct Request: Identifiable {
        let year: Int
        var id: Int { year }
    }

    func body(content: Content) -> some View {
        let binding = Binding<Request?>(get: { model.wrappedYear.map(Request.init) }, set: { model.wrappedYear = $0?.year })
        #if os(macOS)
        content.sheet(item: binding) { WrappedView(year: $0.year) }
        #else
        content.fullScreenCover(item: binding) { WrappedView(year: $0.year) }
        #endif
    }
}
