import AppModel
import DesignSystem
import Focus
import SwiftUI

/// Soustředění: blokování aplikací a webů a čas u obrazovky – samostatná část aplikace, jen na tomto Macu.
/// Vynucuje Strážce (pomocník na pozadí); stránka nastavuje seznamy a plány a ukazuje, co právě platí.
public struct FocusView: View {
    @Environment(FocusController.self) private var focus

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                page(metrics: PageMetrics(width: proxy.size.width), now: Int(Date().timeIntervalSince1970 * 1000))
            }
        }
        .pageBackground()
        .navigationTitle("Soustředění")
    }

    private func page(metrics: PageMetrics, now: Int) -> some View {
        let state = focus.state(at: now)
        return VStack(alignment: .leading, spacing: 40) {
            PageHeader("Soustředění", subtitle: FocusText.summary(state, enabled: focus.config.enabled, status: focus.status),
                       glyph: .symbol("moon.circle")) {}
            if let message = focus.message {
                Banner(message, systemImage: "exclamationmark.circle", tone: .warn) {
                    Button("Zavřít") { focus.message = nil }.buttonStyle(.study(.ghost, size: .small))
                }
            }
            if !focus.isAvailable {
                EmptyNote("Soustředění v tomhle sestavení nejde", systemImage: "moon.circle") {
                    Text("Chybí Strážce nebo sdílený kontejner (sestavení bez podpisu).")
                }
            } else {
                ColumnsLayout(columns: min(2, metrics.columns), spacing: 56, rowSpacing: 40) {
                    GuardSection(now: now)
                    NowSection(state: state, now: now)
                    FocusListsSection()
                    FocusPlansSection(now: now)
                }
            }
        }
        .padding(.horizontal, metrics.padding)
        .padding(.vertical, 36)
        .frame(maxWidth: 1600, alignment: .leading)
    }
}

/// Texty Soustředění (sdílené se stránkou i testy).
enum FocusText {
    static func summary(_ state: ActiveFocus, enabled: Bool, status: FocusController.GuardStatus) -> String {
        switch status {
        case .unavailable: return "Blokování aplikací a webů"
        case .off: return "Strážce je vypnutý – nic se neblokuje"
        case .starting: return "Strážce se zapíná…"
        case .running: break
        }
        guard !state.rules.isEmpty else { return enabled ? "Teď se nic neblokuje" : "Blokování je vypnuté" }
        let names = state.rules.map(\.list.name).uniqued().joined(separator: ", ")
        return "Teď blokuje: \(names)" + (until(state.rules.compactMap(\.until).max()).map { " · \($0)" } ?? "")
    }

    static func until(_ t: Int?) -> String? {
        guard let t else { return nil }
        let date = Date(timeIntervalSince1970: Double(t) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "H:mm" : "EEEE H:mm"
        return "do \(f.string(from: date))"
    }

    static func strictness(_ s: Strictness) -> String {
        if s.locked { return "Přísná" }
        var parts: [String] = []
        if s.delayMinutes > 0 { parts.append("odklad \(s.delayMinutes) min") }
        if s.typingCharacters > 0 { parts.append("opsat \(s.typingCharacters) znaků") }
        if let n = s.weeklyAllowance { parts.append("\(n)× týdně") }
        return parts.isEmpty ? "Volná" : parts.joined(separator: ", ")
    }

    static func trigger(_ t: FocusPlan.Trigger) -> String {
        switch t {
        case let .studyBlock(o): o.duringBreaks ? "během bloku učení i o přestávce" : "během bloku učení"
        case let .schedule(w): "\(w.count) časov\(w.count == 1 ? "é okno" : w.count < 5 ? "á okna" : "ých oken")"
        case .studyPlan: "během Studijního plánu"
        case let .dailyLimit(m): "po \(m) min denně"
        }
    }

    static let strictnessPresets: [(String, Strictness)] = [
        ("Volná – jen odkliknout", .soft), ("Odklad 5 minut", .delay), ("Opsat 120 znaků", .typing),
        ("3 odemknutí týdně", .allowance), ("Přísná – do konce nejde zrušit", .strict),
    ]
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Strážce a Safari

private struct GuardSection: View {
    @Environment(FocusController.self) private var focus
    let now: Int

    var body: some View {
        PageSection("Strážce") {
            VStack(alignment: .leading, spacing: 16) {
                SettingRow("Strážce na pozadí", detail: guardDetail) {
                    switch focus.status {
                    case .running:
                        Button("Vypnout") { focus.disableGuard(now: now) }.buttonStyle(.study(.normal, size: .small))
                    case .starting:
                        ProgressView().controlSize(.small)
                    case .off, .unavailable:
                        Button("Zapnout") { focus.enableGuard() }.buttonStyle(.study(.primary, size: .small))
                            .accessibilityIdentifier("focus.enableGuard")
                    }
                }
                SettingSwitch("Blokovat podle plánů", detail: "Hlavní vypínač. Přísný zámek, který už běží, platí do konce i po vypnutí.",
                              isOn: Binding(get: { focus.config.enabled }, set: { v in focus.update { $0.enabled = v } }), id: "focus.enabled")
                SettingRow("Rozšíření Safari", detail: focus.extensionActive(at: now)
                    ? "Zapnuté – weby se zablokují ještě před načtením."
                    : "Zapni ho v Safari → Nastavení → Rozšíření a povol mu přístup ke všem webům.") {
                    Button("Otevřít v Safari") { focus.openSafariExtensionSettings() }.buttonStyle(.study(.ghost, size: .small))
                }
                SettingRow("Hlídat adresu v Safari", detail: safariDetail) {
                    HStack(spacing: 6) {
                        if focus.report?.safari == .needsPermission {
                            Button("Povolit") { focus.openAutomationSettings() }.buttonStyle(.study(.ghost, size: .small))
                        }
                        Toggle("Hlídat adresu v Safari", isOn: Binding(get: { focus.config.watchSafari }, set: { v in focus.update { $0.watchSafari = v } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingSwitch("Měřit čas u obrazovky", detail: "Čas v aplikacích a na webech po hodinách, jen na tomto Macu. Bez myši a klávesnice déle než \(focus.config.tracking.idleMinutes) min se nepočítá.",
                              isOn: Binding(get: { focus.config.tracking.enabled }, set: { v in focus.update { $0.tracking.enabled = v } }))
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var guardDetail: String {
        switch focus.status {
        case .running: "Běží – blokuje i bez otevřené aplikace. Je vidět v Nastavení systému → Obecné → Položky při přihlášení."
        case .starting: "Zapíná se…"
        case .off, .unavailable: "Pomocník, který blokuje aplikace a weby. macOS ohlásí novou položku na pozadí."
        }
    }

    private var safariDetail: String {
        guard focus.config.watchSafari else { return "Vypnuto – weby blokuje jen rozšíření a čas na webech se neměří." }
        return switch focus.report?.safari {
        case .on: "Pojistka k rozšíření a měření času na webech."
        case .needsPermission: "Chybí souhlas: Nastavení systému → Soukromí a zabezpečení → Automatizace → Strážce → Safari."
        default: "Strážce se zeptá na souhlas, až poběží Safari."
        }
    }
}

// MARK: - Co platí teď

private struct NowSection: View {
    @Environment(FocusController.self) private var focus
    let state: ActiveFocus
    let now: Int

    var body: some View {
        PageSection("Teď", accessory: { Text(attemptsText) }) {
            if state.rules.isEmpty {
                Text(focus.status == .running ? "Nic se neblokuje." : "Bez Strážce se nic neblokuje.")
                    .font(Typo.body).foregroundStyle(Palette.text3).padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.rules.enumerated()), id: \.offset) { _, rule in
                        ListRow {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: rule.strictness.locked ? "lock.fill" : "circle.fill")
                                    .font(.system(size: rule.strictness.locked ? 11 : 7))
                                    .foregroundStyle(rule.strictness.locked ? Palette.danger : Palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.list.name)
                                    Text(([rule.sources.joined(separator: ", "), FocusText.strictness(rule.strictness)]).joined(separator: " · "))
                                        .font(Typo.small).foregroundStyle(Palette.text3)
                                }
                                Spacer()
                                Text(FocusText.until(rule.until) ?? "do konce bloku").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2)
                            }
                        }
                    }
                }
            }
            if let top = topAttempts, !top.isEmpty {
                Text("Nejčastěji dnes: " + top).font(Typo.small).foregroundStyle(Palette.text3).padding(.top, 6)
            }
        }
    }

    private var attemptsText: String {
        let n = focus.report?.attemptsToday.values.reduce(0, +) ?? 0
        return n == 0 ? "dnes žádný pokus" : "dnes \(n) \(n == 1 ? "pokus" : n < 5 ? "pokusy" : "pokusů")"
    }

    private var topAttempts: String? {
        focus.report?.attemptsToday.sorted { $0.value > $1.value }.prefix(3).compactMap { key, n in
            FocusTarget(key: key).map { t -> String in
                switch t {
                case let .site(host): "\(host) \(n)×"
                case let .app(id): "\(id.split(separator: ".").last.map(String.init) ?? id) \(n)×"
                }
            }
        }.joined(separator: ", ")
    }
}

// MARK: - Seznamy

private struct FocusListsSection: View {
    @Environment(FocusController.self) private var focus

    var body: some View {
        PageSection("Seznamy", accessory: {
            Menu("Přidat ze šablony") {
                ForEach([FocusTemplates.studyOnly] + FocusTemplates.all) { t in
                    Button(t.name) { add(t) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("focus.addList")
        }) {
            if focus.config.lists.isEmpty {
                Text("Zatím žádný seznam. Začni šablonou – třeba Sociální sítě a Video.").font(Typo.body).foregroundStyle(Palette.text3).padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(focus.config.lists) { list in
                    ListRow {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name)
                                Text(detail(list)).font(Typo.small).foregroundStyle(Palette.text3)
                            }
                            Spacer()
                            Menu(FocusText.strictness(list.strictness)) {
                                ForEach(FocusText.strictnessPresets, id: \.0) { name, s in
                                    Button(name) { set(list.id) { $0.strictness = s } }
                                }
                                Divider()
                                Picker("Aplikace", selection: Binding(get: { list.appAction }, set: { a in set(list.id) { $0.appAction = a } })) {
                                    Text("Schovat a ukázat obrazovku").tag(FocusList.AppAction.shield)
                                    Text("Ukončit").tag(FocusList.AppAction.quit)
                                }
                                Divider()
                                Button("Smazat seznam", role: .destructive) { remove(list.id) }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func detail(_ list: FocusList) -> String {
        let mode = list.mode == .allowOnly ? "povolit jen tyhle" : "blokovat"
        func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String { "\(n) \(n == 1 ? one : n < 5 ? few : many)" }
        return [mode, count(list.apps.count, "aplikace", "aplikace", "aplikací"), count(list.sites.count, "web", "weby", "webů")].joined(separator: " · ")
    }

    private func add(_ t: FocusTemplates.Template) {
        var list = t.makeList()
        if t.id == FocusTemplates.studyOnly.id { list.mode = .allowOnly }
        let id = list.id
        // Nový seznam se přidá i do plánů (nejčastěji je jen „během bloku učení“).
        focus.update {
            $0.lists.append(list)
            for i in $0.plans.indices { $0.plans[i].listIds.append(id) }
        }
    }

    private func set(_ id: String, _ change: (inout FocusList) -> Void) {
        focus.update { c in
            if let i = c.lists.firstIndex(where: { $0.id == id }) { change(&c.lists[i]) }
        }
    }

    private func remove(_ id: String) {
        focus.update { c in
            c.lists.removeAll { $0.id == id }
            for i in c.plans.indices { c.plans[i].listIds.removeAll { $0 == id } }
            for i in c.locks.indices { c.locks[i].listIds.removeAll { $0 == id } }
        }
    }
}

// MARK: - Plány

private struct FocusPlansSection: View {
    @Environment(FocusController.self) private var focus
    let now: Int

    var body: some View {
        PageSection("Plány", accessory: {
            Menu("Přidat") {
                Button("Během bloku učení") { add("Během učení", .studyBlock(StudyBlockOptions())) }
                Button("Během Studijního plánu") { add("Studijní plán", .studyPlan) }
                Button("Všední dny 8–16") { add("Všední dny", .schedule([TimeWindow(weekdays: [0, 1, 2, 3, 4], start: 8 * 60, end: 16 * 60)])) }
                Button("Denní limit 30 minut") { add("Denní limit", .dailyLimit(minutes: 30)) }
                Divider()
                ForEach([30, 60, 120, 240], id: \.self) { m in
                    Button("Zamknout teď na \(m < 60 ? "\(m) min" : "\(m / 60) h")") { lock(minutes: m) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(focus.config.lists.isEmpty)
            .accessibilityIdentifier("focus.addPlan")
        }) {
            if focus.config.plans.isEmpty, activeLocks.isEmpty {
                Text("Kdy blokovat: nejčastěji během bloku učení. Plán použije všechny seznamy.")
                    .font(Typo.body).foregroundStyle(Palette.text3).padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(focus.config.plans) { plan in
                    ListRow {
                        SettingRow(plan.name, detail: "\(FocusText.trigger(plan.trigger)) · \(plan.listIds.count) seznam\(plan.listIds.count == 1 ? "" : plan.listIds.count < 5 ? "y" : "ů")") {
                            HStack(spacing: 8) {
                                Toggle(plan.name, isOn: Binding(get: { plan.enabled }, set: { v in setPlan(plan.id) { $0.enabled = v } }))
                                    .labelsHidden().toggleStyle(.switch)
                                Button { focus.update { $0.plans.removeAll { $0.id == plan.id } } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.study(.ghost, size: .small)).help("Smazat plán")
                            }
                        }
                    }
                }
                ForEach(activeLocks) { lock in
                    ListRow {
                        SettingRow("Ruční zámek", detail: FocusText.until(lock.end) ?? "") {
                            Image(systemName: "lock").foregroundStyle(Palette.text3)
                        }
                    }
                }
            }
        }
    }

    private var activeLocks: [FocusLock] { focus.config.locks.filter { $0.end > now } }

    private func add(_ name: String, _ trigger: FocusPlan.Trigger) {
        focus.update { $0.plans.append(FocusPlan(name: name, listIds: $0.lists.map(\.id), trigger: trigger)) }
    }

    private func lock(minutes: Int) {
        focus.update {
            $0.locks.removeAll { $0.end <= now }
            $0.locks.append(FocusLock(listIds: $0.lists.map(\.id), start: now, end: now + minutes * 60_000))
        }
    }

    private func setPlan(_ id: String, _ change: (inout FocusPlan) -> Void) {
        focus.update { c in
            if let i = c.plans.firstIndex(where: { $0.id == id }) { change(&c.plans[i]) }
        }
    }
}
