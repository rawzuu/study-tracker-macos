import AppModel
import DesignSystem
import Features
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var page: Page? = .prehled

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.Group.allCases, id: \.self) { group in
                    SwiftUI.Section(group.rawValue) {
                        ForEach(visiblePages.filter { $0.group == group }) { page in
                            Text(page.title)
                                .tag(page)
                                .accessibilityIdentifier("nav.\(page.rawValue)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .automatic) { SyncStatusButton() }
                }
        }
        .preferredColorScheme(colorScheme)
        .tint(Palette.accent)
    }

    /// Stránky skryté v nastavení (`hiddenPages`) se v navigaci neukazují – jako na webu.
    private var visiblePages: [Page] {
        let hidden = Set(store.document.settings.hiddenPages)
        return Page.allCases.filter { !hidden.contains($0.rawValue) }
    }

    /// Téma ze synchronizovaného nastavení (výchozí tmavé, jako na webu).
    private var colorScheme: ColorScheme? {
        switch store.document.settings.theme {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch store.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).pageBackground()
        case .failed(let message):
            FailureView(message: message)
        case .ready:
            switch page ?? .prehled {
            case .prehled: DashboardView(openPage: open)
            case .historie: HistoryView()
            case .predmety: SubjectsView()
            case .nastaveni: SettingsPage()
            case let other: PlaceholderPage(page: other)
            }
        }
    }

    private func open(_ id: String) {
        page = Page(rawValue: id) ?? page
    }
}

/// Data na Macu se nepodařilo otevřít. Nic se nemaže – stačí aktualizovat aplikaci nebo napsat autorovi.
private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data se nepodařilo otevřít").font(Typo.pageTitle)
            Text(message).foregroundStyle(Palette.text2)
            Text("Nic se nesmazalo – data na Macu i na GitHubu zůstávají beze změny.").foregroundStyle(Palette.text3)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pageBackground()
    }
}

/// Dočasná stránka, dokud daná část nevznikne.
private struct PlaceholderPage: View {
    let page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageHeader(page.title, subtitle: "Připravuje se – milník \(page.milestone).")
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pageBackground()
        .navigationTitle(page.title)
    }
}
