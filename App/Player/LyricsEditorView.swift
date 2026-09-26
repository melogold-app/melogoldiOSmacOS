import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Редактор текста (docs/PROMPT.md §5.7, `spec/lyrics.md` «Редактор», Android `lyricseditor`, модель `LyricsDraft`):
/// «Текст» — строка на строку, скобки в конце — подпевка; «Разметка» — нажатие «Отметить» во время воспроизведения
/// задаёт начало строки (или слова) под курсором, «Конец строки» оставляет паузу; сдвиг строки ±0,1 с, сторона дуэта,
/// «Отменить». Позиция — минус 150 мс на реакцию. Сохранение — TTML и обычный текст рядом, источник «свой».
/// iPhone, iPad и Mac.
struct LyricsEditorView: View {
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
        line.words.enumerated().reduce(Text(verbatim: "")) { result, item in
            let marked = item.offset < line.wordStarts.count && line.wordStarts[item.offset] != nil
            let current = item.offset == draft.wordCursor
            let word = Text(verbatim: item.element + " ")
                .fontWeight(current ? .bold : .regular)
                .foregroundStyle(marked ? Color.primary : (current ? Color.accentColor : Color.secondary))
            return result + word
        }
    }

    private var controls: some View {
        let player = model.services.player
        return VStack(spacing: 10) {
            HStack(spacing: 20) {
                Button { player.seek(to: max(0, player.position - 5)) } label: {
                    Image(systemName: "gobackward.5").font(.title2)
                }
                .accessibilityLabel(Text("editor.back5"))
                PlayPauseButton(size: .title)
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward").font(.title2) }
                    .disabled(history.isEmpty)
                    .accessibilityLabel(Text("editor.undo"))
                Button { change(draft.markEnd(position())) } label: {
                    Label("editor.lineEnd", systemImage: "pause.circle").font(.subheadline)
                }
                .disabled(draft.cursor == 0)
            }
            .buttonStyle(.borderless)
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(draft.cursor >= draft.lines.count)
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
        let lyrics = model.services.lyrics
        if let synced = lyrics.synced {
            // Сдвиг трека становится временем текста: редактор правит то, что звучит.
            draft = LyricsDraft.from(synced).shifted(by: -lyrics.offsetMs)
            mode = .marks
        } else {
            draft = LyricsDraft.fromText(lyrics.plain ?? "")
            mode = .text
        }
        text = draft.toText()
    }

    private func save() {
        let final = currentDraft
        let lyrics = model.services.lyrics
        if let synced = final.toSyncedLyrics() {
            lyrics.saveOwn(synced: TtmlFormat.write(synced), plain: final.toText(), source: LyricsSources.user, language: final.language)
        } else {
            lyrics.saveOwn(synced: nil, plain: final.toText(), source: LyricsSources.user, language: final.language)
        }
        model.toast = Toast(text: String(localized: "editor.saved"))
        dismiss()
    }

    private func timestamp(_ ms: Int64) -> String {
        let total = max(0, ms)
        return String(format: "%d:%02d.%d", total / 60_000, total / 1000 % 60, total % 1000 / 100)
    }
}
