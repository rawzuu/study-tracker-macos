import AppModel
import DesignSystem
import Features
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @Environment(Navigator.self) private var navigator
    @Environment(Toasts.self) private var toasts

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            List(selection: $navigator.page) {
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
        // Šum a notifikace podle nastavení – i když se změní synchronizací z webu.
        .onChange(of: store.document.settings) { timer.syncEffects() }
        // Po bloku – ať je uživatel na kterékoli stránce.
        .sheet(isPresented: Binding(get: { timer.pendingRating != nil }, set: { if !$0 { timer.skipRating() } })) {
            if let id = timer.pendingRating { AfterBlockSheet(sessionId: id) }
        }
        .overlay(alignment: .bottom) {
            if let toast = toasts.current { ToastView(toast: toast).id(toast.id).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: toasts.current?.id)
        // Hlášky časovače (krátký blok se neukládá) jdou stejnou cestou jako ostatní.
        .onChange(of: timer.notice) { _, notice in
            guard let notice else { return }
            toasts.show(notice)
            timer.notice = nil
        }
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
            switch navigator.page ?? .prehled {
            case .prehled: DashboardView(openPage: open)
            case .casovac: TimerView()
            case .planovac: CalendarView(openPage: open)
            case .historie: HistoryView()
            case .predmety: SubjectsView()
            case .nastaveni: SettingsPage()
            case let other: PlaceholderPage(page: other)
            }
        }
    }

    private func open(_ id: String) {
        navigator.page = Page(rawValue: id) ?? navigator.page
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

/// Hláška dole v okně; s akcí „Vrátit“ zůstane déle, aby se dala stihnout.
private struct ToastView: View {
    @Environment(Toasts.self) private var toasts
    let toast: Toasts.Toast

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text).font(Typo.body)
            if toast.undo != nil {
                Button("Vrátit") { toasts.undo() }
                    .buttonStyle(.denik(.ghost, size: .small))
                    .accessibilityIdentifier("toast.undo")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, toast.undo == nil ? 16 : 6)
        .padding(.vertical, toast.undo == nil ? 10 : 4)
        .background(Palette.panel3, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.lineStrong))
        .padding(.bottom, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast")
        .task {
            try? await Task.sleep(for: .seconds(toast.undo == nil ? 4 : 6))
            toasts.dismiss(toast.id)
        }
    }
}
