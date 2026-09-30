import SwiftUI
import MelogoldCore
import MelogoldServer

/// «Мои ссылки» (задание 0019, API §4.11): снимки своих плейлистов, которыми делились, — название, число треков, дата;
/// «Скопировать ссылку» и «Удалить ссылку» (ссылка перестаёт открываться, плейлист в библиотеке остаётся).
struct MySharesView: View {
    @Environment(AppModel.self) private var model
    @State private var shares: [ShareDto] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var deleting: ShareDto?

    var body: some View {
        List {
            if !shares.isEmpty {
                Section {
                    ForEach(shares) { share in
                        row(share)
                    }
                } footer: {
                    Text("myLinks.text")
                }
            }
        }
        .playerBarClearance()
        .overlay {
            if !loaded {
                LoadingView()
            } else if failed, shares.isEmpty {
                ContentUnavailableView {
                    Label("myLinks.error", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("common.retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if shares.isEmpty {
                ContentUnavailableView {
                    Label("myLinks.title", systemImage: "link")
                } description: {
                    Text("myLinks.empty")
                }
            }
        }
        .navigationTitle(Text("myLinks.title"))
        .inlineTitle()
        .confirmationDialog(Text("share.deleteTitle"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { share in
            Button("share.deleteLink", role: .destructive) { Task { await delete(share) } }
        } message: { share in
            Text("share.deleteText \(share.name)")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ share: ShareDto) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: share.name).lineLimit(1)
            Text(verbatim: subtitle(share))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu { actions(share) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = share } label: { Label("share.deleteLink", systemImage: "trash") }
            Button { copy(share) } label: { Label("share.copyLink", systemImage: "link") }
                .tint(.accentColor)
        }
        .accessibilityAction(named: Text("share.copyLink")) { copy(share) }
        .accessibilityAction(named: Text("share.deleteLink")) { deleting = share }
    }

    @ViewBuilder
    private func actions(_ share: ShareDto) -> some View {
        Button { copy(share) } label: { Label("share.copyLink", systemImage: "link") }
        if let url = URL(string: share.url) {
            ShareLink(item: url, subject: Text(verbatim: share.name), message: Text(verbatim: share.name)) {
                Label("menu.share", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button(role: .destructive) { deleting = share } label: { Label("share.deleteLink", systemImage: "trash") }
    }

    /// «12 треков · 30 сентября 2026».
    private func subtitle(_ share: ShareDto) -> String {
        let count = String(localized: "library.tracks \(share.tracks.count)")
        guard let date = IsoTime.date(share.createdAt) else { return count }
        return count + " · " + date.formatted(date: .abbreviated, time: .omitted)
    }

    private func copy(_ share: ShareDto) {
        if let url = URL(string: share.url) { model.copyLink(url) }
    }

    private func load() async {
        do {
            shares = try await model.account.shares().shares
            failed = false
        } catch {
            failed = true
        }
        loaded = true
    }

    private func delete(_ share: ShareDto) async {
        do {
            try await model.account.deleteShare(share.shareId)
            shares.removeAll { $0.shareId == share.shareId }
            model.toast = Toast(text: String(localized: "share.linkDeleted"))
        } catch let error as APIError where error.code == "share_not_found" {
            shares.removeAll { $0.shareId == share.shareId }
        } catch {
            model.toast = Toast(text: String(localized: "share.deleteFailed"))
        }
    }
}
