import AppKit
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
            // Hláška je pod obsahem a ve vlastním pohledu AppKitu: na macOS 26 se plocha pro klik vnořené
            // rolovací oblasti (týdenní mřížka) neořízne podle stránky a vybíhá pod obsah – klik na „Vrátit“
            // by jinak dostal schovaný blok kalendáře.
            VStack(spacing: 0) {
                detail.frame(maxHeight: .infinity)
                if let toast = toasts.current {
                    ToastHost(toast: toast, toasts: toasts)
                        .id(toast.id)
                        .frame(maxWidth: .infinity)
                        .background(Palette.bg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: toasts.current?.id)
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

/// Hláška ve vlastním `NSHostingView` – AppKit ho řadí nad rolovací oblasti stránky, takže klik dostane vždy ona.
private struct ToastHost: NSViewRepresentable {
    let toast: Toasts.Toast
    let toasts: Toasts

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        NSHostingView(rootView: content)
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    private var content: AnyView {
        AnyView(ToastView(toast: toast).environment(toasts))
    }
}

/// Hláška dole v okně; s akcí „Vrátit“ zůstane déle (7 s jako na webu) a pod myší nezmizí.
private struct ToastView: View {
    @Environment(Toasts.self) private var toasts
    let toast: Toasts.Toast
    @State private var hovering = false

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
        .padding(.top, 10)
        .padding(.bottom, 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast")
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard !hovering else { return }
            do {
                try await Task.sleep(for: .seconds(toast.undo == nil ? 4 : 7))
            } catch {
                return // myš se vrátila nad hlášku – odpočet začne znovu
            }
            toasts.dismiss(toast.id)
        }
    }
}
