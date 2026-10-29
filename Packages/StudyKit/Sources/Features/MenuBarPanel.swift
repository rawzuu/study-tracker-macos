import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import Focus
import SwiftUI

/// Ikona v horní liště: symbol stavu a odpočet běžícího bloku (`MenuBarStatus`).
public struct MenuBarLabel: View {
    @Environment(MenuBarStatus.self) private var status
    let showsTime: Bool

    public init(showsTime: Bool) {
        self.showsTime = showsTime
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
            if showsTime, let title = status.title {
                Text(title).monospacedDigit()
            }
        }
        .accessibilityLabel(status.title.map { "Study Tracker, \($0)" } ?? "Study Tracker")
    }
}

/// Okénko z horní lišty: dnešek, běžící blok s ovládáním, nebo „Co teď?“ a další blok plánu –
/// všechno bez otevírání hlavního okna.
public struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @Environment(Advisor.self) private var advisor
    @Environment(FocusController.self) private var focus: FocusController?
    @Environment(\.openWindow) private var openWindow
    let openPage: (String) -> Void

    public init(openPage: @escaping (String) -> Void) {
        self.openPage = openPage
    }

    public var body: some View {
        let now = store.nowMs
        let state = DashboardState(document: store.document, now: now, clock: store.clock)
        VStack(alignment: .leading, spacing: 0) {
            today(state)
                .padding(.bottom, 14)
            Divider().overlay(Palette.line)
            Group {
                if timer.state.status == .idle {
                    nextUp(now: now)
                } else {
                    running
                }
            }
            .padding(.vertical, 14)
            if let next = nextBlock(state) {
                Divider().overlay(Palette.line)
                planRow(next).padding(.vertical, 10)
            }
            if let focus, focus.isAvailable, !focus.config.lists.isEmpty {
                Divider().overlay(Palette.line)
                focusRow(focus, now: now).padding(.vertical, 10)
            }
            Divider().overlay(Palette.line)
            footer.padding(.top, 10)
        }
        .padding(16)
        .frame(width: 340)
        .background(Palette.bg)
        .tint(Palette.accent)
    }

    // MARK: - Dnešek

    private func today(_ s: DashboardState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PageGlyphView(.today(day: store.clock.calendar.component(.day, from: store.clock.date(store.nowMs))), size: 15)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                DurationText(Format.duration(s.todaySec), size: 20)
                if s.goalSec > 0 {
                    Text(s.todaySec >= s.goalSec ? "cíl splněn" : "ze \(Format.duration(s.goalSec))").font(Typo.small).foregroundStyle(Palette.text3)
                }
                Spacer()
                if s.streak.current > 0 {
                    Text("série \(s.streak.current)").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                }
            }
            if s.goalSec > 0 {
                ProgressLine(min(1, Double(s.todaySec) / Double(s.goalSec)), color: s.todaySec >= s.goalSec ? Palette.success : Palette.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menubar.today")
    }

    // MARK: - Běžící blok

    private var running: some View {
        let state = timer.state
        let subject = state.subjectId.isEmpty ? nil : store.document.record(Subject.self, id: state.subjectId)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(state.topic.isEmpty ? subject?.name ?? "Bez předmětu" : state.topic).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                SubjectCapsule(name: subject?.name ?? "Bez předmětu", color: subject?.color ?? "#9aa3ad")
            }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                if state.status == .running, let start = state.segmentStart {
                    TimelineView(.periodic(from: Date(timeIntervalSince1970: Double(start) / 1000), by: 1)) { context in
                        clock(Int(context.date.timeIntervalSince1970 * 1000))
                    }
                } else {
                    clock(timer.currentTime())
                }
                Text(phaseLabel).font(Typo.small).foregroundStyle(Palette.text3)
            }
            TimerControls(size: .small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.timer")
    }

    private func clock(_ now: Int) -> some View {
        let state = timer.state
        return Text(Format.clock(ms: state.remaining(at: now) ?? state.elapsed(at: now)))
            .font(.system(size: 40, weight: .light).monospacedDigit())
            .foregroundStyle(state.status == .paused ? Palette.text2 : state.phase == .work ? Palette.text : Palette.breakColor)
    }

    private var phaseLabel: String {
        let s = timer.state
        let phase = switch s.status {
        case .paused: "pozastaveno"
        case .ready: s.phase == .work ? "připraveno na další blok" : "připravená pauza"
        default: s.phase == .work ? "učení" : "pauza"
        }
        return "\(phase) · \(timer.mode.name)"
    }

    // MARK: - Co teď?

    @ViewBuilder
    private func nextUp(now: Int) -> some View {
        let recs = advisor.recommendations(now: now).filter { $0.subjectId != nil }
        if let top = recs.first {
            let subject = SubjectInfo(top.subjectId, in: store.document)
            VStack(alignment: .leading, spacing: 10) {
                Text("Co teď?").font(Typo.heading).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.subject(subject.color)).frame(width: 8, height: 8)
                        Text(subject.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let context = top.context {
                        Text(context).font(.system(size: 12.5)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = top.reasons.first {
                        Text(reason).font(Typo.small).foregroundStyle(Palette.text3)
                    }
                }
                Button { start(top) } label: { Label("Začít · \(top.minutes) min", systemImage: "play.fill") }
                    .buttonStyle(.study(.primary, size: .small))
                    .accessibilityIdentifier("menubar.start")
                if recs.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(recs.dropFirst().prefix(2)) { r in alternative(r) }
                    }
                }
            }
        } else {
            Text("Zatím není co doporučit – přidej předměty, cíle nebo zkoušky.")
                .font(Typo.small).foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func alternative(_ r: Recommendation) -> some View {
        let subject = SubjectInfo(r.subjectId, in: store.document)
        return Button { start(r) } label: {
            HStack(spacing: 8) {
                ColorMark(color: subject.color)
                (Text(subject.name).fontWeight(.medium).foregroundStyle(Palette.text) + Text("  \(r.title)").foregroundStyle(Palette.text3))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(r.minutes) min").monospacedDigit().foregroundStyle(Palette.text3)
            }
            .font(.system(size: 12.5))
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(r.reasons.joined(separator: " · "))
    }

    /// Doporučení rovnou spustí – z lišty se nikam nepřepíná.
    private func start(_ r: Recommendation) {
        guard let subjectId = r.subjectId else { return }
        timer.setup(TimerSetup(subjectId: subjectId, topic: r.topic, modeId: r.modeId, planBlockId: r.planBlockId))
        timer.start()
    }

    // MARK: - Plán

    /// První neodškrtnutý blok dnešního plánu (kromě toho, který právě běží).
    private func nextBlock(_ s: DashboardState) -> DashboardState.PlanRow? {
        s.todayPlan.first { !$0.done && $0.id != timer.state.planBlockId }
    }

    private func planRow(_ b: DashboardState.PlanRow) -> some View {
        HStack(spacing: 10) {
            BlockCheck(.open)
            Text(b.time).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Palette.text2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    ColorMark(color: b.subject.color)
                    Text(b.subject.name).font(.system(size: 12.5, weight: .medium))
                }
                if !b.title.isEmpty { Text(b.title).font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(b.durationMin) min").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
            Button {
                timer.setup(TimerSetup(subjectId: b.subject.id, topic: b.topic, planBlockId: b.id))
                timer.start()
            } label: { Image(systemName: "play.fill") }
                .buttonStyle(.study(.normal, size: .small))
                .disabled(!timer.state.canSwitch)
                .help("Začít blok z plánu")
                .accessibilityLabel("Začít blok z plánu")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.plan")
    }

    // MARK: - Soustředění

    /// Co se právě blokuje a rychlý zámek (jako „Start block“ v liště blokovačů).
    private func focusRow(_ focus: FocusController, now: Int) -> some View {
        let state = focus.state(at: now)
        let running = focus.status == .running
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: state.isLocked ? "lock.fill" : "moon.circle")
                .font(.system(size: 13))
                .foregroundStyle(state.rules.isEmpty ? Palette.text3 : state.isLocked ? Palette.danger : Palette.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.rules.isEmpty ? "Nic se neblokuje" : "Blokuje: \(FocusText.names(state))")
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(focusDetail(state, running: running))
                    .font(Typo.small).foregroundStyle(Palette.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if running {
                Menu {
                    Section("Zablokovat všechny seznamy") {
                        ForEach([25, 60, 120, 240], id: \.self) { m in
                            Button("Na \(FocusText.minutes(m))") { focus.lock(minutes: m, strictness: nil, now: store.nowMs) }
                        }
                    }
                    Section("Přísně – do konce nejde zrušit") {
                        ForEach([60, 120], id: \.self) { m in
                            Button("Na \(FocusText.minutes(m))") { focus.lock(minutes: m, strictness: .strict, now: store.nowMs) }
                        }
                    }
                } label: {
                    Image(systemName: "lock")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Zablokovat teď")
                .accessibilityLabel("Zablokovat teď")
            } else {
                Button("Zapnout") { open("soustredeni") }.buttonStyle(.study(.ghost, size: .small))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.focus")
    }

    private func focusDetail(_ state: ActiveFocus, running: Bool) -> String {
        guard running else { return "Strážce je vypnutý" }
        if let until = FocusText.until(state.rules.compactMap(\.until).max()) { return until }
        return state.rules.isEmpty ? "Soustředění" : "do konce bloku"
    }

    // MARK: - Patička

    private var footer: some View {
        HStack {
            Button { open("prehled") } label: { Label("Otevřít Study Tracker", systemImage: "macwindow") }
                .buttonStyle(.study(.ghost, size: .small))
            Spacer()
            Button { open("casovac") } label: { Image(systemName: "timer") }
                .buttonStyle(.study(.ghost, size: .small))
                .help("Časovač")
                .accessibilityLabel("Časovač")
        }
    }

    private func open(_ page: String) {
        openPage(page)
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Horní lišta v Nastavení – jen pro tento Mac.
struct MenuBarSettings: View {
    @AppStorage(MenuBarPanel.shownKey) private var shown = true
    @AppStorage(MenuBarPanel.timeKey) private var time = true

    var body: some View {
        PageSection("Horní lišta") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Ukazovat Study Tracker v horní liště", isOn: $shown)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.menuBar")
                Toggle("S odpočtem běžícího bloku", isOn: $time)
                    .toggleStyle(.switch)
                    .disabled(!shown)
                Text("Z lišty spustíš doporučený blok nebo blok z plánu, pozastavíš ho a uložíš – bez otevírání okna. Když okno zavřeš, lišta dál běží.")
                    .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

extension MenuBarPanel {
    /// Klíče v UserDefaults (nastavení jen pro tento Mac).
    public static let shownKey = "st.menuBar"
    public static let timeKey = "st.menuBar.time"
}
