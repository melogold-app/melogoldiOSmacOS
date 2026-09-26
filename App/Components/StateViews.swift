import SwiftUI
import MelogoldInnerTube

/// Загрузка — индикатор по центру видимой области, появляется через 300 мс, скелетонов нет (docs/PROMPT.md §5.10).
struct LoadingView: View {
    @State private var visible = false

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                visible = true
            }
    }
}

/// Ошибка экрана — тексты REWRITE §3.0 дословно (GLOSSARY §4.0) и «Повторить».
struct ErrorStateView: View {
    let kind: YouTubeError.Kind
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } actions: {
            Button("common.retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }

    private var title: LocalizedStringResource {
        switch kind {
        case .offline: "error.offline"
        case .blocked: "error.blocked"
        case .parser: "error.parser"
        case .unknown: "error.unknown"
        }
    }

    private var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .blocked: "hand.raised"
        case .parser: "exclamationmark.triangle"
        case .unknown: "exclamationmark.circle"
        }
    }
}
