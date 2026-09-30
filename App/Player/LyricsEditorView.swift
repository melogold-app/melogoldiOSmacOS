import SwiftUI
import MelogoldCore
import MelogoldLyrics
import MelogoldPlayback

/// Редактор текста (docs/PROMPT.md §5.7, `spec/lyrics.md` «Редактор», Android `lyricseditor`, модель `LyricsDraft`):
/// «Текст» — строка на строку, скобки в конце — подпевка; «Разметка» — нажатие «Отметить» во время воспроизведения
/// задаёт начало строки (или слова) под курсором, «Конец строки» оставляет паузу; сдвиг строки ±0,1 с, сторона дуэта,
/// «Отменить». Позиция — минус 150 мс на реакцию. Сохранение — TTML и обычный текст рядом, источник «свой».
/// iPhone, iPad и Mac. Редактор открыт для трека `track` и пишет только в него: пока он открыт, очередь может уйти к
/// следующему треку, и правка не должна лечь туда.
struct LyricsEditorView: View {
    let track: Track

    enum Mode: String, CaseIterable, Identifiable {
        case text, marks
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = LyricsDraft(lines: [])
    @State private var history: [LyricsDraft] = []
    @State private var text = ""
    @State private var mode: Mode = .text
    @State private var selected: Int?
    @State private var confirmDiscard = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(selection: $mode) {
                    Text("editor.text").tag(Mode.text)
                    Text("editor.marks").tag(Mode.marks)
                } label: {
                    Text("editor.mode")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()
                switch mode {
                case .text:
                    TextEditor(text: $text)
                        .font(.body)
                        .padding(.horizontal)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("editor.placeholder").foregroundStyle(.tertiary).padding(.horizontal, 24).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                case .marks:
                    marksList
                    controls
                }
            }
            .navigationTitle(Text("player.lyrics"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { if history.isEmpty && !textChanged { dismiss() } else { confirmDiscard = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }.disabled(currentDraft.lines.isEmpty)
                }
            }
            .confirmationDialog(Text("editor.discard"), isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("editor.discard.confirm", role: .destructive) { dismiss() }
            }
            .onChange(of: mode) { _, newMode in
                if newMode == .marks { commitText() } else { text = draft.toText() }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    /// Черновик с текстом из поля (в «Тексте» правка ещё не применена).
    private var currentDraft: LyricsDraft {
        mode == .text ? draft.withText(text) : draft
    }

    private var textChanged: Bool { text != draft.toText() }

    private var marksList: some View {
        ScrollViewReader { proxy in
            List(selection: $selected) {
                Picker(selection: Binding(get: { draft.timing }, set: { change(draft.withTiming($0)) })) {
                    Text("editor.byLines").tag(LyricsTiming.line)
                    Text("editor.byWords").tag(LyricsTiming.word)
                } label: {
                    Text("editor.marking")
                }
                ForEach(Array(draft.lines.enumerated()), id: \.offset) { index, line in
                    row(index, line)
                        .tag(index)
                        .id(index)
                        .contextMenu {
                            Button("editor.markFromHere") { change(draft.moved(to: index)) }
                            Button("editor.nudgeEarlier") { change(draft.nudge(index, by: -100)) }
                            Button("editor.nudgeLater") { change(draft.nudge(index, by: 100)) }
                            Button(line.side == .end ? "editor.sideStart" : "editor.sideEnd") {
                                change(draft.withSide(index, line.side == .end ? .start : .end))
                            }
                            Button("editor.clearTiming", role: .destructive) { change(draft.clearingTiming(index)) }
                        }
                }
            }
            .listStyle(.plain)
            .onChange(of: draft.cursor) { _, cursor in
                withAnimation { proxy.scrollTo(min(cursor, max(0, draft.lines.count - 1)), anchor: .center) }
            }
        }
    }

    private func row(_ index: Int, _ line: DraftLine) -> some View {
        let isCursor = index == draft.cursor
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.startMs.map(timestamp) ?? "—:—")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(line.startMs == nil ? .tertiary : .secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: line.side == .end ? .trailing : .leading, spacing: 2) {
                if draft.timing == .word, isCursor {
                    wordsLine(line)
                } else {
                    Text(verbatim: line.text).fontWeight(isCursor ? .semibold : .regular)
                }
                if let backing = line.backing {
                    Text(verbatim: backing).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: line.side == .end ? .trailing : .leading)
            if line.endMs != nil {
                Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel(Text("editor.pauseAfter"))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(isCursor ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func wordsLine(_ line: DraftLine) -> Text {
        // Одна `AttributedString`: `Text + Text` в iOS 26 устарел
        var result = AttributedString()
        for item in line.words.enumerated() {
            let marked = item.offset < line.wordStarts.count && line.wordStarts[item.offset] != nil
            let current = item.offset == draft.wordCursor
            var word = AttributedString(item.element + " ")
            word.font = .body.weight(current ? .bold : .regular)
            word.foregroundColor = marked ? Color.primary : (current ? Color.accentColor : Color.secondary)
            result.append(word)
        }
        return Text(result)
    }

    /// Играет уже другой трек: время отмечать не по чему.
    private var trackChanged: Bool { model.services.player.currentTrack?.videoId != track.videoId }

    /// «Далее» — строка, которую отметят следующей, целиком, как её написали (задание 0016 §2): без многоточия и без
    /// ограничения числа строк, с подпевкой; в режиме «Слова» — отмеченные слова цветом акцента, следующее жирным и
    /// подчёркнутым. Только очень длинная строка (выше ~200 pt) прокручивается внутри блока, с начала при каждой новой
    /// строке, — чтобы «Отметить» не уехала с экрана.
    @ViewBuilder
    private var nextBlock: some View {
        if draft.cursor < draft.lines.count {
            let line = draft.lines[draft.cursor]
            let content = VStack(alignment: .leading, spacing: Design.Space.xxs) {
                if draft.timing == .word {
                    nextWordsLine(line)
                } else {
                    Text(verbatim: line.text).font(.title3.weight(.semibold))
                }
                if let backing = line.backing {
                    Text(verbatim: backing).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text("editor.next")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Короткая строка — как есть, длинная — в прокрутке
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                        .scrollIndicators(.visible)
                }
                .frame(maxHeight: 200)
                .id(draft.cursor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func nextWordsLine(_ line: DraftLine) -> Text {
        var result = AttributedString()
        for item in line.words.enumerated() {
            let marked = item.offset < line.wordStarts.count && line.wordStarts[item.offset] != nil
            let current = item.offset == draft.wordCursor
            var word = AttributedString(item.element + " ")
            word.font = Font.title3.weight(current ? .bold : .semibold)
            word.foregroundColor = marked ? Color.accentColor : (current ? Color.primary : Color.secondary)
            if current { word.underlineStyle = .single }
            result.append(word)
        }
        return Text(result)
    }

    private var controls: some View {
        let player = model.services.player
        return VStack(spacing: Design.Space.s) {
            nextBlock
            if trackChanged {
                Label { Text("editor.trackChanged") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ControlGlassGroup {
                HStack(spacing: Design.Space.m) {
                    Button { player.seek(to: max(0, player.position - 5)) } label: {
                        Image(systemName: "gobackward.5").font(.title2).frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassCircle(48)
                    .accessibilityLabel(Text("editor.back5"))
                    PlayPauseButton(glass: GlassSpec(diameter: 56))
                    Button { undo() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.title2).frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassCircle(48)
                    .disabled(history.isEmpty)
                    .accessibilityLabel(Text("editor.undo"))
                    Button { change(draft.markEnd(position())) } label: {
                        Label("editor.lineEnd", systemImage: "pause.circle")
                            .font(.subheadline)
                            .padding(.horizontal, Design.Space.m)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .controlGlass(Capsule(), interactive: true)
                    .disabled(draft.cursor == 0 || trackChanged)
                }
            }
            .iconTypeSize()
            if let selected, draft.lines.indices.contains(selected) {
                HStack {
                    Button("editor.minus01") { change(draft.nudge(selected, by: -100)) }
                    Button("editor.plus01") { change(draft.nudge(selected, by: 100)) }
                    Button(draft.lines[selected].side == .end ? "editor.sideStart" : "editor.sideEnd") {
                        change(draft.withSide(selected, draft.lines[selected].side == .end ? .start : .end))
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
            Button {
                change(draft.mark(position()))
            } label: {
                Text(draft.cursor < draft.lines.count ? "editor.mark" : "editor.allMarked")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .prominentGlassButton()
            .controlSize(.large)
            .disabled(draft.cursor >= draft.lines.count || trackChanged)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding()
        .background(.bar)
    }

    /// Позиция с поправкой на реакцию и сдвиг текста трека.
    private func position() -> Int64 {
        Int64(model.services.player.livePosition() * 1000) - LyricsDraft.reactionMs
    }

    private func change(_ next: LyricsDraft) {
        guard next != draft else { return }
        history.append(draft)
        if history.count > 200 { history.removeFirst() }
        draft = next
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        draft = previous
    }

    private func commitText() {
        let next = draft.withText(text)
        if next != draft { change(next) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // Текст своего трека из базы, а не тот, что показан: показан может быть уже другой трек
        let content = LyricsContent(model.services.lyrics.stored(for: track.videoId))
        if let synced = content.synced {
            // Сдвиг трека становится временем текста: редактор правит то, что звучит.
            draft = LyricsDraft.from(synced).shifted(by: -content.offsetMs)
            mode = .marks
        } else {
            draft = LyricsDraft.fromText(content.plain ?? "")
            mode = .text
        }
        text = draft.toText()
        #if DEBUG
        applyDebugState()
        #endif
    }

    #if DEBUG
    /// `-MelogoldLyricsEditor marks|words|second` — сразу «Разметка»; `words` — по словам, три слова отмечены; `second` —
    /// первая строка отмечена (курсор на второй, очень длинной): снимки блока «Далее» без нажатий.
    private func applyDebugState() {
        guard let state = UserDefaults.standard.string(forKey: "MelogoldLyricsEditor"), state != "YES" else { return }
        mode = .marks
        switch state {
        case "words":
            draft = draft.withTiming(.word)
            for index in 0..<3 { draft = draft.mark(Int64(1_000 + index * 500)) }
        case "second":
            draft = draft.mark(1_000)
        default:
            break
        }
    }
    #endif

    private func save() {
        let final = currentDraft
        let lyrics = model.services.lyrics
        if let synced = final.toSyncedLyrics() {
            lyrics.saveOwn(videoId: track.videoId, synced: TtmlFormat.write(synced), plain: final.toText(), source: LyricsSources.user,
                           language: final.language)
        } else {
            lyrics.saveOwn(videoId: track.videoId, synced: nil, plain: final.toText(), source: LyricsSources.user, language: final.language)
        }
        model.toast = Toast(text: String(localized: "editor.saved"))
        dismiss()
    }

    private func timestamp(_ ms: Int64) -> String {
        let total = max(0, ms)
        return String(format: "%d:%02d.%d", total / 60_000, total / 1000 % 60, total % 1000 / 100)
    }
}
