import AppModel
import Core
import DesignSystem
import Engine
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
            Sidebar(pages: visiblePages, selection: $navigator.page)
                .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 280)
        } detail: {
            // Hláška je pruh pod obsahem stránky – nic nepřekrývá a obsah se na chvíli jen zkrátí zespodu.
            VStack(spacing: 0) {
                detail.frame(maxHeight: .infinity)
                if let toast = toasts.current {
                    ToastView(toast: toast)
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
            case .planovac: CalendarView(openPage: open, focus: navigator.calendarFocus)
            case .historie: HistoryView()
            case .predmety: SubjectsView()
            case .nastaveni: SettingsPage()
            case .statistiky: StatsView()
            case .report: ReportView()
            case .reflexe: ReflectionView(openPage: open)
            case let other: PlaceholderPage(page: other)
            }
        }
    }

    private func open(_ id: String) {
        navigator.page = Page(rawValue: id) ?? navigator.page
    }
}

/// Postranní panel: stránky s barevnými ikonami ve skupinách bez nadpisů, předměty s koláčkem
/// týdenního cíle a nastavení dole.
private struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    let pages: [Page]
    @Binding var selection: Page?

    var body: some View {
        let now = store.nowMs
        let day = store.clock.calendar.component(.day, from: store.clock.date(now))
        List(selection: $selection) {
            Section {
                ForEach(pages.filter { $0.group == .learning }) { row($0, day: day) }
            }
            Section {
                ForEach(pages.filter { $0.group == .overview }) { row($0, day: day) }
            }
            Section {
                if pages.contains(.predmety) { row(.predmety, day: day) }
                ForEach(subjects(now: now)) { s in
                    Button { selection = .predmety } label: {
                        Label {
                            Text(s.name).lineLimit(1)
                        } icon: {
                            ProgressPie(s.fraction, color: Palette.subject(s.color), size: 13)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(s.help)
                    .accessibilityIdentifier("nav.subject.\(s.id)")
                }
            }
            if pages.contains(.nastaveni) {
                Section { row(.nastaveni, day: day) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ page: Page, day: Int) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(page.title).accessibilityIdentifier("nav.\(page.rawValue)")
                Spacer(minLength: 4)
                trailing(page)
            }
        } icon: {
            PageGlyphView(page.glyph(day: day), size: 16)
        }
        .tag(page)
    }

    @ViewBuilder
    private func trailing(_ page: Page) -> some View {
        switch page {
        case .prehled:
            let open = openBlocksToday
            if open > 0 { Text("\(open)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.text2) }
        case .casovac:
            if timer.state.isStudying || timer.state.status == .running {
                SidebarClock()
            }
        default:
            EmptyView()
        }
    }

    /// Bloky plánu na dnešek, které ještě nejsou hotové.
    private var openBlocksToday: Int {
        let today = store.clock.startOfDay(store.nowMs)
        let tomorrow = store.clock.addDays(today, 1)
        return store.document.alive(PlanBlock.self).filter { !$0.done && $0.start >= today && $0.start < tomorrow }.count
    }

    private struct SubjectRow: Identifiable {
        let id: String
        let name: String
        let color: String
        let fraction: Double
        let help: String
    }

    /// Aktivní předměty s postupem k týdennímu cíli.
    private func subjects(now: Int) -> [SubjectRow] {
        let week = Stats.bySubject(Stats.inRange(store.document.alive(Session.self), from: store.clock.startOfWeek(now), to: now + 1))
        return store.document.alive(Subject.self).filter { !$0.archived }.map { s in
            let sec = week[s.id, default: 0], goal = s.weeklyGoalMin * 60
            return SubjectRow(id: s.id, name: s.name, color: s.color, fraction: goal > 0 ? Double(sec) / Double(goal) : 0,
                              help: goal > 0 ? "Tento týden \(Format.duration(sec)) z \(Format.duration(goal))" : "Tento týden \(Format.duration(sec))")
        }
    }
}

/// Živý čas běžícího bloku v postranním panelu (překresluje se jen tento text).
private struct SidebarClock: View {
    @Environment(TimerStore.self) private var timer

    var body: some View {
        let state = timer.state
        Group {
            if state.status == .running, let start = state.segmentStart {
                TimelineView(.periodic(from: Date(timeIntervalSince1970: Double(start) / 1000), by: 1)) { context in
                    text(Int(context.date.timeIntervalSince1970 * 1000))
                }
            } else {
                text(timer.currentTime())
            }
        }
    }

    private func text(_ now: Int) -> some View {
        let s = timer.state
        return Text(Format.clock(ms: s.remaining(at: now) ?? s.elapsed(at: now)))
            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(s.phase == .work ? Palette.accent : Palette.breakColor)
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
            PageHeader(page.title, subtitle: "Připravuje se – milník \(page.milestone).", glyph: page.glyph(day: 1))
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pageBackground()
        .navigationTitle(page.title)
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
                    .buttonStyle(.study(.ghost, size: .small))
                    // ⌘Z jako „Odvolat“ – jen dokud je hláška vidět
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Vrátit (⌘Z)")
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
